/// COSMIC's panel lists in RON: `None`, `Some([ … ])` (plugins_center) and
/// `Some(([ … ], [ … ]))` (plugins_wings). Parsed so that a change rewrites only the lists that
/// changed, in the file's own style (indent, trailing commas, one per line or all on one line);
/// everything outside them (comments too) stays byte for byte.
library;

/// One string in a list, with the comments written before it (they move with it).
final class RonItem {
  RonItem(this.value, {this.comments = const [], this.raw});
  final String value;

  /// The string as written (escapes kept), so a rewrite never changes an id it doesn't know.
  final String? raw;
  final List<String> comments;
}

/// One `[ … ]` in the text.
final class RonList {
  RonList(this.start, this.end, this.items, this.trailing, this.multiline, this.indent, this.trailingComma);

  /// Offsets of `[` and one past `]`.
  final int start;
  final int end;
  final List<RonItem> items;

  /// Comments after the last item.
  final List<String> trailing;
  final bool multiline;
  final String indent;
  final bool trailingComma;

  List<String> get values => [for (final i in items) i.value];
}

final class RonListDoc {
  RonListDoc._(this.text, this.isNone, this.lists, [this.noneAt]);

  /// Where `None` is in the text (a rewrite replaces only it, comments around it stay).
  final int? noneAt;

  /// The text as read ('' for a missing file).
  final String text;

  /// `None` (or an empty file): no lists.
  final bool isNone;
  final List<RonList> lists;

  List<List<String>> get values => [for (final l in lists) l.values];

  /// Parses [text], which must hold [count] lists (`Some(...)`) or be `None`/empty.
  static RonListDoc parse(String text, {required int count}) {
    final lists = <RonList>[];
    final outside = StringBuffer(); // the text outside lists and comments, to check the shape
    var i = 0;
    int? firstWord;
    RonList? readList() {
      final start = i;
      i++; // [
      final items = <RonItem>[];
      var pending = <String>[];
      var sawNewline = false;
      String? indent;
      var lastWasComma = false;
      while (true) {
        if (i >= text.length) throw const FormatException('unterminated list');
        final c = text[i];
        if (c == ']') {
          i++;
          return RonList(start, i, items, pending, sawNewline, indent ?? '    ', lastWasComma);
        }
        if (c == '\n') {
          sawNewline = true;
          i++;
          continue;
        }
        if (c == ' ' || c == '\t' || c == '\r') {
          i++;
          continue;
        }
        if (c == '/') {
          pending.add(_comment(text, i, (e) => i = e));
          continue;
        }
        if (c == ',') {
          if (items.isEmpty || lastWasComma) throw const FormatException('stray comma');
          lastWasComma = true;
          i++;
          continue;
        }
        if (c == '"') {
          if (items.isNotEmpty && !lastWasComma) throw const FormatException('missing comma');
          if (sawNewline && indent == null) {
            final lineStart = text.lastIndexOf('\n', i) + 1;
            final lead = text.substring(lineStart, i);
            if (lead.trim().isEmpty && lead.isNotEmpty) indent = lead;
          }
          final from = i;
          final s = _string(text, i, (e) => i = e);
          items.add(RonItem(s, comments: pending, raw: text.substring(from, i)));
          pending = <String>[];
          lastWasComma = false;
          continue;
        }
        if (c == '[') throw const FormatException('nested list');
        throw FormatException('unexpected "$c" in a list');
      }
    }

    while (i < text.length) {
      final c = text[i];
      if (c == '/' && i + 1 < text.length && (text[i + 1] == '/' || text[i + 1] == '*')) {
        _comment(text, i, (e) => i = e);
        continue;
      }
      if (c == '[') {
        lists.add(readList()!);
        outside.write('L');
        continue;
      }
      if (c == '"') throw const FormatException('string outside a list');
      if (c == ']') throw const FormatException('unbalanced ]');
      if (c.trim().isNotEmpty) {
        firstWord ??= i;
        outside.write(c);
      }
      i++;
    }
    final shape = outside.toString();
    if (shape.isEmpty || shape == 'None') return RonListDoc._(text, true, const [], firstWord);
    final want = count == 1 ? 'Some(L)' : 'Some((L,L))';
    final wantComma = count == 1 ? 'Some(L,)' : 'Some((L,L,))';
    if (shape != want && shape != wantComma) {
      throw FormatException('expected ${count == 1 ? 'Some([…])' : 'Some(([…], […]))'} or None');
    }
    return RonListDoc._(text, false, lists);
  }

