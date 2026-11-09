import 'dart:typed_data';

/// One received file as kept on disk.
class StoredFile {
  /// Storage key (safe file-name stem), unique per radio.
  final String key;
  final String name;
  final int channelIndex;
  final DateTime receivedAt;
  final Uint8List data;

  /// True for a file this device sent; [status] is then delivered, failed or
  /// cancelled, otherwise received.
  final bool outgoing;
  final String status;
  final String? error;

  const StoredFile({
    required this.key,
    required this.name,
    required this.channelIndex,
    required this.receivedAt,
    required this.data,
    this.outgoing = false,
    this.status = 'received',
    this.error,
  });
}

/// Keeps received files across app restarts, scoped per radio.
abstract class FileJobStore {
  /// Newest first, at most [FileJobStore.maxFiles] entries.
  Future<List<StoredFile>> load(String radioKey);

  /// Returns false when the file could not be stored.
  Future<bool> save(String radioKey, StoredFile file);

  Future<void> delete(String radioKey, String key);

  /// The radio whose files were shown last, so they can be listed right after
  /// launch, before the radio has connected.
  Future<String?> lastRadio();

  Future<void> setLastRadio(String radioKey);

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

  String? _last;

  @override
  Future<String?> lastRadio() async => _last;

  @override
  Future<void> setLastRadio(String radioKey) async => _last = radioKey;
}
