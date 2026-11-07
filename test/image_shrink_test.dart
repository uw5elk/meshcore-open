import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/image_shrink.dart';

/// A fake photo whose "JPEG" is a size model: pixels * (quality / 100) / 4,
/// monotonic in both size and quality like a real encoder.
ShrinkFrame _frame(int side) =>
    ShrinkFrame(width: side, height: side * 3 ~/ 4, rgb: Uint8List(0));

Uint8List _fakeJpeg(ShrinkFrame f, int q) =>
    Uint8List((f.width * f.height * q / 100 / 4).ceil() + 600);

void main() {
  group('shrinkSides', () {
    test('never upscales and keeps the largest first', () {
      expect(shrinkSides(4000).first, 1600);
      expect(shrinkSides(1000).first, 1000);
      expect(shrinkSides(1000), contains(800));
      expect(shrinkSides(1000), isNot(contains(1024)));
      expect(shrinkSides(30), <int>[30]);
      final sides = shrinkSides(3000);
      for (var i = 1; i < sides.length; i++) {
        expect(sides[i], lessThan(sides[i - 1]));
      }
    });
  });

  test('result fits the budget and is as good as the model allows', () async {
    var renders = 0;
    var encodes = 0;
    final r = await shrinkToBudget(
      sourceLongSide: 4000,
      budgetBytes: 20 * 1024,
      render: (side) async {
        renders++;
        return _frame(side);
      },
      encode: (f, q) {
        encodes++;
        return _fakeJpeg(f, q);
      },
    );
    expect(r, isNotNull);
    expect(r!.bytes.length, lessThanOrEqualTo(20 * 1024));
    // One step up in quality would no longer fit (or the cap was reached).
    if (r.quality < kShrinkMaxQuality) {
      final more = _fakeJpeg(
        ShrinkFrame(width: r.width, height: r.height, rgb: Uint8List(0)),
        r.quality + 1,
      );
      expect(more.length, greaterThan(20 * 1024));
    }
    // And the next larger size would not fit at the floor.
    final sides = shrinkSides(4000);
    final i = sides.indexWhere((s) => s * 3 ~/ 4 == r.height);
    if (i > 0) {
      final bigger = _fakeJpeg(
        _frame(sides[i - 1]),
        kShrinkQualityFloors.first,
      );
      expect(bigger.length, greaterThan(20 * 1024));
    }
    expect(encodes, lessThan(20));
    expect(renders, lessThan(10));
  });

  test('a generous budget keeps the full size at high quality', () async {
    final r = await shrinkToBudget(
      sourceLongSide: 800,
      budgetBytes: 10 * 1024 * 1024,
      render: (side) async => _frame(side),
      encode: _fakeJpeg,
    );
    expect(r!.width, 800);
    expect(r.quality, kShrinkMaxQuality);
  });

  test('falls back to the low quality floor when nothing else fits', () async {
    // 48 px at quality 35 is above this budget, at quality 10 below it.
    final tiny = _fakeJpeg(_frame(48), 35).length;
    final low = _fakeJpeg(_frame(48), 10).length;
    expect(low, lessThan(tiny));
    final r = await shrinkToBudget(
      sourceLongSide: 4000,
      budgetBytes: low + 1,
      render: (side) async => _frame(side),
      encode: _fakeJpeg,
    );
    expect(r, isNotNull);
    expect(r!.quality, lessThan(kShrinkQualityFloors.first));
    expect(r.bytes.length, lessThanOrEqualTo(low + 1));
  });

  test('returns null when even the smallest picture does not fit', () async {
    final r = await shrinkToBudget(
      sourceLongSide: 4000,
      budgetBytes: 300,
      render: (side) async => _frame(side),
      encode: _fakeJpeg,
    );
    expect(r, isNull);
    expect(
      await shrinkToBudget(
        sourceLongSide: 0,
        budgetBytes: 100,
        render: (side) async => _frame(side),
        encode: _fakeJpeg,
      ),
      isNull,
    );
  });

  test('JPEG detection and file naming', () {
    expect(looksLikeJpeg(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), isTrue);
    expect(
      looksLikeJpeg(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])),
      isFalse,
    );
    expect(looksLikeJpeg(Uint8List(2)), isFalse);
    expect(shrunkPhotoName('IMG_001.PNG'), 'IMG_001.jpg');
    expect(shrunkPhotoName('a.b.webp'), 'a.b.jpg');
    expect(shrunkPhotoName('noext'), 'noext.jpg');
    expect(shrunkPhotoName('.jpg'), '.jpg.jpg');
    expect(shrunkPhotoName('  '), 'photo.jpg');
  });
}