  /// The text with the lists set to [values]: unchanged lists are kept as they are, changed
  /// ones are written in their own style. From `None`/empty: COSMIC's multi-line style.
  String render(List<List<String>> values) {
    if (isNone) {
      final parts = [for (final v in values) _renderList(v, const [], const [], const {}, true, '    ', true)];
      final some = values.length == 1 ? 'Some(${parts[0]})' : 'Some((${parts.join(', ')}))';
      final at = noneAt;
      return at == null ? some : text.substring(0, at) + some + text.substring(at + 4);
    }
    if (values.length != lists.length) throw ArgumentError('expected ${lists.length} lists');
    var out = text;
    // Items keep their comments and spelling, also when they move to the other list of the file.
    final comments = {for (final l in lists) for (final it in l.items) it.value: it.comments};
    final raws = {for (final l in lists) for (final it in l.items) it.value: ?it.raw};
    for (var k = lists.length - 1; k >= 0; k--) {
      final l = lists[k];
      if (_same(l.values, values[k])) continue;
      final rendered = _renderList(
        values[k],
        [for (final v in values[k]) comments[v] ?? const <String>[]],
        l.trailing,
        raws,
        l.multiline || l.trailing.any((c) => c.startsWith('//')) || comments.values.any((cs) => cs.any((c) => c.startsWith('//'))),
        l.indent,
        l.multiline ? (l.items.isEmpty ? true : l.trailingComma) : false,
      );
      out = out.substring(0, l.start) + rendered + out.substring(l.end);
    }
    return out;
  }
}

String _renderList(List<String> values, List<List<String>> comments, List<String> trailing, Map<String, String> raws, bool multiline, String indent, bool trailingComma) {
  String q(String v) => raws[v] ?? _quote(v);
  if (values.isEmpty && trailing.isEmpty) return '[]';
  final b = StringBuffer('[');
  if (multiline) {
    for (var k = 0; k < values.length; k++) {
      for (final c in k < comments.length ? comments[k] : const <String>[]) {
        b.write('\n$indent$c');
      }
      b.write('\n$indent${q(values[k])}');
      if (k < values.length - 1 || trailingComma) b.write(',');
    }
    for (final c in trailing) {
      b.write('\n$indent$c');
    }
    b.write('\n]');
  } else {
    final parts = <String>[];
    for (var k = 0; k < values.length; k++) {
      final cs = k < comments.length ? comments[k] : const <String>[];
      parts.add([...cs, q(values[k])].join(' '));
    }
    b.write(parts.join(', '));
    if (trailing.isNotEmpty) b.write(' ${trailing.join(' ')}');
    b.write(']');
  }
  return b.toString();
}

bool _same(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _quote(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n').replaceAll('\t', r'\t').replaceAll('\r', r'\r')}"';

/// A `//` or (nested) `/* */` comment at [i]; [setEnd] gets the offset after it. The comment's
/// text is returned without the line end.
String _comment(String text, int i, void Function(int) setEnd) {
  if (text.startsWith('//', i)) {
    final nl = text.indexOf('\n', i);
    final end = nl < 0 ? text.length : nl;
    setEnd(end);
    return text.substring(i, end);
  }
  if (text.startsWith('/*', i)) {
    var depth = 0, j = i;
    while (j < text.length) {
      if (text.startsWith('/*', j)) {
        depth++;
        j += 2;
      } else if (text.startsWith('*/', j)) {
        depth--;
        j += 2;
        if (depth == 0) break;
      } else {
        j++;
      }
    }
    if (depth != 0) throw const FormatException('unterminated comment');
    setEnd(j);
    return text.substring(i, j);
  }
  throw const FormatException('unexpected "/"');
}

String _string(String text, int i, void Function(int) setEnd) {
  final b = StringBuffer();
  var j = i + 1;
  while (j < text.length && text[j] != '"') {
    if (text[j] == '\\' && j + 1 < text.length) {
      j++;
      switch (text[j]) {
        case 'n':
          b.write('\n');
        case 't':
          b.write('\t');
        case 'r':
          b.write('\r');
        case '0':
          b.write('\u0000');
        case '\\' || '"' || "'":
          b.write(text[j]);
        case 'u' when j + 1 < text.length && text[j + 1] == '{':
          final close = text.indexOf('}', j);
          final code = close < 0 ? null : int.tryParse(text.substring(j + 2, close), radix: 16);
          if (code == null || code > 0x10FFFF) throw const FormatException('bad \\u{…} escape');
          b.writeCharCode(code);
          j = close;
        case 'x' when j + 2 < text.length:
          final code = int.tryParse(text.substring(j + 1, j + 3), radix: 16);
          if (code == null) throw const FormatException('bad \\x escape');
          b.writeCharCode(code);
          j += 2;
        default:
          throw FormatException('unsupported escape \\${text[j]}');
      }
    } else {
      b.write(text[j]);
    }
    j++;
  }
  if (j >= text.length) throw const FormatException('unterminated string');
  setEnd(j + 1);
  return b.toString();
}

/// The string lists in a RON value, in order (`None` gives none); any shape.
List<List<String>> ronStringLists(String text) {
  for (final count in [2, 1]) {
    try {
      return RonListDoc.parse(text, count: count).values;
    } on FormatException catch (e) {
      if (!e.message.startsWith('expected ')) rethrow;
    }
  }
  throw const FormatException('expected Some([…]), Some(([…], […])) or None');
}
