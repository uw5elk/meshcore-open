import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../utils/lora_airtime.dart';
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

/// UI-facing wrapper around [FileTransferEngine]: files sent and received as
/// channel GRP_DATA. The connector feeds it inbound blobs and lifecycle events.
class FileTransferService extends ChangeNotifier {
  late final FileTransferEngine _engine;

  /// Called when a complete, verified file has arrived.
  void Function(FileTransferJob job)? onFileReceived;

  FileTransferService({
    required FileBlobSender sendBlobs,
    void Function(String message)? log,
  }) {
    _engine = FileTransferEngine(
      sendBlobs: sendBlobs,
      onChanged: notifyListeners,
      onFileReceived: (job) => onFileReceived?.call(job),
      log: log,
    );
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

  void dismiss(int jobId) => _engine.dismiss(jobId);

  void handleBlob(Uint8List blob, int channelIndex) =>
      _engine.handleBlob(blob, channelIndex);

  void clear() => _engine.clear();

  void clearChannel(int channelIndex) => _engine.clearChannel(channelIndex);
}
