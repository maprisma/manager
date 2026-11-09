/// The KDE apps' own remove steps (plan: "Changes after the plan review"), around the file
/// deletion of the remove job:
///
/// - **Tiling**: `maprisma-tiling-shortcuts --restore` (the keys it took from other KDE actions
///   back), the scripts unloaded, `[Plugins] <script>Enabled` and only the keys of
///   `[Script-maprisma-tiling]` deleted from kwinrc, `kpackagetool6 -r` for an unchanged package,
///   KWin reconfigured, D-Bus told about the removed overlay service. Krohnkite (replaced by the
///   install, saved in `~/.local/share/maprisma-tiling/krohnkite-backup.tar.gz`) stays and the plan
///   says how to get it back; omarchy-navigation stays when it was there before.
/// - **Icons**: every Maprisma Icons widget taken out of the panels (`evaluateScript`), the Plasma
///   style switched back to the one active before the install when a generated `maprisma-panel-*`
///   style is active, `kpackagetool6 -r` for an unchanged package, then the generated styles and
///   the colour cache deleted (only when they hold nothing but what maprisma-panel-color writes).
///
/// Both only on KDE Plasma (the routes refuse elsewhere).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bar_kde.dart';
import 'catalog.dart';
import 'context.dart';
import 'paths.dart';
import 'receipts.dart';

enum StepWhen { before, after }

/// One step a remove runs besides deleting files; shown in the plan before it runs.
final class RecipeStep {
  RecipeStep(this.id, this.title, {this.commands = const [], this.when = StepWhen.before, this.required = false, this.run});
  final String id;
  final String title;
  final List<List<String>> commands;
  final StepWhen when;

  /// A failure stops the remove before any file is deleted.
  final bool required;

  /// A step of its own (plasmashell script, deleting generated files); returns an error or null.
  final Future<String?> Function(void Function(String) log)? run;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (commands.isNotEmpty) 'commands': [for (final c in commands) c.join(' ')],
    'when': when.name,
    if (required) 'required': true,
  };
}

final class RecipePlan {
  final steps = <RecipeStep>[];
  final stays = <Map<String, dynamic>>[];

  /// Generated files a step deletes: `{path, kind: generated, why}`.
  final goes = <Map<String, dynamic>>[];
  final notes = <String>[];
  String? blocked;
}

/// A value from an ini file (kwinrc, plasmarc), null when absent.
String? iniValue(String path, String group, String key) => iniGroup(path, group)[key];

