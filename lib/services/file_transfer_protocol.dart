/// Reliable file transfer over MeshCore `PAYLOAD_TYPE_GRP_DATA` (0x06), carried
/// by `CMD_SEND_CHANNEL_DATA` (62) and received as
/// `RESP_CODE_CHANNEL_DATA_RECV` (27), the same companion commands the image
/// transport in `image_chunk_transport.dart` uses, under a different data type.
///
/// Everything here is pure Dart (no Flutter, BLE or connector), so it can be
/// unit-tested directly.
///
/// ## Why not reuse the image framing
///
/// The image framing has a 4-bit chunk index (15 chunks, about 2.3 KB) and one
/// XOR parity chunk, which recovers a single loss. GRP_DATA is unacknowledged,
/// so tens of KB need selective retransmission instead.
///
/// ## Model
///
/// 1. The sender emits one OFFER (name, size, CRC-32), every DATA chunk, then a
///    PROBE ("report what you have").
/// 2. A receiver answers a PROBE with a STATUS: whether the file is complete,
///    and up to [kFileStatusMaxMissing] missing chunk indices.
/// 3. The sender resends exactly those chunks, then probes again, until a
///    STATUS says complete or the caller gives up (see [FileSendPlan.onStatus]).
///
/// Use a private 2-member channel for point-to-point transfers: the channel
/// secret then provides confidentiality, and only the peer sees the file.
///
/// ## Wire format
///
/// One GRP_DATA blob per message, at most [kFileBlobBytes] bytes. Every blob
/// starts with a 4-byte common header:
///
/// ```
///   off  size  field
///   0    1     kind        1 OFFER, 2 DATA, 3 PROBE, 4 STATUS, 5 CANCEL
///   1    2     prefix      first 2 bytes of the SENDING node's public key
///                          (the firmware supplies no sender on channel data)
///   3    1     session     uint8 transfer id chosen by the file sender
/// ```
///
/// OFFER: common + `total(2) size(4) crc32(4) flags(1) name(utf8)`.
/// DATA: common + `index(2) body`, body up to [kFileChunkBodyBytes].
/// PROBE and CANCEL: common only.
/// STATUS: common (prefix = the replying node) +
/// `target(2) flags(1) received(2) missing(2 each)`. `target` is the file
/// sender's prefix; flags bit0 = complete, bit1 = offer needed.
///
/// All multi-byte integers are big-endian. The LoRa PHY CRC and the 2-byte
/// MeshCore HMAC protect each packet, so the CRC-32 in the OFFER exists to
/// catch what they cannot: chunks of two different files merged under one
/// (sender, session).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Application data type for file transfer. `0x0000` is rejected by firmware;
/// `0xAE1C` is the image transport.
const int dataTypeFileTransfer = 0xF11E;

/// Largest GRP_DATA blob; same binding limit as the image transport.
const int kFileBlobBytes = 163;

const int kFileKindOffer = 1;
const int kFileKindData = 2;
const int kFileKindProbe = 3;
const int kFileKindStatus = 4;
const int kFileKindCancel = 5;

/// kind(1) + prefix(2) + session(1).
const int kFileCommonHeaderBytes = 4;

/// Common header + index(2).
const int kFileDataHeaderBytes = kFileCommonHeaderBytes + 2;

/// File bytes in one DATA chunk.
const int kFileChunkBodyBytes = kFileBlobBytes - kFileDataHeaderBytes;

/// Common header + `total(2) size(4) crc32(4) flags(1)`.
const int kFileOfferFixedBytes = kFileCommonHeaderBytes + 11;

/// Longest file name carried in an OFFER (utf8 bytes).
const int kFileMaxNameBytes = 100;

/// Common header + `target(2) flags(1) received(2)`.
const int kFileStatusFixedBytes = kFileCommonHeaderBytes + 5;

/// Missing chunk indices that fit in one STATUS.
const int kFileStatusMaxMissing = (kFileBlobBytes - kFileStatusFixedBytes) ~/ 2;

/// Policy limit on a transferred file. LoRa airtime makes more than this
/// impractical, and it bounds receiver memory.
const int kFileMaxBytes = 128 * 1024;

