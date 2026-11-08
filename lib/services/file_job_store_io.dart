/// File-backed [FileJobStore] under the application support directory.
///
/// ```
/// <application support>/received_files/<radioKey>/
///     <key>.bin        the file bytes
///     <key>.json       {name, channel, ts}; written last, atomically
/// ```
///
/// The name from the sender is only data inside the JSON: every path is built
/// from validated keys, so a hostile name cannot escape the directory.
/// A `.bin` without its `.json` (crash mid-save) is swept on [load].
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import 'file_job_store.dart';

class FileJobStoreIo implements FileJobStore {
  static final RegExp _safe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  final Future<Directory> Function() _base;

  FileJobStoreIo({Future<Directory> Function()? baseDirectory})
    : _base = baseDirectory ?? getApplicationSupportDirectory;

  Future<Directory?> _dir(String radioKey, {bool create = false}) async {
    if (!_safe.hasMatch(radioKey)) return null;
    final base = await _base();
    final dir = Directory(
      '${base.path}${Platform.pathSeparator}received_files'
      '${Platform.pathSeparator}$radioKey',
    );
    if (create && !await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _path(Directory dir, String key, String ext) =>
      '${dir.path}${Platform.pathSeparator}$key$ext';

  @override
  Future<List<StoredFile>> load(String radioKey) async {
    try {
      final dir = await _dir(radioKey);
      if (dir == null || !await dir.exists()) return <StoredFile>[];
      final result = <StoredFile>[];
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final name = entity.uri.pathSegments.last;
        final key = name.substring(0, name.length - '.json'.length);
        if (!_safe.hasMatch(key)) continue;
        try {
          final meta = jsonDecode(await entity.readAsString());
          final bin = File(_path(dir, key, '.bin'));
          if (meta is! Map || !await bin.exists()) continue;
          result.add(
            StoredFile(
              key: key,
              name: meta['name'] as String? ?? '',
              channelIndex: meta['channel'] as int? ?? 0,
              receivedAt: DateTime.fromMillisecondsSinceEpoch(
                meta['ts'] as int? ?? 0,
              ),
              data: Uint8List.fromList(await bin.readAsBytes()),
            ),
          );
        } catch (_) {
          // Unreadable record: ignored, swept below.
        }
      }
      result.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      final kept = result.take(FileJobStore.maxFiles).toList();
      for (final extra in result.skip(FileJobStore.maxFiles)) {
        await delete(radioKey, extra.key);
      }
      await _sweepOrphans(dir, kept.map((f) => f.key).toSet());
      return kept;
    } catch (e) {
      debugPrint('FileJobStore.load failed: $e');
      return <StoredFile>[];
    }
  }

  Future<void> _sweepOrphans(Directory dir, Set<String> keep) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final dot = name.indexOf('.');
        final stem = dot < 0 ? name : name.substring(0, dot);
        if (!keep.contains(stem)) await entity.delete();
      }
    } catch (_) {}
  }

  @override
  Future<bool> save(String radioKey, StoredFile file) async {
    try {
      if (!_safe.hasMatch(file.key)) return false;
      final dir = await _dir(radioKey, create: true);
      if (dir == null) return false;
      await File(_path(dir, file.key, '.bin')).writeAsBytes(
        file.data,
        flush: true,
      );
      final tmp = File(_path(dir, file.key, '.json.tmp'));
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{
          'name': file.name,
          'channel': file.channelIndex,
          'ts': file.receivedAt.millisecondsSinceEpoch,
        }),
        flush: true,
      );
      await tmp.rename(_path(dir, file.key, '.json'));
      await _prune(radioKey);
      return true;
    } catch (e) {
      debugPrint('FileJobStore.save failed: $e');
      return false;
    }
  }

  Future<void> _prune(String radioKey) async {
    await load(radioKey); // drops the excess itself
  }

  @override
  Future<void> delete(String radioKey, String key) async {
    try {
      if (!_safe.hasMatch(key)) return;
      final dir = await _dir(radioKey);
      if (dir == null) return;
      for (final ext in const ['.json', '.bin', '.json.tmp']) {
        final f = File(_path(dir, key, ext));
        if (await f.exists()) await f.delete();
      }
    } catch (e) {
      debugPrint('FileJobStore.delete failed: $e');
    }
  }
}
