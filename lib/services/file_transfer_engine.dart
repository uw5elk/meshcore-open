/// Drives [FileSendPlan] / [FileReassembler] over a transport: retransmission
/// rounds for outgoing files, STATUS replies and job tracking for incoming
/// ones.
///
/// Pure Dart. The connector-facing side is the injected [FileBlobSender].
library;

import 'dart:async';
import 'dart:typed_data';

import 'file_compression.dart';
import 'file_transfer_protocol.dart';

/// Sends [blobs] in order as GRP_DATA of type [dataTypeFileTransfer] on
/// [channelIndex]; returns false when the transport is unavailable. May throw.
typedef FileBlobSender =
    Future<bool> Function(
      List<Uint8List> blobs,
      int channelIndex,
      void Function(int sent, int total)? onProgress,
    );

/// [FileTransferJob.error] of a send that nobody ever answered.
const String kFileErrorNoResponse = 'no response';

/// [FileTransferJob.error] of a partly received file whose sender went quiet.
const String kFileErrorExpired = 'transfer expired';

enum FileJobStatus {
  /// Outgoing: transmitting a burst of blobs.
  sending,

  /// Outgoing: burst sent, waiting for the receiver's STATUS.
  waitingForStatus,

  /// Incoming: chunks are arriving.
  receiving,

  /// Outgoing: the receiver confirmed a verified copy.
  delivered,

  /// Incoming: the file arrived and passed its CRC-32.
  received,

  failed,

  cancelled,
}

class FileTransferJob {
  final int id;
  final bool outgoing;
  final int channelIndex;
  final DateTime startedAt;

  String name;
  int size;
  FileJobStatus status;

  /// Outgoing: blobs sent in the current burst.
  int sentBlobs = 0;
  int totalBlobs = 0;

  /// Outgoing: retransmission rounds used so far (0 = first burst).
  int round = 0;

  /// Incoming: chunks held and the file's chunk count (null before the OFFER).
  int receivedChunks = 0;
  int? totalChunks;

  /// Incoming, once [status] is [FileJobStatus.received].
  Uint8List? data;
  String? error;

  /// Outgoing: the original file, kept so the bubble can show a preview and a
  /// failed transfer can be retried. Released when the job is dismissed.
  Uint8List? sourceData;

  /// Outgoing: whether the original send allowed zlib compression.
  bool sourceCompress = true;

  FileTransferJob({
    required this.id,
    required this.outgoing,
    required this.channelIndex,
    required this.name,
    required this.size,
    required this.status,
    required this.startedAt,
  });

  bool get isActive =>
      status == FileJobStatus.sending ||
      status == FileJobStatus.waitingForStatus ||
      status == FileJobStatus.receiving;

  /// 0..1 progress of the current phase.
  double get fraction {
    if (outgoing) {
      return totalBlobs == 0 ? 0 : sentBlobs / totalBlobs;
    }
    final total = totalChunks;
    if (total == null || total == 0) return 0;
    return receivedChunks / total;
  }
}

/// The bytes that go on the air for one file.
class PreparedFile {
  /// Sent verbatim: the zlib stream when [compressed], else the file itself.
  final Uint8List wire;
  final bool compressed;
  final int originalSize;

  const PreparedFile({
    required this.wire,
    required this.compressed,
    required this.originalSize,
  });
}

/// Compresses [data] when that makes it smaller. Throws [ArgumentError] for an
/// empty file, one above [kFileMaxOriginalBytes], or one that still exceeds
/// [kFileMaxBytes] after compression.
PreparedFile prepareFileForSend(Uint8List data, {bool compress = true}) {
  if (data.isEmpty) {
    throw ArgumentError.value(data.length, 'data', 'file is empty');
  }
  if (data.length > kFileMaxOriginalBytes) {
    throw ArgumentError.value(
      data.length,
      'data',
      'exceeds kFileMaxOriginalBytes ($kFileMaxOriginalBytes)',
    );
  }
  if (compress) {
    final packed = deflateBytes(data);
    if (packed != null &&
        packed.length < data.length &&
        packed.length <= kFileMaxBytes) {
      return PreparedFile(
        wire: packed,
        compressed: true,
        originalSize: data.length,
      );
    }
  }
  if (data.length > kFileMaxBytes) {
    throw ArgumentError.value(
      data.length,
      'data',
      'exceeds kFileMaxBytes ($kFileMaxBytes) and does not compress below it',
    );
  }
  return PreparedFile(wire: data, compressed: false, originalSize: data.length);
}

