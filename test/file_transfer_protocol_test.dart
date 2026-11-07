import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/file_transfer_protocol.dart';

Uint8List _bytes(int n, {int seed = 1}) {
  final r = math.Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

FileSendPlan _plan(Uint8List data, {int session = 7, String name = 'a.bin'}) {
  return FileSendPlan.build(
    data: data,
    name: name,
    senderPrefix: 0xAABB,
    session: session,
  );
}

/// Runs the OFFER/DATA/PROBE/STATUS loop. [lose] decides which sender->receiver
/// blobs are dropped, given the round and the blob.
FileBlobOutcome? _transfer(
  FileSendPlan plan,
  FileReassembler rx, {
  bool Function(int round, Uint8List blob)? lose,
  int maxRounds = 20,
}) {
  FileBlobOutcome? completed;
  var pending = plan.initialBurst;
  for (var round = 0; round < maxRounds && !plan.isComplete; round++) {
    Uint8List? reply;
    for (final blob in pending) {
      if (lose != null && lose(round, blob)) continue;
      final out = rx.addBlob(blob);
      if (out.status == FileBlobStatus.completed) completed = out;
      if (out.reply != null) reply = out.reply;
    }
    if (reply == null) {
      pending = <Uint8List>[plan.probe];
      continue;
    }
    final status = parseFileStatus(reply)!;
    pending = plan.onStatus(status);
  }
  return completed;
}

void main() {
  test('crc32 matches the standard check value', () {
    expect(crc32('123456789'.codeUnits), 0xCBF43926);
    expect(crc32(const <int>[]), 0);
  });

  test('wire constants stay inside one GRP_DATA blob', () {
    expect(kFileChunkBodyBytes, 157);
    expect(kFileDataHeaderBytes + kFileChunkBodyBytes, kFileBlobBytes);
    expect(
      kFileStatusFixedBytes + kFileStatusMaxMissing * 2,
      lessThanOrEqualTo(kFileBlobBytes),
    );
    expect(
      kFileOfferFixedBytes + kFileMaxNameBytes,
      lessThanOrEqualTo(kFileBlobBytes),
    );
    expect(fileChunkCount(0), 0);
    expect(fileChunkCount(1), 1);
    expect(fileChunkCount(157), 1);
    expect(fileChunkCount(158), 2);
  });

  test('every built blob fits and parses', () {
    final plan = _plan(_bytes(30000));
    expect(plan.totalChunks, fileChunkCount(30000));
    for (final blob in plan.initialBurst) {
      expect(blob.length, lessThanOrEqualTo(kFileBlobBytes));
      expect(parseFileHeader(blob), isNotNull);
    }
    final offer = parseFileOffer(plan.offer)!;
    expect(offer.size, 30000);
    expect(offer.totalChunks, plan.totalChunks);
    expect(offer.crc, crc32(_bytes(30000)));
    expect(offer.name, 'a.bin');
    expect(offer.isCompressed, isFalse);
  });

  test('build rejects empty and oversized files', () {
    expect(() => _plan(Uint8List(0)), throwsArgumentError);
    expect(() => _plan(Uint8List(kFileMaxBytes + 1)), throwsArgumentError);
    expect(_plan(Uint8List(kFileMaxBytes)).totalChunks, greaterThan(0));
  });

  test('lossless delivery in one round', () {
    final data = _bytes(10000);
    final plan = _plan(data);
    final rx = FileReassembler(selfPrefix: 0x1111);
    final done = _transfer(plan, rx);
    expect(done, isNotNull);
    expect(done!.result!.data, data);
    expect(done.result!.name, 'a.bin');
    expect(done.result!.compressed, isFalse);
    expect(plan.isComplete, isTrue);
  });

  test('single-chunk and exact-boundary files', () {
    for (final n in <int>[1, 156, 157, 158, 314, 315]) {
      final data = _bytes(n, seed: n);
      final plan = _plan(data);
      final rx = FileReassembler(selfPrefix: 0x1111);
      final done = _transfer(plan, rx);
      expect(done?.result?.data, data, reason: 'size $n');
    }
  });

  test('recovers from random loss through STATUS retransmission', () {
    final data = _bytes(30000, seed: 3);
    final plan = _plan(data);
    final rx = FileReassembler(selfPrefix: 0x1111);
    final rng = math.Random(42);
    final done = _transfer(
      plan,
      rx,
      lose: (round, blob) => rng.nextDouble() < 0.3,
      maxRounds: 60,
    );
    expect(done, isNotNull);
    expect(done!.result!.data, data);
  });

  test('recovers when the OFFER and the first PROBE are lost', () {
    final data = _bytes(2000, seed: 5);
    final plan = _plan(data);
    final rx = FileReassembler(selfPrefix: 0x1111);
    final done = _transfer(
      plan,
      rx,
      lose: (round, blob) => round == 0 && blob[0] != kFileKindData,
    );
    expect(done?.result?.data, data);
  });

  test('out-of-order delivery and duplicates are tolerated', () {
    final data = _bytes(1000, seed: 9);
    final plan = _plan(data);
    final rx = FileReassembler(selfPrefix: 0x1111);
    final order = <Uint8List>[...plan.chunks.reversed, plan.offer];
    FileBlobOutcome? last;
    for (final blob in order) {
      last = rx.addBlob(blob);
    }
    expect(last!.status, FileBlobStatus.completed);
    expect(last.result!.data, data);
    expect(rx.addBlob(plan.chunks[0]).status, FileBlobStatus.duplicate);
    expect(rx.addBlob(plan.offer).status, FileBlobStatus.duplicate);
  });

  test('chunk-bearing duplicates before completion are reported', () {
    final plan = _plan(_bytes(400));
    final rx = FileReassembler(selfPrefix: 0x1111);
    expect(rx.addBlob(plan.offer).status, FileBlobStatus.offerAccepted);
    expect(rx.addBlob(plan.chunks[0]).status, FileBlobStatus.chunkAccepted);
    expect(rx.addBlob(plan.chunks[0]).status, FileBlobStatus.duplicate);
  });

  test('STATUS lists missing chunks and the probe asks for them', () {
    final data = _bytes(157 * 5);
    final plan = _plan(data);
    final rx = FileReassembler(selfPrefix: 0x1111);
    rx.addBlob(plan.offer);
    rx.addBlob(plan.chunks[0]);
    rx.addBlob(plan.chunks[2]);
    rx.addBlob(plan.chunks[4]);
    final out = rx.addBlob(plan.probe);
    expect(out.status, FileBlobStatus.probeAnswered);
    final status = parseFileStatus(out.reply!)!;
    expect(status.complete, isFalse);
    expect(status.needOffer, isFalse);
    expect(status.missing, <int>[1, 3]);
    expect(status.receivedChunks, 3);
    expect(status.replierPrefix, 0x1111);
    expect(status.targetPrefix, 0xAABB);
    final resend = plan.onStatus(status);
    expect(resend, <Uint8List>[plan.chunks[1], plan.chunks[3], plan.probe]);
  });

  test('probe before the OFFER asks for the OFFER', () {
    final plan = _plan(_bytes(500));
    final rx = FileReassembler(selfPrefix: 0x1111);
    final status = parseFileStatus(rx.addBlob(plan.probe).reply!)!;
    expect(status.needOffer, isTrue);
    expect(status.missing, isEmpty);
    expect(plan.onStatus(status), <Uint8List>[plan.offer, plan.probe]);
  });

  test('STATUS missing list is capped and then continues next round', () {
    final data = _bytes(kFileChunkBodyBytes * 200);
    final plan = _plan(data);
    final rx = FileReassembler(selfPrefix: 0x1111);
    rx.addBlob(plan.offer);
    final status = parseFileStatus(rx.addBlob(plan.probe).reply!)!;
    expect(status.missing.length, kFileStatusMaxMissing);
    expect(status.missing.first, 0);
  });

  test('a late probe after completion gets a complete STATUS', () {
    final plan = _plan(_bytes(300));
    final rx = FileReassembler(selfPrefix: 0x1111);
    for (final blob in plan.initialBurst) {
      rx.addBlob(blob);
    }
    final status = parseFileStatus(rx.addBlob(plan.probe).reply!)!;
    expect(status.complete, isTrue);
    plan.onStatus(status);
    expect(plan.isComplete, isTrue);
  });

  test('STATUS for another session or sender is ignored by the plan', () {
    final plan = _plan(_bytes(300), session: 7);
    const other = FileStatus(
      replierPrefix: 0x1111,
      session: 8,
      targetPrefix: 0xAABB,
      complete: true,
      needOffer: false,
      receivedChunks: 2,
      missing: <int>[],
    );
    expect(plan.onStatus(other), isEmpty);
    expect(plan.isComplete, isFalse);
    const wrongTarget = FileStatus(
      replierPrefix: 0x1111,
      session: 7,
      targetPrefix: 0x0001,
      complete: true,
      needOffer: false,
      receivedChunks: 2,
      missing: <int>[],
    );
    expect(plan.onStatus(wrongTarget), isEmpty);
    expect(plan.isComplete, isFalse);
  });

  test('corrupted chunk fails the CRC and the transfer restarts cleanly', () {
    final data = _bytes(600, seed: 11);
    final plan = _plan(data);
    final rx = FileReassembler(selfPrefix: 0x1111);
    final bad = Uint8List.fromList(plan.chunks[1]);
    bad[kFileDataHeaderBytes] ^= 0xFF;
    rx.addBlob(plan.offer);
    rx.addBlob(plan.chunks[0]);
    for (var i = 2; i < plan.chunks.length; i++) {
      rx.addBlob(plan.chunks[i]);
    }
    expect(rx.addBlob(bad).status, FileBlobStatus.integrityFailed);
    expect(rx.pendingCount, 0);

    final status = parseFileStatus(rx.addBlob(plan.probe).reply!)!;
    expect(status.needOffer, isTrue);
    final done = _transfer(plan, rx);
    expect(done?.result?.data, data);
  });

  test('chunk with the wrong length is malformed once the OFFER is known', () {
    final plan = _plan(_bytes(400));
    final rx = FileReassembler(selfPrefix: 0x1111);
    rx.addBlob(plan.offer);
    final short = Uint8List.sublistView(plan.chunks[0], 0, 20);
    expect(rx.addBlob(short).status, FileBlobStatus.malformed);
  });

  test('inconsistent OFFER is rejected', () {
    final plan = _plan(_bytes(400));
    final bad = Uint8List.fromList(plan.offer);
    bad[5] = bad[5] + 1; // total chunks no longer matches size
    final rx = FileReassembler(selfPrefix: 0x1111);
    expect(rx.addBlob(bad).status, FileBlobStatus.rejected);
    expect(rx.pendingCount, 0);
  });

  test('own blobs are dropped as loopback', () {
    final plan = _plan(_bytes(100));
    final rx = FileReassembler(selfPrefix: 0xAABB);
    expect(rx.addBlob(plan.offer).status, FileBlobStatus.fromSelf);
    expect(rx.addBlob(plan.chunks[0]).status, FileBlobStatus.fromSelf);
  });

  test('garbage is malformed', () {
    final rx = FileReassembler(selfPrefix: 0x1111);
    expect(rx.addBlob(Uint8List(0)).status, FileBlobStatus.malformed);
    expect(rx.addBlob(Uint8List(3)).status, FileBlobStatus.malformed);
    expect(
      rx.addBlob(Uint8List.fromList(<int>[kFileKindMask, 0, 0, 0, 0])).status,
      FileBlobStatus.malformed,
    );
    expect(
      rx.addBlob(Uint8List(kFileBlobBytes + 1)).status,
      FileBlobStatus.malformed,
    );
  });

  test('CANCEL drops partial state', () {
    final plan = _plan(_bytes(400));
    final rx = FileReassembler(selfPrefix: 0x1111);
    rx.addBlob(plan.offer);
    expect(rx.pendingCount, 1);
    rx.addBlob(buildFileCancel(senderPrefix: 0xAABB, session: 7));
    expect(rx.pendingCount, 0);
  });

  test('session id reuse with a different file starts a new transfer', () {
    final first = _plan(_bytes(200, seed: 1), session: 9);
    final second = _plan(_bytes(200, seed: 2), session: 9);
    final rx = FileReassembler(selfPrefix: 0x1111);
    expect(_transfer(first, rx)?.result?.data, _bytes(200, seed: 1));
    final done = _transfer(second, rx);
    expect(done?.result?.data, _bytes(200, seed: 2));
  });

  test('partial transfers expire after the TTL', () {
    var now = DateTime(2026, 11, 7, 12);
    final rx = FileReassembler(
      selfPrefix: 0x1111,
      ttl: const Duration(minutes: 5),
      clock: () => now,
    );
    final plan = _plan(_bytes(400));
    rx.addBlob(plan.offer);
    expect(rx.pendingCount, 1);
    now = now.add(const Duration(minutes: 6));
    rx.evictExpired();
    expect(rx.pendingCount, 0);
  });

  test('concurrent streams are capped', () {
    final rx = FileReassembler(selfPrefix: 0x1111, maxConcurrentStreams: 2);
    for (var s = 0; s < 5; s++) {
      rx.addBlob(_plan(_bytes(400, seed: s), session: s).offer);
    }
    expect(rx.pendingCount, 2);
  });

  test('file names are cut on a character boundary', () {
    final name = 'ф' * 80; // 160 utf8 bytes
    final plan = _plan(_bytes(10), name: name);
    final offer = parseFileOffer(plan.offer)!;
    expect(offer.name, 'ф' * 50);
    expect(
      parseFileOffer(plan.offer)!.name.runes.every((r) => r == 0x444),
      isTrue,
    );
  });

  test('received file names are sanitized', () {
    expect(sanitizeFileName('../../etc/passwd'), '_.._etc_passwd');
    expect(sanitizeFileName(r'C:\Windows\x.exe'), 'C__Windows_x.exe');
    expect(sanitizeFileName('  ..hidden.txt. '), 'hidden.txt');
    expect(sanitizeFileName('a\u0000b\nc'), 'a_b_c');
    expect(sanitizeFileName('...'), 'file');
    expect(sanitizeFileName(''), 'file');
    expect(sanitizeFileName('звіт 2026.pdf'), 'звіт 2026.pdf');
    final plan = _plan(_bytes(10), name: '../x.bin');
    expect(parseFileOffer(plan.offer)!.name, '_x.bin');
  });

  test('compressed flag survives the round trip', () {
    final plan = FileSendPlan.build(
      data: _bytes(50),
      name: 'z.txt.z',
      senderPrefix: 0xAABB,
      session: 1,
      compressed: true,
    );
    final rx = FileReassembler(selfPrefix: 0x1111);
    final done = _transfer(plan, rx);
    expect(done?.result?.compressed, isTrue);
  });

  test('session allocator wraps at 256 and honours a seed', () {
    final a = FileSessionAllocator(seed: 254);
    expect(<int>[a.next(), a.next(), a.next()], <int>[254, 255, 0]);
  });

  test('salt changes the bytes but not the meaning', () {
    final plan = _plan(_bytes(400));
    for (final blob in <Uint8List>[plan.offer, plan.chunks[0], plan.probe]) {
      final salted = withFileSalt(blob, 5);
      expect(salted, isNot(equals(blob)));
      expect(salted.sublist(1), blob.sublist(1));
      final a = parseFileHeader(blob)!;
      final b = parseFileHeader(salted)!;
      expect(b.kind, a.kind);
      expect(b.senderPrefix, a.senderPrefix);
      expect(b.session, a.session);
    }
    expect(withFileSalt(plan.probe, 0), plan.probe);
    expect(withFileSalt(plan.probe, 8), plan.probe);
  });

  test(
    'a salted transfer still reassembles and a salted probe is answered',
    () {
      final data = _bytes(900);
      final plan = _plan(data);
      final rx = FileReassembler(selfPrefix: 0x1111);
      FileBlobOutcome last = rx.addBlob(withFileSalt(plan.offer, 3));
      for (final c in plan.chunks) {
        last = rx.addBlob(withFileSalt(c, 6));
      }
      expect(last.status, FileBlobStatus.completed);
      expect(last.result!.data, data);
      // Completion carries an unsolicited "got it".
      final done = parseFileStatus(last.reply!)!;
      expect(done.complete, isTrue);
      expect(done.targetPrefix, plan.senderPrefix);
      final out = rx.addBlob(withFileSalt(plan.probe, 2));
      expect(out.status, FileBlobStatus.probeAnswered);
      expect(parseFileStatus(withFileSalt(out.reply!, 4))!.complete, isTrue);
    },
  );
}
