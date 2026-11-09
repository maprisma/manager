/// GitHub facts (plan: "GitHub"): where an app's repo is on GitHub, whether it is public, its
/// default branch and latest release with its assets. Read through `gh api` when gh is installed
/// and logged in, else the public REST API without a token. Cached in
/// `~/.local/state/maprisma-manager/github.json` with the time they were checked; refreshed only
/// by `github.refresh` (and a release job), at most every [githubInterval] unless forced. Offline:
/// the last known facts with their age.
///
/// Tests never reach the network: [GitHub.http] and [GitHub.download] are injectable, and with
/// `MAPRISMA_MANAGER_OFFLINE=1` the built-in ones refuse and gh is used only when
/// `MAPRISMA_MANAGER_GH` names it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'bar_cosmic.dart' show atomicWrite, withStateLock;
import 'catalog.dart';
import 'context.dart';

/// How long checked facts count as fresh.
const githubInterval = Duration(minutes: 30);

/// One HTTP answer (the REST API, or a download's first response).
typedef HttpAnswer = ({int status, String body, Map<String, String> headers});

/// A GET of an API URL; throws [SocketException]/[HttpException]/[TimeoutException] when offline.
typedef HttpGet = Future<HttpAnswer> Function(Uri uri);

/// Downloads [url] to [dest] (a new file); [cancelled] is asked between chunks (true: stop, the
/// partial file is removed by the caller). Throws on any failure.
typedef Download = Future<void> Function(Uri url, String dest, {required bool Function() cancelled});

final class GitHubError implements Exception {
  GitHubError(this.message, {this.status, this.rateLimited = false, this.reset});
  final String message;
  final int? status;
  final bool rateLimited;
  final DateTime? reset;
  @override
  String toString() => message;
}

/// An API answer: [json] for 200, null with [status] 404 for "not there".
final class ApiAnswer {
  ApiAnswer(this.status, this.json);
  final int status;
  final Object? json;
}

/// How the facts are read: `gh api` or the REST API.
abstract interface class GitHubApi {
  String get via;
  Future<ApiAnswer> get(String path);
}

/// `gh api <path>` (the user's own login; also private repos).
final class GhCliApi implements GitHubApi {
  GhCliApi(this.ctx, this.gh);
  final Ctx ctx;
  final String gh;

  @override
  String get via => 'gh';

  @override
  Future<ApiAnswer> get(String path) async {
    final r = await ctx.runner.run([gh, 'api', '-H', 'Accept: application/vnd.github+json', path],
        extraEnv: const {'GH_PROMPT_DISABLED': '1', 'NO_COLOR': '1', 'GH_NO_UPDATE_NOTIFIER': '1'}, timeout: const Duration(seconds: 30));
    if (r.ok) {
      try {
        return ApiAnswer(200, jsonDecode(r.stdout));
      } on FormatException {
        throw GitHubError('gh api $path: not JSON');
      }
    }
    final status = int.tryParse(RegExp(r'HTTP (\d{3})').firstMatch(r.stderr)?.group(1) ?? '');
    if (status == 404) return ApiAnswer(404, null);
    // no answer from GitHub at all: offline, like the REST API's SocketException
    if (status == null && (r.code == 124 || _transport.hasMatch(r.stderr))) {
      throw SocketException('gh: ${_firstLine(r.stderr)}');
    }
    final limited = status == 429 || (status == 403 && r.stderr.toLowerCase().contains('rate limit'));
    throw GitHubError(
      limited ? 'rate limited' : 'gh api $path: ${_firstLine(r.stderr)}',
      status: status,
      rateLimited: limited,
    );
  }
}

/// The public REST API without a token (60 requests an hour per address).
final class RestApi implements GitHubApi {
  RestApi(this.http, {this.base = 'https://api.github.com/'});
  final HttpGet http;
  final String base;

  @override
  String get via => 'rest';

  @override
  Future<ApiAnswer> get(String path) async {
    final a = await http(Uri.parse('$base$path'));
    if (a.status == 200) {
      try {
        return ApiAnswer(200, jsonDecode(a.body));
      } on FormatException {
        throw GitHubError('$path: not JSON', status: 200);
      }
    }
    if (a.status == 404) return ApiAnswer(404, null);
    final remaining = a.headers['x-ratelimit-remaining'];
    final limited = a.status == 429 || (a.status == 403 && (remaining == '0' || a.body.toLowerCase().contains('rate limit')));
    final resetSec = int.tryParse(a.headers['x-ratelimit-reset'] ?? '');
    final reset = resetSec == null ? null : DateTime.fromMillisecondsSinceEpoch(resetSec * 1000, isUtc: true);
    throw GitHubError(
      limited ? 'rate limited${reset == null ? '' : ' until ${reset.toIso8601String()}'}' : '$path: HTTP ${a.status}',
      status: a.status,
      rateLimited: limited,
      reset: reset,
    );
  }
}