/// Thrown from the progress callback to stop a burst that is still being
/// transmitted when the user cancels, instead of letting it run to the end.
class _SendAborted implements Exception {
  const _SendAborted();
}

class _OutgoingState {
  final FileSendPlan plan;
  Completer<FileStatus?>? waiter;
  bool cancelled = false;

  _OutgoingState(this.plan);
}

class FileTransferEngine {
  final FileBlobSender sendBlobs;

  /// Local sender prefix (first 2 bytes of the public key); null until known.
  int? get selfPrefix => _reassembler.selfPrefix;
  set selfPrefix(int? value) => _reassembler.selfPrefix = value;

  /// How long to wait for a STATUS after a burst before probing again.
  final Duration statusWait;

  /// Retransmission rounds after the first burst before giving up.
  final int maxRounds;

  /// Silent rounds (no STATUS at all) tolerated when no receiver has ever
  /// answered this file: past that, nobody is listening and probing on only
  /// wastes airtime. Once any STATUS has arrived, [maxRounds] applies instead.
  final int maxSilentRounds;

  /// Wait for the first answers while no receiver has been heard yet; null
  /// means [statusWait]. A receiver replies within seconds, so a long wait
  /// for silence only delays the verdict.
  final Duration Function()? silentWait;

  /// A partly received file with no new packet for this long is given up.
  final Duration incomingIdleTimeout;

  /// Minimum spacing of STATUS replies to probes of one incoming stream.
  final Duration replyInterval;

  /// Finished jobs kept in [jobs].
  final int maxJobs;

  final void Function()? onChanged;
  final void Function(FileTransferJob job)? onFileReceived;

  /// Diagnostic lines (what was sent, what came back, why a STATUS was
  /// ignored). Optional.
  final void Function(String message)? log;

  final FileReassembler _reassembler;
  final FileSessionAllocator _sessions;
  final DateTime Function() _clock;

  final List<FileTransferJob> _jobs = <FileTransferJob>[];
  final Map<int, _OutgoingState> _outgoing = <int, _OutgoingState>{};
  final Map<FileStreamKey, FileTransferJob> _incomingJobs =
      <FileStreamKey, FileTransferJob>{};
  final Map<FileStreamKey, DateTime> _lastReply = <FileStreamKey, DateTime>{};

  Future<void> _sendChain = Future<void>.value();
  int _replySalt = 0;
  int _nextJobId = 1;

  FileTransferEngine({
    required this.sendBlobs,
    int? selfPrefix,
    this.statusWait = const Duration(seconds: 90),
    this.maxRounds = 12,
    this.maxSilentRounds = 1,
    this.silentWait,
    this.incomingIdleTimeout = const Duration(minutes: 5),
    this.replyInterval = const Duration(seconds: 5),
    this.maxJobs = 20,
    this.onChanged,
    this.onFileReceived,
    this.log,
    FileReassembler? reassembler,
    FileSessionAllocator? sessions,
    DateTime Function()? clock,
  }) : _reassembler =
           reassembler ??
           FileReassembler(selfPrefix: selfPrefix, ttl: incomingIdleTimeout),
       _sessions = sessions ?? FileSessionAllocator(),
       _clock = clock ?? DateTime.now {
    if (reassembler != null && selfPrefix != null) {
      reassembler.selfPrefix = selfPrefix;
    }
  }