/// Largest original file; it must still fit [kFileMaxBytes] once compressed,
/// and a receiver never inflates past this.
const int kFileMaxOriginalBytes = 512 * 1024;

/// OFFER flag bit0: payload is zlib-compressed; the receiver inflates it.
const int kFileFlagCompressed = 1;

const int kFileStatusFlagComplete = 1;
const int kFileStatusFlagNeedOffer = 2;

/// Data chunks needed for [size] bytes (0 for an empty file).
int fileChunkCount(int size) =>
    size <= 0 ? 0 : (size + kFileChunkBodyBytes - 1) ~/ kFileChunkBodyBytes;

// ---------------------------------------------------------------------------
// CRC-32 (IEEE 802.3, the zlib/PNG polynomial)
// ---------------------------------------------------------------------------

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
  }
  return c;
});

/// CRC-32 of [data]; `crc32("123456789")` is `0xCBF43926`.
int crc32(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

int _u16(Uint8List b, int o) => ((b[o] & 0xFF) << 8) | (b[o + 1] & 0xFF);

int _u32(Uint8List b, int o) =>
    ((b[o] & 0xFF) << 24) |
    ((b[o + 1] & 0xFF) << 16) |
    ((b[o + 2] & 0xFF) << 8) |
    (b[o + 3] & 0xFF);

void _putU16(BytesBuilder out, int v) {
  out
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);
}

void _putU32(BytesBuilder out, int v) {
  out
    ..addByte((v >> 24) & 0xFF)
    ..addByte((v >> 16) & 0xFF)
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);
}

/// Bits of the first byte that carry the blob kind; the top three bits are a
/// salt (see [withFileSalt]).
const int kFileKindMask = 0x1F;

/// Copy of [blob] with a different first-byte salt (0..7).
///
/// MeshCore nodes drop a packet whose payload they have already seen, so an
/// identical PROBE, STATUS or retransmitted chunk would be silently discarded
/// by the first node that heard the original. Changing the salt per
/// transmission makes each one a new packet. The receiver masks it away.
Uint8List withFileSalt(Uint8List blob, int salt) {
  if (blob.isEmpty) return blob;
  final out = Uint8List.fromList(blob);
  out[0] = (out[0] & kFileKindMask) | ((salt & 7) << 5);
  return out;
}

BytesBuilder _commonHeader(int kind, int senderPrefix, int session) {
  return BytesBuilder()
    ..addByte(kind)
    ..addByte((senderPrefix >> 8) & 0xFF)
    ..addByte(senderPrefix & 0xFF)
    ..addByte(session & 0xFF);
}

/// [name] as utf8, cut to [kFileMaxNameBytes] without splitting a character.
Uint8List encodeFileName(String name) {
  final bytes = utf8.encode(name);
  if (bytes.length <= kFileMaxNameBytes) return Uint8List.fromList(bytes);
  var end = kFileMaxNameBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return Uint8List.fromList(bytes.sublist(0, end));
}

/// Makes a received file name safe to hand to a save dialog or the file
/// system: no path separators, reserved or control characters, no leading or
/// trailing dots and spaces. Falls back to `file` when nothing is left.
String sanitizeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001F\u007F]'), '_')
      .replaceAll(RegExp(r'^[.\s]+|[.\s]+$'), '');
  return cleaned.isEmpty ? 'file' : cleaned;
}

// ---------------------------------------------------------------------------
// Parsed forms
// ---------------------------------------------------------------------------

class FileBlobHeader {
  final int kind;
  final int senderPrefix;
  final int session;

  const FileBlobHeader({
    required this.kind,
    required this.senderPrefix,
    required this.session,
  });
}

/// Parses the common header, or null if [blob] cannot be a file-transfer blob.
FileBlobHeader? parseFileHeader(Uint8List blob) {
  if (blob.length < kFileCommonHeaderBytes || blob.length > kFileBlobBytes) {
    return null;
  }
  final kind = blob[0] & kFileKindMask;
  if (kind < kFileKindOffer || kind > kFileKindCancel) return null;
  return FileBlobHeader(
    kind: kind,
    senderPrefix: _u16(blob, 1),
    session: blob[3] & 0xFF,
  );
}

