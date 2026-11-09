import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'git.dart';
import 'github.dart';
import 'paths.dart';
import 'procs.dart';
import 'run.dart';

/// A core route: params in, result out; throw [RouteError] for a refusal.
typedef Handler = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

final class RouteError implements Exception {
  RouteError(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => 'RouteError($code${message == null ? '' : ': $message'})';
}

/// COSMIC / KDE / other from XDG_CURRENT_DESKTOP; MAPRISMA_MANAGER_DESKTOP overrides it.
DesktopId detectDesktop(Map<String, String> env) {
  final forced = parseDesktop(env['MAPRISMA_MANAGER_DESKTOP']);
  if (forced != null) return forced;
  final names = (env['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase().split(':');
  if (names.contains('COSMIC')) return DesktopId.cosmic;
  if (names.contains('KDE')) return DesktopId.kde;
  return DesktopId.other;
}

DesktopId? parseDesktop(String? v) => switch (v?.toLowerCase()) {
  'cosmic' => DesktopId.cosmic,
  'kde' => DesktopId.kde,
  'other' => DesktopId.other,
  _ => null,
};

/// What every route gets: where things are, the desktop, and how to run read-only commands.
final class Ctx {
  Ctx({required this.paths, required this.environment, DesktopId? desktop, Runner? runner, DateTime Function()? clock, int? uid})
    : desktop = desktop ?? detectDesktop(environment),
      runner = runner ?? Runner(environment),
      clock = clock ?? DateTime.now,
      uid = uid ?? currentUid() {
    settings = Settings.load(paths);
    final projects = resolveProjectsDir(paths, environment, settings, catalogRepos);
    projectsDir = projects.dir;
    projectsSource = projects.source;
    git = Git(this.runner);
  }

  final Paths paths;
  final Map<String, String> environment;
  final DesktopId desktop;
  final Runner runner;
  final DateTime Function() clock;
  final int? uid;
  late final Settings settings;
  late final String projectsDir;
  late final String projectsSource;
  late final Git git;

  /// The URL to clone a GitHub repo (`org/name`) from; tests point it at a local bare repo.
  /// A folder's remote is "the GitHub remote" when its URL is this one or a GitHub URL of the slug.
  String Function(String slug) cloneUrlFor = (slug) => 'https://github.com/$slug.git';

  /// GitHub facts (cache, refresh, releases, downloads).
  late final GitHub github = GitHub(this);

  /// When this core last tried to fetch a repo (an offline fetch leaves FETCH_HEAD old).
  final Map<String, DateTime> fetchAttempts = {};

  String repoFolder(String repo) => p.join(projectsDir, repo);

  /// The flutter executable: the `flutter` setting (executable or its folder), MAPRISMA_FLUTTER,
  /// PATH, then `<projects folder>/../flutter`, ~/flutter.
  ({String? exe, String source}) flutter() {
    String? asExe(String? v) {
      if (v == null || v.isEmpty) return null;
      final path = v.startsWith('~/') ? p.join(paths.home, v.substring(2)) : v;
      if (isExecutableFile(path) && !Directory(path).existsSync()) return path;
      final inDir = p.join(path, 'flutter');
      if (isExecutableFile(inDir)) return inDir;
      final inBin = p.join(path, 'bin/flutter');
      if (isExecutableFile(inBin)) return inBin;
      return null;
    }

    final fromSettings = asExe(settings.str('flutter'));
    if (fromSettings != null) return (exe: fromSettings, source: 'settings');
    final fromEnv = asExe(environment['MAPRISMA_FLUTTER']);
    if (fromEnv != null) return (exe: fromEnv, source: 'env');
    final inPath = runner.which('flutter');
    if (inPath != null) return (exe: inPath, source: 'PATH');
    for (final c in [p.join(p.dirname(projectsDir), 'flutter'), p.join(paths.home, 'flutter')]) {
      final e = asExe(c);
      if (e != null) return (exe: e, source: 'found');
    }
    return (exe: null, source: 'missing');
  }

  /// A prerequisite's program, or null. flutter/dart come from [flutter]; cargo also from ~/.cargo/bin.
  String? tool(String command) {
    switch (command) {
      case 'flutter':
        return flutter().exe;
      case 'dart':
        final f = flutter().exe;
        if (f != null) {
          final d = p.join(p.dirname(f), 'dart');
          if (isExecutableFile(d)) return d;
        }
        return runner.which('dart');
      case 'cargo':
        return runner.which('cargo') ?? (isExecutableFile(p.join(paths.home, '.cargo/bin/cargo')) ? p.join(paths.home, '.cargo/bin/cargo') : null);
      default:
        return runner.which(command);
    }
  }

  List<ProcInfo> processes() => listProcesses(paths.proc, uid: uid);
}
