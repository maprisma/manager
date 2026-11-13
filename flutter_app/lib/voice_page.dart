import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show VoiceService, tr, trf;

import 'backend.dart' show ServiceError;
import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';
import 'theme.dart';

/// Voice: Maprisma Dictation's voice service `maprisma-voice` (`voice.*`, always through its
/// command line): whether it is ready and why not, Dictation (on/off, engine, language,
/// microphone, when the model is unloaded, loading it at start), the wake phrase (on/off, the
/// phrase, its language, sensitivity and model, whether it listens now, Try the phrase), the
/// Whisper models (Download with progress and Cancel, Remove, Use) and Try it (5 s, the partial
/// and final text).
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

/// Try the phrase: how long it listens.
const wakeTestSeconds = 8;

/// While the wake phrase is on, its status line is read again this often.
const wakeStatusEvery = Duration(seconds: 3);

class VoicePageState extends State<VoicePage> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'voice.get';

  /// voice.tasks as last polled (download, dictate).
  Map<String, dynamic> tasks = const {};
  Timer? _poll;

  /// The wake phrase's field: saved on submit or when it loses the focus.
  final phrase = TextEditingController();
  final phraseFocus = FocusNode();
  String? phraseError;
  Timer? _wakePoll;

  @override
  void initState() {
    super.initState();
    phraseFocus.addListener(() {
      if (!phraseFocus.hasFocus) unawaited(_savePhrase());
    });
  }

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

  /// The wake phrase as the service has it.
  String get savedPhrase {
    final s = data?['status'] as Map?, settings = data?['settings'] as Map?;
    return '${s?['wake_phrase'] ?? settings?['wake_phrase'] ?? 'Hey Linux'}';
  }

  @override
  Future<void> load() async {
    await super.load();
    if (!mounted) return;
    final t = data?['tasks'];
    if (t is Map<String, dynamic>) {
      setState(() => tasks = t);
      _follow();
    }
    if (!phraseFocus.hasFocus && phraseError == null) phrase.text = savedPhrase;
    _watchWake();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _wakePoll?.cancel();
    phrase.dispose();
    phraseFocus.dispose();
    super.dispose();
  }

  /// While the wake phrase is on, its line follows the service (voice.status, every 3 s).
  void _watchWake() {
    final on = (data?['status'] as Map?)?['wake_enabled'] == true;
    if (!on) {
      _wakePoll?.cancel();
      _wakePoll = null;
      return;
    }
    _wakePoll ??= Timer.periodic(wakeStatusEvery, (_) async {
      if (working) return;
      Map<String, dynamic> r;
      try {
        r = await core('voice.status');
      } on ServiceError {
        return;
      }
      if (!mounted || data == null || r['status'] is! Map) return;
      setState(() => data = {...data!, 'status': r['status']});
      _watchWake();
    });
  }

  /// The phrase field's value: saved when the service would take it, else the error stays.
  Future<void> _savePhrase() async {
    final v = phrase.text.trim();
    if (!VoiceService.validWakePhrase(v)) {
      if (mounted) setState(() => phraseError = tr('2–40 letters or digits; also spaces and , . ! ? \' -'));
      return;
    }
    if (mounted) setState(() => phraseError = null);
    if (v == savedPhrase) {
      phrase.text = v;
      return;
    }
    await _set('wake_phrase', v);
  }

  bool _running(String kind) => (tasks[kind] as Map?)?['state'] == 'running';

  bool get _anyRunning => _running('download') || _running('dictate') || _running('wake');

  /// Polls voice.tasks while one runs; when one ends, the page is read again.
  void _follow() {
    if (_poll != null || !_anyRunning) return;
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
      if (!_anyRunning) {
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
    final code = await showDialog<String>(context: context, builder: (_) => const _LanguageCodeDialog());
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

  static String sensitivityName(String id) => switch (id) {
    'strict' => tr('Strict'),
    'loose' => tr('Loose'),
    _ => tr('Normal'),
  };

  /// The wake recogniser's models: the smallest installed one, then each installed model
  /// (named like the catalog, short), and the saved one when it is not among them.
  static List<(String, String)> wakeModelChoices(Map? listing, String current) {
    final catalog = ((listing?['catalog'] as List?) ?? const []).cast<Map>();
    final installed = ((listing?['models'] as List?) ?? const []).cast<Map>();
    // the catalog's name without its size note ("Whisper base (148 MB · …)"): the drop-down stays narrow
    String label(String file) => '${catalog.where((c) => c['file'] == file).firstOrNull?['label'] ?? file}'.split(' (').first;
    final files = [for (final m in installed) '${m['name']}'];
    final known = current.isEmpty || files.contains(current) || catalog.any((c) => c['id'] == current && files.contains(c['file']));
    return [
      ('', tr('Smallest installed')),
      for (final f in files) (f, label(f)),
      if (!known) (current, current),
    ];
  }

  /// The saved wake model as one of [wakeModelChoices] (a catalog id names its file).
  static String wakeModelValue(Map? listing, String current) {
    final catalog = ((listing?['catalog'] as List?) ?? const []).cast<Map>();
    final c = catalog.where((c) => c['id'] == current).firstOrNull;
    final installed = ((listing?['models'] as List?) ?? const []).cast<Map>();
    return c != null && installed.any((m) => m['name'] == c['file']) ? '${c['file']}' : current;
  }

  /// The wake listener's state now (status `wake_why_not`): its kind (on, paused, off, problem)
  /// and the words.
  static (String, String) wakeLine(Map s) {
    final phrase = '${s['wake_phrase'] ?? 'Hey Linux'}';
    if (s['wake_enabled'] != true) return ('off', tr('Off: the microphone is not listening for the phrase.'));
    final why = '${s['wake_why_not'] ?? ''}';
    final message = '${s['wake_message'] ?? ''}';
    return switch (why) {
      '' => s['wake_active'] == true ? ('on', trf('Listening for “{0}”', [phrase])) : ('paused', trf('Starting to listen for “{0}”…', [phrase])),
      'off' => ('off', tr('Off: the microphone is not listening for the phrase.')),
      'disabled' => ('paused', tr('Not listening: Dictation is off.')),
      'busy' => ('paused', tr('Paused while a dictation runs.')),
      'speaking' => ('paused', tr('Paused while an answer is read aloud.')),
      'cooldown' => ('paused', tr('Heard just now; listening again in a moment.')),
      'no_whisper_server' => ('problem', tr('Not listening: whisper-server is missing.')),
      'no_model' => ('problem', tr('Not listening: no Whisper model is installed.')),
      'no_recorder' => ('problem', tr('Not listening: no audio recorder was found.')),
      'recorder_failed' => ('problem', tr('Not listening: the microphone could not be opened.')),
      'failed' => ('problem', message.isEmpty ? tr('The wake listener failed.') : trf('The wake listener failed: {0}', [message])),
      _ => ('problem', message.isEmpty ? why : message),
    };
  }

  static String _percentOf(Object? v) => v is num ? '${(v * 100).round()} %' : '–';

  Widget _wake(Map d, Map? s) {
    final scheme = Theme.of(context).colorScheme;
    final marks = markColors(context);
    final settings = (d['settings'] as Map?) ?? const {};
    final lock = working;
    final on = s?['wake_enabled'] == true;
    final language = '${settings['wake_language'] ?? 'auto'}';
    final sensitivity = '${settings['wake_sensitivity'] ?? 'normal'}';
    final listing = d['models'] as Map?;
    final model = wakeModelValue(listing, '${settings['wake_model'] ?? ''}');

    final (kind, line) = s == null ? ('problem', tr('The voice service does not answer')) : wakeLine(s);
    final (IconData icon, Color color) = switch (kind) {
      'on' => (Icons.hearing, marks.running),
      'paused' => (Icons.pause_circle_outline, marks.fresh),
      'off' => (Icons.mic_off_outlined, scheme.onSurfaceVariant),
      _ => (Icons.error_outline, scheme.error),
    };

    // Try the phrase
    final t = tasks['wake'] as Map?;
    final testing = _running('wake');
    Widget? result;
    if (t != null) {
      final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, fontStyle: FontStyle.italic);
      final small = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]);
      final r = t['result'] as Map?;
      IconData mark = Icons.notes;
      Color markColor = scheme.onSurfaceVariant;
      final Widget body;
      if (testing) {
        (mark, markColor) = (Icons.mic, scheme.primary);
        body = Text(tr('Say your phrase now…'), style: muted);
      } else if (t['state'] == 'cancelled') {
        body = Text(tr('Cancelled'), style: muted);
      } else if (t['state'] == 'failed' || r == null) {
        (mark, markColor) = (Icons.error_outline, scheme.error);
        body = Text('${t['message'] ?? ''}'.isEmpty ? tr('The test did not work.') : '${t['message']}', style: TextStyle(color: scheme.error));
      } else if (r['speech'] != true) {
        body = Text(tr('Nothing was heard.'), style: muted);
      } else {
        final matched = r['matched'] == true;
        (mark, markColor) = matched ? (Icons.check_circle, marks.running) : (Icons.cancel_outlined, scheme.error);
        final heard = '${r['heard'] ?? ''}', rest = '${r['rest'] ?? ''}';
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(matched ? trf('It matches. Heard: “{0}”', [heard]) : trf('No match. Heard: “{0}”', [heard]), key: const ValueKey('voice-wake-heard')),
            const SizedBox(height: 2),
            Text(
              [
                trf('Score {0} (a match needs {1})', [_percentOf(r['score']), _percentOf(r['needed'])]),
                if (matched && rest.isNotEmpty) trf('Request after it: {0}', [rest]),
              ].join(' · '),
              style: small,
            ),
          ],
        );
      }
      result = Padding(
        key: const ValueKey('voice-wake-result'),
        padding: SettingsMetrics.rowPadding.copyWith(top: 12, bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(mark, size: 20, color: markColor),
            const SizedBox(width: SettingsMetrics.rowSpacing),
            Expanded(child: body),
          ],
        ),
      );
    }

    return SettingsSection(
      title: tr('Wake phrase'),
      note: tr('While it listens, the microphone stays open. Only short stretches of speech are turned into text, on this PC; nothing is stored or sent online.'),
      children: [
        SettingsToggle(
          key: const ValueKey('voice-wake-enabled'),
          title: tr('Start Maprisma Dictation with a phrase'),
          description: tr('Say the phrase to open Maprisma Dictation, then your request. The microphone stays open while this is on.'),
          value: on,
          onChanged: lock || s == null ? null : (v) => _set('wake_enabled', v),
        ),
        SettingsItem(
          key: const ValueKey('voice-wake-status'),
          leading: Icon(icon, color: color),
          title: line,
        ),
        SettingsItem(
          title: tr('Phrase'),
          description: tr('For example “Hey Linux”: two or three words that are rarely said otherwise.'),
          trailing: SizedBox(
            width: 240,
            child: TextField(
              key: const ValueKey('voice-wake-phrase'),
              controller: phrase,
              focusNode: phraseFocus,
              enabled: !lock,
              maxLength: 40,
              // the card is surfaceContainer, like the theme's fields: one step up so it reads as a field
              decoration: InputDecoration(isDense: true, counterText: '', fillColor: scheme.surfaceContainerHighest, errorText: phraseError, errorMaxLines: 3, hintText: 'Hey Linux'),
              onChanged: (_) {
                if (phraseError != null) setState(() => phraseError = null);
              },
              onSubmitted: (_) => _savePhrase(),
            ),
          ),
        ),
        SettingsChoice<String>(
          key: const ValueKey('voice-wake-language'),
          title: tr('Language of the phrase'),
          description: tr('Set it to the phrase\'s language when it is misheard.'),
          value: language,
          choices: [
            ('auto', tr('Automatic')),
            ...voiceLanguages,
            if (language != 'auto' && !voiceLanguages.any((l) => l.$1 == language)) (language, language),
          ],
          onChanged: lock ? null : (v) => v == language ? null : _set('wake_language', v),
        ),
        SettingsChoice<String>(
          key: const ValueKey('voice-wake-sensitivity'),
          title: tr('Sensitivity'),
          description: tr('Loose also takes a phrase that was heard less exactly, but starts by mistake more often.'),
          value: VoiceService.sensitivities.contains(sensitivity) ? sensitivity : 'normal',
          choices: [for (final x in VoiceService.sensitivities) (x, sensitivityName(x))],
          onChanged: lock ? null : (v) => v == sensitivity ? null : _set('wake_sensitivity', v),
        ),
        SettingsChoice<String>(
          key: const ValueKey('voice-wake-model'),
          title: tr('Model for the phrase'),
          description: tr('It runs on the processor; a small model is enough and answers fastest.'),
          value: model,
          choices: wakeModelChoices(listing, model),
          onChanged: lock ? null : (v) => v == model ? null : _set('wake_model', v),
        ),
        SettingsItem(
          title: tr('Try the phrase'),
          description: trf('Say it within {0} seconds. Nothing is started; you only see what was heard.', [wakeTestSeconds]),
          trailing: testing
              ? OutlinedButton(key: const ValueKey('voice-wake-stop'), onPressed: () => _cancel('wake'), child: Text(tr('Cancel')))
              : FilledButton(
                  key: const ValueKey('voice-wake-try'),
                  onPressed: s == null || _running('dictate') ? null : () => _start('voice.wake_test', {'seconds': wakeTestSeconds}),
                  child: Text(tr('Try the phrase')),
                ),
        ),
        ?result,
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
            status = tr('Not downloaded');
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
    // Voxtype, Superwhisper and Omarchy type the text themselves, into the focused window
    final typesItself = s?['typed_by_engine'] == true;
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
      note: s != null && !ready
          ? tr('Dictation has to be ready first.')
          : typesItself
          ? tr('This engine types the text itself, into the window that has the focus, so it can\'t be tried here.')
          : null,
      children: [
        SettingsItem(
          title: tr('Try dictation'),
          description: trf('Speak for {0} seconds. The text is only shown here; nothing is typed.', [trySeconds]),
          trailing: running
              ? OutlinedButton(key: const ValueKey('voice-try-stop'), onPressed: () => _cancel('dictate'), child: Text(tr('Stop')))
              : FilledButton(
                  key: const ValueKey('voice-try'),
                  onPressed: ready && !typesItself && !_running('wake') ? () => _start('voice.try', {'seconds': trySeconds}) : null,
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
        _wake(d, s),
        _models(d),
        _try(s),
      ],
    );
  }
}

/// Other language: a Whisper code typed in (the service checks it).
class _LanguageCodeDialog extends StatefulWidget {
  const _LanguageCodeDialog();
  @override
  State<_LanguageCodeDialog> createState() => _LanguageCodeDialogState();
}

class _LanguageCodeDialogState extends State<_LanguageCodeDialog> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
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
  );
}
