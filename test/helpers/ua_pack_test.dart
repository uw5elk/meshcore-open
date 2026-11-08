import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/smaz.dart';
import 'package:meshcore_open/helpers/ua_pack.dart';

void main() {
  const samples = [
    'Привіт! Як справи? Ти сьогодні на зв\'язку?',
    'Повітряна тривога в районі Кривого Рогу, всім у укриття!',
    'Репітер на горі чути добре, сигнал -85 дБм, SNR 6.',
    'Test message, how are you? Signal is good here.',
    'Слава Україні! Героям слава!',
    'ПРИВІТ ВСІМ',
    'Їжак, єнот, ґанок 😀 і ще текст українською мовою',
  ];

  test('UaPack round-trips and shrinks Ukrainian text', () {
    var shrunk = 0;
    for (final s in samples) {
      final enc = UaPack.encodeIfSmaller(s);
      if (enc == null) continue;
      shrunk++;
      expect(enc.startsWith('u:'), isTrue);
      expect(UaPack.tryDecodePrefixed(enc), s, reason: s);
      expect(Smaz.tryDecodePrefixed(enc), s, reason: s);
    }
    expect(shrunk, greaterThanOrEqualTo(5));
  });

  test('Smaz.encodeIfSmaller picks a decodable result for every sample', () {
    for (final s in samples) {
      final enc = Smaz.encodeIfSmaller(s);
      expect(Smaz.tryDecodePrefixed(enc) ?? enc, s, reason: s);
    }
  });

  test('plain text starting with u: is left alone', () {
    for (final s in ['u:', 'u:привіт', 'u: hello world', 'u:ok!']) {
      expect(UaPack.tryDecodePrefixed(s), isNull, reason: s);
    }
  });

  test('Ukrainian saves a lot vs UTF-8', () {
    const s = 'Хто може передати інформацію на північ? Потрібна допомога.';
    final enc = Smaz.encodeIfSmaller(s);
    expect(enc.length, lessThan(s.codeUnits.length * 2 * 0.7));
  });
}
