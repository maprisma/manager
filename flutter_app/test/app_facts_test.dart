// The list's sections: an app whose bar icon is another app's (barVia) follows that app.
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma_manager/app_facts.dart';

void main() {
  App app(String id, {String state = 'installed', Map<String, dynamic>? bar, String? via}) => {
    'id': id,
    'name': 'App $id',
    'kind': 'k',
    'state': state,
    'bar': bar ?? {'has': false, 'state': 'none'},
    if (via != null) 'barVia': {'id': via, 'name': 'App $via'},
  };
  List<String> ids(List<App> apps) => [
    for (final (t, l) in sections(apps, 'hyprland')) '$t: ${[for (final a in l) a['id']].join(', ')}',
  ];

  test('a barVia app follows its host in the host\'s section and names it', () {
    final apps = [
      app('maprisma', via: 'control'),
      app('home', bar: {'has': true, 'state': 'in', 'zone': 'right'}),
      app('control', bar: {'has': true, 'state': 'in', 'zone': 'right'}),
      app('tiling'),
    ];
    expect(ids(apps), [
      'In the bar: home, control, maprisma',
      'Not in the bar: ',
      'No bar icon: tiling',
      'Not installed: ',
    ]);
    expect(subtitle(apps.first, 'hyprland'), contains('bar icon: App control'));
  });

  test('without its host (not installed or filtered out) it stays under No bar icon', () {
    expect(ids([app('maprisma', via: 'control'), app('control', state: 'notInstalled', bar: {'has': true, 'state': 'out'})])[2],
        'No bar icon: maprisma');
    expect(ids([app('maprisma', via: 'control')])[2], 'No bar icon: maprisma');
  });
}
