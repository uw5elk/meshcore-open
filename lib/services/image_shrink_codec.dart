/// Flutter side of [shrinkToBudget]: decodes a photo with the engine's native
/// decoder (scaled while decoding, so a 12 MP photo is never held at full size)
/// and encodes JPEG with the pure-Dart `image` package.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'image_shrink.dart';

/// Shrinks the encoded photo [bytes] (JPEG, PNG, WebP, GIF, BMP...) to a JPEG
/// of at most [budgetBytes]. Returns null when the photo cannot be decoded or
/// does not fit even at the smallest size and lowest quality.
Future<ShrinkResult?> shrinkPhotoToBudget(
  Uint8List bytes, {
  required int budgetBytes,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final d = descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = d.width;
    final height = d.height;
    if (width < 1 || height < 1) return null;
    return await shrinkToBudget(
      sourceLongSide: math.max(width, height),
      budgetBytes: budgetBytes,
      render: (side) => _render(d, width, height, side),
      encode: _encodeJpeg,
    );
  } on Object catch (error) {
    debugPrint('photo shrink failed: $error');
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

Future<ShrinkFrame> _render(
  ui.ImageDescriptor descriptor,
  int width,
  int height,
  int side,
) async {
  final longest = math.max(width, height);
  final scale = side >= longest ? 1.0 : side / longest;
  final targetWidth = math.max(1, (width * scale).round());
  final targetHeight = math.max(1, (height * scale).round());
  final codec = await descriptor.instantiateCodec(
    targetWidth: targetWidth,
    targetHeight: targetHeight,
  );
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw StateError('photo has no pixel data');
      return ShrinkFrame(
        width: image.width,
        height: image.height,
        rgb: _rgbOnWhite(data),
      );
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// RGBA to packed RGB; transparent pixels are composited onto white because a
/// JPEG has no alpha channel.
Uint8List _rgbOnWhite(ByteData rgbaData) {
  final rgba = rgbaData.buffer.asUint8List(
    rgbaData.offsetInBytes,
    rgbaData.lengthInBytes,
  );
  final pixels = rgba.length ~/ 4;
  final rgb = Uint8List(pixels * 3);
  for (var i = 0, o = 0; i < pixels; i++, o += 3) {
    final p = i * 4;
    final a = rgba[p + 3];
    if (a == 255) {
      rgb[o] = rgba[p];
      rgb[o + 1] = rgba[p + 1];
      rgb[o + 2] = rgba[p + 2];
    } else {
      final inv = 255 - a;
      rgb[o] = (rgba[p] * a + 255 * inv) ~/ 255;
      rgb[o + 1] = (rgba[p + 1] * a + 255 * inv) ~/ 255;
      rgb[o + 2] = (rgba[p + 2] * a + 255 * inv) ~/ 255;
    }
  }
  return rgb;
}

Uint8List _encodeJpeg(ShrinkFrame frame, int quality) {
  final image = img.Image.fromBytes(
    width: frame.width,
    height: frame.height,
    bytes: frame.rgb.buffer,
    numChannels: 3,
  );
  return img.encodeJpg(image, quality: quality, chroma: img.JpegChroma.yuv420);
}