/// The web URL `https://github.com/<org>/<repo>` and the clone URL for a slug.
String githubWebUrl(String slug) => 'https://github.com/$slug';

/// `org/repo` from a GitHub URL (https, ssh, git@), lower case; null for anything else.
String? githubSlugOf(String url) {
  final u = url.trim();
  final m = RegExp(r'^(?:https?://(?:[^@/]+@)?github\.com/|ssh://git@github\.com/|git@github\.com:|git://github\.com/)([^/]+)/([^/]+?)(?:\.git)?/?$',
          caseSensitive: false)
      .firstMatch(u);
  if (m == null) return null;
  return '${m.group(1)}/${m.group(2)}'.toLowerCase();
}

/// A version from a tag or package version: `v0.14.2`, `0.14.2-1`, `0.1.4+5` → [0, 14, 2] …;
/// null when it doesn't start with numbers.
List<int>? parseVersion(String? v) {
  if (v == null) return null;
  final m = RegExp(r'^[vV]?(\d+(?:\.\d+)*)').firstMatch(v.trim());
  if (m == null) return null;
  return [for (final part in m.group(1)!.split('.')) int.parse(part)];
}

/// < 0, 0, > 0; null when either isn't a version.
int? compareVersions(String? a, String? b) {
  final x = parseVersion(a), y = parseVersion(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// The tag's version (`v0.1.4` → `0.1.4`).
String tagVersion(String tag) => tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;

/// A release as kept in the cache.
Map<String, dynamic> releaseFacts(Map json) => {
  'tag': json['tag_name'],
  'name': json['name'],
  'published': json['published_at'],
  'url': json['html_url'],
  'prerelease': json['prerelease'] == true,
  'assets': [
    for (final a in (json['assets'] as List? ?? const []))
      if (a is Map)
        {
          'name': a['name'],
          'size': a['size'],
          'url': a['browser_download_url'],
          if (a['digest'] is String) 'digest': a['digest'],
        },
  ],
};

/// The GitHub facts of one core: cache, refresh, releases, downloads.
final class GitHub {
  GitHub(this.ctx);
  final Ctx ctx;

  /// The REST API's GET (tests inject fixtures).
  HttpGet? http;

  /// Downloads (tests inject a copy from fixtures).
  Download? download;

  /// Tests: the API to use, whatever is installed.
  GitHubApi? api;

  /// When this process last tried each repo (a failed try counts for the throttle too).
  final Map<String, DateTime> _tried = {};

  bool get offline => ctx.environment['MAPRISMA_MANAGER_OFFLINE'] == '1';

  String get cacheFile => p.join(ctx.paths.managerState, 'github.json');
  String get downloads => p.join(ctx.paths.cache, 'maprisma-manager', 'downloads');

  /// Every GitHub repo of the catalog (or of one app), in catalog order.
  static List<String> slugs([AppEntry? app]) => [
    for (final a in app == null ? catalog : [app])
      for (final i in a.inputs)
        if (i.github != null) i.github!,
  ].fold<List<String>>([], (l, s) => l.contains(s) ? l : (l..add(s)));

  Map<String, dynamic> _load() {
    try {
      final data = jsonDecode(File(cacheFile).readAsStringSync());
      if (data is Map<String, dynamic> && data['repos'] is Map<String, dynamic>) return data;
    } on FileSystemException {
      // none yet
    } on FormatException {
      // a broken cache counts as none
    }
    return {'schema': 1, 'repos': <String, dynamic>{}};
  }

  void _save(Map<String, dynamic> data) => atomicWrite(cacheFile, const JsonEncoder.withIndent('  ').convert(data));

  /// What is known about [slug] (cache only, no network): `{repo, url, known, …facts, checked,
  /// age (seconds), stale, error?, lastTry?}`.
  Map<String, dynamic> facts(String slug, {Map<String, dynamic>? cache}) {
    final e = ((cache ?? _load())['repos'] as Map)[slug];
    final out = <String, dynamic>{'repo': slug, 'url': githubWebUrl(slug), 'cloneUrl': ctx.cloneUrlFor(slug)};
    if (e is! Map) return {...out, 'known': false, 'stale': true};
    final checked = e['checked'] is String ? DateTime.tryParse(e['checked']) : null;
    final f = e['facts'];
    final now = ctx.clock();
    return {
      ...out,
      'known': f is Map,
      if (f is Map) ...{
        if (f['url'] is String) 'url': f['url'],
        'public': f['public'],
        'defaultBranch': f['defaultBranch'],
        'release': f['release'],
      },
      'checked': checked?.toUtc().toIso8601String(),
      'age': checked == null ? null : now.difference(checked).inSeconds,
      'stale': checked == null || now.difference(checked) >= githubInterval,
      if (e['error'] is String) 'error': e['error'],
      if (e['lastTry'] is String) 'lastTry': e['lastTry'],
      if (e['via'] is String) 'via': e['via'],
    };
  }

  /// The facts of every catalog repo at once (one read of the cache).
  Map<String, Map<String, dynamic>> allFacts() {
    final cache = _load();
    return {for (final s in slugs()) s: facts(s, cache: cache)};
  }

  /// gh when installed and logged in, else the REST API.
  Future<GitHubApi> chooseApi() async {
    if (api != null) return api!;
    final named = ctx.environment['MAPRISMA_MANAGER_GH'];
    final gh = named != null && named.isNotEmpty ? ctx.runner.which(named) : (offline ? null : ctx.runner.which('gh'));
    if (gh != null) {
      final st = await ctx.runner.run([gh, 'auth', 'status', '--hostname', 'github.com'],
          extraEnv: const {'GH_PROMPT_DISABLED': '1', 'NO_COLOR': '1'}, timeout: const Duration(seconds: 20));
      if (st.ok) return GhCliApi(ctx, gh);
    }
    return RestApi(http ?? _httpGet);
  }

  Future<HttpAnswer> _httpGet(Uri uri) async {
    if (offline) throw const SocketException('offline (MAPRISMA_MANAGER_OFFLINE)');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      req.headers
        ..set('Accept', 'application/vnd.github+json')
        ..set('User-Agent', 'maprisma-manager')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      return (status: res.statusCode, body: body, headers: headers);
    } finally {
      client.close(force: true);
    }
  }

  /// Reads the facts of one repo from GitHub (two requests: the repo and its latest release).
  Future<Map<String, dynamic>> _read(GitHubApi api, String slug) async {
    final repo = await api.get('repos/$slug');
    if (repo.status == 404 || repo.json is! Map) {
      throw GitHubError('not found on GitHub (or private without access)', status: 404);
    }
    final r = repo.json as Map;
    final latest = await api.get('repos/$slug/releases/latest');
    return {
      'url': r['html_url'] is String ? r['html_url'] : githubWebUrl(slug),
      'public': r['private'] is bool ? !(r['private'] as bool) : (r['visibility'] == null ? null : r['visibility'] == 'public'),
      'defaultBranch': r['default_branch'],
      'release': latest.status == 200 && latest.json is Map ? releaseFacts(latest.json as Map) : null,
    };
  }

  /// `github.refresh`: reads the facts of every repo (of [only]) not checked or tried within
  /// [githubInterval] (all of them with [force]). A failure keeps the last known facts.
  Future<Map<String, dynamic>> refresh({List<String>? only, bool force = false}) async {
    final list = only ?? slugs();
    final now = ctx.clock();
    final results = <Map<String, dynamic>>[];
    GitHubApi? api;
    String? stop;
    final updates = <String, Map<String, dynamic>>{};
    final before = _load();
    for (final slug in list) {
      final e = (before['repos'] as Map)[slug];
      final last = [
        if (e is Map && e['checked'] is String) DateTime.tryParse(e['checked']),
        if (e is Map && e['lastTry'] is String) DateTime.tryParse(e['lastTry']),
        _tried[slug],
      ].whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
      if (!force && last != null && now.difference(last) < githubInterval) {
        results.add({'repo': slug, 'checked': false, 'skipped': 'recent', 'at': last.toUtc().toIso8601String()});
        continue;
      }
      if (stop != null) {
        results.add({'repo': slug, 'checked': false, 'skipped': stop});
        continue;
      }
      api ??= await chooseApi();
      _tried[slug] = now;
      try {
        final f = await _read(api, slug);
        updates[slug] = {'checked': now.toUtc().toIso8601String(), 'via': api.via, 'facts': f};
        results.add({'repo': slug, 'checked': true, 'via': api.via, 'release': (f['release'] as Map?)?['tag']});
      } on GitHubError catch (err) {
        updates[slug] = {'lastTry': now.toUtc().toIso8601String(), 'error': err.message, 'via': api.via};
        results.add({'repo': slug, 'checked': false, 'error': err.message});
        if (err.rateLimited) stop = err.message;
      } on Object catch (err) {
        // offline, DNS, timeout: the last known facts stay
        final why = 'offline: ${err is SocketException ? err.message : err}';
        updates[slug] = {'lastTry': now.toUtc().toIso8601String(), 'error': why, 'via': api.via};
        results.add({'repo': slug, 'checked': false, 'error': why});
        stop = 'offline';
      }
    }
    if (updates.isNotEmpty) {
      await withStateLock(ctx.paths, () async {
        final data = _load(); // again: another Manager may have written meanwhile
        final repos = data['repos'] as Map<String, dynamic>;
        for (final u in updates.entries) {
          final old = repos[u.key] is Map ? Map<String, dynamic>.from(repos[u.key] as Map) : <String, dynamic>{};
          if (u.value.containsKey('facts')) {
            repos[u.key] = u.value;
          } else {
            repos[u.key] = {...old, ...u.value}; // facts and checked kept
          }
        }
        data['schema'] = 1;
        _save(data);
      });
    }
    return {
      'force': force,
      'via': api?.via,
      'repos': results,
      'facts': {for (final s in list) s: facts(s)},
    };
  }

  /// The release [tag] of [slug], read now (null: no such release); without a tag the latest,
  /// from the cache when fresh, else refreshed (null: none).
  Future<Map<String, dynamic>?> release(String slug, {String? tag}) async {
    if (tag == null) {
      var f = facts(slug);
      if (f['stale'] == true) {
        final r = await refresh(only: [slug], force: true);
        final res = (r['repos'] as List).single as Map;
        if (res['error'] != null && f['known'] != true) throw GitHubError('${res['error']}');
        f = facts(slug);
      }
      final rel = f['release'];
      return rel is Map ? Map<String, dynamic>.from(rel) : null;
    }
    final api = await chooseApi();
    final a = await api.get('repos/$slug/releases/tags/${Uri.encodeComponent(tag)}');
    if (a.status == 404 || a.json is! Map) return null;
    return releaseFacts(a.json as Map);
  }

  /// Downloads an asset with the injected [download], else HttpClient (redirects followed).
  Future<void> fetchTo(Uri url, String dest, {required bool Function() cancelled}) async {
    final d = download;
    if (d != null) return d(url, dest, cancelled: cancelled);
    if (offline) throw const SocketException('offline (MAPRISMA_MANAGER_OFFLINE)');
    if (url.scheme != 'https') throw GitHubError('not an https URL: $url');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final out = File(dest).openWrite();
    try {
      final req = await client.getUrl(url);
      req.headers.set('User-Agent', 'maprisma-manager');
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) throw GitHubError('download: HTTP ${res.statusCode}', status: res.statusCode);
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        if (cancelled()) throw const _Stopped();
        out.add(chunk);
      }
    } finally {
      await out.close();
      client.close(force: true);
    }
  }
}

final class _Stopped implements Exception {
  const _Stopped();
  @override
  String toString() => 'cancelled';
}

/// The sha256 in a `.sha256` asset (`<hash>  <name>` or just the hash); the name, when there is
/// one, must be [asset]. Null when it isn't one.
String? parseSha256File(String text, String asset) {
  for (final line in const LineSplitter().convert(text)) {
    final m = RegExp(r'^\s*([0-9a-fA-F]{64})(?:\s+\*?(\S.*?))?\s*$').firstMatch(line);
    if (m == null) continue;
    final name = m.group(2);
    if (name != null && p.basename(name) != asset) return null;
    return m.group(1)!.toLowerCase();
  }
  return null;
}

/// sha256 of a file, streamed.
Future<String> sha256OfFile(String path) async => (await sha256.bind(File(path).openRead()).first).toString();

final _transport = RegExp(
  r'error connecting to|dial tcp|no such host|could not resolve|connection refused|network is unreachable|i/o timeout|timed out|TLS handshake',
  caseSensitive: false,
);

String _firstLine(String s) => s.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'failed');
