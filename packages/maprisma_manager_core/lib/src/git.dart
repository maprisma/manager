import 'dart:io';

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
    this.dirtyTracked = 0,
    this.untracked = 0,
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
  final int dirtyTracked;
  final int untracked;
  bool get dirty => dirtyTracked > 0 || untracked > 0;

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
  int? get newUpstreamCommits => relation == Relation.behind ? behind : (relation == Relation.diverged ? behind : null);

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

final class Git {
  Git(this.runner);
  final Runner runner;

  Future<RunResult> _git(String folder, List<String> args, {Duration timeout = const Duration(seconds: 20)}) =>
      runner.run(['git', '-C', folder, ...args], extraEnv: _gitEnv, timeout: timeout);

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
    var tracked = 0, untracked = 0;
    for (final line in results[2].stdout.split('\n')) {
      if (line.length < 3) continue;
      line.startsWith('??') ? untracked++ : tracked++;
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
      final headInUp = (await _git(folder, ['merge-base', '--is-ancestor', 'HEAD', '@{upstream}'])).code == 0;
      final upInHead = (await _git(folder, ['merge-base', '--is-ancestor', '@{upstream}', 'HEAD'])).code == 0;
      relation = switch ((headInUp, upInHead)) {
        (true, true) => Relation.upToDate,
        (true, false) => Relation.behind,
        (false, true) => Relation.ahead,
        (false, false) => Relation.diverged,
      };
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
    );
  }

  /// Fetches the upstream's remote (only that one). The caller decides about throttling.
  Future<RunResult> fetch(String folder, String remote) =>
      _git(folder, ['fetch', '--quiet', '--prune', remote], timeout: const Duration(seconds: 60));
}

bool _same(String a, String b) {
  try {
    return Directory(a).resolveSymbolicLinksSync() == Directory(b).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.equals(a, b);
  }
}
