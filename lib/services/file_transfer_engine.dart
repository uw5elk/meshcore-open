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

  /// Minimum spacing of STATUS replies to probes of one incoming stream.
  final Duration replyInterval;

  /// Finished jobs kept in [jobs].
  final int maxJobs;

  final void Function()? onChanged;
  final void Function(FileTransferJob job)? onFileReceived;

  final FileReassembler _reassembler;
  final FileSessionAllocator _sessions;
  final DateTime Function() _clock;

  final List<FileTransferJob> _jobs = <FileTransferJob>[];
  final Map<int, _OutgoingState> _outgoing = <int, _OutgoingState>{};
  final Map<FileStreamKey, FileTransferJob> _incomingJobs =
      <FileStreamKey, FileTransferJob>{};
  final Map<FileStreamKey, DateTime> _lastReply = <FileStreamKey, DateTime>{};

  Future<void> _sendChain = Future<void>.value();
  int _nextJobId = 1;

  FileTransferEngine({
    required this.sendBlobs,
    int? selfPrefix,
    this.statusWait = const Duration(seconds: 90),
    this.maxRounds = 12,
    this.replyInterval = const Duration(seconds: 5),
    this.maxJobs = 20,
    this.onChanged,
    this.onFileReceived,
    FileReassembler? reassembler,
    FileSessionAllocator? sessions,
    DateTime Function()? clock,
  }) : _reassembler = reassembler ?? FileReassembler(selfPrefix: selfPrefix),
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
    )..totalBlobs = plan.initialBurst.length;
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
        final status = await waiter.future.timeout(
          statusWait,
          onTimeout: () => null,
        );
        state.waiter = null;
        if (state.cancelled) return _finish(job, FileJobStatus.cancelled);

        if (status == null) {
          // No answer: the PROBE or the STATUS was lost. Probe again.
          burst = <Uint8List>[state.plan.probe];
          continue;
        }
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
      case FileBlobStatus.integrityFailed:
        final job = _incomingJobs.remove(key);
        if (job != null) _fail(job, 'file failed its integrity check');
      case FileBlobStatus.probeAnswered:
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
    if (status == null) return;
    if (selfPrefix != null && status.replierPrefix == selfPrefix) return;
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
    if (last != null && now.difference(last) < replyInterval) return;
    _lastReply[key] = now;
    if (_lastReply.length > 32) {
      _lastReply.removeWhere((_, t) => now.difference(t) > replyInterval * 6);
    }
    // Fire and forget: a failed reply is recovered by the sender's next probe.
    unawaited(
      sendBlobs(
        <Uint8List>[reply],
        key.channelIndex,
        null,
      ).then((_) {}, onError: (Object _) {}),
    );
  }

  /// Marks incoming jobs whose partial state the reassembler already dropped.
  void _sweepExpired() {
    _reassembler.evictExpired();
    final alive = _reassembler.pendingKeys.toSet();
    final gone = _incomingJobs.keys.where((k) => !alive.contains(k)).toList();
    for (final key in gone) {
      final job = _incomingJobs.remove(key);
      if (job != null && job.status == FileJobStatus.receiving) {
        _fail(job, 'transfer expired');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Disconnect or new session: drop partial files, fail running transfers.
  void clear() {
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