  /// Newest first.
  List<FileTransferJob> get jobs => List<FileTransferJob>.unmodifiable(_jobs);

  bool get hasActiveJobs => _jobs.any((j) => j.isActive);

  // -------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------

  /// Sends [data] on [channelIndex] and completes when the transfer ended
  /// (delivered, failed or cancelled); the returned job holds the outcome.
  /// Transfers are serialised: a second call waits for the first.
  ///
  /// The file is zlib-compressed first when that makes it smaller (unless
  /// [compress] is false). Throws [ArgumentError] for an empty or oversized
  /// file, and [StateError] when the local sender prefix is not known yet.
  Future<FileTransferJob> sendFile({
    required Uint8List data,
    required String name,
    required int channelIndex,
    bool compress = true,
  }) {
    final prefix = selfPrefix;
    if (prefix == null) {
      throw StateError('local sender prefix is not known yet');
    }
    final prepared = prepareFileForSend(data, compress: compress);
    final plan = FileSendPlan.build(
      data: prepared.wire,
      name: name,
      senderPrefix: prefix,
      session: _sessions.next(),
      compressed: prepared.compressed,
    );
    final job = FileTransferJob(
      id: _nextJobId++,
      outgoing: true,
      channelIndex: channelIndex,
      name: name,
      size: data.length,
      status: FileJobStatus.sending,
      startedAt: _clock(),
    )
      ..totalBlobs = plan.initialBurst.length
      ..sourceData = data
      ..sourceCompress = compress;
    _addJob(job);
    final state = _OutgoingState(plan);
    _outgoing[job.id] = state;

    final done = _sendChain.then((_) => _runSend(job, state));
    _sendChain = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  Future<FileTransferJob> _runSend(
    FileTransferJob job,
    _OutgoingState state,
  ) async {
    try {
      var burst = state.plan.initialBurst;
      var silentRounds = 0;
      var heardStatus = false;
      for (var round = 0; round <= maxRounds; round++) {
        if (state.cancelled) return _finish(job, FileJobStatus.cancelled);
        job
          ..round = round
          ..sentBlobs = 0
          ..totalBlobs = burst.length
          ..status = FileJobStatus.sending;
        _changed();

        final waiter = Completer<FileStatus?>();
        // Armed before sending: a receiver may answer the PROBE while the
        // radio is still draining the rest of the burst.
        state.waiter = waiter;
        // Retransmissions differ from the first transmission (see
        // withFileSalt), otherwise nodes that heard the original drop them.
        if (round > 0) {
          burst = <Uint8List>[for (final b in burst) withFileSalt(b, round)];
        }
        log?.call(
          'job ${job.id} round $round: sending ${burst.length} blobs on '
          'channel ${job.channelIndex}',
        );
        final sent = await sendBlobs(burst, job.channelIndex, (s, t) {
          job
            ..sentBlobs = s
            ..totalBlobs = t;
          _changed();
          // Called after every blob: the point where a cancel can take effect.
          if (state.cancelled) throw const _SendAborted();
        });
        if (state.cancelled) return _finish(job, FileJobStatus.cancelled);
        if (!sent) {
          return _fail(job, 'transport unavailable');
        }

        job.status = FileJobStatus.waitingForStatus;
        _changed();
        final wait = heardStatus
            ? statusWait
            : (silentWait?.call() ?? statusWait);
        final status = await waiter.future.timeout(
          wait,
          onTimeout: () => null,
        );
        state.waiter = null;
        if (state.cancelled) return _finish(job, FileJobStatus.cancelled);

        if (status == null) {
          log?.call('job ${job.id} round $round: no STATUS within $wait');
          silentRounds++;
          if (!heardStatus && silentRounds >= maxSilentRounds) {
            return _fail(job, kFileErrorNoResponse);
          }
          // No answer: the PROBE or the STATUS was lost. Probe again.
          burst = <Uint8List>[state.plan.probe];
          continue;
        }
        heardStatus = true;
        log?.call(
          'job ${job.id} round $round: STATUS complete=${status.complete} '
          'missing=${status.missing.length} needOffer=${status.needOffer}',
        );
        burst = state.plan.onStatus(status);
        if (state.plan.isComplete) {
          return _finish(job, FileJobStatus.delivered);
        }
      }
      return _fail(job, 'no confirmation after $maxRounds rounds');
    } on _SendAborted {
      return _finish(job, FileJobStatus.cancelled);
    } on Exception catch (e) {
      if (state.cancelled) return _finish(job, FileJobStatus.cancelled);
      return _fail(job, '$e');
    } finally {
      _outgoing.remove(job.id);
    }
  }

  /// Stops an outgoing transfer (a CANCEL is sent best effort) or discards an
  /// incoming one.
  Future<void> cancel(int jobId) async {
    final job = _jobs.where((j) => j.id == jobId).firstOrNull;
    if (job == null || !job.isActive) return;
    final state = _outgoing[jobId];
    if (state != null) {
      state.cancelled = true;
      final waiter = state.waiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete(null);
      // Show it at once; the burst in flight stops after its current blob.
      _finish(job, FileJobStatus.cancelled);
      final cancelBlob = buildFileCancel(
        senderPrefix: state.plan.senderPrefix,
        session: state.plan.session,
      );
      try {
        await sendBlobs(<Uint8List>[cancelBlob], job.channelIndex, null);
      } on Exception {
        // Best effort.
      }
      return;
    }
    final key = _incomingJobs.entries
        .where((e) => identical(e.value, job))
        .map((e) => e.key)
        .firstOrNull;
    if (key != null) {
      _incomingJobs.remove(key);
      _reassembler.addBlob(
        buildFileCancel(senderPrefix: key.senderPrefix, session: key.session),
        channelIndex: key.channelIndex,
      );
    }
    _finish(job, FileJobStatus.cancelled);
  }

  // -------------------------------------------------------------------------
  // Receiving
  // -------------------------------------------------------------------------

  /// Feeds one GRP_DATA blob of type [dataTypeFileTransfer].
  void handleBlob(Uint8List blob, int channelIndex) {
    _sweepExpired();

    final header = parseFileHeader(blob);
    if (header != null && header.kind == kFileKindStatus) {
      _routeStatus(blob, channelIndex);
      return;
    }

    final outcome = _reassembler.addBlob(blob, channelIndex: channelIndex);
    final h = outcome.header;
    if (h == null) return;
    final key = FileStreamKey(
      senderPrefix: h.senderPrefix,
      session: h.session,
      channelIndex: channelIndex,
    );

    switch (outcome.status) {
      case FileBlobStatus.offerAccepted:
      case FileBlobStatus.chunkAccepted:
        _updateIncoming(key);
      case FileBlobStatus.completed:
        _completeIncoming(key, outcome.result!);
        // Tell the sender right away instead of waiting for its probe.
        final done = outcome.reply;
        if (done != null) _replyToProbe(key, done);
      case FileBlobStatus.integrityFailed:
        final job = _incomingJobs.remove(key);
        if (job != null) _fail(job, 'file failed its integrity check');
      case FileBlobStatus.probeAnswered:
        log?.call(
          'PROBE received on channel $channelIndex from '
          '${h.senderPrefix.toRadixString(16)} session ${h.session}',
        );
        _replyToProbe(key, outcome.reply!);
      case FileBlobStatus.ignored:
        if (h.kind == kFileKindCancel) {
          final job = _incomingJobs.remove(key);
          if (job != null) _finish(job, FileJobStatus.cancelled);
        }
      case FileBlobStatus.malformed:
      case FileBlobStatus.fromSelf:
      case FileBlobStatus.duplicate:
      case FileBlobStatus.rejected:
        break;
    }
  }

  void _routeStatus(Uint8List blob, int channelIndex) {
    final status = parseFileStatus(blob);
    if (status == null) {
      log?.call('STATUS ignored: malformed');
      return;
    }
    if (selfPrefix != null && status.replierPrefix == selfPrefix) return;
    log?.call(
      'STATUS received on channel $channelIndex: from '
      '${status.replierPrefix.toRadixString(16)} session ${status.session} '
      'target ${status.targetPrefix.toRadixString(16)} '
      'complete=${status.complete}, ours is '
      '${selfPrefix?.toRadixString(16)} with ${_outgoing.length} job(s)',
    );
    for (final entry in _outgoing.entries) {
      final state = entry.value;
      final job = _jobs.where((j) => j.id == entry.key).firstOrNull;
      if (job == null || job.channelIndex != channelIndex) continue;
      if (state.plan.session != status.session ||
          state.plan.senderPrefix != status.targetPrefix) {
        continue;
      }
      final waiter = state.waiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete(status);
      return;
    }
    log?.call('STATUS matched no outgoing job');
  }

  void _updateIncoming(FileStreamKey key) {
    final progress = _reassembler.progress(key);
    if (progress == null) return;
    final offer = _reassembler.offerOf(key);
    var job = _incomingJobs[key];
    if (job == null) {
      job = FileTransferJob(
        id: _nextJobId++,
        outgoing: false,
        channelIndex: key.channelIndex,
        name: offer?.name ?? '',
        size: offer?.size ?? 0,
        status: FileJobStatus.receiving,
        startedAt: _clock(),
      );
      _incomingJobs[key] = job;
      _addJob(job);
      _startSweepTimer();
    }
    if (offer != null) {
      job
        ..name = offer.name
        ..size = offer.size;
    }
    job
      ..receivedChunks = progress.received
      ..totalChunks = progress.total;
    _changed();
  }

  void _completeIncoming(FileStreamKey key, FileReassemblyResult result) {
    final wireChunks = fileChunkCount(result.data.length);
    var job = _incomingJobs.remove(key);
    job ??= FileTransferJob(
      id: _nextJobId++,
      outgoing: false,
      channelIndex: key.channelIndex,
      name: result.name,
      size: result.data.length,
      status: FileJobStatus.receiving,
      startedAt: _clock(),
    );
    if (!_jobs.contains(job)) _addJob(job);
    var data = result.data;
    if (result.compressed) {
      final inflated = inflateBytes(data, maxBytes: kFileMaxOriginalBytes);
      if (inflated == null || inflated.isEmpty) {
        job
          ..name = result.name
          ..receivedChunks = wireChunks
          ..totalChunks = wireChunks;
        _fail(job, 'cannot decompress the file');
        return;
      }
      data = inflated;
    }
    job
      ..name = result.name
      ..size = data.length
      ..receivedChunks = wireChunks
      ..totalChunks = wireChunks
      ..data = data
      ..status = FileJobStatus.received;
    _changed();
    onFileReceived?.call(job);
  }

  void _replyToProbe(FileStreamKey key, Uint8List reply) {
    final now = _clock();
    final last = _lastReply[key];
    if (last != null && now.difference(last) < replyInterval) {
      log?.call('STATUS reply throttled');
      return;
    }
    _lastReply[key] = now;
    if (_lastReply.length > 32) {
      _lastReply.removeWhere((_, t) => now.difference(t) > replyInterval * 6);
    }
    final salted = withFileSalt(reply, _replySalt++);
    log?.call('STATUS sent on channel ${key.channelIndex}');
    // Fire and forget: a failed reply is recovered by the sender's next probe.
    unawaited(
      sendBlobs(<Uint8List>[salted], key.channelIndex, null).then(
        (ok) {
          if (!ok) log?.call('STATUS not sent: transport unavailable');
        },
        onError: (Object e) {
          log?.call('STATUS not sent: $e');
        },
      ),
    );
  }

  /// Marks incoming jobs whose partial state the reassembler already dropped.
  Timer? _sweepTimer;

  void _startSweepTimer() {
    _sweepTimer ??= Timer.periodic(const Duration(seconds: 20), (_) {
      _sweepExpired();
      if (_incomingJobs.isEmpty) _stopSweepTimer();
    });
  }

  void _stopSweepTimer() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }

