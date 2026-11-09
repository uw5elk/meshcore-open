
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
      onChanged: notifyListeners,
      onFileReceived: _handleReceived,
      log: log,
    );
  }

  void _handleReceived(FileTransferJob job) {
    final radio = _radioKey;
    final data = job.data;
    if (radio != null && data != null) {
      final key =
          '${job.startedAt.millisecondsSinceEpoch}-'
          '${_random.nextInt(1 << 32).toRadixString(16)}';
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

  /// Switches to the radio [radioKey] and shows its saved files. Files of a
  /// previously connected radio are dropped from the list (they stay on disk).
  Future<void> attachRadio(String radioKey) async {
    if (_radioKey == radioKey) return;
    _radioKey = radioKey;
    _storeKeys.clear();
    final stored = await _store.load(radioKey);
    if (_radioKey != radioKey) return; // switched again while loading
    final restored = <FileTransferJob>[];
    for (final f in stored) {
      restored.add(
        FileTransferJob(
          id: 0,
          outgoing: false,
          channelIndex: f.channelIndex,
          name: f.name,
          size: f.data.length,
          status: FileJobStatus.received,
          startedAt: f.receivedAt,
        )..data = f.data,
      );
    }
    _engine.replaceFinishedJobs(restored);
    // Map the new job ids back to their storage keys (same order: the
    // engine sorts by time, ties keep insertion order).
    final byTime = <String, StoredFile>{
      for (final f in stored)
        '${f.receivedAt.millisecondsSinceEpoch}|${f.name}|${f.channelIndex}': f,
    };
    for (final job in _engine.jobs) {
      if (job.outgoing || job.status != FileJobStatus.received) continue;
      final f =
          byTime['${job.startedAt.millisecondsSinceEpoch}|${job.name}|'
              '${job.channelIndex}'];
      if (f != null) _storeKeys[job.id] = f.key;
    }
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
  Future<FileTransferJob>? retry(int jobId) => _engine.retry(jobId);

  void dismiss(int jobId) {
    final key = _storeKeys.remove(jobId);
    final radio = _radioKey;
    if (key != null && radio != null) unawaited(_store.delete(radio, key));
    _engine.dismiss(jobId);
  }

  void handleBlob(Uint8List blob, int channelIndex) =>
      _engine.handleBlob(blob, channelIndex);

  void clear() => _engine.clear();

  void clearChannel(int channelIndex) => _engine.clearChannel(channelIndex);
}