class FileOffer {
  final int totalChunks;
  final int size;
  final int crc;
  final int flags;
  final String name;

  const FileOffer({
    required this.totalChunks,
    required this.size,
    required this.crc,
    required this.flags,
    required this.name,
  });

  bool get isCompressed => (flags & kFileFlagCompressed) != 0;
}

/// Parses an OFFER body, or null when malformed or inconsistent (size out of
/// range, or a chunk count that does not match the size).
FileOffer? parseFileOffer(Uint8List blob) {
  if (blob.length < kFileOfferFixedBytes) return null;
  if ((blob[0] & kFileKindMask) != kFileKindOffer) return null;
  final total = _u16(blob, 4);
  final size = _u32(blob, 6);
  if (size < 1 || size > kFileMaxBytes) return null;
  if (total != fileChunkCount(size)) return null;
  final nameBytes = blob.sublist(kFileOfferFixedBytes);
  if (nameBytes.length > kFileMaxNameBytes) return null;
  return FileOffer(
    totalChunks: total,
    size: size,
    crc: _u32(blob, 10),
    flags: blob[14] & 0xFF,
    name: sanitizeFileName(utf8.decode(nameBytes, allowMalformed: true)),
  );
}

class FileStatus {
  /// Node that sent this STATUS.
  final int replierPrefix;
  final int session;

  /// Prefix of the file sender the STATUS answers.
  final int targetPrefix;
  final bool complete;
  final bool needOffer;
  final int receivedChunks;

  /// Missing chunk indices, ascending, possibly truncated to
  /// [kFileStatusMaxMissing].
  final List<int> missing;

  const FileStatus({
    required this.replierPrefix,
    required this.session,
    required this.targetPrefix,
    required this.complete,
    required this.needOffer,
    required this.receivedChunks,
    required this.missing,
  });
}

FileStatus? parseFileStatus(Uint8List blob) {
  if (blob.length < kFileStatusFixedBytes) return null;
  if ((blob[0] & kFileKindMask) != kFileKindStatus) return null;
  if ((blob.length - kFileStatusFixedBytes) % 2 != 0) return null;
  final flags = blob[6] & 0xFF;
  final missing = <int>[];
  for (var o = kFileStatusFixedBytes; o < blob.length; o += 2) {
    missing.add(_u16(blob, o));
  }
  return FileStatus(
    replierPrefix: _u16(blob, 1),
    session: blob[3] & 0xFF,
    targetPrefix: _u16(blob, 4),
    complete: (flags & kFileStatusFlagComplete) != 0,
    needOffer: (flags & kFileStatusFlagNeedOffer) != 0,
    receivedChunks: _u16(blob, 7),
    missing: missing,
  );
}

Uint8List _buildStatus({
  required int replierPrefix,
  required int session,
  required int targetPrefix,
  required bool complete,
  required bool needOffer,
  required int received,
  required List<int> missing,
}) {
  final out = _commonHeader(kFileKindStatus, replierPrefix, session);
  _putU16(out, targetPrefix);
  out.addByte(
    (complete ? kFileStatusFlagComplete : 0) |
        (needOffer ? kFileStatusFlagNeedOffer : 0),
  );
  _putU16(out, received);
  for (final i in missing.take(kFileStatusMaxMissing)) {
    _putU16(out, i);
  }
  return out.toBytes();
}

/// A CANCEL blob; the receiver drops its partial state for the session.
Uint8List buildFileCancel({required int senderPrefix, required int session}) =>
    _commonHeader(kFileKindCancel, senderPrefix, session).toBytes();

// ---------------------------------------------------------------------------
// Send side
// ---------------------------------------------------------------------------

/// Hands out per-transfer session ids, avoiding immediate reuse.
class FileSessionAllocator {
  int _next;

  FileSessionAllocator({int? seed, math.Random? random})
    : _next = seed ?? (random ?? math.Random()).nextInt(256);

  int next() {
    final id = _next & 0xFF;
    _next = (_next + 1) & 0xFF;
    return id;
  }
}

