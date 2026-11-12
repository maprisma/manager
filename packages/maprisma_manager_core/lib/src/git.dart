import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;

import 'run.dart';

/// How the branch stands against its configured upstream (ancestry checked, not just counts).
/// A diverged history whose other side holds the files of an earlier commit of HEAD counts as
/// [ahead] (a rewritten mirror of older work).
/// [sameContent]: the histories diverged but both sides hold the very same files (HEAD's tree is
/// the other side's tree), e.g. a public mirror whose commits were rewritten; nothing to update.
enum Relation { upToDate, behind, ahead, diverged, sameContent, unknown }

/// One repo's provenance, read only (git never prompts, never takes optional locks).
final class GitInfo {
  GitInfo({
    required this.repo,
    required this.folder,
    required this.present,
    this.isRepo = false,
    this.branch,
    this.head,
    this.dirtyTracked,
    this.untracked,
    this.upstream,
    this.upstreamRemote,
    this.upstreamUrl,
    this.ahead,
    this.behind,
    this.relation = Relation.unknown,
    this.lastFetch,
    this.error,
  });

  final String repo;
  final String folder;
  final bool present;
  final bool isRepo;

  /// null = detached HEAD.
  final String? branch;
  final String? head;
  /// null = git status failed (unknown, never "clean").
  final int? dirtyTracked;
  final int? untracked;
  bool? get dirty => dirtyTracked == null || untracked == null ? null : dirtyTracked! > 0 || untracked! > 0;

  /// e.g. `origin/main`; null = none configured.
  final String? upstream;
  final String? upstreamRemote;
  final String? upstreamUrl;
  final int? ahead;
  final int? behind;
  final Relation relation;
  final DateTime? lastFetch;
  final String? error;

  /// Commits the upstream has that HEAD hasn't, when HEAD can fast-forward to them.
  int? get newUpstreamCommits => switch (relation) {
    Relation.behind || Relation.diverged => behind,
    Relation.upToDate || Relation.ahead || Relation.sameContent => 0,
    Relation.unknown => null,
  };

  Map<String, dynamic> toJson() => {
    'repo': repo,
    'folder': folder,
    'present': present,
    'isRepo': isRepo,
    'branch': branch,
    'detached': isRepo && branch == null,
    'head': head,
    'dirty': dirty,
    'dirtyTracked': dirtyTracked,
    'untracked': untracked,
    'upstream': upstream,
    'upstreamRemote': upstreamRemote,
    'upstreamUrl': upstreamUrl,
    'ahead': ahead,
    'behind': behind,
    'relation': relation.name,
    'lastFetch': lastFetch?.toUtc().toIso8601String(),
    if (error != null) 'error': error,
  };
}

const _gitEnv = {'GIT_TERMINAL_PROMPT': '0', 'GIT_OPTIONAL_LOCKS': '0', 'LC_ALL': 'C', 'GIT_ASKPASS': 'true', 'SSH_ASKPASS': 'true'};

/// Read-only inspection: no fsmonitor hook, no lazy fetch of missing objects (partial clones),
/// no transport at all.
const _readOnlyEnv = {..._gitEnv, 'GIT_NO_LAZY_FETCH': '1'};
const _readOnlyConfig = ['-c', 'core.fsmonitor=false', '-c', 'protocol.allow=never'];

final class Git {
  Git(this.runner);
  final Runner runner;

  Future<RunResult> _git(String folder, List<String> args, {Duration timeout = const Duration(seconds: 20)}) =>
      runner.run(['git', ..._readOnlyConfig, '-C', folder, ...args], extraEnv: _readOnlyEnv, timeout: timeout);

  /// Diverged histories compared by their files: [Relation.sameContent] when HEAD holds the very
  /// files of [ref]; [Relation.ahead] when an earlier commit of HEAD's (first-parent, up to
  /// [historyDepth] back) does, i.e. [ref] is a rewritten copy of older work (a public mirror)
  /// and the folder has more; else [Relation.diverged].
  static const historyDepth = 1000;
  Future<Relation> _byContent(String folder, String ref) async {
    final at = await _treeAt(folder, ref, 'HEAD');
    if (at == null) return Relation.diverged;
    return at == 0 ? Relation.sameContent : Relation.ahead;
  }

  /// How far back in [rev]'s first-parent history (0 = [rev] itself) a commit holds [ref]'s
  /// files; null when none of the last [historyDepth] does or git fails.
  Future<int?> _treeAt(String folder, String ref, String rev) async {
    final r = await _git(folder, ['rev-parse', '-q', '--verify', '$ref^{tree}']);
    final tree = r.ok ? r.stdout.trim() : '';
    if (tree.isEmpty) return null;
    final log = await _git(folder, ['log', '--first-parent', '-n', '$historyDepth', '--format=%T', rev]);
    if (!log.ok) return null;
    final trees = log.stdout.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final i = trees.indexOf(tree);
    return i < 0 ? null : i;
  }

