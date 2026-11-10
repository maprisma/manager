/// Where an app's inputs exist (plan: "GitHub"): the local folder and GitHub, and which remote of
/// the folder is the GitHub one (by URL, not by name: maprisma's origin is a private repo, its
/// GitHub remote is `public`).
library;

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'context.dart';
import 'git.dart';
import 'github.dart';
import 'receipts.dart';

/// The folder's remote whose URL is [slug]'s GitHub repo (or [Ctx.cloneUrlFor] of it); the
/// configured upstream's remote wins when several are.
Future<({String name, String url})?> githubRemote(Ctx ctx, String folder, String slug, {String? upstreamRemote}) async {
  final remotes = await ctx.git.remotes(folder);
  final want = slug.toLowerCase();
  final clone = ctx.cloneUrlFor(slug);
  bool matches(String url) => githubSlugOf(url) == want || _sameUrl(url, clone);
  if (upstreamRemote != null && remotes[upstreamRemote] != null && matches(remotes[upstreamRemote]!)) {
    return (name: upstreamRemote, url: remotes[upstreamRemote]!);
  }
  for (final e in remotes.entries) {
    if (matches(e.value)) return (name: e.key, url: e.value);
  }
  return null;
}

bool _sameUrl(String a, String b) {
  String norm(String u) {
    var s = u.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.git')) s = s.substring(0, s.length - 4);
    return p.isAbsolute(s) ? p.normalize(s) : s.toLowerCase();
  }

  return norm(a) == norm(b);
}

/// The branch on GitHub to compare with: its default branch (as last checked), else the folder's
/// branch, else main.
String githubBranch(Map<String, dynamic>? facts, GitInfo g) =>
    (facts?['defaultBranch'] is String ? facts!['defaultBranch'] as String : null) ?? g.branch ?? 'main';

/// One input's sources: `{repo, folder: {path, present, isRepo, branch, head, dirty}, github:
/// {repo, url, cloneUrl, known, public, defaultBranch, release, checked, age, stale, error?} | null,
/// remote: {name, url, isUpstream} | null, compare: {ref, fetched, ahead, behind, relation} | null,
/// newSinceBuild}`.
Future<Map<String, dynamic>> inputSource(
  Ctx ctx,
  Input input,
  GitInfo g,
  Map<String, Map<String, dynamic>> facts,
  Receipt? receipt,
) async {
  final slug = ctx.github.slugOf(input);
  final f = slug == null ? null : facts[slug] ?? ctx.github.facts(slug);
  final out = <String, dynamic>{
    'repo': input.repo,
    'folder': {
      'path': g.folder,
      'present': g.present,
      'isRepo': g.isRepo,
      'branch': g.branch,
      'head': g.head,
      'dirty': g.dirty,
    },
    'github': f == null ? null : {...f, 'linkedBy': ctx.github.linkVia(input)},
    'remote': null,
    'compare': null,
  };
  if (slug == null || !g.isRepo) return out;
  final remote = await githubRemote(ctx, g.folder, slug, upstreamRemote: g.upstreamRemote);
  if (remote == null) return out;
  out['remote'] = {'name': remote.name, 'url': remote.url, 'isUpstream': remote.name == g.upstreamRemote};
  if (g.head == null) return out;
  final ref = '${remote.name}/${githubBranch(f, g)}';
  final c = await ctx.git.compare(g.folder, ref);
  out['compare'] = {'ref': ref, 'fetched': c.exists, 'ahead': c.ahead, 'behind': c.behind, 'relation': c.relation.name};
  final built = receipt?.input(input.repo)?.commit;
  if (c.exists && built != null && receipt?.source?['kind'] != 'release') {
    out['newSinceBuild'] = await ctx.git.newSince(g.folder, built, ref);
  }
  return out;
}

/// `folder`, `GitHub`, `both` or `none` for an app (its main input).
String whereOf(Map<String, dynamic> mainSource) {
  final folder = (mainSource['folder'] as Map)['present'] == true;
  final gh = mainSource['github'] != null;
  return folder && gh ? 'both' : (folder ? 'folder' : (gh ? 'GitHub' : 'none'));
}

/// The GitHub repos of an app's inputs (the catalog's or found: [GitHub.resolveLinks] first).
List<String> appSlugs(Ctx ctx, AppEntry app) => [for (final i in app.inputs) ?ctx.github.slugOf(i)];
