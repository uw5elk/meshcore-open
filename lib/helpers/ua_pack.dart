import 'dart:convert';
import 'dart:typed_data';

/// Dictionary compressor for short Ukrainian / English chat text.
///
/// SMAZ's dictionary is English-only, so Cyrillic text passes through it
/// almost untouched. This codec uses a 240-entry dictionary of the most
/// valuable letter groups from Ukrainian and English word-frequency lists
/// (built by BPE), so one byte replaces ~2-3 Cyrillic letters (4-6 bytes of
/// UTF-8).
///
/// Wire format (before base64): each byte below [_tokenCount] is a
/// dictionary entry; [_capFlag] capitalises the first letter of the next
/// entry; [_verbatim] is followed by a length byte and that many raw UTF-8
/// bytes. The compressed bytes travel as `u:<base64>`. The dictionary order
/// is part of the wire format and MUST NOT change.
class UaPack {
  static const int _tokenCount = 240;
  static const int _capFlag = 253;
  static const int _verbatim = 255;
  static const String prefix = 'u:';

  static const List<String> _tokens = [
    ' украї', ' the', ' від', ' для', ' при', ' про', ' під', ' так',
    'ення', 'краї', 'сько', 'ться', ' in', ' to', ' бу', ' ва', ' ви',
    ' во', ' ві', ' го', ' до', ' за', ' ко', ' ма', ' мо', ' мі', ' на',
    ' не', ' ні', ' по', ' ра', ' ро', ' та', ' те', ' то', ' це', ' що',
    ' як', 'ing', 'ере', 'кра', 'ний', 'них', 'ння', 'ого', 'ста', 'сто',
    'іль', ' a', ' b', ' c', ' d', ' f', ' h', ' i', ' m', ' o', ' p',
    ' s', ' t', ' w', ' а', ' б', ' в', ' г', ' д', ' ж', ' з', ' й',
    ' к', ' м', ' н', ' о', ' п', ' с', ' т', ' у', ' ф', ' х', ' ц',
    ' ч', ' я', ' є', ' і', 'an', 'at', 'en', 'er', 'es', 'he', 'in',
    'nd', 'on', 'or', 'ou', 're', 'би', 'бо', 'ва', 'ви', 'во', 'ві',
    'га', 'го', 'да', 'де', 'ди', 'до', 'ду', 'ді', 'ен', 'ер', 'же',
    'ка', 'ки', 'ко', 'ку', 'ла', 'ле', 'ли', 'ло', 'ль', 'лю', 'ля',
    'лі', 'ма', 'ми', 'мо', 'му', 'мі', 'на', 'не', 'ни', 'но', 'ну',
    'ня', 'ні', 'по', 'ра', 'ре', 'ри', 'ро', 'ру', 'рі', 'ст', 'сь',
    'ся', 'сі', 'та', 'те', 'ти', 'то', 'ту', 'ть', 'ті', 'ці', 'ча',
    'чи', 'ше', 'ши', 'що', 'ів', 'ід', ' ', '!', '\'', ',', '-',
    '.', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', '?',
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
    'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'а', 'б', 'в', 'г', 'д', 'е', 'ж', 'з', 'и', 'й', 'к', 'л', 'м',
    'н', 'о', 'п', 'р', 'с', 'т', 'у', 'ф', 'х', 'ц', 'ч', 'ш', 'щ',
    'ь', 'ю', 'я', 'є', 'і', 'ї', 'ґ',
  ];

  static final Map<String, int> _index = {
    for (var i = 0; i < _tokens.length; i++) _tokens[i]: i,
  };
  static final int _maxLen = _tokens.fold(
    0,
    (m, t) => t.length > m ? t.length : m,
  );

  /// Returns `u:<base64>` when that is shorter than [text] in UTF-8 bytes
  /// and decodes back to exactly [text]; otherwise null.
  static String? encodeIfSmaller(String text) {
    if (text.isEmpty || text.startsWith(prefix)) return null;
    final bytes = compress(text);
    if (bytes == null) return null;
    final candidate = '$prefix${base64Encode(bytes)}';
    if (utf8.encode(candidate).length >= utf8.encode(text).length) return null;
    if (decompress(bytes) != text) return null;
    return candidate;
  }

