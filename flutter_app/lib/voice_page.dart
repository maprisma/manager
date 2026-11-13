import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';
import 'theme.dart';

/// Voice: Maprisma Dictation's voice service `maprisma-voice` (`voice.*`, always through its
/// command line): whether it is ready and why not, Dictation (on/off, engine, language,
/// microphone, when the model is unloaded, loading it at start), the Whisper models (Download
/// with progress and Cancel, Remove, Use) and Try it (5 s, the partial and final text).
// TODO(dictation step 4/5): the overlay's key and mode, the assistant's options and speech.
class VoicePage extends StatefulWidget {
  const VoicePage({super.key, required this.core, this.onInstall});
  final CoreCall core;

  /// Installs Maprisma Dictation (the Apps page's job); null: not possible here or not known yet.
  final VoidCallback? onInstall;
  @override
  State<VoicePage> createState() => VoicePageState();
}

/// The languages offered (Whisper codes); any other code can be typed.
const voiceLanguages = [('de', 'Deutsch'), ('en', 'English'), ('fr', 'Français'), ('es', 'Español'), ('it', 'Italiano'), ('pt', 'Português'), ('nl', 'Nederlands'), ('pl', 'Polski')];

/// Free GPU memory after (unload_minutes; 0 = never).
const unloadChoices = [0, 5, 10, 30, 60];

/// The try's length.
const trySeconds = 5;

