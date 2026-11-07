import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// zlib-compresses [data] at the highest level.
Uint8List? deflateBytes(Uint8List data) {
  try {
    return Uint8List.fromList(
      ZLibCodec(level: ZLibOption.maxLevel).encode(data),
    );
  } on Object {
    return null;
  }
}

/// Inflates zlib [data], or returns null when it is corrupt or would expand
/// beyond [maxBytes] (a decompression bomb from the radio must not exhaust
/// memory).
Uint8List? inflateBytes(Uint8List data, {required int maxBytes}) {
  try {
    final sink = _LimitedSink(maxBytes);
    final conversion = ZLibDecoder().startChunkedConversion(sink);
    const step = 4096;
    for (var i = 0; i < data.length; i += step) {
      conversion.add(
        Uint8List.sublistView(data, i, math.min(i + step, data.length)),
      );
    }
    conversion.close();
    return sink.takeBytes();
  } on Object {
    return null;
  }
}

class _LimitedSink extends ByteConversionSinkBase {
  final int maxBytes;
  final BytesBuilder _out = BytesBuilder(copy: false);

  _LimitedSink(this.maxBytes);

  @override
  void add(List<int> chunk) {
    _out.add(chunk);
    if (_out.length > maxBytes) {
      throw const FormatException('inflated data exceeds the limit');
    }
  }

  @override
  void close() {}

  Uint8List takeBytes() => _out.takeBytes();
}
