import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';

/// The Theme page: Maprisma Theme's themes in short (`maprisma-theme-core list`, its route
/// themes.brief) and applying one (`maprisma-theme-core apply <slug>`, the same route the Theme
/// app, its applet and its shortcuts use; Theme core runs one apply at a time). Nothing of
/// Theme's own files is read or written here.
final class ThemeViewService {
  ThemeViewService(this.ctx);
  final Ctx ctx;

  static final slugRe = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._+-]*$');
  static final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// `$MAPRISMA_THEME_CORE` (an absolute program, for trying a new Theme build), else
  /// `~/.local/bin/maprisma-theme-core` (where Theme installs it), else the one on PATH.
  String? binary() {
    final own = ctx.environment['MAPRISMA_THEME_CORE'];
    if (own != null && own.startsWith('/') && ctx.runner.which(own) != null) return own;
    final local = p.join(ctx.paths.bin, 'maprisma-theme-core');
    if (ctx.runner.which(local) != null) return local;
    return ctx.runner.which('maprisma-theme-core');
  }

  String _need() => binary() ?? (throw RouteError('not_installed', tr('Maprisma Theme is not installed')));

  Future<Map<String, dynamic>> _run(List<String> args, Duration timeout) async {
    final r = await ctx.runner.run([_need(), ...args], timeout: timeout);
    Object? v;
    try {
      v = jsonDecode(r.stdout.trim().split('\n').lastWhere((l) => l.trim().isNotEmpty, orElse: () => ''));
    } on FormatException {
      v = null;
    }
    if (v is Map<String, dynamic>) {
      final error = v['error'];
      if (error is String) {
        // An older Theme core doesn't know `list` yet.
        if (error == 'bad_args') throw RouteError('too_old', tr('Update Maprisma Theme to pick its themes here'));
        throw RouteError(error, v['message'] is String ? v['message'] as String : null);
      }
      if (r.ok) return v;
    }
    if (r.code == 124) throw RouteError('timeout', tr('Maprisma Theme took too long'));
    throw RouteError('failed', r.stderr.trim().isEmpty ? trf('exit {0}', [r.code]) : r.stderr.trim().split('\n').first);
  }

  /// One theme as the page shows it; null when the entry is unusable.
  static Map<String, dynamic>? clean(Object? t) {
    if (t is! Map || t['slug'] is! String || !slugRe.hasMatch(t['slug'] as String)) return null;
    final colors = t['colors'] is Map ? t['colors'] as Map : const {};
    final preview = t['preview'];
    return {
      'slug': t['slug'],
      'name': t['name'] is String && (t['name'] as String).trim().isNotEmpty ? (t['name'] as String).trim() : t['slug'],
      'current': t['current'] == true,
      'favorite': t['favorite'] == true,
      'preview': preview is String && preview.startsWith('/') && File(preview).existsSync() ? preview : null,
      'mode': colors['mode'] == 'light' ? 'light' : 'dark',
      'colors': {
        for (final k in ['background', 'foreground', 'accent', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan'])
          if (colors[k] is String && _hex.hasMatch(colors[k] as String)) k: colors[k],
      },
    };
  }

  /// `theme.list`: {current, themes: [{slug, name, current, favorite, preview, mode, colors}]}
  /// in Theme's order, without the themes hidden there.
  Future<Map<String, dynamic>> list() async {
    final v = await _run(['list'], const Duration(seconds: 20));
    final themes = [
      for (final t in v['themes'] is List ? v['themes'] as List : const [])
        if (t is Map && t['hidden'] != true) ?clean(t),
    ];
    return {'current': v['current'] is String ? v['current'] : '', 'themes': themes};
  }

  /// `theme.apply` {slug}: Theme core's answer (what was done).
  Future<Map<String, dynamic>> apply(Map<String, dynamic> params) async {
    final slug = params['slug'];
    if (slug is! String || !slugRe.hasMatch(slug)) throw RouteError('bad_params', 'slug');
    return _run(['apply', slug], const Duration(seconds: 120));
  }
}
