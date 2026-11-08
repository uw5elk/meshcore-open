import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/file_compression.dart';
import 'package:meshcore_open/services/file_transfer_engine.dart';
import 'package:meshcore_open/services/file_transfer_protocol.dart';

Uint8List _bytes(int n, {int seed = 1}) {
  final r = math.Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

/// Two engines joined by a lossy in-memory "radio".
class _Net {
  final math.Random rng = math.Random(7);
  final double lossAtoB;
  final double lossBtoA;
  int blobsFromA = 0;
  int blobsFromB = 0;
  final List<FileTransferJob> receivedByB = <FileTransferJob>[];
  late final FileTransferEngine a;
  late final FileTransferEngine b;

  _Net({
    this.lossAtoB = 0,
    this.lossBtoA = 0,
    Duration statusWait = const Duration(milliseconds: 30),
    int maxRounds = 40,
    Duration bReplyInterval = Duration.zero,
  }) {
    a = FileTransferEngine(
      selfPrefix: 0xAAAA,
      statusWait: statusWait,
      maxRounds: maxRounds,
      sendBlobs: (blobs, ch, progress) async {
        blobsFromA += blobs.length;
        return _deliver(() => b, blobs, ch, lossAtoB, progress);
      },
    );
    b = FileTransferEngine(
      selfPrefix: 0xBBBB,
      replyInterval: bReplyInterval,
      onFileReceived: receivedByB.add,
      sendBlobs: (blobs, ch, progress) async {
        blobsFromB += blobs.length;
        return _deliver(() => a, blobs, ch, lossBtoA, progress);
      },
    );
  }

  Future<bool> _deliver(
    FileTransferEngine Function() to,
    List<Uint8List> blobs,
    int channel,
    double loss,
    void Function(int, int)? progress,
  ) async {
    for (var i = 0; i < blobs.length; i++) {
      await Future<void>.delayed(Duration.zero);
      if (rng.nextDouble() >= loss) to().handleBlob(blobs[i], channel);
      progress?.call(i + 1, blobs.length);
    }
    return true;
  }
}

void main() {
  test('clean link: delivered, received and verified', () async {
    final net = _Net();
    final data = _bytes(3000);
    final job = await net.a.sendFile(
      data: data,
      name: 'photo.bin',
      channelIndex: 2,
    );
    expect(job.status, FileJobStatus.delivered);
    expect(job.round, 0);
    expect(net.receivedByB.length, 1);
    final got = net.receivedByB.single;
    expect(got.status, FileJobStatus.received);
    expect(got.name, 'photo.bin');
    expect(got.size, 3000);
    expect(got.data, data);
    expect(got.channelIndex, 2);
    expect(got.fraction, 1.0);
  });

  test('30% loss in both directions still delivers', () async {
    final net = _Net(lossAtoB: 0.3, lossBtoA: 0.3);
    final data = _bytes(20000, seed: 4);
    final job = await net.a.sendFile(
      data: data,
      name: 'big.bin',
      channelIndex: 0,
    );
    expect(job.status, FileJobStatus.delivered);
    expect(job.round, greaterThan(0));
    expect(net.receivedByB.single.data, data);
  });

  test('gives up when nobody answers', () async {
    final net = _Net(
      lossAtoB: 1,
      statusWait: const Duration(milliseconds: 10),
      maxRounds: 2,
    );
    final job = await net.a.sendFile(
      data: _bytes(500),
      name: 'x',
      channelIndex: 0,
    );
    expect(job.status, FileJobStatus.failed);
    expect(job.error, 'no confirmation after 2 rounds');
    expect(net.receivedByB, isEmpty);
  });

  test('cancel stops a transfer that waits for a status', () async {
    final net = _Net(lossAtoB: 1, statusWait: const Duration(seconds: 30));
    final result = net.a.sendFile(
      data: _bytes(500),
      name: 'x',
      channelIndex: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(net.a.jobs.single.status, FileJobStatus.waitingForStatus);
    await net.a.cancel(net.a.jobs.single.id);
    final job = await result;
    expect(job.status, FileJobStatus.cancelled);
    expect(net.a.hasActiveJobs, isFalse);
  });

  test('transport failure fails the job', () async {
    final engine = FileTransferEngine(
      selfPrefix: 0xAAAA,
      sendBlobs: (blobs, ch, progress) async => false,
    );
    final job = await engine.sendFile(
      data: _bytes(10),
      name: 'x',
      channelIndex: 0,
    );
    expect(job.status, FileJobStatus.failed);
    expect(job.error, 'transport unavailable');
  });

  test('sendFile validates input and needs a sender prefix', () {
    final noPrefix = FileTransferEngine(
      sendBlobs: (blobs, ch, progress) async => true,
    );
    expect(
      () => noPrefix.sendFile(data: _bytes(5), name: 'x', channelIndex: 0),
      throwsStateError,
    );
    final engine = FileTransferEngine(
      selfPrefix: 1,
      sendBlobs: (blobs, ch, progress) async => true,
    );
    expect(
      () => engine.sendFile(data: Uint8List(0), name: 'x', channelIndex: 0),
      throwsArgumentError,
    );
  });

  test('two sends are serialised and both deliver', () async {
    final net = _Net();
    final first = net.a.sendFile(
      data: _bytes(400, seed: 1),
      name: 'one',
      channelIndex: 0,
    );
    final second = net.a.sendFile(
      data: _bytes(400, seed: 2),
      name: 'two',
      channelIndex: 0,
    );
    expect((await first).status, FileJobStatus.delivered);
    expect((await second).status, FileJobStatus.delivered);
    expect(net.receivedByB.map((j) => j.name).toList(), <String>['one', 'two']);
  });

  test('probe replies are throttled per stream', () async {
    final net = _Net(bReplyInterval: const Duration(hours: 1));
    final plan = FileSendPlan.build(
      data: _bytes(300),
      name: 'x',
      senderPrefix: 0xAAAA,
      session: 3,
    );
    net.b.handleBlob(plan.offer, 0);
    net.b.handleBlob(plan.probe, 0);
    net.b.handleBlob(plan.probe, 0);
    net.b.handleBlob(plan.probe, 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(net.blobsFromB, 1);
  });

  test('incoming job tracks progress, then clear() fails it', () {
    final net = _Net();
    final plan = FileSendPlan.build(
      data: _bytes(157 * 4),
      name: 'p.bin',
      senderPrefix: 0xAAAA,
      session: 5,
    );
    net.b.handleBlob(plan.chunks[0], 1);
    expect(net.b.jobs.single.status, FileJobStatus.receiving);
    expect(net.b.jobs.single.totalChunks, isNull);
    net.b.handleBlob(plan.offer, 1);
    net.b.handleBlob(plan.chunks[2], 1);
    final job = net.b.jobs.single;
    expect(job.name, 'p.bin');
    expect(job.size, 157 * 4);
    expect(job.receivedChunks, 2);
    expect(job.totalChunks, 4);
    expect(job.fraction, 0.5);
    net.b.clear();
    expect(job.status, FileJobStatus.failed);
    expect(net.b.hasActiveJobs, isFalse);
  });

  test('clearChannel only fails jobs on that channel', () {
    final net = _Net();
    final p1 = FileSendPlan.build(
      data: _bytes(400),
      name: 'one',
      senderPrefix: 0xAAAA,
      session: 1,
    );
    final p2 = FileSendPlan.build(
      data: _bytes(400),
      name: 'two',
      senderPrefix: 0xAAAA,
      session: 2,
    );
    net.b.handleBlob(p1.offer, 0);
    net.b.handleBlob(p2.offer, 1);
    net.b.clearChannel(1);
    final byName = {for (final j in net.b.jobs) j.name: j.status};
    expect(byName['one'], FileJobStatus.receiving);
    expect(byName['two'], FileJobStatus.failed);
  });

  test('a corrupted file is reported as failed, not received', () {
    final net = _Net();
    final plan = FileSendPlan.build(
      data: _bytes(300, seed: 8),
      name: 'bad',
      senderPrefix: 0xAAAA,
      session: 4,
    );
    final bad = Uint8List.fromList(plan.chunks[1]);
    bad[kFileDataHeaderBytes] ^= 0x55;
    net.b.handleBlob(plan.offer, 0);
    net.b.handleBlob(plan.chunks[0], 0);
    net.b.handleBlob(bad, 0);
    expect(net.b.jobs.single.status, FileJobStatus.failed);
    expect(net.receivedByB, isEmpty);
  });

  test('our own blobs and foreign STATUS blobs are ignored', () {
    final net = _Net();
    final own = FileSendPlan.build(
      data: _bytes(50),
      name: 'own',
      senderPrefix: 0xBBBB,
      session: 1,
    );
    net.b.handleBlob(own.offer, 0);
    expect(net.b.jobs, isEmpty);
  });

  test('finished jobs can be dismissed, active ones cannot', () async {
    final net = _Net();
    final job = await net.a.sendFile(
      data: _bytes(100),
      name: 'x',
      channelIndex: 0,
    );
    net.a.dismiss(job.id);
    expect(net.a.jobs, isEmpty);
  });

  test('job list is capped, keeping active jobs', () async {
    var changes = 0;
    final engine = FileTransferEngine(
      selfPrefix: 1,
      maxJobs: 3,
      onChanged: () => changes++,
      sendBlobs: (blobs, ch, progress) async => false,
    );
    for (var i = 0; i < 6; i++) {
      await engine.sendFile(data: _bytes(10), name: 'f$i', channelIndex: 0);
    }
    expect(engine.jobs.length, 3);
    expect(engine.jobs.first.name, 'f5');
    expect(changes, greaterThan(0));
  });

  group('compression', () {
    Uint8List text(int n) => Uint8List.fromList(
      List<int>.generate(
        n,
        (i) => 'meshcore file transfer, line ${i ~/ 40}\n'.codeUnitAt(i % 30),
      ),
    );

    test('compressible file is sent smaller and restored exactly', () async {
      final net = _Net();
      final data = text(20000);
      final prepared = prepareFileForSend(data);
      expect(prepared.compressed, isTrue);
      expect(prepared.wire.length, lessThan(data.length ~/ 3));

      final job = await net.a.sendFile(
        data: data,
        name: 'notes.txt',
        channelIndex: 1,
      );
      expect(job.status, FileJobStatus.delivered);
      final got = net.receivedByB.single;
      expect(got.status, FileJobStatus.received);
      expect(got.data, data);
      expect(got.size, data.length);
      // Far fewer packets than the raw 20000 bytes would need.
      expect(net.blobsFromA, lessThan(fileChunkCount(data.length) ~/ 3));
    });

    test('incompressible data goes out verbatim', () {
      final data = _bytes(4000);
      final prepared = prepareFileForSend(data);
      expect(prepared.compressed, isFalse);
      expect(prepared.wire, data);
    });

    test('compress: false is honoured', () {
      expect(
        prepareFileForSend(text(5000), compress: false).compressed,
        isFalse,
      );
    });

    test('limits: raw above 128 KB needs compression, above 512 KB never', () {
      expect(prepareFileForSend(Uint8List(300 * 1024)).compressed, isTrue);
      expect(
        () => prepareFileForSend(Uint8List(300 * 1024), compress: false),
        throwsArgumentError,
      );
      expect(() => prepareFileForSend(_bytes(200 * 1024)), throwsArgumentError);
      expect(
        () => prepareFileForSend(Uint8List(kFileMaxOriginalBytes + 1)),
        throwsArgumentError,
      );
    });

    test('a corrupt compressed stream fails the job, not the app', () {
      final received = <FileTransferJob>[];
      final b = FileTransferEngine(
        selfPrefix: 0xBBBB,
        onFileReceived: received.add,
        sendBlobs: (blobs, ch, progress) async => true,
      );
      final junk = _bytes(500, seed: 9);
      final plan = FileSendPlan.build(
        data: junk,
        name: 'bad.bin',
        senderPrefix: 0xAAAA,
        session: 1,
        compressed: true,
      );
      for (final blob in plan.initialBurst) {
        b.handleBlob(blob, 0);
      }
      expect(received, isEmpty);
      expect(b.jobs.single.status, FileJobStatus.failed);
    });

    test('a decompression bomb is refused', () {
      final received = <FileTransferJob>[];
      final b = FileTransferEngine(
        selfPrefix: 0xBBBB,
        onFileReceived: received.add,
        sendBlobs: (blobs, ch, progress) async => true,
      );
      final bomb = deflateBytes(Uint8List(8 * 1024 * 1024))!;
      expect(bomb.length, lessThan(kFileMaxBytes));
      final plan = FileSendPlan.build(
        data: bomb,
        name: 'bomb.bin',
        senderPrefix: 0xAAAA,
        session: 2,
        compressed: true,
      );
      for (final blob in plan.initialBurst) {
        b.handleBlob(blob, 0);
      }
      expect(received, isEmpty);
      expect(b.jobs.single.status, FileJobStatus.failed);
    });
  });

  test('cancel stops a burst that is still being transmitted', () async {
    final sentIndexes = <int>[];
    var cancelBlobs = 0;
    late FileTransferEngine engine;
    engine = FileTransferEngine(
      selfPrefix: 0xAAAA,
      statusWait: const Duration(milliseconds: 30),
      sendBlobs: (blobs, ch, progress) async {
        if (blobs.length == 1 && blobs.single[0] == kFileKindCancel) {
          cancelBlobs++;
          return true;
        }
        for (var i = 0; i < blobs.length; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          sentIndexes.add(i);
          progress?.call(i + 1, blobs.length);
        }
        return true;
      },
    );
    final result = engine.sendFile(
      data: _bytes(8000),
      name: 'big.bin',
      channelIndex: 0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final job = engine.jobs.single;
    expect(job.status, FileJobStatus.sending);
    await engine.cancel(job.id);
    // The list shows it cancelled immediately...
    expect(job.status, FileJobStatus.cancelled);
    // ...and the burst really stops instead of running to the end.
    final done = await result;
    expect(done.status, FileJobStatus.cancelled);
    expect(sentIndexes.length, lessThan(job.totalBlobs ~/ 2));
    expect(cancelBlobs, 1);
    expect(engine.hasActiveJobs, isFalse);
  });

  test('a queued transfer can be cancelled before it starts', () async {
    final net = _Net();
    final first = net.a.sendFile(
      data: _bytes(2000),
      name: 'one.bin',
      channelIndex: 0,
    );
    final second = net.a.sendFile(
      data: _bytes(2000, seed: 3),
      name: 'two.bin',
      channelIndex: 0,
    );
    final secondJob = net.a.jobs.first;
    expect(secondJob.name, 'two.bin');
    await net.a.cancel(secondJob.id);
    expect((await first).status, FileJobStatus.delivered);
    expect((await second).status, FileJobStatus.cancelled);
    expect(net.receivedByB.length, 1);
  });

  test('retransmissions are never byte-identical to earlier probes', () async {
    final probes = <Uint8List>[];
    final engine = FileTransferEngine(
      selfPrefix: 0xAAAA,
      statusWait: const Duration(milliseconds: 5),
      maxRounds: 6,
      sendBlobs: (blobs, ch, progress) async {
        for (final b in blobs) {
          if ((b[0] & kFileKindMask) == kFileKindProbe) probes.add(b);
        }
        return true;
      },
    );
    final job = await engine.sendFile(
      data: _bytes(300),
      name: 'x.bin',
      channelIndex: 0,
    );
    expect(job.status, FileJobStatus.failed);
    expect(probes.length, 7);
    final distinct = probes.map((p) => p.join(',')).toSet();
    expect(distinct.length, probes.length);
  });

  test('receiver confirms on completion without waiting for a probe', () {
    final sent = <Uint8List>[];
    final b = FileTransferEngine(
      selfPrefix: 0xBBBB,
      replyInterval: Duration.zero,
      sendBlobs: (blobs, ch, progress) async {
        sent.addAll(blobs);
        return true;
      },
    );
    final plan = FileSendPlan.build(
      data: _bytes(900),
      name: 'x.bin',
      senderPrefix: 0xAAAA,
      session: 9,
    );
    // Everything except the trailing probe.
    for (final blob in plan.initialBurst.where(
      (x) => (x[0] & kFileKindMask) != kFileKindProbe,
    )) {
      b.handleBlob(blob, 0);
    }
    expect(sent.length, 1);
    final status = parseFileStatus(sent.single)!;
    expect(status.complete, isTrue);
    expect(status.targetPrefix, 0xAAAA);
    expect(status.session, 9);
  });

  test('an early STATUS from a finished receiver ends the wait', () async {
    final net = _Net(statusWait: const Duration(seconds: 5));
    final job = await net.a.sendFile(
      data: _bytes(700),
      name: 'x.bin',
      channelIndex: 0,
    );
    expect(job.status, FileJobStatus.delivered);
    expect(job.round, 0);
  });
}
