import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/file_job_store.dart';
import 'package:meshcore_open/services/file_job_store_io.dart';
import 'package:meshcore_open/services/file_transfer_engine.dart';
import 'package:meshcore_open/services/file_transfer_service.dart';

StoredFile _file(String key, int minute, {String name = 'a.txt'}) => StoredFile(
  key: key,
  name: name,
  channelIndex: 1,
  receivedAt: DateTime(2026, 1, 1, 10, minute),
  data: Uint8List.fromList(<int>[1, 2, 3, minute]),
);

void main() {
  silentWaitTests();
  group('FileJobStoreIo', () {
    late Directory tmp;
    late FileJobStoreIo store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('file_job_store_test');
      store = FileJobStoreIo(baseDirectory: () async => tmp);
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('round-trips files newest first and deletes them', () async {
      expect(await store.save('abc1234567', _file('k1', 1)), isTrue);
      expect(await store.save('abc1234567', _file('k2', 2, name: 'b.png')),
          isTrue);
      final loaded = await store.load('abc1234567');
      expect(loaded.map((f) => f.name), <String>['b.png', 'a.txt']);
      expect(loaded.first.data, <int>[1, 2, 3, 2]);
      expect(loaded.first.channelIndex, 1);

      await store.delete('abc1234567', 'k2');
      expect((await store.load('abc1234567')).map((f) => f.key), <String>[
        'k1',
      ]);
    });

    test('radios are isolated from each other', () async {
      await store.save('radioaaaaa', _file('k1', 1));
      expect(await store.load('radiobbbbb'), isEmpty);
    });

    test('keeps only the newest maxFiles', () async {
      for (var i = 0; i < FileJobStore.maxFiles + 3; i++) {
        await store.save('abc1234567', _file('k$i', i));
      }
      final loaded = await store.load('abc1234567');
      expect(loaded, hasLength(FileJobStore.maxFiles));
      expect(loaded.first.key, 'k${FileJobStore.maxFiles + 2}');
    });

    test('rejects unsafe keys and radio ids', () async {
      expect(await store.save('abc1234567', _file('../evil', 1)), isFalse);
      expect(await store.save('../x', _file('k1', 1)), isFalse);
      expect(await store.load('../x'), isEmpty);
    });

    test('a hostile file name stays inside the record', () async {
      await store.save('abc1234567', _file('k1', 1, name: '../../evil.txt'));
      final loaded = await store.load('abc1234567');
      expect(loaded.single.name, '../../evil.txt');
      expect(File('${tmp.path}/evil.txt').existsSync(), isFalse);
    });
  });

  group('FileTransferService persistence', () {
    test('attachRadio restores saved files and dismiss deletes them', () async {
      final store = InMemoryFileJobStore();
      await store.save('radio00001', _file('k1', 3));
      final service = FileTransferService(
        sendBlobs: (blobs, ch, progress) async => true,
        store: store,
      );
      await service.attachRadio('radio00001');
      expect(service.jobs, hasLength(1));
      final job = service.jobs.single;
      expect(job.status, FileJobStatus.received);
      expect(job.data, <int>[1, 2, 3, 3]);

      service.dismiss(job.id);
      await Future<void>.delayed(Duration.zero);
      expect(service.jobs, isEmpty);
      expect(await store.load('radio00001'), isEmpty);
    });

    test('switching radio swaps the visible files', () async {
      final store = InMemoryFileJobStore();
      await store.save('radio00001', _file('k1', 1));
      await store.save('radio00002', _file('k2', 2, name: 'other.txt'));
      final service = FileTransferService(
        sendBlobs: (blobs, ch, progress) async => true,
        store: store,
      );
      await service.attachRadio('radio00001');
      await service.attachRadio('radio00002');
      expect(service.jobs.map((j) => j.name), <String>['other.txt']);
    });
  });
}

void silentWaitTests() {
  group('fileSilentWait', () {
    test('unknown radio parameters give 30 s', () {
      expect(
        fileSilentWait(
          spreadingFactor: null,
          bandwidthHz: null,
          codingRate: null,
        ),
        const Duration(seconds: 30),
      );
    });

    test('fast settings wait about 10 s, slow ones longer', () {
      final fast = fileSilentWait(
        spreadingFactor: 7,
        bandwidthHz: 250000,
        codingRate: 1,
      );
      final slow = fileSilentWait(
        spreadingFactor: 12,
        bandwidthHz: 125000,
        codingRate: 1,
      );
      expect(fast, greaterThanOrEqualTo(const Duration(seconds: 10)));
      expect(fast, lessThan(const Duration(seconds: 12)));
      expect(slow, greaterThan(fast));
      expect(slow, lessThanOrEqualTo(const Duration(seconds: 45)));
    });
  });
}
