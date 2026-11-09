import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;

import 'run.dart';

/// How the branch stands against its configured upstream (ancestry checked, not just counts).
enum Relation { upToDate, behind, ahead, diverged, unknown }

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
    Relation.upToDate || Relation.ahead => 0,
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

  /// Whether [a] is an ancestor of [b]: null when git failed (exit codes other than 0 and 1).
  Future<bool?> _isAncestor(String folder, String a, String b) async {
    final r = await _git(folder, ['merge-base', '--is-ancestor', a, b]);
    return r.code == 0 ? true : (r.code == 1 ? false : null);
  }

  Future<GitInfo> inspect(String repo, String folder) async {
    if (!Directory(folder).existsSync()) return GitInfo(repo: repo, folder: folder, present: false);
    if (runner.which('git') == null) return GitInfo(repo: repo, folder: folder, present: true, error: 'git not found');
    final top = await _git(folder, ['rev-parse', '--show-toplevel']);
    if (!top.ok || !_same(top.stdout.trim(), folder)) {
      return GitInfo(repo: repo, folder: folder, present: true, error: 'not a git repository');
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
      errors.add('git status failed');
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
      if (relation == Relation.unknown) errors.add('could not compare with $upstream');
      if (ahead == null || behind == null) errors.add('could not count commits against $upstream');
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