/// One outgoing file: its blobs plus the retransmission logic.
class FileSendPlan {
  final int session;
  final int senderPrefix;
  final int size;
  final int crc;
  final int totalChunks;
  final Uint8List offer;
  final List<Uint8List> chunks;
  final Uint8List probe;

  bool _complete = false;

  FileSendPlan._({
    required this.session,
    required this.senderPrefix,
    required this.size,
    required this.crc,
    required this.totalChunks,
    required this.offer,
    required this.chunks,
    required this.probe,
  });

  /// Builds the blobs for [data].
  ///
  /// [data] is sent verbatim; set [compressed] when the caller has already
  /// zlib-compressed it so the receiver inflates it. Throws [ArgumentError] for
  /// an empty file or one larger than [kFileMaxBytes].
  factory FileSendPlan.build({
    required Uint8List data,
    required String name,
    required int senderPrefix,
    required int session,
    bool compressed = false,
  }) {
    if (data.isEmpty) {
      throw ArgumentError.value(data.length, 'data', 'file is empty');
    }
    if (data.length > kFileMaxBytes) {
      throw ArgumentError.value(
        data.length,
        'data',
        'exceeds kFileMaxBytes ($kFileMaxBytes)',
      );
    }
    final total = fileChunkCount(data.length);
    final crc = crc32(data);

    final offerOut = _commonHeader(kFileKindOffer, senderPrefix, session);
    _putU16(offerOut, total);
    _putU32(offerOut, data.length);
    _putU32(offerOut, crc);
    offerOut.addByte(compressed ? kFileFlagCompressed : 0);
    offerOut.add(encodeFileName(name));

    final chunks = <Uint8List>[];
    for (var i = 0; i < total; i++) {
      final start = i * kFileChunkBodyBytes;
      final end = math.min(start + kFileChunkBodyBytes, data.length);
      final out = _commonHeader(kFileKindData, senderPrefix, session);
      _putU16(out, i);
      out.add(Uint8List.sublistView(data, start, end));
      chunks.add(out.toBytes());
    }

    return FileSendPlan._(
      session: session,
      senderPrefix: senderPrefix,
      size: data.length,
      crc: crc,
      totalChunks: total,
      offer: offerOut.toBytes(),
      chunks: chunks,
      probe: _commonHeader(kFileKindProbe, senderPrefix, session).toBytes(),
    );
  }

  /// True once a receiver reported the file complete and verified.
  bool get isComplete => _complete;

  /// First transmission: OFFER, every DATA chunk, then a PROBE.
  List<Uint8List> get initialBurst => <Uint8List>[offer, ...chunks, probe];

  /// Blobs to send after a [status] that was received on this transfer.
  ///
  /// Returns the OFFER if requested, each missing chunk, then a PROBE. Returns
  /// an empty list (and sets [isComplete]) when the receiver has everything, and
  /// also for a STATUS that belongs to another session or file sender.
  List<Uint8List> onStatus(FileStatus status) {
    if (status.session != session || status.targetPrefix != senderPrefix) {
      return const <Uint8List>[];
    }
    if (status.complete) {
      _complete = true;
      return const <Uint8List>[];
    }
    final out = <Uint8List>[];
    if (status.needOffer) out.add(offer);
    for (final index in status.missing) {
      if (index < totalChunks) out.add(chunks[index]);
    }
    out.add(probe);
    return out;
  }
}

// ---------------------------------------------------------------------------
// Receive side
// ---------------------------------------------------------------------------

/// Identity of one incoming transfer.
class FileStreamKey {
  final int senderPrefix;
  final int session;
  final int channelIndex;

  const FileStreamKey({
    required this.senderPrefix,
    required this.session,
    required this.channelIndex,
  });

  @override
  bool operator ==(Object other) =>
      other is FileStreamKey &&
      other.senderPrefix == senderPrefix &&
      other.session == session &&
      other.channelIndex == channelIndex;

  @override
  int get hashCode => Object.hash(senderPrefix, session, channelIndex);

  @override
  String toString() =>
      'FileStreamKey(0x${senderPrefix.toRadixString(16).padLeft(4, '0')}'
      '/$session@$channelIndex)';
}

enum FileBlobStatus {
  /// Not a well-formed file-transfer blob, or inconsistent with its stream.
  malformed,

