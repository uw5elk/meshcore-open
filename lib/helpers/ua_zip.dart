import 'dart:convert';
import 'dart:typed_data';

import 'ua_zip_data.dart';

/// Word-level Huffman compressor for short Ukrainian / English chat text.
///
/// Text is split into words, numbers, spaces and punctuation. A word found in
/// the built-in dictionary ([kUaZipWords], ranked by frequency) costs about
/// 10-14 bits (an interval code plus the offset inside the interval); a word
/// that is not in the dictionary is spelled letter by letter with a Huffman
/// letter code. Case is carried by the token type, a following space is
/// merged into the token. The bit stream is turned into printable ASCII
/// (base94, 13 bytes -> 16 chars) and sent as `z:<payload>`.
///
/// The dictionary order and the code-length tables are part of the wire
/// format. A reference implementation and the golden vectors live in
/// `tools/ua_zip`.
class UaZip {
  static const String prefix = 'z:';

  // ---- token types (order is part of the format) ----
  // ignore: unused_field
  static const int _wlS = 0, _wl = 1, _wcS = 2, _wc = 3, _wuS = 4, _wu = 5;
  // ignore: unused_field
  static const int _olS = 6, _ol = 7, _ocS = 8, _oc = 9, _ouS = 10, _ou = 11;
  // ignore: unused_field
  static const int _omS = 12, _om = 13;
  static const int _num = 14, _numS = 15, _space = 16;
  static const int _punct = 17, _punctS = 18, _raw = 19, _pad = 20;

  static const String _ukLetters = 'абвгґдеєжзиіїйклмнопрстуфхцчшщьюя';
  static const String _latin = 'abcdefghijklmnopqrstuvwxyz';
  // Letters of the OOV alphabet: 33 Ukrainian + apostrophe + 26 Latin.
  static const String _chars = "$_ukLetters'$_latin";
  static const int _charEnd = 60;
  static const String _punctChars = '.,!?:;-()"/+%…\n*#@=_[]<>&|~^\$\\';
  static const String _b94 =
      '!"#\$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`'
      'abcdefghijklmnopqrstuvwxyz{|}~';

  static List<String>? _words;
  static Map<String, int>? _index;
  static List<int>? _starts;
  static _Huff? _types, _puncts, _letters, _intervals;

  static void _init() {
    if (_words != null) return;
    final words = kUaZipWords.split(' ');
    final index = <String, int>{
      for (var i = 0; i < words.length; i++) words[i]: i,
    };
    final n = words.length;
    final starts = <int>[0, 1, 2, 3];
    var k = 2;
    while (starts.last < n) {
      starts.add(1 << k);
      starts.add(3 * (1 << (k - 1)));
      k++;
    }
    final st = starts.where((s) => s < n).toList()..add(n);
    _types = _Huff(kUaZipTypeLen);
    _puncts = _Huff(kUaZipPunctLen);
    _letters = _Huff(kUaZipCharLen);
    _intervals = _Huff(kUaZipIntervalLen);
    _index = index;
    _starts = st;
    _words = words;
  }

  static int _intervalOf(int rank) {
    final s = _starts!;
    var lo = 0, hi = s.length - 1;
    while (hi - lo > 1) {
      final m = (lo + hi) >> 1;
      if (s[m] <= rank) {
        lo = m;
      } else {
        hi = m;
      }
    }
    return lo;
  }

  static int _offsetBits(int interval) {
    final size = _starts![interval + 1] - _starts![interval];
    var b = 0;
    while ((1 << b) < size) {
      b++;
    }
    return b;
  }

  // ---------------------------------------------------------------- public

  /// `z:<payload>` when it is shorter than [text] in UTF-8 bytes and decodes
  /// back to exactly [text]; otherwise null.
  static String? encodeIfSmaller(String text) {
    if (text.isEmpty || text.startsWith(prefix)) return null;
    try {
      final bytes = compress(text);
      final candidate = '$prefix${base94Encode(bytes)}';
      if (utf8.encode(candidate).length >= utf8.encode(text).length) {
        return null;
      }
      if (decompress(bytes) != text) return null;
      return candidate;
    } catch (_) {
      return null;
    }
  }