  /// Whether [a] is an ancestor of [b]: null when git failed (exit codes other than 0 and 1).
  Future<bool?> _isAncestor(String folder, String a, String b) async {
    final r = await _git(folder, ['merge-base', '--is-ancestor', a, b]);
    return r.code == 0 ? true : (r.code == 1 ? false : null);
  }

  Future<GitInfo> inspect(String repo, String folder) async {
    if (!Directory(folder).existsSync()) return GitInfo(repo: repo, folder: folder, present: false);
    if (runner.which('git') == null) return GitInfo(repo: repo, folder: folder, present: true, error: tr('git not found'));
    final top = await _git(folder, ['rev-parse', '--show-toplevel']);
    if (!top.ok || !_same(top.stdout.trim(), folder)) {
      return GitInfo(repo: repo, folder: folder, present: true, error: tr('not a git repository'));
    }
    final results = await Future.wait([
      _git(folder, ['symbolic-ref', '-q', '--short', 'HEAD']),
      _git(folder, ['rev-parse', '-q', '--verify', 'HEAD^{commit}']),
      _git(folder, ['status', '--porcelain=v1', '--untracked-files=normal']),
      _git(folder, ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}']),
      _git(folder, ['rev-parse', '--git-path', 'FETCH_HEAD']),
    ]);
    final branch = results[0].ok ? results[0].stdout.trim() : null;
    final head = results[1].ok ? results[1].stdout.trim() : null;
    int? tracked, untracked;
    final errors = <String>[];
    if (results[2].ok) {
      final lines = [for (final l in results[2].stdout.split('\n')) if (l.length >= 3) l];
      untracked = lines.where((l) => l.startsWith('??')).length;
      tracked = lines.length - untracked;
    } else {
      errors.add(tr('git status failed'));
    }
    final upstream = results[3].ok ? results[3].stdout.trim() : null;
    DateTime? lastFetch;
    if (results[4].ok) {
      final fh = results[4].stdout.trim();
      final f = File(p.isAbsolute(fh) ? fh : p.join(folder, fh));
      if (f.existsSync()) lastFetch = f.lastModifiedSync();
    }
    String? remote, url;
    int? ahead, behind;
    var relation = Relation.unknown;
    if (upstream != null && upstream.isNotEmpty && head != null) {
      if (branch != null) {
        final r = await _git(folder, ['config', '--get', 'branch.$branch.remote']);
        if (r.ok) remote = r.stdout.trim();
        if (remote != null && remote != '.') {
          final u = await _git(folder, ['remote', 'get-url', remote]);
          if (u.ok) url = u.stdout.trim();
        }
      }
      final counts = await _git(folder, ['rev-list', '--left-right', '--count', 'HEAD...@{upstream}']);
      final parts = counts.stdout.trim().split(RegExp(r'\s+'));
      if (counts.ok && parts.length == 2) {
        ahead = int.tryParse(parts[0]);
        behind = int.tryParse(parts[1]);
      }
      final headInUp = await _isAncestor(folder, 'HEAD', '@{upstream}');
      final upInHead = await _isAncestor(folder, '@{upstream}', 'HEAD');
      relation = switch ((headInUp, upInHead)) {
        (true, true) => Relation.upToDate,
        (true, false) => Relation.behind,
        (false, true) => Relation.ahead,
        (false, false) => Relation.diverged,
        _ => Relation.unknown,
      };
      if (relation == Relation.diverged) relation = await _byContent(folder, '@{upstream}');
      if (relation == Relation.unknown) errors.add(trf('could not compare with {0}', [upstream]));
      if (ahead == null || behind == null) errors.add(trf('could not count commits against {0}', [upstream]));
    }
    return GitInfo(
      repo: repo,
      folder: folder,
      present: true,
      isRepo: true,
      branch: branch,
      head: head,
      dirtyTracked: tracked,
      untracked: untracked,
      upstream: upstream,
      upstreamRemote: remote,
      upstreamUrl: url,
      ahead: ahead,
      behind: behind,
      relation: relation,
      lastFetch: lastFetch,
      error: errors.isEmpty ? null : errors.join('; '),
    );
  }

  /// `git pull --ff-only` (an update job, only when clean, behind and the upstream is known).
  Future<RunResult> pullFfOnly(String folder) => runner.run(
    ['git', '-c', 'core.fsmonitor=false', '-C', folder, 'pull', '--ff-only', '--quiet'],
    extraEnv: _gitEnv,
    timeout: const Duration(seconds: 120),
  );