  /// Carries our own sender prefix: a loopback of something we sent.
  fromSelf,

  /// Valid, but nothing for a receiver to do (STATUS, CANCEL, unknown stream).
  ignored,

  /// OFFER stored; the file is still incomplete.
  offerAccepted,

  /// DATA chunk stored; the file is still incomplete.
  chunkAccepted,

  /// Already held this chunk or file.
  duplicate,

  /// PROBE answered; [FileBlobOutcome.reply] holds the STATUS to transmit.
  probeAnswered,

  /// Every chunk arrived and the CRC matched; [FileBlobOutcome.result] is set.
  completed,

  /// Every chunk arrived but size or CRC-32 did not match. Partial state is
  /// dropped, so the next STATUS asks the sender for everything again.
  integrityFailed,

  /// OFFER refused (size out of range, or chunk count inconsistent).
  rejected,
}

class FileReassemblyResult {
  final FileStreamKey key;
  final String name;
  final bool compressed;

  /// The file bytes as sent (still compressed when [compressed] is true).
  final Uint8List data;

  const FileReassemblyResult({
    required this.key,
    required this.name,
    required this.compressed,
    required this.data,
  });
}

class FileBlobOutcome {
  final FileBlobStatus status;
  final FileBlobHeader? header;

  /// STATUS blob to transmit, set for [FileBlobStatus.probeAnswered] and for
  /// [FileBlobStatus.completed] (an unsolicited "got it").
  final Uint8List? reply;
  final FileReassemblyResult? result;

  const FileBlobOutcome(this.status, {this.header, this.reply, this.result});
}

class _Incoming {
  final FileStreamKey key;
  FileOffer? offer;
  final Map<int, Uint8List> chunks = <int, Uint8List>{};
  DateTime lastSeen;

  _Incoming(this.key, this.lastSeen);
}

class _Completed {
  final DateTime at;
  final int crc;
  final int received;

  _Completed(this.at, this.crc, this.received);
}

/// Collects blobs into whole files. Pure Dart, injectable clock, tolerant of
/// loss, reordering and duplicates.
class FileReassembler {
  /// Prefix of the local public key; blobs bearing it are dropped as loopback.
  int? selfPrefix;

  /// A partial file is dropped after this long without any blob for it.
  final Duration ttl;

  /// How long a finished file is remembered so a late PROBE still gets a
  /// "complete" STATUS and stragglers are not reopened as new transfers.
  final Duration completedTtl;

  final int maxConcurrentStreams;
  final int maxCompletedStreams;

  final DateTime Function() _clock;

  final Map<FileStreamKey, _Incoming> _incoming = <FileStreamKey, _Incoming>{};
  final Map<FileStreamKey, _Completed> _completed =
      <FileStreamKey, _Completed>{};