  void _sweepExpired() {
    _reassembler.evictExpired();
    final alive = _reassembler.pendingKeys.toSet();
    final gone = _incomingJobs.keys.where((k) => !alive.contains(k)).toList();
    for (final key in gone) {
      final job = _incomingJobs.remove(key);
      if (job != null && job.status == FileJobStatus.receiving) {
        _fail(job, kFileErrorExpired);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Disconnect or new session: drop partial files, fail running transfers.
  void clear() {
    _stopSweepTimer();
    _reassembler.clear();
    _incomingJobs.clear();
    _lastReply.clear();
    for (final state in _outgoing.values) {
      state.cancelled = true;
      final waiter = state.waiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete(null);
    }
    for (final job in _jobs.where((j) => j.isActive && !j.outgoing)) {
      _fail(job, 'disconnected');
    }
  }

  /// The radio slot [channelIndex] now holds a different channel.
  void clearChannel(int channelIndex) {
    _reassembler.clearChannel(channelIndex);
    final stale = _incomingJobs.keys
        .where((k) => k.channelIndex == channelIndex)
        .toList();
    for (final key in stale) {
      final job = _incomingJobs.remove(key);
      if (job != null) _fail(job, 'channel changed');
    }
    _lastReply.removeWhere((k, _) => k.channelIndex == channelIndex);
  }

  /// Sends a failed or cancelled outgoing file again as a new transfer and
  /// drops the old bubble. Returns null when [jobId] is not retryable.
  Future<FileTransferJob>? retry(int jobId) {
    final index = _jobs.indexWhere((j) => j.id == jobId);
    if (index < 0) return null;
    final old = _jobs[index];
    final data = old.sourceData;
    if (!old.outgoing ||
        old.isActive ||
        data == null ||
        (old.status != FileJobStatus.failed &&
            old.status != FileJobStatus.cancelled)) {
      return null;
    }
    final future = sendFile(
      data: data,
      name: old.name,
      channelIndex: old.channelIndex,
      compress: old.sourceCompress,
    );
    _jobs.remove(old);
    _changed();
    return future;
  }

  /// Replaces every finished job with copies of [restored] (loaded from
  /// storage); running transfers are kept. Returns the new jobs in the order
  /// of [restored]. [jobs] stays newest first.
  List<FileTransferJob> replaceFinishedJobs(List<FileTransferJob> restored) {
    _jobs.removeWhere((j) => !j.isActive);
    final created = <FileTransferJob>[];
    for (final job in restored) {
      final copy = FileTransferJob(
        id: _nextJobId++,
        outgoing: job.outgoing,
        channelIndex: job.channelIndex,
        name: job.name,
        size: job.size,
        status: job.status,
        startedAt: job.startedAt,
      )
        ..data = job.data
        ..error = job.error
        ..sourceData = job.sourceData;
      _jobs.add(copy);
      created.add(copy);
    }
    _jobs.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    _changed();
    return created;
  }

  /// Removes a finished job from the list.
  void dismiss(int jobId) {
    final before = _jobs.length;
    _jobs.removeWhere((j) => j.id == jobId && !j.isActive);
    if (_jobs.length != before) _changed();
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  FileTransferJob _finish(FileTransferJob job, FileJobStatus status) {
    job.status = status;
    _changed();
    return job;
  }

  FileTransferJob _fail(FileTransferJob job, String error) {
    job
      ..status = FileJobStatus.failed
      ..error = error;
    _changed();
    return job;
  }

  void _addJob(FileTransferJob job) {
    _jobs.insert(0, job);
    while (_jobs.length > maxJobs) {
      final index = _jobs.lastIndexWhere((j) => !j.isActive);
      if (index < 0) break;
      _jobs.removeAt(index);
    }
    _changed();
  }

  void _changed() => onChanged?.call();
}