  /// Decodes [text] produced by [encodeIfSmaller]; null if it is not one.
  ///
  /// Plain text may start with `z:`, so a payload only counts when its
  /// re-compression reproduces exactly the same characters.
  static String? tryDecodePrefixed(String text) {
    final t = text.trimLeft();
    if (!t.startsWith(prefix) || t.length <= prefix.length) return null;
    try {
      final payload = t.substring(prefix.length).trim();
      final bytes = base94Decode(payload);
      if (bytes == null) return null;
      final decoded = decompress(bytes);
      if (decoded == null) return null;
      if (base94Encode(compress(decoded)) != payload) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- tokenizer

  static bool _isWordChar(int c) {
    if (c >= 0x61 && c <= 0x7a) return true; // a-z
    if (c >= 0x41 && c <= 0x5a) return true; // A-Z
    if (c == 0x27) return true; // '
    final s = String.fromCharCode(c);
    return _ukLetters.contains(s.toLowerCase()) && s != '\'';
  }

  static String _caseClass(String w) {
    final lo = w.toLowerCase();
    if (w == lo) return 'l';
    final first = w.substring(0, 1);
    if (first != first.toLowerCase() &&
        first + w.substring(1).toLowerCase() == w) {
      return 'C';
    }
    if (w.toUpperCase() == w && w.length >= 2) return 'U';
    return 'M';
  }

  static String _applyCase(String lo, String cl) {
    if (cl == 'l') return lo;
    if (cl == 'C') return lo.substring(0, 1).toUpperCase() + lo.substring(1);
    return lo.toUpperCase();
  }

  // ---------------------------------------------------------------- encode

  static Uint8List compress(String text) {
    _init();
    final runes = text.runes.toList(growable: false);
    final n = runes.length;
    final bw = _BitWriter();
    var i = 0;
    String chr(int a, int b) => String.fromCharCodes(runes.sublist(a, b));
    bool spaceAt(int p) => p < n && runes[p] == 0x20;

    while (i < n) {
      final c = runes[i];
      if (_isWordChar(c) && c != 0x27) {
        var j = i;
        while (j < n && _isWordChar(runes[j])) {
          j++;
        }
        while (runes[j - 1] == 0x27) {
          j--;
        }
        final w = chr(i, j);
        final sp = spaceAt(j);
        final cl = _caseClass(w);
        final lo = w.toLowerCase();
        final rank = cl == 'M' ? null : _index![lo];
        if (rank != null) {
          final base = cl == 'l' ? _wl : (cl == 'C' ? _wc : _wu);
          _types!.write(bw, sp ? base - 1 : base);
          final iv = _intervalOf(rank);
          _intervals!.write(bw, iv);
          bw.put(rank - _starts![iv], _offsetBits(iv));
        } else {
          final base = cl == 'l'
              ? _ol
              : (cl == 'C' ? _oc : (cl == 'U' ? _ou : _om));
          _types!.write(bw, sp ? base - 1 : base);
          for (final ch in w.split('')) {
            final low = ch.toLowerCase();
            _letters!.write(bw, _chars.indexOf(low));
            if (cl == 'M') bw.put(ch != low ? 1 : 0, 1);
          }
          _letters!.write(bw, _charEnd);
        }
        i = sp ? j + 1 : j;
      } else if (c >= 0x30 && c <= 0x39) {
        var j = i;
        while (j < n && runes[j] >= 0x30 && runes[j] <= 0x39) {
          j++;
        }
        var s = chr(i, j);
        final sp = spaceAt(j);
        while (s.length > 16) {
          _types!.write(bw, _num);
          _digits(bw, s.substring(0, 16));
          s = s.substring(16);
        }
        _types!.write(bw, sp ? _numS : _num);
        _digits(bw, s);
        i = sp ? j + 1 : j;
      } else if (c == 0x20) {
        _types!.write(bw, _space);
        i++;
      } else if (_punctChars.contains(String.fromCharCode(c))) {
        final sp = spaceAt(i + 1);
        _types!.write(bw, sp ? _punctS : _punct);
        _puncts!.write(bw, _punctChars.indexOf(String.fromCharCode(c)));
        i = sp ? i + 2 : i + 1;
      } else {
        final u = utf8.encode(String.fromCharCode(c));
        _types!.write(bw, _raw);
        bw.put(u.length - 1, 2);
        for (final b in u) {
          bw.put(b, 8);
        }
        i++;
      }
    }
    return bw.toBytes();
  }

  static void _digits(_BitWriter bw, String s) {
    bw.put(s.length - 1, 4);
    for (final d in s.codeUnits) {
      bw.put(d - 0x30, 4);
    }
  }

  // ---------------------------------------------------------------- decode

  /// Inverse of [compress]; null on malformed input.
  static String? decompress(Uint8List bytes) {
    _init();
    final br = _BitReader(bytes);
    final out = StringBuffer();
    while (true) {
      final t = _types!.read(br);
      if (t == _Huff.end || t == _pad) break;
      if (t == _Huff.bad) return null;
      if (t <= _wu || (t >= _olS && t <= _om)) {
        // Types come in (…_S, …) pairs: even index = followed by a space.
        final sp = t.isEven;
        String word;
        String cl;
        if (t <= _wu) {
          cl = t >> 1 == 0 ? 'l' : (t >> 1 == 1 ? 'C' : 'U');
          final iv = _intervals!.read(br);
          if (iv < 0) return null;
          final b = _offsetBits(iv);
          final off = br.get(b);
          if (off < 0) return null;
          final rank = _starts![iv] + off;
          if (rank >= _words!.length) return null;
          word = _words![rank];
        } else {
          final k = (t - _olS) >> 1;
          cl = const ['l', 'C', 'U', 'M'][k];
          final sb = StringBuffer();
          while (true) {
            final s = _letters!.read(br);
            if (s == _charEnd) break;
            if (s < 0 || s >= _chars.length) return null;
            final ch = _chars[s];
            if (cl == 'M') {
              final bit = br.get(1);
              if (bit < 0) return null;
              sb.write(bit == 1 ? ch.toUpperCase() : ch);
            } else {
              sb.write(ch);
            }
          }
          word = sb.toString();
          if (word.isEmpty) return null;
        }
        out.write(cl == 'M' ? word : _applyCase(word, cl));
        if (sp) out.write(' ');
      } else if (t == _num || t == _numS) {
        final len = br.get(4);
        if (len < 0) return null;
        for (var k = 0; k <= len; k++) {
          final d = br.get(4);
          if (d < 0 || d > 9) return null;
          out.write(d);
        }
        if (t == _numS) out.write(' ');
      } else if (t == _space) {
        out.write(' ');
      } else if (t == _punct || t == _punctS) {
        final p = _puncts!.read(br);
        if (p < 0 || p >= _punctChars.length) return null;
        out.write(_punctChars[p]);
        if (t == _punctS) out.write(' ');
      } else if (t == _raw) {
        final len = br.get(2);
        if (len < 0) return null;
        final u = <int>[];
        for (var k = 0; k <= len; k++) {
          final b = br.get(8);
          if (b < 0) return null;
          u.add(b);
        }
        out.write(utf8.decode(u));
      } else {
        return null;
      }
    }
    return out.toString();
  }

  // ---------------------------------------------------------------- base94

  static int _blockChars(int bytes) {
    var c = 1;
    var cap = BigInt.from(94);
    final need = BigInt.one << (8 * bytes);
    while (cap < need) {
      cap *= BigInt.from(94);
      c++;
    }
    return c;
  }

  static String base94Encode(Uint8List data) {
    final sb = StringBuffer();
    for (var i = 0; i < data.length; i += 13) {
      final end = i + 13 < data.length ? i + 13 : data.length;
      var n = BigInt.zero;
      for (var k = i; k < end; k++) {
        n = (n << 8) | BigInt.from(data[k]);
      }
      final c = end - i == 13 ? 16 : _blockChars(end - i);
      final chars = List<String>.filled(c, '');
      final b94 = BigInt.from(94);
      for (var k = c - 1; k >= 0; k--) {
        chars[k] = _b94[(n % b94).toInt()];
        n ~/= b94;
      }
      sb.writeAll(chars);
    }
    return sb.toString();
  }

  static Uint8List? base94Decode(String s) {
    final out = BytesBuilder();
    final b94 = BigInt.from(94);
    for (var i = 0; i < s.length; i += 16) {
      final end = i + 16 < s.length ? i + 16 : s.length;
      final c = end - i;
      int bytes;
      if (c == 16) {
        bytes = 13;
      } else {
        bytes = 0;
        for (var r = 1; r <= 12; r++) {
          if (_blockChars(r) == c) {
            bytes = r;
            break;
          }
        }
        if (bytes == 0) return null;
      }
      var n = BigInt.zero;
      for (var k = i; k < end; k++) {
        final v = _b94.indexOf(s[k]);
        if (v < 0) return null;
        n = n * b94 + BigInt.from(v);
      }
      if (n >= (BigInt.one << (8 * bytes))) return null;
      final chunk = Uint8List(bytes);
      for (var k = bytes - 1; k >= 0; k--) {
        chunk[k] = (n & BigInt.from(255)).toInt();
        n >>= 8;
      }
      out.add(chunk);
    }
    return out.toBytes();
  }
}

class _BitWriter {
  final List<int> _bytes = [];
  int _cur = 0, _n = 0;

  void put(int value, int bits) {
    for (var i = bits - 1; i >= 0; i--) {
      _cur = (_cur << 1) | ((value >> i) & 1);
      if (++_n == 8) {
        _bytes.add(_cur);
        _cur = 0;
        _n = 0;
      }
    }
  }

  /// Pads the last byte with 1 bits (they never form a real symbol).
  Uint8List toBytes() {
    while (_n != 0) {
      put(1, 1);
    }
    return Uint8List.fromList(_bytes);
  }
}

class _BitReader {
  final Uint8List _data;
  int _pos = 0;
  _BitReader(this._data);

  int get remaining => _data.length * 8 - _pos;

  int bit() {
    if (_pos >= _data.length * 8) return -1;
    final b = (_data[_pos >> 3] >> (7 - (_pos & 7))) & 1;
    _pos++;
    return b;
  }

  /// [bits] bits as an unsigned number, or -1 when the data ends early.
  int get(int bits) {
    var v = 0;
    for (var i = 0; i < bits; i++) {
      final b = bit();
      if (b < 0) return -1;
      v = (v << 1) | b;
    }
    return v;
  }
}

/// Canonical Huffman code defined by code lengths.
class _Huff {
  static const int end = -1; // only padding (1-bits) left
  static const int bad = -2;

  final List<int> _lens;
  final Map<int, int> _bySymbolKey = {};
  late final List<int> _code = List<int>.filled(_lens.length, 0);
  int _maxLen = 0;

  _Huff(this._lens) {
    final order = List<int>.generate(_lens.length, (i) => i)
      ..sort((a, b) {
        final d = _lens[a] - _lens[b];
        return d != 0 ? d : a - b;
      });
    var code = 0, prev = 0;
    for (final s in order) {
      code <<= (_lens[s] - prev);
      prev = _lens[s];
      _code[s] = code;
      _bySymbolKey[(_lens[s] << 40) | code] = s;
      code++;
      if (_lens[s] > _maxLen) _maxLen = _lens[s];
    }
  }

  void write(_BitWriter bw, int symbol) => bw.put(_code[symbol], _lens[symbol]);

  /// Next symbol; [end] if only a run of 1-bits (padding) is left, [bad] if
  /// the bits match no code.
  int read(_BitReader br) {
    var code = 0, len = 0;
    var allOnes = true;
    while (len < _maxLen) {
      final b = br.bit();
      if (b < 0) return allOnes ? end : bad;
      code = (code << 1) | b;
      if (b == 0) allOnes = false;
      len++;
      final s = _bySymbolKey[(len << 40) | code];
      if (s != null) return s;
    }
    return bad;
  }
}