  /// Decodes text produced by [encodeIfSmaller]; null if [text] is not one.
  ///
  /// Plain text may start with `u:`, so a payload only counts when the
  /// base64 is canonical and re-compressing the result reproduces the same
  /// bytes.
  static String? tryDecodePrefixed(String text) {
    final t = text.trimLeft();
    if (!t.startsWith(prefix) || t.length <= prefix.length) return null;
    try {
      final encoded = t.substring(prefix.length).trim();
      final bytes = base64Decode(encoded);
      if (base64Encode(bytes) != encoded) return null;
      final decoded = decompress(bytes);
      if (decoded == null) return null;
      final again = compress(decoded);
      if (again == null || !_equal(again, bytes)) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  static bool _equal(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Uppercases the first letter of [t] (entries may start with a space).
  static String _capitalise(String t) {
    for (var i = 0; i < t.length; i++) {
      final up = t[i].toUpperCase();
      if (up != t[i]) return t.substring(0, i) + up + t.substring(i + 1);
    }
    return t;
  }

  /// Shortest parse by dynamic programming; null if [text] has characters
  /// whose case change alters the length (never produced for supported
  /// scripts, but guarded so the round trip is exact).
  static Uint8List? compress(String text) {
    final chars = text.runes.map(String.fromCharCode).toList(growable: false);
    final n = chars.length;
    const inf = 1 << 30;
    final cost = List<int>.filled(n + 1, inf);
    // choice[i] = token index ending at i (>=0), -1 verbatim, with cap flag.
    final prevAt = List<int>.filled(n + 1, 0);
    final tokAt = List<int>.filled(n + 1, -1);
    final capAt = List<bool>.filled(n + 1, false);
    cost[0] = 0;
    for (var i = 0; i < n; i++) {
      if (cost[i] >= inf) continue;
      final sb = StringBuffer();
      for (var l = 1; l <= _maxLen && i + l <= n; l++) {
        sb.write(chars[i + l - 1]);
        final sub = sb.toString();
        final low = sub.toLowerCase();
        if (low.length != sub.length) break;
        final idx = _index[low];
        if (idx == null) continue;
        final cap = sub != low;
        if (cap && sub != _capitalise(low)) continue;
        final c = cost[i] + 1 + (cap ? 1 : 0);
        if (c < cost[i + l]) {
          cost[i + l] = c;
          prevAt[i + l] = i;
          tokAt[i + l] = idx;
          capAt[i + l] = cap;
        }
      }
      final c = cost[i] + 1 + utf8.encode(chars[i]).length;
      if (c < cost[i + 1]) {
        cost[i + 1] = c;
        prevAt[i + 1] = i;
        tokAt[i + 1] = -1;
        capAt[i + 1] = false;
      }
    }
    // Walk back, then emit forward merging verbatim runs.
    final steps = <int>[];
    for (var i = n; i > 0; i = prevAt[i]) {
      steps.add(i);
    }
    final out = BytesBuilder(copy: false);
    final run = <int>[];
    void flush() {
      var data = run;
      while (data.isNotEmpty) {
        final take = data.length > 255 ? 255 : data.length;
        // Do not split a UTF-8 sequence across runs.
        var cut = take;
        while (cut < data.length && cut > 0 && (data[cut] & 0xC0) == 0x80) {
          cut--;
        }
        out.addByte(_verbatim);
        out.addByte(cut);
        out.add(data.sublist(0, cut));
        data = data.sublist(cut);
      }
      run.clear();
    }

    for (final end in steps.reversed) {
      final tok = tokAt[end];
      if (tok < 0) {
        run.addAll(utf8.encode(chars[end - 1]));
      } else {
        flush();
        if (capAt[end]) out.addByte(_capFlag);
        out.addByte(tok);
      }
    }
    flush();
    return out.toBytes();
  }

  /// Inverse of [compress]; null on malformed input.
  static String? decompress(Uint8List bytes) {
    final out = StringBuffer();
    var cap = false;
    var i = 0;
    try {
      while (i < bytes.length) {
        final b = bytes[i++];
        if (b == _capFlag) {
          if (cap) return null;
          cap = true;
        } else if (b == _verbatim) {
          if (cap || i >= bytes.length) return null;
          final len = bytes[i++];
          if (len == 0 || i + len > bytes.length) return null;
          out.write(utf8.decode(bytes.sublist(i, i + len)));
          i += len;
        } else if (b < _tokenCount) {
          final t = _tokens[b];
          out.write(cap ? _capitalise(t) : t);
          cap = false;
        } else {
          return null;
        }
      }
    } catch (_) {
      return null;
    }
    return cap ? null : out.toString();
  }
}
