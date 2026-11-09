import 'dart:convert';
import 'dart:io';

import 'bar_cosmic.dart';
import 'context.dart';
import 'paths.dart';
import 'run.dart';

/// Maprisma Icons' plugin id.
const iconsWidget = 'com.maprisma.panel';

/// The config keys of Maprisma Icons ([General] group, StringList each).
const kdeKeys = ['zoneLeft', 'zoneCenter', 'zoneRight', 'hidden'];

/// One Maprisma Icons instance in a Plasma panel, as plasmashell has it.
final class KdeWidget {
  KdeWidget({required this.panel, required this.widget, this.screen, this.location, required this.config, this.order});

  /// The widget's earlier single order (read only): its zones fall back to it like main.qml does.
  final List<String>? order;

  factory KdeWidget.fromJson(Map<String, dynamic> j) => KdeWidget(
    panel: (j['panel'] as num).toInt(),
    widget: (j['widget'] as num).toInt(),
    screen: (j['screen'] as num?)?.toInt(),
    location: j['location']?.toString(),
    config: {for (final k in kdeKeys) k: _strings(j[k])},
    order: _strings(j['order']),
  );

  final int panel;
  final int widget;
  final int? screen;
  final String? location;

  /// zoneLeft/zoneCenter/zoneRight/hidden; null = not set (the widget's default).
  final Map<String, List<String>?> config;

  List<String> get hidden => config['hidden'] ?? const [];

  /// The zones as saved (the centre's default is the clock), each id once (the first wins).
  Layout get savedLayout {
    final seen = <String>{};
    List<String> uniq(List<String>? l) => [for (final x in l ?? const <String>[]) if (seen.add(x)) x];
    final left = config['zoneLeft'] ?? const [], right = config['zoneRight'] ?? const [];
    final center = config['zoneCenter'] ?? const ['clock'];
    // main.qml zones(): nothing in left/right, an old `order` and at most the clock in the centre.
    if (left.isEmpty && right.isEmpty && (order ?? const []).isNotEmpty && center.length <= 1) {
      return Layout(uniq(order), uniq(center.isEmpty ? const ['clock'] : center), const []);
    }
    return Layout(uniq(left), uniq(center), uniq(right));
  }

  String get revision => fnv64(jsonEncode({for (final k in kdeKeys) k: config[k]}));

  Map<String, dynamic> toJson() => {
    'panel': panel,
    'widget': widget,
    'screen': ?screen,
    'location': ?location,
    for (final k in kdeKeys) k: config[k],
  };
}

List<String>? _strings(Object? v) {
  if (v == null) return null;
  if (v is String) return v.isEmpty ? const [] : v.split(',');
  if (v is List) return [for (final x in v) '$x'];
  return null;
}

/// The JavaScript helpers both scripts share: a StringList comes back as a JS array, a string
/// (an unknown key) as comma text, or not at all.
const _jsCommon = r'''
var L = function (v) {
  if (v === undefined || v === null) return null;
  if (typeof v === 'string') return v === '' ? [] : v.split(',');
  var o = []; for (var i = 0; i < v.length; i++) o.push(String(v[i])); return o;
};
var KEYS = ['zoneLeft', 'zoneCenter', 'zoneRight', 'hidden'];
// readConfig decodes by the default's type: a list default reads a StringList; configKeys tells
// a missing key (null: the widget's own default) from an empty one.
var describe = function (pn, w) {
  w.currentConfigGroup = ['General'];
  var d = {panel: pn.id, widget: w.id, screen: pn.screen, location: String(pn.location)};
  var have = L(w.configKeys) || [];
  var read = function (key) { return have.indexOf(key) >= 0 ? L(w.readConfig(key, [])) : null; };
  for (var k = 0; k < KEYS.length; k++) d[KEYS[k]] = read(KEYS[k]);
  d.order = read('order');
  return d;
};
''';

/// Lists every Maprisma Icons instance in every panel.
String kdeReadScript() => '''$_jsCommon
var out = [];
var ps = panels();
for (var i = 0; i < ps.length; i++) {
  var ws = ps[i].widgets('$iconsWidget');
  for (var j = 0; j < ws.length; j++) out.push(describe(ps[i], ws[j]));
}
print('MM:' + JSON.stringify(out));
''';

/// Writes [values] (keys of [kdeKeys]) to widget [widget] when its config is still [expected];
/// prints the config read back, `{"changed": true, ...}` or `null` (no such widget).
String kdeWriteScript(int widget, Map<String, List<String>> values, Map<String, List<String>?> expected) => '''$_jsCommon
var want = ${jsonEncode(values)};
var expected = ${jsonEncode(expected)};
var result = null;
var ps = panels();
for (var i = 0; i < ps.length && result === null; i++) {
  var ws = ps[i].widgets('$iconsWidget');
  for (var j = 0; j < ws.length; j++) {
    if (ws[j].id !== $widget) continue;
    var now = describe(ps[i], ws[j]);
    var same = true;
    for (var k = 0; k < KEYS.length; k++)
      if (JSON.stringify(now[KEYS[k]]) !== JSON.stringify(expected[KEYS[k]])) same = false;
    if (!same) { now.changed = true; result = now; break; }
    ws[j].currentConfigGroup = ['General'];
    for (var key in want) ws[j].writeConfig(key, want[key]);
    result = describe(ps[i], ws[j]);
    break;
  }
}
print('MM:' + JSON.stringify(result));
''';

