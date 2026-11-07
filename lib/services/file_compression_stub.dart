import 'dart:typed_data';

/// No zlib on web: files are sent uncompressed.
Uint8List? deflateBytes(Uint8List data) => null;

/// No zlib on web: a compressed file cannot be opened there.
Uint8List? inflateBytes(Uint8List data, {required int maxBytes}) => null;
