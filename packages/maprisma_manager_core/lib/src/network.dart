import 'translations.dart';
import 'dart:convert';
import 'dart:io';

import 'private_files.dart' show PrivateFolder;

import 'context.dart';

/// The Network & Wireless page on Hyprland (COSMIC Settings' Wi-Fi, Wired and VPN): the Wi-Fi
/// switch, known and visible networks (connect, disconnect, forget), wired and VPN connections
/// (connect, disconnect). Through `nmcli` (NetworkManager); a Wi-Fi password goes only through
/// a private passwd-file (never a command line, never nmcli's editor and its history). WPA-Enterprise and editing are left to
/// Maprisma WLAN Monitor or nm-connection-editor.
final class NetworkService {
  NetworkService(this.ctx);
  final Ctx ctx;

  /// nmcli's terse line split at unescaped ':' (`\:` and `\\` are escapes).
  static List<String> terse(String line) {
    final out = <String>[];
    final b = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == r'\' && i + 1 < line.length) {
        b.write(line[++i]);
      } else if (c == ':') {
        out.add(b.toString());
        b.clear();
      } else {
        b.write(c);
      }
    }
    out.add(b.toString());
    return out;
  }

  Future<List<List<String>>> _rows(List<String> args, {Duration timeout = const Duration(seconds: 15)}) async {
    final r = await ctx.runner.run(['nmcli', '-t', ...args], timeout: timeout);
    if (!r.ok) throw RouteError('failed', _why(r.stderr, r.code));
    return [for (final l in r.stdout.split('\n')) if (l.isNotEmpty) terse(l)];
  }

  Future<void> _nmcli(List<String> args, {Duration timeout = const Duration(seconds: 45)}) async {
    final r = await ctx.runner.run(['nmcli', ...args], timeout: timeout);
    if (!r.ok) throw RouteError('failed', _why(r.stderr, r.code));
  }

  static String _why(String s, int code) {
    final l = s.trim().split('\n').where((x) => x.trim().isNotEmpty).lastOrNull?.trim() ?? '';
    return l.isEmpty ? trf('exit {0}', [code]) : l.replaceFirst(RegExp(r'^Error:\s*'), '');
  }

  void _need() {
    if (ctx.runner.which('nmcli') == null) throw RouteError('unavailable', tr('nmcli is missing (NetworkManager)'));
  }

  static const _wifi = '802-11-wireless', _wired = '802-3-ethernet';
  static const _vpn = {'vpn', 'wireguard'};

  /// `network.get` {rescan?}.
  Future<Map<String, dynamic>> get([Map<String, dynamic> params = const {}]) async {
    _need();
    final rescan = params['rescan'] == true;
    final radio = await _rows(['radio', 'wifi']);
    final devices = await _rows(['-f', 'DEVICE,TYPE,STATE,CONNECTION', 'device', 'status']);
    final conns = await _rows(['-f', 'NAME,UUID,TYPE,ACTIVE,DEVICE', 'connection', 'show']);
    final hasWifi = devices.any((d) => d.length > 1 && d[1] == 'wifi');
    final wifiOn = radio.isNotEmpty && radio.first.first == 'enabled';
    var visible = <List<String>>[];
    if (hasWifi && wifiOn) {
      try {
        visible = await _rows(['-f', 'IN-USE,SSID,SECURITY,SIGNAL', 'device', 'wifi', 'list', '--rescan', rescan ? 'yes' : 'no'], timeout: const Duration(seconds: 30));
      } on RouteError {
        visible = const [];
      }
    }
    Map<String, dynamic> conn(List<String> c) => {'name': c[0], 'uuid': c[1], 'type': c[2], 'active': c[3] == 'yes', 'device': c.length > 4 ? c[4] : ''};
    final known = [for (final c in conns) if (c.length >= 4 && c[2] == _wifi) conn(c)];
    // One row per network name: the strongest; the known ones are listed above.
    final bySsid = <String, Map<String, dynamic>>{};
    for (final v in visible) {
      if (v.length < 4 || v[1].isEmpty) continue;
      final signal = int.tryParse(v[3]) ?? 0;
      final seen = bySsid[v[1]];
      if (seen == null || (seen['signal'] as int) < signal || v[0] == '*') {
        bySsid[v[1]] = {'ssid': v[1], 'security': v[2], 'signal': signal, 'inUse': v[0] == '*' || (seen?['inUse'] == true), 'known': known.any((k) => k['name'] == v[1])};
      }
    }
    final networks = bySsid.values.toList()..sort((a, b) => (b['signal'] as int).compareTo(a['signal'] as int));
    return {
      'wifiDevice': hasWifi,
      'wifiOn': wifiOn,
      'known': known,
      'visible': networks,
      'wired': [for (final c in conns) if (c.length >= 4 && c[2] == _wired) conn(c)],
      'wiredDevices': [
        for (final d in devices)
          if (d.length >= 3 && d[1] == 'ethernet') {'device': d[0], 'state': d[2], 'connection': d.length > 3 ? d[3] : ''},
      ],
      'vpn': [for (final c in conns) if (c.length >= 4 && _vpn.contains(c[2])) conn(c)],
      'monitor': ctx.runner.which('maprisma-wlan-monitor') != null,
      'editor': ctx.runner.which('nm-connection-editor') != null,
    };
  }

  /// `network.wifi` {on}.
  Future<Map<String, dynamic>> wifi(Map<String, dynamic> params) async {
    _need();
    final on = params['on'];
    if (on is! bool) throw RouteError('bad_params', 'on');
    await _nmcli(['radio', 'wifi', on ? 'on' : 'off'], timeout: const Duration(seconds: 15));
    return {'on': on};
  }

  Future<Map<String, dynamic>> _known(Object? uuid, {Set<String>? types}) async {
    if (uuid is! String || !RegExp(r'^[0-9a-fA-F-]{8,64}$').hasMatch(uuid)) throw RouteError('bad_params', 'uuid');
    final conns = await _rows(['-f', 'NAME,UUID,TYPE,ACTIVE,DEVICE', 'connection', 'show']);
    final c = conns.where((c) => c.length >= 4 && c[1] == uuid && (types == null || types.contains(c[2]))).firstOrNull;
    if (c == null) throw RouteError('not_found', tr('no such connection'));
    return {'name': c[0], 'uuid': c[1], 'type': c[2]};
  }

  /// `network.up` / `network.down` {uuid}: a known Wi-Fi, wired or VPN connection.
  Future<Map<String, dynamic>> up(Map<String, dynamic> params) async {
    _need();
    final c = await _known(params['uuid'], types: {_wifi, _wired, ..._vpn});
    await _nmcli(['connection', 'up', 'uuid', c['uuid'] as String]);
    return c;
  }

  Future<Map<String, dynamic>> down(Map<String, dynamic> params) async {
    _need();
    final c = await _known(params['uuid'], types: {_wifi, _wired, ..._vpn});
    await _nmcli(['connection', 'down', 'uuid', c['uuid'] as String], timeout: const Duration(seconds: 20));
    return c;
  }

  /// `network.forget` {uuid}: a known Wi-Fi network only.
  Future<Map<String, dynamic>> forget(Map<String, dynamic> params) async {
    _need();
    final c = await _known(params['uuid'], types: {_wifi});
    await _nmcli(['connection', 'delete', 'uuid', c['uuid'] as String], timeout: const Duration(seconds: 20));
    return c;
  }

  /// `network.connect` {ssid, password?}: a visible network. Open: `device wifi connect`; with a
  /// password: a new connection without the key, brought up with a private passwd-file.
  Future<Map<String, dynamic>> connect(Map<String, dynamic> params) async {
    _need();
    final ssid = params['ssid'], password = params['password'];
    // A name starting with '-' would reach nmcli as an option.
    if (ssid is! String || ssid.isEmpty || ssid.length > 32 || ssid.contains('\n') || ssid.startsWith('-')) throw RouteError('bad_params', 'ssid');
    if (password != null && (password is! String || password.length < 8 || password.length > 63 || password.contains('\n'))) {
      throw RouteError('bad_params', tr('The password needs 8 to 63 characters'));
    }
    // nmcli trims what it reads from a passwd-file: such a password would be sent shortened.
    if (password is String && password.trim() != password) {
      throw RouteError('bad_params', tr('A password that starts or ends with a space can\'t be set here: use Maprisma WLAN Monitor or nmcli'));
    }
    if (password == null) {
      await _nmcli(['device', 'wifi', 'connect', ssid]);
      return {'ssid': ssid};
    }
    // The key is saved by NetworkManager (psk-flags 0) when it comes from nmcli's passwd-file:
    // never on a command line, never in nmcli's editor history (~/.cache/nmcli-history).
    final add = await ctx.runner.run(['nmcli', '-t', '-f', 'connection.uuid', 'connection', 'add', 'type', 'wifi', 'con-name', ssid, 'ssid', ssid, 'wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk-flags', '0'], timeout: const Duration(seconds: 20));
    if (!add.ok) throw RouteError('failed', _why(add.stderr, add.code));
    final uuid = RegExp(r'[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}').firstMatch(add.stdout)?.group(0);
    if (uuid == null) throw RouteError('failed', tr('NetworkManager made no connection'));
    // A folder only this user can enter (0700, in the runtime folder: memory, not disk), the
    // file only this user can read (0600, never through a link).
    final runtime = ctx.environment['XDG_RUNTIME_DIR'];
    final base = runtime != null && runtime.startsWith('/') && Directory(runtime).existsSync() ? runtime : Directory.systemTemp.path;
    final dir = Directory('$base/maprisma-manager-wifi-$pid-${DateTime.now().microsecondsSinceEpoch}');
    try {
      final folder = PrivateFolder.open(dir.path);
      try {
        folder.writeNew('secrets', utf8.encode('802-11-wireless-security.psk:$password\n'));
      } finally {
        folder.close();
      }
      await _nmcli(['connection', 'up', 'uuid', uuid, 'passwd-file', '${dir.path}/secrets'], timeout: const Duration(seconds: 60));
    } on Object {
      // A wrong password (or a secret file that couldn't be written) leaves no half connection.
      await ctx.runner.run(['nmcli', 'connection', 'delete', 'uuid', uuid], timeout: const Duration(seconds: 15));
      rethrow;
    } finally {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    return {'ssid': ssid, 'uuid': uuid};
  }
}
