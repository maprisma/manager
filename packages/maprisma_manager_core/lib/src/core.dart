import 'dart:convert';
import 'dart:io';

import 'translations.dart';

import 'about.dart';
import 'ai_update.dart';
import 'applications.dart';
import 'bar.dart';
import 'bluetooth.dart';
import 'catalog.dart';
import 'context.dart';
import 'desktop_look.dart';
import 'discovery.dart';
import 'displays.dart';
import 'icons.dart';
import 'animations.dart';
import 'input.dart';
import 'theme_view.dart';
import 'jobs.dart';
import 'network.dart';
import 'notifications.dart';
import 'native.dart';
import 'paths.dart';
import 'power.dart';
import 'procs.dart';
import 'protocol.dart';
import 'removal.dart';
import 'sources.dart';
import 'run.dart';
import 'sound.dart';
import 'status.dart';
import 'time_lang.dart';
import 'voice.dart';

const coreVersion = '0.3.1';

/// How long a fetch counts as fresh (plan: "fetch at most every 30 min unless forced").
const fetchInterval = Duration(minutes: 30);

/// Routes that read the found GitHub repos ([GitHub.resolveLinks]); a job keeps the ones of its
/// start (`jobs.start`).
const _usesLinks = {
  'apps.list', 'apps.get', 'git.fetch', 'github.refresh', 'jobs.start', 'apps.remove_plan',
  'discovered.list', 'discovered.clone', 'discovered.open_folder',
};

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
    configureLanguage(ctx.settings.str('language'), environment);
    jobs = JobEngine(ctx);
    routes = {
      'core.hello': (_) async => {
        'version': coreVersion,
        'protocol': protocolVersion,
        'desktop': ctx.desktop.name,
        'projectsDir': ctx.projectsDir,
        'projectsSource': ctx.projectsSource,
      },
      'settings.get': (_) async {
        final settings = Settings.load(ctx.paths);
        return {
          'language': settings.str('language') ?? 'auto',
          'systemLanguage': systemLanguage(ctx.environment),
          'corners': settings.corners,
          'screenshot_key': settings.screenshotKey,
          'ai_updates': settings.values['ai_updates'] == true,
          // The window's size as the user left it (rule 5a), null when missing or broken.
          'window_size': windowSize(settings.values['window_size']),
        };
      },
      'settings.language': (params) async {
        final value = params['language'];
        if (value != 'auto' && !languageNames.containsKey(value)) {
          throw RouteError('bad_params', 'language');
        }
        _saveSetting('language', value);
        configureLanguage(value as String, ctx.environment);
        return {'language': value};
      },
      // The settings menu: Corners (windows, slight, rounded, square) and F12 saves a screenshot.
      'settings.set': (params) async {
        final key = params['key'], value = params['value'];
        final ok = switch (key) {
          'corners' => cornerSettings.contains(value),
          'screenshot_key' => value is bool,
          // Let AI do the updates (off by default); its helper is the shared one (ai.set_helper).
          'ai_updates' => value is bool,
          // Sound › Amplification: volumes up to 150 %.
          'sound_amplify' => value is bool,
          // The window's size (GTK's [width, height]), saved after a resize.
          'window_size' => windowSize(value) != null,
          _ => false,
        };
        if (!ok) throw RouteError('bad_params', 'key, value');
        _saveSetting(key as String, value);
        return {'key': key, 'value': value};
      },
      'desktop.look': (_) async => desktopLook(ctx),
      // Let AI do the updates (ai_update.dart): the helpers, one run at a time, polled.
      'ai.helpers': (_) async => ai.helpers(),
      // The AI page: the helper every Maprisma app uses (maprisma-ai/settings.json).
      'ai.set_helper': (params) => ai.setHelper(params),
      'ai.start': (params) async => ai.start(params),
      'ai.get': (_) async => ai.get(),
      'ai.cancel': (_) => ai.cancel(),
      'apps.list': (params) async {
        final status = StatusReader(_withDesktop(params));
        return {..._header(status.ctx), 'apps': await status.apps(), 'discovered': await discover(ctx)};
      },
      // New Maprisma apps the catalog doesn't know: shown only; a GitHub-only one can be cloned.
      'discovered.list': (_) => discover(ctx),
      'discovered.clone': (params) {
        final repo = params['repo'];
        if (repo is! String || !RegExp(r'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$').hasMatch(repo) || repo.contains('..')) {
          throw RouteError('bad_params', 'repo (org/name)');
        }
        return cloneDiscovered(ctx, repo);
      },
      // The folder of a new app (one of discovered.list's), opened with xdg-open.
      'discovered.open_folder': (params) async {
        final name = params['name'];
        if (name is! String) throw RouteError('bad_params', 'name');
        final d = await discover(ctx);
        final app = (d['apps'] as List).cast<Map<String, dynamic>>().where((a) => a['name'] == name && a['folder'] != null).firstOrNull;
        if (app == null) throw RouteError('not_found', trf('no new app {0} with a folder', [name]));
        final open = ctx.runner.which('xdg-open');
        if (open == null) throw RouteError('unavailable', tr('xdg-open is missing'));
        if (!await jobs.startDetached(open, [app['folder'] as String])) throw RouteError('internal', tr('could not start xdg-open'));
        return {'name': name, 'folder': app['folder'], 'opened': true};
      },
      'apps.get': (params) async {
        final id = _app(params);
        final status = StatusReader(_withDesktop(params));
        return {..._header(status.ctx), 'app': (await status.apps(only: id, detail: true)).single};
      },
      'git.fetch': _fetch,
      'github.refresh': (params) async {
        final force = params['force'] ?? false;
        if (force is! bool) throw RouteError('bad_params', 'force');
        final only = params.containsKey('id') ? appSlugs(ctx, findApp(_app(params))!) : null;
        if (only != null && only.isEmpty) return {'force': force, 'repos': const [], 'facts': const {}, 'note': tr('not on GitHub')};
        return ctx.github.refresh(only: only, force: force);
      },
      'bar.get': (params) => Bar(ctx).get(params),
      'bar.place': (params) => _bar((b) => b.place(params)),
      'bar.move': (params) => _bar((b) => b.move(params)),
      'bar.remove': (params) => _bar((b) => b.remove(params)),
      'bar.apply': (params) => _bar((b) => b.applyWanted()),
      'jobs.start': (params) async => jobs.start(params),
      'jobs.get': (params) async => jobs.get(params),
      'jobs.list': (params) async => jobs.list(params),
      'jobs.cancel': (params) => jobs.cancel(params),
      'jobs.log': (params) async => jobs.readLog(params),
      'icons.get': (params) => icons.get(params),
      'icons.set': (params) => icons.set(params),
      'icons.reset': (params) => icons.reset(params),
      // The Power page: the desktop's own settings app, or Maprisma Shell's idle times and the
      // power profile (power.dart).
      'power.get': (_) => power.get(),
      'power.set_idle': (params) => power.setIdle(params),
      'power.set_profile': (params) => power.setProfile(params),
      'power.open_native': (_) => power.openNative(),
      // COSMIC's and KDE's own settings app for a page (native.dart).
      'native.get': (params) async => native.get(params),
      'native.open': (params) => native.open(params),
      // The Sound page on Hyprland (sound.dart, pactl).
      'sound.get': (_) => sound.get(),
      'sound.volume': (params) => sound.volume(params),
      'sound.mute': (params) => sound.mute(params),
      'sound.default': (params) => sound.setDefault(params),
      'sound.stream': (params) => sound.stream(params),
      'sound.profile': (params) => sound.profile(params),
      // The Notifications page: Maprisma Notifier's settings and history, Maprisma Shell's
      // popups on Hyprland, do not disturb per desktop (notifications.dart).
      'notifications.get': (_) => notifications.get(),
      'notifications.set': (params) => notifications.set(params),
      'notifications.set_shell': (params) => notifications.setShell(params),
      'notifications.clear_history': (_) => notifications.clearHistory(),
      // The Voice page: Maprisma Dictation's voice service through its CLI (voice.dart).
      'voice.get': (_) => voice.get(),
      'voice.set': (params) => voice.set(params),
      'voice.unset': (params) => voice.unset(params),
      'voice.download': (params) => voice.download(params),
      'voice.remove': (params) => voice.remove(params),
      'voice.try': (params) => voice.tryIt(params),
      'voice.tasks': (_) async => voice.tasks(),
      'voice.cancel': (params) => voice.cancel(params),
      // Displays and Input devices on Hyprland (hypr-manager.lua, hypr_config.dart).
      'displays.get': (_) => displays.get(),
      'displays.set': (params) => displays.set(params),
      'displays.undo': (_) => displays.undo(),
      'displays.keep': (_) => displays.keep(),
      'input.get': (_) => input.get(),
      'input.set': (params) => input.set(params),
      // Hyprland's animations on the Appearance page (hypr-manager.lua, animations.dart).
      'animations.get': (_) => animations.get(),
      'animations.set': (params) => animations.set(params),
      'animations.reset': (_) => animations.reset(),
      // The Theme page: Maprisma Theme's themes, applied through its core (theme_view.dart).
      'theme.list': (_) => themeView.list(),
      'theme.apply': (params) => themeView.apply(params),
      // Network & Wireless and Bluetooth on Hyprland (nmcli, bluetoothctl).
      'network.get': (params) => network.get(params),
      'network.wifi': (params) => network.wifi(params),
      'network.up': (params) => network.up(params),
      'network.down': (params) => network.down(params),
      'network.forget': (params) => network.forget(params),
      'network.connect': (params) => network.connect(params),
      'bluetooth.get': (_) => bluetooth.get(),
      'bluetooth.power': (params) => bluetooth.power(params),
      'bluetooth.scan': (params) => bluetooth.scan(params),
      'bluetooth.connect': (params) => bluetooth.device('connect', params),
      'bluetooth.disconnect': (params) => bluetooth.device('disconnect', params),
      'bluetooth.forget': (params) => bluetooth.device('forget', params),
      'bluetooth.pair': (params) => bluetooth.device('pair', params),
      // Applications, Time & Language and About on Hyprland.
      'apps_default.get': (_) => applications.defaults(),
      'apps_default.set': (params) => applications.setDefault(params),
      'autostart.list': (_) async => applications.autostart(),
      'autostart.set': (params) async => applications.setAutostart(params),
      'autostart.add': (params) async => applications.add(params),
      'autostart.remove': (params) async => applications.remove(params),
      'time.get': (_) => timeLang.time(),
      'time.set_ntp': (params) => timeLang.setNtp(params),
      'time.set_timezone': (params) => timeLang.setTimezone(params),
      'locale.get': (_) => timeLang.locale(),
      'locale.set': (params) => timeLang.setLocale(params),
      'about.get': (_) => about.get(),
      // One read per page.
      'applications.get': (_) async => {...await applications.defaults(), 'autostart': applications.autostart()},
      'timelang.get': (_) async => {'time': await timeLang.time(), 'locale': await timeLang.locale()},
      'apps.open': (params) async {
        final app = findApp(_app(params))!;
        final cmd = app.open;
        if (cmd == null) throw RouteError('unavailable', trf('{0} has no window of its own', [app.name]));
        final exe = ctx.paths.expand(cmd.first);
        if (!isExecutableFile(exe)) throw RouteError('not_installed', trf('{0} is missing', [exe]));
        final ok = await jobs.startDetached(exe, cmd.skip(1).toList());
        if (!ok) throw RouteError('internal', trf('could not start {0}', [exe]));
        return {'id': app.id, 'opened': true};
      },
      // A GitHub page of an app (the details' link), opened with xdg-open.
      'links.open': (params) async {
        final url = params['url'];
        if (url is! String || !RegExp(r'^https://github\.com/[A-Za-z0-9._-]+(/[A-Za-z0-9._/-]*)?$').hasMatch(url) || url.contains('..')) {
          throw RouteError('bad_params', tr('url (a https://github.com/ page)'));
        }
        final open = ctx.runner.which('xdg-open');
        if (open == null) throw RouteError('unavailable', tr('xdg-open is missing'));
        final ok = await jobs.startDetached(open, [url]);
        if (!ok) throw RouteError('internal', tr('could not start xdg-open'));
        return {'url': url, 'opened': true};
      },
      'apps.remove_plan': (params) async {
        final id = _app(params);
        final del = params['delete_settings'] ?? false;
        if (del is! bool) throw RouteError('bad_params', 'delete_settings');
        return (await removePlan(ctx, findApp(id)!, deleteSettings: del)).json;
      },
    };
  }

  late final Ctx ctx;
  late final Map<String, Handler> routes;

  /// The job engine (install, update, reinstall, remove).
  late final JobEngine jobs;

  /// Let AI do the updates (ai.*).
  late final AiUpdater ai = AiUpdater(ctx, jobs, fetch: () => _fetch(const {}));

  /// The desktop's own settings app (native.*).
  late final NativeSettings native = NativeSettings(ctx, jobs.startDetached);

  /// The Displays and Input devices pages (displays.*, input.*); one service each for the
  /// whole session (Displays keeps what to undo).
  late final DisplaysService displays = DisplaysService(ctx);
  late final InputService input = InputService(ctx);

  /// Hyprland's animations (animations.*); one service, so changes go one after another.
  late final AnimationsService animations = AnimationsService(ctx);

  /// The Theme page (theme.*): Maprisma Theme's core does the work.
  late final ThemeViewService themeView = ThemeViewService(ctx);

  /// The Network & Wireless and Bluetooth pages (network.*, bluetooth.*).
  late final NetworkService network = NetworkService(ctx);
  late final BluetoothService bluetooth = BluetoothService(ctx);

  /// The Applications, Time & Language and About pages.
  late final ApplicationsService applications = ApplicationsService(ctx);
  late final TimeLangService timeLang = TimeLangService(ctx);
  late final AboutService about = AboutService(ctx);

  /// The Sound page (sound.*).
  late final SoundService sound = SoundService(ctx);

  /// The Notifications page (notifications.*).
  late final NotificationsService notifications = NotificationsService(ctx, native);

  /// The Voice page (voice.*).
  late final VoiceService voice = VoiceService(ctx, sound);

  /// The Power page (power.*).
  late final PowerService power = PowerService(ctx, jobs.startDetached);

  /// Bar icon changes (icons.*).
  late final IconService icons = IconService(ctx, jobs);

  Future<Map<String, dynamic>> Function(List<ProcInfo> before)? _followPanel;

  /// Waits for cosmic-panel after a write; tests replace it (the jobs' bar steps use it too).
  Future<Map<String, dynamic>> Function(List<ProcInfo> before)? get followPanel => _followPanel;
  set followPanel(Future<Map<String, dynamic>> Function(List<ProcInfo> before)? f) {
    _followPanel = f;
    // the jobs' bar steps and the applet nudge after an install: replaced together, so a
    // replaced follow-up never meets a real cosmic-panel
    jobs.follow = f;
  }

  Future<Map<String, dynamic>> _bar(Future<Map<String, dynamic>> Function(Bar b) f) => f(Bar(ctx)..follow = followPanel);

  /// A `desktop` param shows the status as another desktop would see it.
  /// One setting into settings.json; the others stay (written whole, then renamed into place).
  void _saveSetting(String key, Object? value) {
    final settings = Map<String, dynamic>.of(Settings.load(ctx.paths).values);
    settings[key] = value;
    final file = File(ctx.paths.settingsFile);
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(settings), flush: true);
    temporary.renameSync(file.path);
  }

  Ctx _withDesktop(Map<String, dynamic> params) {
    final raw = params['desktop'];
    if (raw == null) return ctx;
    final d = raw is String ? parseDesktop(raw) : null;
    if (d == null) throw RouteError('bad_params', 'desktop');
    if (d == ctx.desktop) return ctx;
    final other = Ctx(paths: ctx.paths, environment: ctx.environment, desktop: d, runner: ctx.runner, clock: ctx.clock, uid: ctx.uid)
      ..cloneUrlFor = ctx.cloneUrlFor;
    other.github.links = ctx.github.links;
    return other;
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
    if (findApp(id) == null) throw RouteError('not_found', trf('no app {0}', [id]));
    return id;
  }

  /// Fetches the configured upstream's remote of each input repo (of one app with `id`, else all)
  /// and its GitHub remote (the remote whose URL is the input's GitHub repo) when that is another
  /// one. Repos fetched (or tried) within [fetchInterval] are skipped unless `force` is true.
  Future<Map<String, dynamic>> _fetch(Map<String, dynamic> params) async {
    final force = params['force'] ?? false;
    if (force is! bool) throw RouteError('bad_params', 'force');
    final apps = params.containsKey('id') ? [findApp(_app(params))!] : catalog;
    final inputs = <String, Input>{};
    for (final a in apps) {
      for (final i in a.inputs) {
        inputs.putIfAbsent(i.repo, () => i);
      }
    }
    final now = ctx.clock();
    final results = await Future.wait([
      for (final input in inputs.values)
        () async {
          final repo = input.repo;
          final folder = ctx.repoFolder(repo);
          final before = await ctx.git.inspect(repo, folder);
          if (!before.isRepo) return {'repo': repo, 'fetched': false, 'skipped': before.present ? 'not a repo' : 'missing'};
          final upstream = before.upstream != null && before.upstreamRemote != null && before.upstreamRemote != '.' ? before.upstreamRemote : null;
          final slug = ctx.github.slugOf(input);
          final gh = slug == null ? null : await githubRemote(ctx, folder, slug, upstreamRemote: before.upstreamRemote);
          final remotes = [?upstream, if (gh != null && gh.name != upstream) gh.name];
          if (remotes.isEmpty) return {'repo': repo, 'fetched': false, 'skipped': 'no upstream'};
          final last = [before.lastFetch, ctx.fetchAttempts[repo]].whereType<DateTime>().fold<DateTime?>(
            null,
            (a, b) => a == null || b.isAfter(a) ? b : a,
          );
          if (!force && last != null && now.difference(last) < fetchInterval) {
            return {'repo': repo, 'fetched': false, 'skipped': 'recent', 'lastFetch': last.toUtc().toIso8601String()};
          }
          ctx.fetchAttempts[repo] = now;
          final fetched = <Map<String, dynamic>>[];
          for (final remote in remotes) {
            final r = await ctx.git.fetch(folder, remote);
            fetched.add({'remote': remote, 'fetched': r.ok, if (!r.ok) 'error': _firstLine(r.stderr), if (remote == gh?.name) 'github': true});
          }
          final after = await ctx.git.inspect(repo, folder);
          final ok = fetched.every((f) => f['fetched'] == true);
          Map<String, dynamic>? github;
          if (gh != null && after.head != null) {
            final branch = githubBranch(ctx.github.facts(slug!), after);
            final c = await ctx.git.compare(folder, '${gh.name}/$branch');
            github = {'remote': gh.name, 'ref': '${gh.name}/$branch', 'fetched': c.exists, 'behind': c.behind, 'relation': c.relation.name};
          }
          return {
            'repo': repo,
            'fetched': ok,
            if (!ok) 'error': fetched.firstWhere((f) => f['fetched'] != true)['error'],
            'remotes': fetched,
            if (upstream != null) ...{'behind': after.behind, 'relation': after.relation.name},
            'github': ?github,
          };
        }(),
    ]);
    return {'force': force, 'repos': results};
  }

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final handler = routes[method];
    if (handler == null) throw RouteError('unknown_route', method);
    // The GitHub repos of catalog apps without one (folder remotes, the org's list), as the
    // folders are now: only for the routes that use them (not for job polls, the bar, icons).
    if (_usesLinks.contains(method)) await ctx.github.resolveLinks();
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

/// A saved window size: [width, height], whole numbers 100…20000; else null.
List<int>? windowSize(Object? value) => value is List &&
        value.length == 2 &&
        value.every((v) => v is int && v >= 100 && v <= 20000)
    ? [value[0] as int, value[1] as int]
    : null;