  /// A content fingerprint of the working tree: `tree:<HEAD's tree>` when clean, else
  /// `dirty:<sha256 of HEAD and every changed/untracked file's path and content hash>`.
  Future<String?> fingerprint(String folder, String Function(String path) hashFile) async {
    final tree = await _git(folder, ['rev-parse', '-q', '--verify', 'HEAD^{tree}']);
    if (!tree.ok) return null;
    final st = await _git(folder, ['status', '--porcelain=v1', '-z', '--untracked-files=all']);
    if (!st.ok) return null;
    final fields = st.stdout.split('\u0000');
    final changed = <String>[];
    for (var i = 0; i < fields.length; i++) {
      final f = fields[i];
      if (f.length < 4) continue;
      changed.add(f.substring(3));
      if (f[0] == 'R' || f[0] == 'C') i++; // the original path follows
    }
    if (changed.isEmpty) return 'tree:${tree.stdout.trim()}';
    changed.sort();
    final parts = <String>['head ${tree.stdout.trim()}'];
    for (final rel in changed) {
      final path = p.join(folder, rel);
      String h;
      try {
        h = FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file ? hashFile(path) : 'other';
      } on FileSystemException {
        h = 'unreadable';
      }
      parts.add('$rel\t${FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound ? 'deleted' : h}');
    }
    return 'dirty:${sha256.convert(utf8.encode(parts.join('\n')))}';
  }

  /// The folder's remotes: name → fetch URL (read-only).
  Future<Map<String, String>> remotes(String folder) async {
    final r = await _git(folder, ['config', '--get-regexp', r'^remote\..*\.url$']);
    final out = <String, String>{};
    if (!r.ok) return out;
    for (final line in r.stdout.split('\n')) {
      final m = RegExp(r'^remote\.(.+)\.url (.+)$').firstMatch(line.trim());
      if (m != null) out.putIfAbsent(m.group(1)!, () => m.group(2)!.trim());
    }
    return out;
  }

  /// HEAD against [ref] (e.g. `public/main`, as of the last fetch): ancestry checked as for the
  /// upstream. `exists: false` when the ref isn't there (never fetched).
  Future<({bool exists, String? commit, int? ahead, int? behind, Relation relation})> compare(String folder, String ref) async {
    final ref0 = ref.startsWith('refs/') ? ref : 'refs/remotes/$ref';
    final v = await _git(folder, ['rev-parse', '-q', '--verify', '$ref0^{commit}']);
    if (!v.ok) return (exists: false, commit: null, ahead: null, behind: null, relation: Relation.unknown);
    // Everything below against the exact commit: a branch or tag of the same short name can't interfere.
    final full = v.stdout.trim();
    final counts = await _git(folder, ['rev-list', '--left-right', '--count', 'HEAD...$full']);
    final parts = counts.stdout.trim().split(RegExp(r'\s+'));
    final ahead = counts.ok && parts.length == 2 ? int.tryParse(parts[0]) : null;
    final behind = counts.ok && parts.length == 2 ? int.tryParse(parts[1]) : null;
    final headIn = await _isAncestor(folder, 'HEAD', full);
    final refIn = await _isAncestor(folder, full, 'HEAD');
    var relation = switch ((headIn, refIn)) {
      (true, true) => Relation.upToDate,
      (true, false) => Relation.behind,
      (false, true) => Relation.ahead,
      (false, false) => Relation.diverged,
      _ => Relation.unknown,
    };
    if (relation == Relation.diverged) relation = await _byContent(folder, full);
    return (exists: true, commit: full, ahead: ahead, behind: behind, relation: relation);
  }

  /// Commits [ref] has that [commit] hasn't (null when either is unknown here).
  Future<int?> newSince(String folder, String commit, String ref) async {
    final full = ref.startsWith('refs/') ? ref : 'refs/remotes/$ref';
    final r = await _git(folder, ['rev-list', '--count', '$commit..$full']);
    final n = r.ok ? int.tryParse(r.stdout.trim()) : null;
    // A rewritten mirror of what the build already has (its files are those of [commit] or an
    // earlier commit of it): nothing new.
    if (n != null && n > 0 && await _treeAt(folder, full, commit) != null) return 0;
    return n;
  }

  /// `git merge --ff-only <commit>` (an update job, only when clean and [commit] contains HEAD;
  /// always an exact commit id, never a ref name that a local branch or tag could shadow).
  Future<RunResult> mergeFfOnly(String folder, String commit) => runner.run(
    ['git', '-c', 'core.fsmonitor=false', '-C', folder, 'merge', '--ff-only', '--quiet', commit],
    extraEnv: _gitEnv,
    timeout: const Duration(seconds: 120),
  );

  /// The environment for a clone (no prompts).
  static Map<String, String> get cloneEnv => _gitEnv;

  /// Fetches the upstream's remote (only that one). The caller decides about throttling.
  Future<RunResult> fetch(String folder, String remote) => runner.run(
    ['git', '-c', 'core.fsmonitor=false', '-C', folder, 'fetch', '--quiet', '--prune', remote],
    extraEnv: _gitEnv,
    timeout: const Duration(seconds: 60),
  );
}

bool _same(String a, String b) {
  try {
    return Directory(a).resolveSymbolicLinksSync() == Directory(b).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.equals(a, b);
  }
}