  FileReassembler({
    this.selfPrefix,
    this.ttl = const Duration(minutes: 30),
    this.completedTtl = const Duration(minutes: 10),
    this.maxConcurrentStreams = 4,
    this.maxCompletedStreams = 8,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  int get pendingCount => _incoming.length;

  Iterable<FileStreamKey> get pendingKeys => _incoming.keys;

  /// `(received, total)` for a stream in progress; total is null until its
  /// OFFER arrives. Null for an unknown stream.
  ({int received, int? total})? progress(FileStreamKey key) {
    final entry = _incoming[key];
    if (entry == null) return null;
    return (received: entry.chunks.length, total: entry.offer?.totalChunks);
  }

  /// The OFFER of a stream in progress, or null if unknown or not yet received.
  FileOffer? offerOf(FileStreamKey key) => _incoming[key]?.offer;

  /// Drops everything (disconnect or new session).
  void clear() {
    _incoming.clear();
    _completed.clear();
  }

  /// Drops every stream that arrived on [channelIndex], whose radio slot now
  /// holds a different channel.
  void clearChannel(int channelIndex) {
    _incoming.removeWhere((k, _) => k.channelIndex == channelIndex);
    _completed.removeWhere((k, _) => k.channelIndex == channelIndex);
  }

  void evictExpired({DateTime? now}) {
    final at = now ?? _clock();
    _incoming.removeWhere((_, e) => at.difference(e.lastSeen) >= ttl);
    _completed.removeWhere((_, c) => at.difference(c.at) >= completedTtl);
  }

  /// Feeds one received GRP_DATA blob of type [dataTypeFileTransfer].
  FileBlobOutcome addBlob(
    Uint8List blob, {
    int channelIndex = 0,
    DateTime? now,
  }) {
    final at = now ?? _clock();
    evictExpired(now: at);

    final header = parseFileHeader(blob);
    if (header == null) return const FileBlobOutcome(FileBlobStatus.malformed);
    if (selfPrefix != null && header.senderPrefix == selfPrefix) {
      return FileBlobOutcome(FileBlobStatus.fromSelf, header: header);
    }

    final key = FileStreamKey(
      senderPrefix: header.senderPrefix,
      session: header.session,
      channelIndex: channelIndex,
    );

    switch (header.kind) {
      case kFileKindStatus:
        return FileBlobOutcome(FileBlobStatus.ignored, header: header);
      case kFileKindCancel:
        _incoming.remove(key);
        return FileBlobOutcome(FileBlobStatus.ignored, header: header);
      case kFileKindOffer:
        return _onOffer(blob, header, key, at);
      case kFileKindData:
        return _onData(blob, header, key, at);
      case kFileKindProbe:
        return _onProbe(header, key, at);
    }
    return FileBlobOutcome(FileBlobStatus.malformed, header: header);
  }

  FileBlobOutcome _onOffer(
    Uint8List blob,
    FileBlobHeader header,
    FileStreamKey key,
    DateTime at,
  ) {
    final offer = parseFileOffer(blob);
    if (offer == null) {
      return FileBlobOutcome(FileBlobStatus.rejected, header: header);
    }

    final done = _completed[key];
    if (done != null) {
      if (done.crc == offer.crc && done.received == offer.totalChunks) {
        return FileBlobOutcome(FileBlobStatus.duplicate, header: header);
      }
      // Same session id, different file: a new transfer reusing the id.
      _completed.remove(key);
    }

    var entry = _incoming[key];
    final known = entry?.offer;
    if (entry != null &&
        known != null &&
        (known.crc != offer.crc || known.totalChunks != offer.totalChunks)) {
      _incoming.remove(key);
      entry = null;
    }
    if (entry == null) {
      entry = _Incoming(key, at);
      _incoming[key] = entry;
      _evictOverflow();
    }
    entry.lastSeen = at;
    if (entry.offer != null) {
      return FileBlobOutcome(FileBlobStatus.duplicate, header: header);
    }
    // Chunks that arrived before the OFFER must fit the file it describes.
    final lengthsOk = entry.chunks.entries.every(
      (c) => _bodyLengthOk(offer, c.key, c.value.length),
    );
    if (!lengthsOk) {
      _incoming.remove(key);
      return FileBlobOutcome(FileBlobStatus.malformed, header: header);
    }
    entry.offer = offer;
    return _tryFinish(entry, header, FileBlobStatus.offerAccepted, at);
  }

  FileBlobOutcome _onData(
    Uint8List blob,
    FileBlobHeader header,
    FileStreamKey key,
    DateTime at,
  ) {
    if (blob.length <= kFileDataHeaderBytes) {
      return FileBlobOutcome(FileBlobStatus.malformed, header: header);
    }
    if (_completed.containsKey(key)) {
      return FileBlobOutcome(FileBlobStatus.duplicate, header: header);
    }
    final index = _u16(blob, 4);
    final body = Uint8List.sublistView(blob, kFileDataHeaderBytes);

    var entry = _incoming[key];
    final offer = entry?.offer;
    if (offer != null) {
      if (!_bodyLengthOk(offer, index, body.length)) {
        return FileBlobOutcome(FileBlobStatus.malformed, header: header);
      }
    } else if (index >= fileChunkCount(kFileMaxBytes) ||
        body.length > kFileChunkBodyBytes) {
      return FileBlobOutcome(FileBlobStatus.malformed, header: header);
    }
    if (entry == null) {
      entry = _Incoming(key, at);
      _incoming[key] = entry;
      _evictOverflow();
    }
    entry.lastSeen = at;
    if (entry.chunks.containsKey(index)) {
      return FileBlobOutcome(FileBlobStatus.duplicate, header: header);
    }
    entry.chunks[index] = Uint8List.fromList(body);
    return _tryFinish(entry, header, FileBlobStatus.chunkAccepted, at);
  }

  FileBlobOutcome _onProbe(
    FileBlobHeader header,
    FileStreamKey key,
    DateTime at,
  ) {
    final self = selfPrefix ?? 0;
    final done = _completed[key];
    if (done != null) {
      return FileBlobOutcome(
        FileBlobStatus.probeAnswered,
        header: header,
        reply: _buildStatus(
          replierPrefix: self,
          session: header.session,
          targetPrefix: header.senderPrefix,
          complete: true,
          needOffer: false,
          received: done.received,
          missing: const <int>[],
        ),
      );
    }
    final entry = _incoming[key];
    final offer = entry?.offer;
    final missing = <int>[];
    if (offer != null) {
      for (
        var i = 0;
        i < offer.totalChunks && missing.length < kFileStatusMaxMissing;
        i++
      ) {
        if (!entry!.chunks.containsKey(i)) missing.add(i);
      }
      entry!.lastSeen = at;
    }
    return FileBlobOutcome(
      FileBlobStatus.probeAnswered,
      header: header,
      reply: _buildStatus(
        replierPrefix: self,
        session: header.session,
        targetPrefix: header.senderPrefix,
        complete: false,
        needOffer: offer == null,
        received: entry?.chunks.length ?? 0,
        missing: missing,
      ),
    );
  }

  bool _bodyLengthOk(FileOffer offer, int index, int length) {
    if (index >= offer.totalChunks) return false;
    final expected = index == offer.totalChunks - 1
        ? offer.size - index * kFileChunkBodyBytes
        : kFileChunkBodyBytes;
    return length == expected;
  }

  FileBlobOutcome _tryFinish(
    _Incoming entry,
    FileBlobHeader header,
    FileBlobStatus pending,
    DateTime at,
  ) {
    final offer = entry.offer;
    if (offer == null || entry.chunks.length != offer.totalChunks) {
      return FileBlobOutcome(pending, header: header);
    }
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < offer.totalChunks; i++) {
      final chunk = entry.chunks[i];
      if (chunk == null) {
        return FileBlobOutcome(pending, header: header);
      }
      out.add(chunk);
    }
    final data = out.toBytes();
    _incoming.remove(entry.key);
    if (data.length != offer.size || crc32(data) != offer.crc) {
      return FileBlobOutcome(FileBlobStatus.integrityFailed, header: header);
    }
    _completed[entry.key] = _Completed(at, offer.crc, offer.totalChunks);
    _trimCompleted();
    return FileBlobOutcome(
      FileBlobStatus.completed,
      header: header,
      reply: _buildStatus(
        replierPrefix: selfPrefix ?? 0,
        session: header.session,
        targetPrefix: header.senderPrefix,
        complete: true,
        needOffer: false,
        received: offer.totalChunks,
        missing: const <int>[],
      ),
      result: FileReassemblyResult(
        key: entry.key,
        name: offer.name,
        compressed: offer.isCompressed,
        data: data,
      ),
    );
  }

  void _evictOverflow() {
    while (_incoming.length > maxConcurrentStreams) {
      FileStreamKey? oldestKey;
      DateTime? oldest;
      _incoming.forEach((k, e) {
        if (oldest == null || e.lastSeen.isBefore(oldest!)) {
          oldest = e.lastSeen;
          oldestKey = k;
        }
      });
      if (oldestKey == null) return;
      _incoming.remove(oldestKey);
    }
  }

  void _trimCompleted() {
    while (_completed.length > maxCompletedStreams) {
      FileStreamKey? oldestKey;
      DateTime? oldest;
      _completed.forEach((k, c) {
        if (oldest == null || c.at.isBefore(oldest!)) {
          oldest = c.at;
          oldestKey = k;
        }
      });
      if (oldestKey == null) return;
      _completed.remove(oldestKey);
    }
  }
}
