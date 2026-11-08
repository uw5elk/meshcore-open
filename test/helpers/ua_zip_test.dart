import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/helpers/smaz.dart';
import 'package:meshcore_open/helpers/ua_zip.dart';

/// (text, expected `z:` payload) produced by the reference implementation in
/// tools/ua_zip. Changing the dictionary or tables breaks these on purpose.
const List<(String, String)> _golden = [
  ('Привіт! Як справи? Ти сьогодні на зв\'язку?', 'z:Nz!WO9P>{A=w/]M1"Ul'),
  ('Так, я вдома. Світла нема вже дві години, працюю від акумулятора.', 'z:NC9s8Mj.~1TpO<iB#B2;iThphzt)\\'),
  ('Репітер на горі чути добре, сигнал -85 дБм, SNR 6.', 'z::c#Dkn-I#];K/W],3;;xNo*qjD.=UmB'),
  ('Хто може передати інформацію на північ? Потрібна допомога з генератором.', 'z:=?JR/7jqG"y>vaa-**~4"PH}l'),
  ('Повітряна тривога в районі Кривого Рогу, всім у укриття!', 'z::b*PK%?2>-5d\\y8;#Jcd~iWX'),
  ('Відбій тривоги. Дякую всім за чергування.', 'z::^yLekwPb6qZm%-"'),
  ('Завтра о 18:00 зустрічаємось на каналі, обговоримо налаштування антени.', 'z:>;wQXMhB4\'eH*c6I?J6#`VIZ\'A2YJ0hX%>ie_&cEP'),
  ('Перевір, будь ласка, чи працює другий вузол, він щось не відповідає.', 'z:Mv&K+[[3|l,aeh+!!DgD2XF-FnJ'),
  ('Я зараз їду на роботу, буду на зв\'язку ввечері.', 'z:<>RsB|`;8D{E3&\\9)g8*'),
  ('Слава Україні! Героям слава!', 'z:\$|zMqQH(Dv<4gh'),
  ('Чи є хтось у мережі? Перевірка зв\'язку, прийом.', 'z:=+CG7Tfi@vRp=i"#8;lai'),
  ('Купив нову антену на 868 МГц, підключив до плати, дальність стала краще.', 'z:?DLA}Ot@Ym\\ytbM;(Vm>,9kAofpfNIAy8ZXXCG<y(['),
  ('Добрий день, колеги. Повідомляю, що Wi-Fi на репітері вимкнено, працює лише LoRa.', 'z:?:*~p(ej7=H=Z>,(*A&%Pv<m<(nJEkMf!`g7f*<I\\'),
  ('Дякую, все працює! Гарного вечора.', 'z:Nb\'{R`@D>|Rs}mg\\'),
  ('Завтра обіцяють дощ, тож треба сховати обладнання від вологи.', 'z:>;xe.E(0znF;.r;5)7x=aPj02'),
  ('Test message, how are you? Signal is good here.', 'z:?^fS{G52AWSTT(O-!3JYRAkp'),
  ('OK, received. Will call you later.', 'z:QeBCy2;||6WkQM.o\'s,'),
  ('Хороша новина: файл передався повністю, перевірка CRC пройшла.', 'z:?Bg|jeb>&b{=KTsdCI\'9]3L69wUI:I1F!`'),
  ('Хто на каналі? Мене чути? Прийом, прийом.', 'z:=?Qt6&R\'peN]Mvzw68DXr'),
  ('Ввімкни, будь ласка, режим економії енергії на плані, а то розрядиться до ранку.', 'z:T7xWIrHH(_UA1lL@6%Og3)|4]gQ%4ik\'S}7\\7nb_-R\\V:.&V'),
  ('Привіт, UW5ELK! Я на 433.775 МГц, SNR 9.5 дБ 😀', 'z:Nz!R{Cp\'e<H-w?0e99vJC>#TJ}/]a[xP7p?ya[T]`3?M\\>[12.qxF'),
  ('McDonald\'s і ёлка\tтест', 'z:T-O%MI?N&(E71\$fp"K1bU`/np#saH'),
  ('Тест  двох  пробілів ', 'z:?Xelc1zX81j*~IV0"B'),
  ('73! Slava Ukraini, DX QSO RSSI -85 дБм', 'z:S.QHyX`/>]3XsqlY;S%T.JpCy:o[@yIg!GpFm{.b'),
  ('xyzzy qwertyuiop ґанок Їжак ЄВРО ПРИВІТ', 'z:T+5b<wXAU2-wH.KO;/2)z9x.rC*4\\6\\gC*|\\*'),
  ('1234567890123456789012 ok', 'z:SNX9l\$}*Zh}W"RcI&n4b'),
  ('м\'ясо п\'ять \'лапки\' o\'clock', 'z:!J<RSz@/|Pi.01X%#d'),
  ('Рядок1\nРядок2: (дужки) "лапки" a/b 50% #тег @ім\'я', 'z:N%M}ygFzwCqw.tQ8?8"Ji(\\#QY\'&M2kQ86i"+~abD`LcdC=H'),
  ('Z', 'z:2e6"'),
  ('а', 'z:#@6'),
];

void main() {
  test('compress matches the reference vectors', () {
    for (final (text, expected) in _golden) {
      final got = '${UaZip.prefix}${UaZip.base94Encode(UaZip.compress(text))}';
      expect(got, expected, reason: text);
    }
  });

  test('every vector round-trips', () {
    for (final (text, payload) in _golden) {
      expect(UaZip.tryDecodePrefixed(payload), text, reason: text);
      expect(Smaz.tryDecodePrefixed(payload), text, reason: text);
    }
  });

  test('encodeIfSmaller only returns shorter, decodable payloads', () {
    var shrunk = 0;
    for (final (text, _) in _golden) {
      final enc = UaZip.encodeIfSmaller(text);
      if (enc == null) continue;
      shrunk++;
      expect(enc.length, lessThan(text.codeUnits.length * 2));
      expect(UaZip.tryDecodePrefixed(enc), text);
    }
    expect(shrunk, greaterThan(20));
  });

  test('Smaz.encodeIfSmaller keeps text decodable', () {
    for (final (text, _) in _golden) {
      final enc = Smaz.encodeIfSmaller(text);
      expect(Smaz.tryDecodePrefixed(enc) ?? enc, text, reason: text);
    }
  });

  test('Ukrainian text shrinks by more than half', () {
    const s =
        'Хто може передати інформацію на північ? Потрібна допомога з генератором.';
    final enc = Smaz.encodeIfSmaller(s);
    expect(enc.length, lessThan(s.codeUnits.length * 2 * 0.45));
  });

  test('plain text starting with z: is not mistaken for a payload', () {
    for (final s in ['z:', 'z:привіт', 'z: hello world', 'z:ok!', 'z:~~~~']) {
      expect(UaZip.tryDecodePrefixed(s), isNull, reason: s);
    }
  });

  test('random garbage after the prefix never throws', () {
    for (var i = 0; i < 200; i++) {
      final body = String.fromCharCodes(
        List.generate(1 + i % 40, (k) => 0x21 + (i * 31 + k * 17) % 94),
      );
      final s = 'z:$body';
      UaZip.tryDecodePrefixed(s);
    }
  });
}
