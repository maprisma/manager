import 'package:flutter/material.dart';
import 'package:maprisma_manager_core/maprisma_manager_core.dart' show tr;

import 'core_call.dart';
import 'desktop_page.dart';
import 'settings_widgets.dart';

/// Sound, as COSMIC Settings' page: output and input (volume with mute, device), Amplification,
/// the applications' volumes and the devices' profiles. Hyprland: through `sound.*` (pactl).
class SoundPage extends StatelessWidget {
  const SoundPage({super.key, required this.core});
  final CoreCall core;
  @override
  Widget build(BuildContext context) => DesktopSettingsPage(
    core: core,
    page: 'sound',
    title: tr('Sound'),
    what: tr('the sound'),
    own: (_) => _Sound(core: core),
  );
}

class _Sound extends StatefulWidget {
  const _Sound({required this.core});
  final CoreCall core;
  @override
  State<_Sound> createState() => _SoundState();
}

class _SoundState extends State<_Sound> with RoutePage {
  @override
  CoreCall get core => widget.core;
  @override
  String get getRoute => 'sound.get';

  Widget _muteButton(String key, bool mute, VoidCallback? onPressed, {required bool input}) => IconButton(
    key: ValueKey(key),
    tooltip: mute ? tr('Unmute') : tr('Mute'),
    onPressed: onPressed,
    icon: Icon(input ? (mute ? Icons.mic_off : Icons.mic) : (mute ? Icons.volume_off : Icons.volume_up), size: 20),
  );

  /// Output or input: volume (with mute) and device.
  List<Widget> _device(Map d, String target) {
    final list = (d[target == 'sink' ? 'sinks' : 'sources'] as List).cast<Map>();
    final current = list.where((x) => x['name'] == d['default_$target']).firstOrNull;
    final max = d['amplify'] == true ? 150.0 : 100.0;
    final input = target == 'source';
    return [
      if (current != null)
        SettingsSlider(
          key: ValueKey('$target-volume'),
          title: input ? tr('Input volume') : tr('Output volume'),
          value: (current['volume'] as int).toDouble(),
          min: 0,
          max: max,
          label: (v) => '${v.round()} %',
          leading: _muteButton('$target-mute', current['mute'] == true, working ? null : () => act('sound.mute', {'target': target, 'mute': current['mute'] != true}), input: input),
          onChangeEnd: working ? null : (v) => act('sound.volume', {'target': target, 'percent': v.round()}),
        ),
      SettingsChoice<String>(
        key: ValueKey('$target-device'),
        title: input ? tr('Input device') : tr('Output device'),
        value: '${d['default_$target']}',
        choices: [for (final x in list) ('${x['name']}', '${x['description']}')],
        onChanged: working ? null : (v) => act('sound.default', {'target': target, 'name': v}),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return SettingsPage(title: tr('Sound'), actions: reloadActions(), children: loadingOrError(context));
    final streams = (d['streams'] as List).cast<Map>();
    final cards = (d['cards'] as List).cast<Map>();
    final max = d['amplify'] == true ? 150.0 : 100.0;
    return SettingsPage(
      title: tr('Sound'),
      actions: reloadActions(),
      children: [
        SettingsSection(
          title: tr('Output'),
          children: [
            ..._device(d, 'sink'),
            SettingsToggle(
              key: const ValueKey('sound-amplify'),
              title: tr('Amplification'),
              description: tr('Allows raising the volume to 150 %.'),
              value: d['amplify'] == true,
              onChanged: working ? null : (v) => act('settings.set', {'key': 'sound_amplify', 'value': v}),
            ),
          ],
        ),
        SettingsSection(title: tr('Input'), children: _device(d, 'source')),
        if (streams.isNotEmpty)
          SettingsSection(
            title: tr('Applications'),
            children: [
              for (final s in streams)
                SettingsSlider(
                  key: ValueKey('stream-${s['index']}'),
                  title: '${s['app']}',
                  description: s['media'] is String && s['media'] != s['app'] ? '${s['media']}' : null,
                  value: (s['volume'] as int).toDouble(),
                  min: 0,
                  max: max,
                  label: (v) => '${v.round()} %',
                  leading: _muteButton('stream-mute-${s['index']}', s['mute'] == true, working ? null : () => act('sound.stream', {'index': s['index'], 'mute': s['mute'] != true}), input: false),
                  onChangeEnd: working ? null : (v) => act('sound.stream', {'index': s['index'], 'percent': v.round()}),
                ),
            ],
          ),
        if (cards.isNotEmpty)
          SettingsSection(
            title: tr('Device profiles'),
            children: [
              for (final c in cards)
                SettingsChoice<String>(
                  key: ValueKey('card-${c['name']}'),
                  title: '${c['description']}',
                  value: '${c['active']}',
                  choices: [
                    for (final p in (c['profiles'] as List).cast<Map>())
                      if (p['available'] == true || p['name'] == c['active']) ('${p['name']}', '${p['description']}'),
                  ],
                  onChanged: working ? null : (v) => act('sound.profile', {'card': c['name'], 'profile': v}),
                ),
            ],
          ),
      ],
    );
  }
}
