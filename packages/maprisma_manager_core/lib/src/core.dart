import 'dart:convert';

import 'bar.dart';
import 'catalog.dart';
import 'context.dart';
import 'paths.dart';
import 'procs.dart';
import 'protocol.dart';
import 'run.dart';
import 'status.dart';

const coreVersion = '0.1.0';

/// How long a fetch counts as fresh (plan: "fetch at most every 30 min unless forced").
const fetchInterval = Duration(minutes: 30);

/// The core behind the protocol (docs/protocol.md): one JSON frame in, one out.
final class CoreService {
  CoreService({
    required Map<String, String> environment,
    Paths? paths,
    DesktopId? desktop,
    Runner? runner,
    DateTime Function()? clock,
    int? uid,
  }) {
    ctx = Ctx(
      paths: paths ?? Paths.fromEnvironment(environment),
      environment: environment,
      desktop: desktop,
      runner: runner,
      clock: clock,
      uid: uid,
    );
    routes = {
      'core.hello': (_) async => {
        'version': coreVersion,
        'protocol': protocolVersion,
        'desktop': ctx.desktop.name,
        'projectsDir': ctx.projectsDir,
        'projectsSource': ctx.projectsSource,
      },
      'apps.list': (params) async {
        final status = StatusReader(_withDesktop(params));
        return {..._header(status.ctx), 'apps': await status.apps()};
      },
      'apps.get': (params) async {
        final id = _app(params);
        final status = StatusReader(_withDesktop(params));
        return {..._header(status.ctx), 'app': (await status.apps(only: id, detail: true)).single};
      },
      'git.fetch': _fetch,
      'bar.get': (params) => Bar(ctx).get(params),
      'bar.place': (params) => _bar((b) => b.place(params)),
      'bar.move': (params) => _bar((b) => b.move(params)),
      'bar.remove': (params) => _bar((b) => b.remove(params)),
      'bar.apply': (params) => _bar((b) => b.applyWanted()),
    };
  }

  late final Ctx ctx;
  late final Map<String, Handler> routes;

  /// Waits for cosmic-panel after a write; tests replace it.
  Future<Map<String, dynamic>> Function(List<ProcInfo> before)? followPanel;

  Future<Map<String, dynamic>> _bar(Future<Map<String, dynamic>> Function(Bar b) f) => f(Bar(ctx)..follow = followPanel);

  /// A `desktop` param shows the status as another desktop would see it.
  Ctx _withDesktop(Map<String, dynamic> params) {
    final raw = params['desktop'];
    if (raw == null) return ctx;
    final d = raw is String ? parseDesktop(raw) : null;
    if (d == null) throw RouteError('bad_params', 'desktop');
    if (d == ctx.desktop) return ctx;
    return Ctx(paths: ctx.paths, environment: ctx.environment, desktop: d, runner: ctx.runner, clock: ctx.clock, uid: ctx.uid);
  }

  Map<String, dynamic> _header(Ctx c) {
    final f = c.flutter();
    return {
      'desktop': c.desktop.name,
      'projectsDir': c.projectsDir,
      'projectsSource': c.projectsSource,
      'flutter': f.exe,
      'flutterSource': f.source,
    };
  }

  String _app(Map<String, dynamic> params) {
    final id = params['id'];
    if (id is! String || id.isEmpty) throw RouteError('bad_params', 'id');
    if (findApp(id) == null) throw RouteError('not_found', 'no app $id');
    return id;
  }

  /// Fetches the configured upstream's remote of each input repo (of one app with `id`, else all).
  /// Repos fetched (or tried) within [fetchInterval] are skipped unless `force` is true.
  Future<Map<String, dynamic>> _fetch(Map<String, dynamic> params) async {
    final force = params['force'] ?? false;
    if (force is! bool) throw RouteError('bad_params', 'force');
    final apps = params.containsKey('id') ? [findApp(_app(params))!] : catalog;
    final repos = {for (final a in apps) for (final i in a.inputs) i.repo};
    final now = ctx.clock();
    final results = await Future.wait([
      for (final repo in repos)
        () async {
          final folder = ctx.repoFolder(repo);
          final before = await ctx.git.inspect(repo, folder);
          if (!before.isRepo) return {'repo': repo, 'fetched': false, 'skipped': before.present ? 'not a repo' : 'missing'};
          final remote = before.upstreamRemote;
          if (before.upstream == null || remote == null || remote == '.') {
            return {'repo': repo, 'fetched': false, 'skipped': 'no upstream'};
          }
          final last = [before.lastFetch, ctx.fetchAttempts[repo]].whereType<DateTime>().fold<DateTime?>(
            null,
            (a, b) => a == null || b.isAfter(a) ? b : a,
          );
          if (!force && last != null && now.difference(last) < fetchInterval) {
            return {'repo': repo, 'fetched': false, 'skipped': 'recent', 'lastFetch': last.toUtc().toIso8601String()};
          }
          ctx.fetchAttempts[repo] = now;
          final r = await ctx.git.fetch(folder, remote);
          if (!r.ok) return {'repo': repo, 'fetched': false, 'error': _firstLine(r.stderr)};
          final after = await ctx.git.inspect(repo, folder);
          return {'repo': repo, 'fetched': true, 'behind': after.behind, 'relation': after.relation.name};
        }(),
    ]);
    return {'force': force, 'repos': results};
  }

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final handler = routes[method];
    if (handler == null) throw RouteError('unknown_route', method);
    return await handler(params);
  }

  Future<String> handleAsync(String frame) async {
    int? id;
    try {
      final request = Request.decode(frame);
      id = request.id;
      final result = await call(request.method, request.params);
      final out = jsonEncode({'id': id, 'result': result});
      if (out.length > maxResponse) return jsonEncode({'id': id, 'error': {'code': 'response_too_large'}});
      return out;
    } on RouteError catch (e) {
      return jsonEncode({'id': id, 'error': {'code': e.code, 'message': e.message}});
    } on FormatException {
      return jsonEncode({'id': id, 'error': {'code': 'bad_request'}});
    } on ServiceError catch (e) {
      return jsonEncode({'id': id, 'error': {'code': e.code, 'message': e.reason}});
    } catch (e) {
      return jsonEncode({'id': id, 'error': {'code': 'internal', 'message': '$e'}});
    }
  }
}

String _firstLine(String s) => s.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'failed');
