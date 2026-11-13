
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../utils/lora_airtime.dart';
import 'file_job_store.dart';
import 'file_transfer_engine.dart';
import 'file_transfer_protocol.dart';

/// Pause left after each file packet so the radio finishes the previous one:
/// the image pacing model applied to a full-size file blob. Falls back to a
/// conservative gap while the radio parameters are unknown.
Duration fileSendChunkGap({
  required int? spreadingFactor,
  required int? bandwidthHz,
  required int? codingRate,
}) {
  final sf = spreadingFactor;
  final bw = bandwidthHz;
  final cr = codingRate;
  if (sf == null || bw == null || cr == null) {
    return imageSendChunkGap(const Duration(seconds: 1));
  }
  final normalizedCr = normalizeCodingRate(cr);
  if (!areLoRaParamsValid(
    spreadingFactor: sf,
    bandwidthHz: bw,
    codingRate: normalizedCr,
  )) {
    return imageSendChunkGap(const Duration(seconds: 1));
  }
  return imageSendChunkGap(
    loraTimeOnAir(
      payloadBytes: kFileBlobBytes,
      spreadingFactor: sf,
      bandwidthHz: bw,
      codingRate: normalizedCr,
    ),
  );
}

/// Rough wall-clock time to send [size] bytes once, without retransmissions,
/// or null while the radio parameters are unknown (no fabricated ETA).
Duration? estimateFileSendTime({
  required int size,
  required int? spreadingFactor,
  required int? bandwidthHz,
  required int? codingRate,
}) {
  if (!areLoRaParamsValid(
    spreadingFactor: spreadingFactor,
    bandwidthHz: bandwidthHz,
    codingRate: codingRate == null ? null : normalizeCodingRate(codingRate),
  )) {
    return null;
  }
  final airtime = loraTimeOnAir(
    payloadBytes: kFileBlobBytes,
    spreadingFactor: spreadingFactor!,
    bandwidthHz: bandwidthHz!,
    codingRate: normalizeCodingRate(codingRate!),
  );
  // OFFER and PROBE ride along with the data chunks.
  final packets = fileChunkCount(size) + 2;
  final perPacket = airtime + imageSendChunkGap(airtime);
  return perPacket * packets;
}

/// How long a sender waits for the first answer while nobody has replied yet:
/// a receiver answers right after the PROBE, so the reply needs roughly three
/// packet airtimes (hops and a busy channel) plus the reply spacing. Clamped
/// to 8..40 s; 20 s while the radio parameters are unknown.
Duration fileSilentWait({
  required int? spreadingFactor,
  required int? bandwidthHz,
  required int? codingRate,
}) {
  final sf = spreadingFactor;
  final bw = bandwidthHz;
  final cr = codingRate;
  if (sf == null || bw == null || cr == null) {
    return const Duration(seconds: 20);
  }
  final normalizedCr = normalizeCodingRate(cr);
  if (!areLoRaParamsValid(
    spreadingFactor: sf,
    bandwidthHz: bw,
    codingRate: normalizedCr,
  )) {
    return const Duration(seconds: 20);
  }
  final airtime = loraTimeOnAir(
    payloadBytes: kFileBlobBytes,
    spreadingFactor: sf,
    bandwidthHz: bw,
    codingRate: normalizedCr,
  );
  final wait = airtime * 3 + const Duration(seconds: 5);
  if (wait < const Duration(seconds: 8)) return const Duration(seconds: 8);
  if (wait > const Duration(seconds: 40)) return const Duration(seconds: 40);
  return wait;
}

/// UI-facing wrapper around [FileTransferEngine]: files sent and received as
/// channel GRP_DATA. The connector feeds it inbound blobs and lifecycle events.
class FileTransferService extends ChangeNotifier {
  late final FileTransferEngine _engine;

  /// Called when a complete, verified file has arrived.
  void Function(FileTransferJob job)? onFileReceived;

  final FileJobStore _store;
  final math.Random _random = math.Random();

  /// Radio whose files are shown and stored (first 10 hex chars of its key).
  String? _radioKey;

  /// Storage key of each received job, by job id.
  final Map<int, String> _storeKeys = <int, String>{};

  FileTransferService({
    required FileBlobSender sendBlobs,
    void Function(String message)? log,
    FileJobStore? store,
    Duration Function()? silentWait,
  }) : _store = store ?? InMemoryFileJobStore() {
    _engine = FileTransferEngine(
      sendBlobs: sendBlobs,
      silentWait: silentWait,
      onChanged: _handleChanged,
      onFileReceived: _handleReceived,
      log: log,
    );
  }

  String _newKey(FileTransferJob job) =>
      '${job.startedAt.millisecondsSinceEpoch}-'
      '${_random.nextInt(1 << 32).toRadixString(16)}';

  void _handleReceived(FileTransferJob job) {
    final radio = _radioKey;
    final data = job.data;
    if (radio != null && data != null) {
      final key = _newKey(job);
      _storeKeys[job.id] = key;
      unawaited(
        _store.save(
          radio,
          StoredFile(
            key: key,
            name: job.name,
            channelIndex: job.channelIndex,
            receivedAt: job.startedAt,
            data: data,
          ),
        ),
      );
    }
    onFileReceived?.call(job);
  }

