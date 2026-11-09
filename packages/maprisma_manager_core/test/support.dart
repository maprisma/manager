import 'dart:io';

import 'package:maprisma_manager_core/maprisma_manager_core.dart';
import 'package:path/path.dart' as p;

/// A temporary world: HOME, a system root, a fake /proc, a projects folder and a bin folder
/// first in PATH (git linked in, fakes like pacman written there). No network, no real HOME.
final class World {
  World._(this.dir);

  static World create() {
    final w = World._(Directory.systemTemp.createTempSync('mm-test-').path);
    for (final d in [w.home, w.root, w.proc, w.projects, w.fakeBin]) {
      Directory(d).createSync(recursive: true);
    }
    final git = _realWhich('git');
    if (git == null) throw StateError('git is needed for the tests');
    Link(p.join(w.fakeBin, 'git')).createSync(git);
    File(w.gitConfig).writeAsStringSync('[user]\n\tname = Test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n');
    return w;
  }

  final String dir;
  String get home => p.join(dir, 'home');
  String get root => p.join(dir, 'root');
  String get proc => p.join(dir, 'proc');
  String get projects => p.join(dir, 'projects');
  String get fakeBin => p.join(dir, 'fakebin');
  String get gitConfig => p.join(dir, 'gitconfig');

  Map<String, String> env({String desktop = 'COSMIC', Map<String, String> extra = const {}}) => {
    'HOME': home,
    'PATH': fakeBin,
    'XDG_CURRENT_DESKTOP': desktop,
    'MAPRISMA_PROJECTS': projects,
    'MAPRISMA_MANAGER_ROOT': root,
    'MAPRISMA_MANAGER_PROC': proc,
    'GIT_CONFIG_GLOBAL': gitConfig,
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_ALLOW_PROTOCOL': 'file',
    ...extra,
  };

  Paths get paths => Paths.fromEnvironment(env());

  CoreService core({String desktop = 'COSMIC', Map<String, String> extra = const {}, DateTime Function()? clock}) =>
      CoreService(environment: env(desktop: desktop, extra: extra), clock: clock, uid: 1000);

  /// Creates every installer path of [app] as the installer would (links to their targets).
  void install(String app, {Set<String> skipParts = const {}, Set<String> skipComponents = const {}}) {
    final a = findApp(app)!;
    final paths = this.paths;
    for (final c in a.components) {
      if (skipComponents.contains(c.id)) continue;
      for (final ip in c.paths) {
        if (skipParts.contains(ip.part)) continue;
        final path = paths.expand(ip.path);
        switch (ip.kind) {
          case PathKind.dir:
            Directory(path).createSync(recursive: true);
          case PathKind.file:
            File(path)
              ..createSync(recursive: true)
              ..writeAsStringSync('x');
          case PathKind.executable:
            File(path)
              ..createSync(recursive: true)
              ..writeAsStringSync('#!/bin/sh\n');
            chmod(path, '755');
          case PathKind.link:
            Directory(p.dirname(path)).createSync(recursive: true);
            Link(path).createSync(paths.expand(ip.target!));
        }
      }
    }
  }

  void writeFile(String path, String text, {String? mode}) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    if (mode != null) chmod(path, mode);
  }

  /// A shell script in the fake bin folder (e.g. pacman).
  void fake(String name, String body) => writeFile(p.join(fakeBin, name), '#!/bin/sh\n$body\n', mode: '755');

  /// git in [cwd], isolated from the user's configuration.
  ProcessResult git(String cwd, List<String> args) {
    // Only this environment: an inherited GIT_DIR, GIT_WORK_TREE or GIT_CONFIG_* could send
    // these writes into another checkout. Local file transports only.
    final r = Process.runSync(p.join(fakeBin, 'git'), args, workingDirectory: cwd, includeParentEnvironment: false, environment: {
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      'GIT_CONFIG_GLOBAL': gitConfig,
      'GIT_CONFIG_NOSYSTEM': '1',
      'HOME': home,
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_ALLOW_PROTOCOL': 'file',
      'LC_ALL': 'C',
    });
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
    return r;
  }

  /// A repo in the projects folder with one commit; with [upstream], a local bare repo is its
  /// origin and main tracks origin/main.
  String repo(String name, {bool upstream = false}) {
    final dir = p.join(projects, name);
    Directory(dir).createSync(recursive: true);
    git(dir, ['init', '-q']);
    File(p.join(dir, 'README')).writeAsStringSync('one\n');
    git(dir, ['add', '.']);
    git(dir, ['commit', '-q', '-m', 'one']);
    if (upstream) {
      final bare = p.join(this.dir, 'remotes', '$name.git');
      Directory(p.dirname(bare)).createSync(recursive: true);
      git(this.dir, ['init', '-q', '--bare', bare]);
      git(dir, ['remote', 'add', 'origin', bare]);
      git(dir, ['push', '-q', '-u', 'origin', 'main']);
    }
    return dir;
  }

  /// Adds a commit to [name]'s bare upstream from a second clone.
  void pushUpstreamCommit(String name) {
    final bare = p.join(dir, 'remotes', '$name.git');
    final other = p.join(dir, 'other-$name-${DateTime.now().microsecondsSinceEpoch}');
    git(dir, ['clone', '-q', bare, other]);
    File(p.join(other, 'NEW')).writeAsStringSync('new\n');
    git(other, ['add', '.']);
    git(other, ['commit', '-q', '-m', 'upstream']);
    git(other, ['push', '-q', 'origin', 'main']);
  }

  String head(String repo) => (git(p.join(projects, repo), ['rev-parse', 'HEAD']).stdout as String).trim();

  /// A fake `/proc/<pid>` owned by [uid].
  void process(int pid, {String? exe, List<String> argv = const [], int uid = 1000, int ppid = 1, int start = 4242}) {
    final d = p.join(proc, '$pid');
    Directory(d).createSync(recursive: true);
    File(p.join(d, 'status')).writeAsStringSync('Name:\tx\nUid:\t$uid\t$uid\t$uid\t$uid\n');
    File(p.join(d, 'cmdline')).writeAsStringSync(argv.map((a) => '$a\u0000').join());
    File(p.join(d, 'stat')).writeAsStringSync('$pid (x y) S $ppid 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 $start 0 0');
    if (exe != null) Link(p.join(d, 'exe')).createSync(exe);
  }

  void dispose() => Directory(dir).deleteSync(recursive: true);
}

void chmod(String path, String mode) => Process.runSync('/usr/bin/chmod', [mode, path], includeParentEnvironment: false);

String? _realWhich(String c) {
  for (final d in (Platform.environment['PATH'] ?? '/usr/bin').split(':')) {
    final f = File(p.join(d, c));
    if (f.existsSync()) return f.path;
  }
  return null;
}

Map<String, dynamic> appOf(Map<String, dynamic> list, String id) =>
    (list['apps'] as List).cast<Map<String, dynamic>>().firstWhere((a) => a['id'] == id);
