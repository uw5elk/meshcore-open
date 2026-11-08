import 'dart:typed_data';

/// One received file as kept on disk.
class StoredFile {
  /// Storage key (safe file-name stem), unique per radio.
  final String key;
  final String name;
  final int channelIndex;
  final DateTime receivedAt;
  final Uint8List data;

  const StoredFile({
    required this.key,
    required this.name,
    required this.channelIndex,
    required this.receivedAt,
    required this.data,
  });
}

/// Keeps received files across app restarts, scoped per radio.
abstract class FileJobStore {
  /// Newest first, at most [FileJobStore.maxFiles] entries.
  Future<List<StoredFile>> load(String radioKey);

  /// Returns false when the file could not be stored.
  Future<bool> save(String radioKey, StoredFile file);

  Future<void> delete(String radioKey, String key);

  /// Files kept per radio; the oldest are dropped first.
  static const int maxFiles = 20;
}

/// Nothing survives: web, and the default for tests.
class InMemoryFileJobStore implements FileJobStore {
  final Map<String, Map<String, StoredFile>> _files =
      <String, Map<String, StoredFile>>{};

  @override
  Future<List<StoredFile>> load(String radioKey) async {
    final list = (_files[radioKey]?.values.toList() ?? <StoredFile>[])
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return list.take(FileJobStore.maxFiles).toList();
  }

  @override
  Future<bool> save(String radioKey, StoredFile file) async {
    _files.putIfAbsent(radioKey, () => <String, StoredFile>{})[file.key] = file;
    return true;
  }

  @override
  Future<void> delete(String radioKey, String key) async {
    _files[radioKey]?.remove(key);
  }
}