  /// True while files loaded from storage are put into the list: they are
  /// already on disk and must not be saved a second time.
  bool _restoring = false;

  void _handleChanged() {
    if (!_restoring) _persistFinishedOutgoing();
    notifyListeners();
  }

  /// Files this device sent are kept once their transfer has ended, so the
  /// chat shows them (and a failed one can be retried) after a restart.
  void _persistFinishedOutgoing() {
    final radio = _radioKey;
    if (radio == null) return;
    for (final job in _engine.jobs) {
      final data = job.sourceData;
      if (!job.outgoing ||
          job.isActive ||
          data == null ||
          _storeKeys.containsKey(job.id)) {
        continue;
      }
      final key = _newKey(job);
      _storeKeys[job.id] = key;
      unawaited(
        _store.save(
          radio,
          StoredFile(
            key: key,
            name: job.name,
            channelIndex: job.channelIndex,
            receivedAt: job.startedAt,
            data: data,
            outgoing: true,
            status: job.status.name,
            error: job.error,
          ),
        ),
      );
    }
  }

  /// Shows the files of the radio used last, right after launch, before the
  /// radio has connected.
  Future<void> restoreLastRadio() async {
    final last = await _store.lastRadio();
    if (last != null && _radioKey == null) await attachRadio(last);
  }

  /// Switches to the radio [radioKey] and shows its saved files. Files of a
  /// previously connected radio are dropped from the list (they stay on disk).
  Future<void> attachRadio(String radioKey) async {
    if (_radioKey == radioKey) return;
    _radioKey = radioKey;
    _storeKeys.clear();
    unawaited(_store.setLastRadio(radioKey));
    final stored = await _store.load(radioKey);
    if (_radioKey != radioKey) return; // switched again while loading
    FileJobStatus statusOf(StoredFile f) {
      if (!f.outgoing) return FileJobStatus.received;
      return FileJobStatus.values.firstWhere(
        (s) => s.name == f.status && s != FileJobStatus.sending,
        orElse: () => FileJobStatus.failed,
      );
    }

    final restored = <FileTransferJob>[
      for (final f in stored)
        FileTransferJob(
            id: 0,
            outgoing: f.outgoing,
            channelIndex: f.channelIndex,
            name: f.name,
            size: f.data.length,
            status: statusOf(f),
            startedAt: f.receivedAt,
          )
          ..error = f.error
          ..data = f.outgoing ? null : f.data
          ..sourceData = f.outgoing ? f.data : null,
    ];
    _restoring = true;
    try {
      final created = _engine.replaceFinishedJobs(restored);
      for (var i = 0; i < created.length; i++) {
        _storeKeys[created[i].id] = stored[i].key;
      }
    } finally {
      _restoring = false;
    }
    // Notified only now, with every restored job already mapped to its file.
    notifyListeners();
  }

  /// Newest first.
  List<FileTransferJob> get jobs => _engine.jobs;

  bool get hasActiveJobs => _engine.hasActiveJobs;

  set selfPrefix(int? value) => _engine.selfPrefix = value;

  /// See [FileTransferEngine.sendFile].
  Future<FileTransferJob> sendFile({
    required Uint8List data,
    required String name,
    required int channelIndex,
    bool compress = true,
  }) => _engine.sendFile(
    data: data,
    name: name,
    channelIndex: channelIndex,
    compress: compress,
  );

  Future<void> cancel(int jobId) => _engine.cancel(jobId);

  /// Sends a failed or cancelled outgoing file again; null when not possible.
  Future<FileTransferJob>? retry(int jobId) {
    final future = _engine.retry(jobId);
    if (future != null) _forget(jobId);
    return future;
  }

  void _forget(int jobId) {
    final key = _storeKeys.remove(jobId);
    final radio = _radioKey;
    if (key != null && radio != null) unawaited(_store.delete(radio, key));
  }

  void dismiss(int jobId) {
    _forget(jobId);
    _engine.dismiss(jobId);
  }

  void handleBlob(Uint8List blob, int channelIndex) =>
      _engine.handleBlob(blob, channelIndex);

  void clear() => _engine.clear();

  void clearChannel(int channelIndex) => _engine.clearChannel(channelIndex);

  /// Removes every file shown on [channelIndex], from the list and from
  /// storage: the chat was cleared, or the slot was deleted or now holds a
  /// different channel. A file still being sent there is cancelled first.
  void forgetChannel(int channelIndex) {
    _engine.clearChannel(channelIndex);
    for (final job in _engine.jobs.toList()) {
      if (job.channelIndex != channelIndex) continue;
      if (job.isActive) {
        if (job.outgoing) {
          final id = job.id;
          unawaited(_engine.cancel(id).then((_) => dismiss(id)));
        }
      } else {
        dismiss(job.id);
      }
    }
  }
}
