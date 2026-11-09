import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog_model.dart';
import 'paths.dart';
import 'procs.dart';

/// The COSMIC panel's applet lists, read only (step 2 parses and writes them properly).
final class CosmicPanel {
  CosmicPanel(this.left, this.center, this.right, {this.error});
  final List<String> left;
  final List<String> center;
  final List<String> right;
  final String? error;

  /// left / center / right, or null when the id is not in the panel.
  String? zoneOf(String id) => left.contains(id)
      ? 'left'
      : center.contains(id)
      ? 'center'
      : right.contains(id)
      ? 'right'
      : null;

  static CosmicPanel read(Paths paths, {String panel = 'Panel'}) {
    final dir = p.join(paths.config, 'cosmic/com.system76.CosmicPanel.$panel/v1');
    String? error;
    List<List<String>> lists(String name) {
      final f = File(p.join(dir, name));
      if (!f.existsSync()) return const [];
      try {
        return ronStringLists(f.readAsStringSync());
      } on FormatException catch (e) {
        error = '$name: ${e.message}';
        return const [];
      }
    }

    final wings = lists('plugins_wings');
    final center = lists('plugins_center');
    return CosmicPanel(
      wings.isNotEmpty ? wings[0] : const [],
      center.isNotEmpty ? center[0] : const [],
      wings.length > 1 ? wings[1] : const [],
      error: error,
    );
  }
}

/// The string lists in a RON value like `Some(([ "a", ], [ "b" ]))` or `Some([ … ])`, in order;
/// `None` gives none.
List<List<String>> ronStringLists(String text) {
  final out = <List<String>>[];
  List<String>? current;
  var i = 0;
  while (i < text.length) {
    final c = text[i];
    if (c == '[') {
      if (current != null) throw const FormatException('nested list');
      current = <String>[];
    } else if (c == ']') {
      if (current == null) throw const FormatException('unbalanced ]');
      out.add(current);
      current = null;
    } else if (c == '"') {
      final b = StringBuffer();
      i++;
      while (i < text.length && text[i] != '"') {
        if (text[i] == '\\' && i + 1 < text.length) i++;
        b.write(text[i]);
        i++;
      }
      if (i >= text.length) throw const FormatException('unterminated string');
      if (current == null) throw const FormatException('string outside a list');
      current.add(b.toString());
    }
    i++;
  }
  if (current != null) throw const FormatException('unterminated list');
  return out;
}

/// The bar state of one app on the current desktop, as far as step 1 reads it.
Map<String, dynamic> barState(AppEntry app, DesktopId desktop, Paths paths, CosmicPanel? panel, List<ProcInfo> procs) {
  final bar = app.bar;
  if (bar.none) return {'has': false, 'state': 'none'};
  switch (desktop) {
    case DesktopId.cosmic:
      final id = bar.cosmicApplet;
      if (id == null) return {'has': false, 'state': 'none'};
      final zone = panel?.zoneOf(id);
      return {'has': true, 'id': id, 'state': zone == null ? 'out' : 'in', 'zone': zone, 'iconName': bar.iconName};
    case DesktopId.kde:
      final id = bar.kdeId;
      if (id == null) return {'has': false, 'state': 'none'};
      if (bar.kdeKind == KdeBarKind.widgetEntry) {
        // Zones live in Maprisma Icons' config: read in step 2.
        return {'has': true, 'id': id, 'kind': 'widgetEntry', 'state': 'unknown', 'iconName': bar.iconName};
      }
      final autostart = bar.kdeAutostart == null ? null : paths.expand(bar.kdeAutostart!);
      final atLogin = autostart != null && File(autostart).existsSync() && !_hidden(File(autostart));
      final exe = bar.kdeTrayExe == null ? null : paths.expand(bar.kdeTrayExe!);
      final running = exe != null && procs.any((pr) => pr.exe != null && p.equals(pr.exe!, exe));
      return {
        'has': true,
        'id': id,
        'kind': 'tray',
        'state': atLogin || running ? 'in' : 'out',
        'startsAtLogin': atLogin,
        'running': running,
        'iconName': bar.iconName,
      };
    case DesktopId.other:
      return {'has': false, 'state': 'none', 'reason': 'no bar icons on this desktop'};
  }
}

bool _hidden(File desktopFile) {
  try {
    return desktopFile.readAsLinesSync().any((l) => l.trim().toLowerCase() == 'hidden=true');
  } on FileSystemException {
    return false;
  }
}
