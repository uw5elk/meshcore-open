# UaZip reference tools

Python reference implementation and generators for `lib/helpers/ua_zip.dart`
(the `z:` word-level compressor).

- `build.py` builds the ranked word list (wordfreq uk/en, filtered with the
  pymorphy3 Ukrainian dictionary, plus `tech.txt` radio/IT terms and words from
  the app's own Ukrainian strings) into `words.json`.
- `ref.py` is the reference tokenizer / encoder; `gen.py` writes
  `lib/helpers/ua_zip_data.dart` (word list + Huffman code lengths);
  `vec.py` writes the golden vectors used by `test/helpers/ua_zip_test.dart`.

Needs `pip install wordfreq pymorphy3 pymorphy3-dicts-uk`. The generated data is
the wire format: regenerating it with different inputs makes old and new app
versions unable to read each other's `z:` messages, so only do that together
with a new prefix.