/// The keys of one group of an ini file, in order.
Map<String, String> iniGroup(String path, String group) {
  final out = <String, String>{};
  try {
    var inGroup = false;
    for (final line in File(path).readAsLinesSync()) {
      final t = line.trim();
      if (t.startsWith('[')) {
        inGroup = t == '[$group]';
        continue;
      }
      if (!inGroup || t.isEmpty || t.startsWith('#') || t.startsWith(';')) continue;
      final eq = t.indexOf('=');
      if (eq <= 0) continue;
      out[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
    }
  } on FileSystemException {
    // no file
  }
  return out;
}

/// The remove steps of a KDE app ([RemoveRecipe]); [kept] are the tree roots that stay.
Future<RecipePlan> recipePlan(Ctx ctx, AppEntry app, Receipt? receipt, {required Set<String> keptTrees}) async {
  final plan = RecipePlan();
  switch (app.removeRecipe) {
    case RemoveRecipe.none:
      break;
    case RemoveRecipe.kwinTiling:
      _tiling(ctx, plan, keptTrees);
    case RemoveRecipe.plasmaIcons:
      await _icons(ctx, plan, receipt, keptTrees);
  }
  return plan;
}

void _need(Ctx ctx, RecipePlan plan, List<String> tools) {
  final missing = [for (final t in tools) if (ctx.runner.which(t) == null) t];
  if (missing.isNotEmpty) plan.blocked ??= 'needs ${missing.join(', ')} (a KDE Plasma 6 session)';
}

void _tiling(Ctx ctx, RecipePlan plan, Set<String> keptTrees) {
  final paths = ctx.paths;
  _need(ctx, plan, ['qdbus6', 'kwriteconfig6', 'kpackagetool6']);
  final scripts = p.join(paths.data, 'kwin/scripts');
  // A package goes with kpackagetool6 only when it is there and doesn't stay.
  bool goes(String name) {
    final root = p.join(scripts, name);
    return Directory(root).existsSync() && !keptTrees.contains(root);
  }

  final names = [for (final n in ['maprisma-tiling', 'omarchy-navigation']) if (goes(n)) n];
  final shortcuts = p.join(paths.bin, 'maprisma-tiling-shortcuts');
  if (File(shortcuts).existsSync()) {
    plan.steps.add(RecipeStep('shortcuts', 'give back the keys Maprisma Tiling took from other KDE actions',
        commands: [[shortcuts, '--restore']], required: true));
  }
  if (names.isNotEmpty) {
    plan.steps.add(RecipeStep('unload', 'unload the KWin scripts',
        commands: [for (final n in names) ['qdbus6', 'org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting.unloadScript', n]]));
  }
  final kwinrc = p.join(paths.config, 'kwinrc');
  final keys = iniGroup(kwinrc, 'Script-maprisma-tiling').keys.toList();
  final plugins = iniGroup(kwinrc, 'Plugins');
  final cmds = <List<String>>[
    for (final n in ['maprisma-tiling', if (names.contains('omarchy-navigation')) 'omarchy-navigation'])
      if (plugins.containsKey('${n}Enabled')) ['kwriteconfig6', '--file', 'kwinrc', '--group', 'Plugins', '--key', '${n}Enabled', '--delete'],
    for (final k in keys) ['kwriteconfig6', '--file', 'kwinrc', '--group', 'Script-maprisma-tiling', '--key', k, '--delete'],
  ];
  if (cmds.isNotEmpty) {
    plan.steps.add(RecipeStep('kwinrc', 'delete Maprisma Tiling\'s own kwinrc keys (${cmds.length}); nothing else in kwinrc', commands: cmds));
  }
  if (names.isNotEmpty) {
    plan.steps.add(RecipeStep('packages', 'kpackagetool6 removes the script package(s)',
        commands: [for (final n in names) ['kpackagetool6', '-t', 'KWin/Script', '-r', n]]));
  }
  plan.steps.add(RecipeStep('reconfigure', 'KWin reloads its configuration', commands: [['qdbus6', 'org.kde.KWin', '/KWin', 'reconfigure']], when: StepWhen.after));
  plan.steps.add(RecipeStep('dbus', 'D-Bus forgets the overlay service',
      commands: [['busctl', '--user', 'call', 'org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ReloadConfig']], when: StepWhen.after));
  // The Krohnkite migration: shown, never undone automatically.
  final backups = p.join(paths.data, 'maprisma-tiling');
  final kro = p.join(backups, 'krohnkite-backup.tar.gz');
  if (File(kro).existsSync()) {
    plan.stays.add({
      'path': kro,
      'why': 'Krohnkite, saved when Maprisma Tiling replaced it; to use it again: tar -xzf it in ${p.join(paths.data, 'kwin/scripts')} '
          'and switch it on in System Settings › Window Management › KWin Scripts',
    });
  }
  if (Directory(backups).existsSync()) {
    for (final f in Directory(backups).listSync()..sort((a, b) => a.path.compareTo(b.path))) {
      if (RegExp(r'^kwinrc-backup-.*\.ini$').hasMatch(p.basename(f.path))) {
        plan.stays.add({'path': f.path, 'why': 'Krohnkite\'s and the active-frame script\'s kwinrc settings from before the install'});
      }
    }
  }
  if (!names.contains('omarchy-navigation') && Directory(p.join(scripts, 'omarchy-navigation')).existsSync()) {
    plan.notes.add('omarchy-navigation stays switched on (it is not only Maprisma Tiling\'s)');
  }
}

/// Plasma styles maprisma-panel-color writes.
const _styleNames = ['maprisma-panel-a', 'maprisma-panel-b'];
const _styleFiles = {
  'metadata.json',
  'plasmarc',
  'widgets/panel-background.svgz',
  'opaque/widgets/panel-background.svgz',
  'solid/widgets/panel-background.svgz',
  'translucent/widgets/panel-background.svgz',
};

/// Whether [dir] is a style maprisma-panel-color made: its metadata names it and the generator,
/// and it holds nothing else. Null when it is, else why not.
String? _notGenerated(String dir) {
  final name = p.basename(dir);
  try {
    final meta = jsonDecode(File(p.join(dir, 'metadata.json')).readAsStringSync());
    final k = meta is Map ? meta['KPlugin'] : null;
    if (k is! Map || k['Id'] != name || '${k['Description']}'.contains('maprisma-panel-color') == false) {
      return 'its metadata.json is not maprisma-panel-color\'s';
    }
  } on Object {
    return 'no readable metadata.json';
  }
  for (final e in Directory(dir).listSync(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: dir);
    final t = FileSystemEntity.typeSync(e.path, followLinks: false);
    if (t == FileSystemEntityType.directory) continue;
    if (t != FileSystemEntityType.file || !_styleFiles.contains(rel)) return 'holds $rel (not written by maprisma-panel-color)';
  }
  return null;
}

/// Removes every Maprisma Icons widget from every panel; prints `MM:{"removed": n}`.
String removeWidgetsScript() => '''// mm:remove-widgets
var n = 0;
var ps = panels();
for (var i = 0; i < ps.length; i++) {
  var ws = ps[i].widgets('$iconsWidget');
  for (var j = 0; j < ws.length; j++) { ws[j].remove(); n++; }
}
print('MM:' + JSON.stringify({removed: n}));
''';

/// The Plasma style the user had before Icons (a generated one is never "before").
String? plasmaStyle(Paths paths) => iniValue(p.join(paths.config, 'plasmarc'), 'Theme', 'name');

bool isGeneratedStyle(String? name) => name != null && name.startsWith('maprisma-panel-');

Future<void> _icons(Ctx ctx, RecipePlan plan, Receipt? receipt, Set<String> keptTrees) async {
  final paths = ctx.paths;
  _need(ctx, plan, ['qdbus6', 'kpackagetool6']);
  if (plan.blocked == null) {
    try {
      final ws = await readKdeWidgets(ctx.runner);
      plan.notes.add('${ws.length} Maprisma Icons widget(s) in the panels');
    } on RouteError catch (e) {
      plan.blocked = 'plasmashell can\'t be asked (${e.message}): the widgets must leave the panels first';
    }
  }
  plan.steps.add(RecipeStep('widgets', 'take every Maprisma Icons widget out of the panels', required: true, run: (log) async {
    try {
      final v = await evaluatePlasma(ctx.runner, removeWidgetsScript());
      log('widgets removed: ${v is Map ? v['removed'] : '?'}');
      return v is Map ? null : 'plasmashell gave an unreadable answer';
    } on RouteError catch (e) {
      return '${e.code}: ${e.message}';
    }
  }));
  final current = plasmaStyle(paths);
  if (isGeneratedStyle(current)) {
    final back = receipt?.saved['plasmaTheme'] ?? 'default';
    _need(ctx, plan, ['plasma-apply-desktoptheme']);
    plan.steps.add(RecipeStep('style', 'switch the Plasma style from $current back to $back',
        commands: [['plasma-apply-desktoptheme', back]], required: true));
  }
  final root = p.join(paths.data, 'plasma/plasmoids', iconsWidget);
  if (Directory(root).existsSync() && !keptTrees.contains(root)) {
    plan.steps.add(RecipeStep('package', 'kpackagetool6 removes the widget package', commands: [['kpackagetool6', '-t', 'Plasma/Applet', '-r', iconsWidget]]));
  }
  // Generated styles and the colour cache: deleted after the switch, only when they are ours.
  final styles = <String>[];
  for (final n in _styleNames) {
    final dir = p.join(paths.data, 'plasma/desktoptheme', n);
    if (FileSystemEntity.typeSync(dir, followLinks: false) != FileSystemEntityType.directory) continue;
    final why = _notGenerated(dir);
    if (why == null) {
      styles.add(dir);
      plan.goes.add({'path': dir, 'kind': 'generated', 'why': 'Plasma style made by maprisma-panel-color'});
    } else {
      plan.stays.add({'path': dir, 'why': why});
    }
  }
  final cache = p.join(paths.cache, 'maprisma-panel');
  final cacheOk = FileSystemEntity.typeSync(cache, followLinks: false) == FileSystemEntityType.directory &&
      Directory(cache).listSync(followLinks: false).every((e) => p.basename(e.path) == 'state.json' && e is File);
  if (cacheOk) plan.goes.add({'path': cache, 'kind': 'generated', 'why': 'the colour cache'});
  if (styles.isNotEmpty || cacheOk) {
    plan.steps.add(RecipeStep('generated', 'delete the generated Plasma styles and the colour cache', when: StepWhen.after, run: (log) async {
      final active = plasmaStyle(paths);
      for (final d in styles) {
        if (p.basename(d) == active) {
          log('kept $d: it is the active Plasma style');
          continue;
        }
        if (_notGenerated(d) != null) {
          log('kept $d: it changed');
          continue;
        }
        Directory(d).deleteSync(recursive: true);
        log('removed $d');
      }
      if (cacheOk && Directory(cache).existsSync() && Directory(cache).listSync().every((e) => p.basename(e.path) == 'state.json' && e is File)) {
        Directory(cache).deleteSync(recursive: true);
        log('removed $cache');
      }
      return null;
    }));
  }
}

/// Runs the steps of [when]; a required step that fails throws [RecipeFailure].
Future<void> runRecipe(Ctx ctx, List<RecipeStep> steps, StepWhen when, void Function(String) log) async {
  for (final s in steps.where((s) => s.when == when)) {
    log('step: ${s.title}');
    String? error;
    if (s.run != null) {
      error = await s.run!(log);
    } else {
      for (final argv in s.commands) {
        final r = await ctx.runner.run(argv, timeout: const Duration(seconds: 60));
        log('${argv.join(' ')}: ${r.ok ? 'ok' : 'failed (${r.stderr.trim().split('\n').first})'}');
        if (!r.ok) error ??= '${argv.first} failed (exit ${r.code})';
      }
    }
    if (error != null) {
      if (s.required) throw RecipeFailure(s.id, error);
      log('step ${s.id}: $error (continued)');
    }
  }
}

final class RecipeFailure implements Exception {
  RecipeFailure(this.step, this.message);
  final String step;
  final String message;
}
