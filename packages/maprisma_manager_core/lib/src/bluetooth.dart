import 'translations.dart';

import 'context.dart';

/// The Bluetooth page on Hyprland (COSMIC Settings' Bluetooth): the switch, the paired devices
/// (connect, disconnect, forget, battery) and nearby ones (pair and connect after a scan).
/// Through `bluetoothctl` (BlueZ); no root.
final class BluetoothService {
  BluetoothService(this.ctx);
  final Ctx ctx;

  static final _mac = RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$');

  Future<String> _ctl(List<String> args, {Duration timeout = const Duration(seconds: 15)}) async {
    final r = await ctx.runner.run(['bluetoothctl', ...args], timeout: timeout);
    if (!r.ok) throw RouteError('failed', _why('${r.stderr}\n${r.stdout}', r.code));
    return r.stdout;
  }

  static String _why(String s, int code) {
    final l = s.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty).lastOrNull ?? '';
    return l.isEmpty ? trf('exit {0}', [code]) : l;
  }

  void _need() {
    if (ctx.runner.which('bluetoothctl') == null) throw RouteError('unavailable', tr('bluetoothctl is missing (BlueZ)'));
  }

  /// "Device AA:BB:… Name" lines.
  static List<({String mac, String name})> devices(String out) => [
    for (final l in out.split('\n'))
      if (RegExp(r'^Device ([0-9A-F:]{17}) (.*)$').firstMatch(l.trim()) case final m?) (mac: m[1]!, name: m[2]!),
  ];

  /// `bluetoothctl info`'s "Key: value" lines.
  static Map<String, String> info(String out) => {
    for (final l in out.split('\n'))
      if (RegExp(r'^\s*([A-Za-z ]+):\s*(.*)$').firstMatch(l) case final m?) m[1]!.trim(): m[2]!.trim(),
  };

  Future<Map<String, dynamic>> get() async {
    _need();
    final show = await ctx.runner.run(['bluetoothctl', 'show'], timeout: const Duration(seconds: 10));
    final controller = show.ok && show.stdout.contains('Controller');
    final powered = controller && info(show.stdout)['Powered'] == 'yes';
    final paired = <Map<String, dynamic>>[];
    final nearby = <Map<String, dynamic>>[];
    if (controller) {
      final pairedList = devices(await _ctl(['devices', 'Paired']));
      for (final d in pairedList) {
        final i = info(await _ctl(['info', d.mac]));
        final battery = RegExp(r'\((\d+)\)').firstMatch(i['Battery Percentage'] ?? '')?.group(1);
        paired.add({'mac': d.mac, 'name': i['Alias'] ?? d.name, 'connected': i['Connected'] == 'yes', 'icon': i['Icon'], 'battery': battery == null ? null : int.parse(battery)});
      }
      for (final d in devices(await _ctl(['devices']))) {
        if (pairedList.any((x) => x.mac == d.mac)) continue;
        // BlueZ names unnamed devices by their address: no use in a list.
        if (d.name.replaceAll('-', ':').toUpperCase() == d.mac) continue;
        nearby.add({'mac': d.mac, 'name': d.name});
      }
    }
    return {'controller': controller, 'powered': powered, 'paired': paired, 'nearby': nearby, 'monitor': ctx.runner.which('maprisma-bluetooth-monitor') != null};
  }

  /// `bluetooth.power` {on}.
  Future<Map<String, dynamic>> power(Map<String, dynamic> params) async {
    _need();
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    await _ctl(['power', on ? 'on' : 'off']);
    return {'on': on};
  }

  /// `bluetooth.scan`: looks for nearby devices for [seconds] (BlueZ remembers them after).
  Future<Map<String, dynamic>> scan(Map<String, dynamic> params) async {
    _need();
    final seconds = params['seconds'] ?? 8;
    if (seconds is! int || seconds < 2 || seconds > 30) throw RouteError('bad_params', 'seconds (2–30)');
    await ctx.runner.run(['bluetoothctl', '--timeout', '$seconds', 'scan', 'on'], timeout: Duration(seconds: seconds + 10));
    return await get();
  }

  String _macOf(Map<String, dynamic> params) {
    final mac = params['mac'];
    if (mac is! String || !_mac.hasMatch(mac)) throw RouteError('bad_params', 'mac');
    return mac;
  }

  /// `bluetooth.connect` / `disconnect` / `forget` {mac}; `pair` {mac}: pair, trust, connect.
  Future<Map<String, dynamic>> device(String action, Map<String, dynamic> params) async {
    _need();
    final mac = _macOf(params);
    switch (action) {
      case 'connect':
        await _ctl(['connect', mac], timeout: const Duration(seconds: 30));
      case 'disconnect':
        await _ctl(['disconnect', mac]);
      case 'forget':
        await _ctl(['remove', mac]);
      case 'pair':
        await _ctl(['pair', mac], timeout: const Duration(seconds: 60));
        await _ctl(['trust', mac]);
        await _ctl(['connect', mac], timeout: const Duration(seconds: 30));
      default:
        throw RouteError('bad_params', 'action');
    }
    return {'mac': mac, 'done': action};
  }
}