/// Runs a script in plasmashell (`qdbus6 org.kde.plasmashell /PlasmaShell …evaluateScript`) and
/// returns what it printed after `MM:`.
Future<Object?> evaluatePlasma(Runner runner, String script) async {
  if (runner.which('qdbus6') == null) throw RouteError('unavailable', 'qdbus6 not found (Plasma 6 session needed)');
  final r = await runner.run(['qdbus6', 'org.kde.plasmashell', '/PlasmaShell', 'org.kde.PlasmaShell.evaluateScript', script], timeout: const Duration(seconds: 10));
  if (!r.ok) throw RouteError('unavailable', 'plasmashell: ${r.stderr.trim().split('\n').first}');
  final line = r.stdout.split('\n').map((l) => l.trim()).lastWhere((l) => l.startsWith('MM:'), orElse: () => '');
  if (line.isEmpty) throw RouteError('internal', 'plasmashell gave no answer');
  try {
    return jsonDecode(line.substring(3));
  } on FormatException {
    throw RouteError('internal', 'plasmashell gave an unreadable answer');
  }
}

Future<List<KdeWidget>> readKdeWidgets(Runner runner) async {
  final v = await evaluatePlasma(runner, kdeReadScript());
  if (v is! List) throw RouteError('internal', 'plasmashell gave an unreadable answer');
  return [for (final w in v) KdeWidget.fromJson((w as Map).cast<String, dynamic>())];
}

/// Writes the zones of [l] and [hidden] to [w] (deduplicated across zones; hidden ids are in no
/// zone), when the widget's config is still what [w] read; returns the widget as read back.
Future<KdeWidget> writeKdeWidget(Runner runner, KdeWidget w, Layout l, List<String> hidden) async {
  final seen = <String>{};
  final hide = [for (final h in hidden) if (seen.add(h)) h];
  List<String> zone(Area a) => [for (final x in l.areas[a]!) if (seen.add(x)) x];
  final values = {
    'zoneLeft': zone(Area.left),
    'zoneCenter': zone(Area.center),
    'zoneRight': zone(Area.right),
    'hidden': hide,
  };
  final v = await evaluatePlasma(runner, kdeWriteScript(w.widget, values, w.config));
  if (v == null) throw RouteError('not_found', 'Maprisma Icons widget ${w.widget} is gone');
  if (v is! Map) throw RouteError('internal', 'plasmashell gave an unreadable answer');
  final back = KdeWidget.fromJson(v.cast<String, dynamic>());
  if (v['changed'] == true) throw RouteError('changed', 'Maprisma Icons\' zones changed since they were read');
  for (final k in kdeKeys) {
    final got = back.config[k] ?? const <String>[];
    if (jsonEncode(got) != jsonEncode(values[k])) throw RouteError('internal', 'read back $k differs: ${jsonEncode(got)}');
  }
  return back;
}

// --- tray autostart files --------------------------------------------------------------------

/// Whether the autostart file says `Hidden=true` (in its [Desktop Entry] group).
bool desktopHidden(String path) {
  try {
    var inEntry = false;
    for (final line in File(path).readAsLinesSync()) {
      final t = line.trim();
      if (t.startsWith('[')) inEntry = t == '[Desktop Entry]';
      if (inEntry && t.replaceAll(' ', '').toLowerCase() == 'hidden=true') return true;
    }
  } on FileSystemException {
    return false;
  }
  return false;
}

/// Refuses (`bad_file`) an autostart file without a [Desktop Entry] group.
void checkDesktopFile(String path) {
  try {
    if (!File(path).readAsLinesSync().any((l) => l.trim() == '[Desktop Entry]')) {
      throw RouteError('bad_file', '$path has no [Desktop Entry] group');
    }
  } on FileSystemException catch (e) {
    throw RouteError('bad_file', '$path: ${e.message}');
  }
}

/// Sets or clears `Hidden=true` in the autostart file's [Desktop Entry] group; the rest stays.
/// Returns whether the file changed. A missing file: `not_found`.
bool setDesktopHidden(Paths paths, String path, bool hidden) {
  final String text;
  try {
    text = File(path).readAsStringSync();
  } on FileSystemException {
    throw RouteError('not_found', 'no autostart file $path');
  }
  final lines = text.split('\n');
  final out = <String>[];
  var inEntry = false, inserted = false, sawEntry = false;
  for (final line in lines) {
    final t = line.trim();
    if (t.startsWith('[')) {
      inEntry = t == '[Desktop Entry]';
      out.add(line);
      if (inEntry) {
        sawEntry = true;
        if (hidden && !inserted) {
          out.add('Hidden=true');
          inserted = true;
        }
      }
      continue;
    }
    if (inEntry && RegExp(r'^\s*Hidden\s*=').hasMatch(line)) continue;
    out.add(line);
  }
  if (!sawEntry) throw RouteError('bad_file', '$path has no [Desktop Entry] group');
  final next = out.join('\n');
  if (next == text) return false;
  backupFiles(paths, 'autostart', [path]);
  atomicWrite(path, next);
  return true;
}