class VoicePageState extends State<VoicePage> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'voice.get';

  /// voice.tasks as last polled (download, dictate).
  Map<String, dynamic> tasks = const {};
  Timer? _poll;

  static const engines = ['whisper', 'online', 'voxtype', 'superwhisper', 'omarchy'];

  static String engineName(String id) => switch (id) {
    'whisper' => tr('Local Whisper'),
    'online' => tr('Online'),
    'voxtype' => 'Voxtype',
    'superwhisper' => 'Superwhisper',
    'omarchy' => 'Omarchy',
    _ => id,
  };

  /// Why an engine can't be used here.
  static String engineWhy(String id) => switch (id) {
    'whisper' => tr('needs whisper-server and a model'),
    'online' => tr('needs an OpenAI or Groq key'),
    _ => tr('not installed'),
  };

  /// The engine drop-down: Automatic (naming the one in use), then every engine; the ones the
  /// service can't use are shown disabled with why.
  static List<(String, String)> engineChoices(Map status) {
    final available = ((status['engines'] as List?) ?? const []).cast<String>();
    final inUse = status['engine'];
    return [
      ('auto', inUse is String && inUse.isNotEmpty ? trf('Automatic ({0})', [engineName(inUse)]) : tr('Automatic')),
      for (final e in engines) (e, available.contains(e) ? engineName(e) : '${engineName(e)} · ${engineWhy(e)}'),
    ];
  }

  static Set<String> enginesOff(Map status) {
    final available = ((status['engines'] as List?) ?? const []).cast<String>();
    final setting = status['engine_setting'];
    // the saved engine stays selectable, so the drop-down can show it
    return {for (final e in engines) if (!available.contains(e) && e != setting) e};
  }

  static List<(String, String)> languageChoices(String current) => [
    ('auto', tr('Automatic')),
    ...voiceLanguages,
    if (current != 'auto' && !voiceLanguages.any((l) => l.$1 == current)) (current, current),
    ('*', tr('Other code…')),
  ];

  static String unloadLabel(int m) => m == 0 ? tr('Never') : trf('After {0} minutes', [m]);

  static String _short(String path) {
    final home = RegExp(r'^/home/[^/]+').firstMatch(path)?.group(0);
    return home == null ? path : '~${path.substring(home.length)}';
  }

  static String _size(Object? bytes) => bytes is num ? '${(bytes / 1000000).round()} MB' : '';

  @override
  Future<void> load() async {
    await super.load();
    final t = data?['tasks'];
    if (t is Map<String, dynamic> && mounted) {
      setState(() => tasks = t);
      _follow();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool _running(String kind) => (tasks[kind] as Map?)?['state'] == 'running';

  /// Polls voice.tasks while one runs; when one ends, the page is read again.
  void _follow() {
    if (_poll != null || !(_running('download') || _running('dictate'))) return;
    _poll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      final wasDownload = _running('download');
      Map<String, dynamic> t;
      try {
        t = await core('voice.tasks');
      } on ServiceError {
        return;
      }
      if (!mounted) return;
      setState(() => tasks = t);
      if (!_running('download') && !_running('dictate')) {
        _poll?.cancel();
        _poll = null;
      }
      if (wasDownload && !_running('download')) {
        final download = t['download'] as Map?;
        if (download?['state'] == 'failed') tellOn(this, trf('The download failed: {0}', [download?['message'] ?? '']));
        await load();
      }
    });
  }

  Future<void> _start(String route, Map<String, dynamic> params) async {
    try {
      final r = await core(route, params);
      final task = r['task'] as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => tasks = {...tasks, task['kind'] as String: task});
      _follow();
    } on ServiceError catch (e) {
      tellOn(this, failure(e));
    }
  }

  Future<void> _cancel(String kind) async {
    try {
      await core('voice.cancel', {'kind': kind});
    } on ServiceError catch (e) {
      tellOn(this, failure(e));
    }
  }

  Future<void> _set(String key, Object value) => act('voice.set', {'key': key, 'value': value});

  Future<void> _otherLanguage() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Other language')),
        content: SizedBox(
          width: 360,
          child: TextField(
            key: const ValueKey('voice-language-code'),
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('Whisper language code'), hintText: 'sv, ja, uk …'),
            onSubmitted: (v) => Navigator.pop(context, v.trim()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          FilledButton(key: const ValueKey('voice-language-ok'), onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(tr('Use'))),
        ],
      ),
    );
    controller.dispose();
    if (code != null && code.isNotEmpty && mounted) await _set('language', code.toLowerCase());
  }

  Future<void> _remove(Map model) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(trf('Remove {0}?', [model['label'] ?? model['file']])),
        content: Text(tr('The model file is deleted; it can be downloaded again.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(
            key: const ValueKey('voice-remove-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Remove')),
          ),
        ],
      ),
    );
    if (go == true && mounted) await act('voice.remove', {'model': model['id'] ?? model['file']});
  }

  // --- sections ------------------------------------------------------------------------------

  Widget _notInstalled(Map d) => SettingsSection(
    title: tr('Status'),
    note: trf('Or install it by hand: {0} (./install.sh)', ['${d['install_url']}'.replaceFirst('https://', '')]),
    children: [
      SettingsItem(
        leading: const Icon(Icons.mic_off_outlined),
        title: tr('Maprisma Dictation is not installed'),
        description: tr('Its voice service turns speech into text for every Maprisma app, on your own PC by default.'),
        trailing: Wrap(
          spacing: 8,
          children: [
            TextButton(
              key: const ValueKey('voice-github'),
              onPressed: () async {
                try {
                  await core('links.open', {'url': d['install_url']});
                } on ServiceError catch (e) {
                  tellOn(this, failure(e));
                }
              },
              child: Text(tr('GitHub')),
            ),
            FilledButton(key: const ValueKey('voice-install'), onPressed: widget.onInstall, child: Text(tr('Install'))),
          ],
        ),
      ),
    ],
  );

  Widget _status(Map d, Map? s) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    final ready = s?['ready'] == true;
    final off = s != null && s['enabled'] == false;
    final IconData icon;
    final Color color;
    if (ready) {
      (icon, color) = (Icons.check_circle, marks.running);
    } else if (off) {
      (icon, color) = (Icons.pause_circle_outline, marks.fresh);
    } else {
      (icon, color) = (Icons.error_outline, scheme.error);
    }
    final String title;
    if (s == null) {
      title = tr('The voice service does not answer');
    } else if (ready) {
      title = tr('Ready');
    } else {
      title = '${s['message'] ?? ''}'.isEmpty ? tr('Not ready') : '${s['message']}';
    }
    final details = <String>[
      if (s == null) '${d['status_error'] ?? ''}',
      if (s != null && '${s['engine'] ?? ''}'.isNotEmpty) trf('Engine: {0}', [engineName('${s['engine']}')]),
      if (s != null && s['engine'] == 'whisper' && '${s['model'] ?? ''}'.isNotEmpty) trf('Model: {0}', ['${s['model']}']),
      if (s != null && s['version'] != null) 'maprisma-voice ${s['version']}',
    ];
    return SettingsSection(
      title: tr('Status'),
      note: trf('Saved in {0}', ['~/.config/maprisma-voice/settings.json']),
      children: [
        SettingsItem(
          key: const ValueKey('voice-status'),
          leading: Icon(icon, color: color),
          title: title,
          description: details.where((x) => x.isNotEmpty).join(' · '),
        ),
      ],
    );
  }

  Widget _dictation(Map d, Map s) {
    final settings = (d['settings'] as Map?) ?? const {};
    final lock = working;
    final language = '${s['language'] ?? settings['language'] ?? 'auto'}';
    final mics = (d['microphones'] as Map?) ?? const {};
    final sources = ((mics['sources'] as List?) ?? const []).cast<Map>();
    final defaultName = mics['default'];
    final defaultMic = sources.where((m) => m['name'] == defaultName).firstOrNull;
    final microphone = '${s['microphone'] ?? settings['microphone'] ?? 'default'}';
    final unload = settings['unload_minutes'] is int ? settings['unload_minutes'] as int : 10;
    final engineSetting = '${s['engine_setting'] ?? settings['engine'] ?? 'auto'}';
    return SettingsSection(
      title: tr('Dictation'),
      children: [
        SettingsToggle(
          key: const ValueKey('voice-enabled'),
          title: tr('Dictation'),
          description: tr('Maprisma apps can turn your speech into text. The microphone is only on while you dictate.'),
          value: s['enabled'] != false,
          onChanged: lock ? null : (v) => _set('enabled', v),
        ),
        SettingsChoice<String>(
          key: const ValueKey('voice-engine'),
          title: tr('Engine'),
          description: tr('Local Whisper runs on this PC; Online sends the audio to OpenAI or Groq; Voxtype, Superwhisper and Omarchy type the text themselves.'),
          value: engineSetting,
          choices: engineChoices(s),
          disabled: enginesOff(s),
          onChanged: lock ? null : (v) => v == engineSetting ? null : _set('engine', v),
        ),
        SettingsChoice<String>(
          key: const ValueKey('voice-language'),
          title: tr('Language'),
          description: tr('Automatic recognises the language; a fixed one is faster and more accurate with small models.'),
          value: language,
          choices: languageChoices(language),
          onChanged: lock ? null : (v) => v == '*' ? _otherLanguage() : (v == language ? null : _set('language', v)),
        ),
        SettingsChoice<String>(
          key: const ValueKey('voice-microphone'),
          title: tr('Microphone'),
          value: microphone,
          choices: [
            ('default', defaultMic == null ? tr('Default') : trf('Default ({0})', ['${defaultMic['description']}'])),
            for (final m in sources) ('${m['name']}', '${m['description']}'),
            if (microphone != 'default' && !sources.any((m) => m['name'] == microphone)) (microphone, microphone),
          ],
          onChanged: lock ? null : (v) => v == microphone ? null : _set('microphone', v),
        ),
        SettingsChoice<int>(
          key: const ValueKey('voice-unload'),
          title: tr('Free GPU memory after'),
          description: tr('Local Whisper keeps its model loaded for fast answers and unloads it after this idle time.'),
          value: unload,
          choices: [for (final m in {...unloadChoices, unload}.toList()..sort()) (m, unloadLabel(m))],
          onChanged: lock ? null : (v) => v == unload ? null : _set('unload_minutes', v),
        ),
        SettingsToggle(
          key: const ValueKey('voice-preload'),
          title: tr('Load the model at start'),
          description: tr('The first dictation answers at once, but the model takes GPU memory from the start.'),
          value: settings['preload'] == true,
          onChanged: lock ? null : (v) => _set('preload', v),
        ),
      ],
    );
  }

  Widget _models(Map d) {
    final scheme = Theme.of(context).colorScheme;
    final listing = d['models'] as Map?;
    if (listing == null) {
      return SettingsSection(title: tr('Models'), children: [SettingsItem(title: tr('The models could not be listed'))]);
    }
    final settings = (d['settings'] as Map?) ?? const {};
    final chosen = '${settings['model'] ?? ''}';
    final active = listing['active'];
    final catalog = ((listing['catalog'] as List?) ?? const []).cast<Map>();
    final installed = ((listing['models'] as List?) ?? const []).cast<Map>();
    final others = [for (final m in installed) if (!catalog.any((c) => c['file'] == m['name'])) m];
    final download = tasks['download'] as Map?;
    final downloading = _running('download');
    Widget inUse() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check, size: 16, color: markColors(context).running),
        const SizedBox(width: 4),
        Text(tr('In use')),
      ],
    );
    Widget? use(String value) => chosen == value
        ? null
        : TextButton(key: ValueKey('voice-use-$value'), onPressed: working ? null : () => _set('model', value), child: Text(tr('Use')));

    final rows = <Widget>[
      SettingsItem(
        key: const ValueKey('voice-model-auto'),
        title: tr('Automatic'),
        description: tr('Uses large-v3-turbo, then small, then base, whichever is installed.'),
        trailing: chosen.isEmpty
            ? Text(tr('Chosen'), style: TextStyle(color: scheme.onSurfaceVariant))
            : TextButton(key: const ValueKey('voice-use-auto'), onPressed: working ? null : () => act('voice.unset', {'key': 'model'}), child: Text(tr('Use'))),
      ),
      for (final c in catalog)
        () {
          final file = '${c['file']}';
          final mine = downloading && download?['model'] == c['id'];
          final progress = download?['progress'] is num ? (download!['progress'] as num).toDouble() : null;
          final String status;
          if (mine) {
            status = progress == null ? tr('Downloading…') : trf('Downloading… {0} %', [progress.toStringAsFixed(0)]);
          } else if (c['installed'] == true) {
            status = tr('Installed');
          } else {
            status = trf('Not downloaded · {0}', [_size(c['size'])]);
          }
          final managed = installed.any((m) => m['name'] == file && m['managed'] == true);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsItem(
                key: ValueKey('voice-model-${c['id']}'),
                title: '${c['label'] ?? c['id']}',
                description: status,
                trailing: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (mine)
                      OutlinedButton(key: const ValueKey('voice-download-cancel'), onPressed: () => _cancel('download'), child: Text(tr('Cancel')))
                    else if (c['installed'] != true)
                      FilledButton.tonal(
                        key: ValueKey('voice-download-${c['id']}'),
                        onPressed: downloading || working ? null : () => _start('voice.download', {'model': c['id']}),
                        child: Text(tr('Download')),
                      )
                    else ...[
                      if (active == file) inUse(),
                      ?use(file),
                      if (managed)
                        OutlinedButton(
                          key: ValueKey('voice-remove-${c['id']}'),
                          style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                          onPressed: working ? null : () => _remove(c),
                          child: Text(tr('Remove')),
                        ),
                    ],
                  ],
                ),
              ),
              if (mine)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(cornerSizes(context).small),
                    child: LinearProgressIndicator(key: const ValueKey('voice-download-progress'), value: progress == null ? null : progress / 100),
                  ),
                ),
            ],
          );
        }(),
      for (final m in others)
        SettingsItem(
          key: ValueKey('voice-model-${m['name']}'),
          title: '${m['name']}',
          description: trf('{0} · not installed by Maprisma Dictation, so it is not removed here', [_short('${m['path']}')]),
          trailing: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [if (active == m['name']) inUse(), ?use('${m['name']}')]),
        ),
    ];
    return SettingsSection(
      title: tr('Models'),
      note: listing['folder'] is String ? trf('Downloaded to {0}', [_short(listing['folder'] as String)]) : null,
      children: rows,
    );
  }

  Widget _try(Map? s) {
    final scheme = Theme.of(context).colorScheme;
    final t = tasks['dictate'] as Map?;
    final running = _running('dictate');
    final ready = s?['ready'] == true;
    Widget? result;
    if (t != null) {
      final state = t['state'];
      final partial = '${t['partial'] ?? ''}', text = '${t['text'] ?? ''}', message = '${t['message'] ?? ''}';
      final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic);
      final Widget body;
      if (running) {
        body = Text(partial.isEmpty ? trf('Listening for {0} s… speak now', [t['seconds'] ?? trySeconds]) : partial, style: muted);
      } else if (state == 'succeeded' && text.isNotEmpty) {
        body = SelectableText(text, key: const ValueKey('voice-try-text'));
      } else if (state == 'cancelled') {
        body = Text(tr('Cancelled'), style: muted);
      } else {
        body = Text(
          message.isEmpty ? tr('Nothing was heard') : message,
          style: state == 'failed' ? TextStyle(color: scheme.error) : null,
        );
      }
      result = Padding(
        key: const ValueKey('voice-try-result'),
        padding: SettingsMetrics.rowPadding.copyWith(top: 12, bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(running ? Icons.mic : Icons.notes, size: 20, color: running ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: SettingsMetrics.rowSpacing),
            Expanded(child: body),
          ],
        ),
      );
    }
    return SettingsSection(
      title: tr('Try it'),
      note: s != null && !ready ? tr('Dictation has to be ready first.') : null,
      children: [
        SettingsItem(
          title: tr('Try dictation'),
          description: trf('Speak for {0} seconds. The text is only shown here; nothing is typed.', [trySeconds]),
          trailing: running
              ? OutlinedButton(key: const ValueKey('voice-try-stop'), onPressed: () => _cancel('dictate'), child: Text(tr('Stop')))
              : FilledButton(
                  key: const ValueKey('voice-try'),
                  onPressed: ready ? () => _start('voice.try', {'seconds': trySeconds}) : null,
                  child: Text(tr('Try it')),
                ),
        ),
        ?result,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('Voice'), actions: reloadActions(), children: loadingOrError(context));
    if (d['installed'] != true) return SettingsPage(title: tr('Voice'), actions: reloadActions(), children: [_notInstalled(d)]);
    final s = d['status'] as Map?;
    return SettingsPage(
      title: tr('Voice'),
      actions: reloadActions(),
      children: [
        _status(d, s),
        _dictation(d, s ?? const {}),
        _models(d),
        _try(s),
      ],
    );
  }
}
