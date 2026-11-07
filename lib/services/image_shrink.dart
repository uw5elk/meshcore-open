/// Shrinks a photo to a byte budget by choosing the largest picture size and
/// then the highest JPEG quality that still fit.
///
/// Pure Dart: decoding to pixels and JPEG encoding are injected, so the search
/// is unit-tested without a Flutter engine. See `image_shrink_codec.dart` for
/// the real decoder and encoder.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Longest-side candidates in pixels, largest first. A photo is never upscaled.
const List<int> kShrinkLadder = <int>[
  1600,
  1280,
  1024,
  800,
  640,
  512,
  400,
  320,
  256,
  192,
  160,
  128,
  96,
  64,
  48,
];

/// Highest JPEG quality tried.
const int kShrinkMaxQuality = 85;

/// Quality floors, in order: first keep the picture decent, and only when even
/// the smallest size will not fit at that quality accept an ugly one.
const List<int> kShrinkQualityFloors = <int>[45, 10];

/// A decoded picture: tightly packed RGB, 3 bytes per pixel.
class ShrinkFrame {
  final int width;
  final int height;
  final Uint8List rgb;

  const ShrinkFrame({
    required this.width,
    required this.height,
    required this.rgb,
  });
}

class ShrinkResult {
  final Uint8List bytes;
  final int width;
  final int height;
  final int quality;

  const ShrinkResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.quality,
  });
}

/// Renders the source with its longest side scaled to [longSide] pixels.
typedef ShrinkRender = Future<ShrinkFrame> Function(int longSide);

/// JPEG-encodes [frame] at [quality] (1..100).
typedef ShrinkEncode = Uint8List Function(ShrinkFrame frame, int quality);

/// Candidate longest sides for a source whose longest side is [sourceLongSide],
/// largest first and never above it.
List<int> shrinkSides(int sourceLongSide, {List<int> ladder = kShrinkLadder}) {
  final sides = <int>[
    if (sourceLongSide <= ladder.first && !ladder.contains(sourceLongSide))
      sourceLongSide,
    ...ladder.where((s) => s < sourceLongSide || s == sourceLongSide),
  ];
  return sides.isEmpty ? <int>[sourceLongSide] : sides;
}

/// Finds a JPEG of at most [budgetBytes], or null when none fits.
///
/// Size only falls as the picture gets smaller, so the largest size that fits
/// at the quality floor is found by bisection over [shrinkSides]; the highest
/// quality that fits at that size is then found by a second bisection. That
/// takes about ten encodes instead of one per size and quality.
Future<ShrinkResult?> shrinkToBudget({
  required int sourceLongSide,
  required int budgetBytes,
  required ShrinkRender render,
  required ShrinkEncode encode,
  List<int> ladder = kShrinkLadder,
}) async {
  if (budgetBytes <= 0 || sourceLongSide <= 0) return null;
  final sides = shrinkSides(sourceLongSide, ladder: ladder);

  final frames = <int, ShrinkFrame>{};
  final encoded = <String, Uint8List>{};

  Future<ShrinkFrame> frameAt(int side) async {
    final cached = frames[side];
    if (cached != null) return cached;
    // Let the UI repaint between the heavy steps.
    await Future<void>.delayed(Duration.zero);
    return frames[side] = await render(side);
  }

  Future<Uint8List> jpegAt(int side, int quality) async {
    final key = '$side/$quality';
    final cached = encoded[key];
    if (cached != null) return cached;
    final frame = await frameAt(side);
    await Future<void>.delayed(Duration.zero);
    return encoded[key] = encode(frame, quality);
  }

  Future<bool> fits(int side, int quality) async =>
      (await jpegAt(side, quality)).length <= budgetBytes;

  for (final floor in kShrinkQualityFloors) {
    if (!await fits(sides.last, floor)) continue;

    // First (largest) size that fits at the floor.
    var lo = 0;
    var hi = sides.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (await fits(sides[mid], floor)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final side = sides[lo];

    // Highest quality that still fits at that size.
    var qLo = floor;
    var qHi = math.max(floor, kShrinkMaxQuality);
    while (qLo < qHi) {
      final mid = (qLo + qHi + 1) ~/ 2;
      if (await fits(side, mid)) {
        qLo = mid;
      } else {
        qHi = mid - 1;
      }
    }
    final frame = await frameAt(side);
    return ShrinkResult(
      bytes: await jpegAt(side, qLo),
      width: frame.width,
      height: frame.height,
      quality: qLo,
    );
  }
  return null;
}

/// True when [bytes] start with the JPEG signature.
bool looksLikeJpeg(Uint8List bytes) =>
    bytes.length > 3 &&
    bytes[0] == 0xFF &&
    bytes[1] == 0xD8 &&
    bytes[2] == 0xFF;

/// File name for the shrunk photo: the original name with a .jpg extension.
String shrunkPhotoName(String original) {
  final dot = original.lastIndexOf('.');
  final base = (dot > 0 ? original.substring(0, dot) : original).trim();
  return '${base.isEmpty ? 'photo' : base}.jpg';
}
