import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'context.dart';

/// The About page (COSMIC Settings' About), read only: device name, hardware (model, memory,
/// processor, graphics, disks) and the system (OS, architecture, kernel, desktop, windowing
/// system). Files through the paths' root and /proc (fakes in tests), tools by name.
final class AboutService {
  AboutService(this.ctx);
  final Ctx ctx;

  String _read(String absolute) {
    try {
      return File(ctx.paths.sys(absolute)).readAsStringSync().trim();
    } on FileSystemException {
      return '';
    }
  }

  String _proc(String name) {
    try {
      return File(p.join(ctx.paths.proc, name)).readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  Future<String> _out(List<String> argv) async {
    if (ctx.runner.which(argv.first) == null) return '';
    final r = await ctx.runner.run(argv, timeout: const Duration(seconds: 8));
    return r.ok ? r.stdout : '';
  }

  /// "Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XT] (rev c8)" → its last
  /// bracketed name ("Radeon RX 7900 XT"), else the text after the class.
  static String gpuName(String line) {
    final text = line.contains(': ') ? line.substring(line.indexOf(': ') + 2) : line;
    final brackets = RegExp(r'\[([^\]]+)\]').allMatches(text).toList();
    final name = brackets.length >= 2 ? brackets.last[1]! : text.replaceAll(RegExp(r'\s*\(rev [^)]*\)$'), '');
    final vendor = text.contains('AMD') ? 'AMD ' : text.contains('NVIDIA') ? 'NVIDIA ' : text.contains('Intel') ? 'Intel ' : '';
    return name.startsWith(vendor.trim()) ? name : '$vendor$name';
  }

  /// Bytes as "64 GB" / "2 TB" (powers of 1000, as disks are sold).
  static String size(num bytes) {
    const units = ['B', 'kB', 'MB', 'GB', 'TB', 'PB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return '${v >= 100 || v == v.roundToDouble() ? v.round() : v.toStringAsFixed(1)} ${units[i]}';
  }

  Future<Map<String, dynamic>> get() async {
    String host = '';
    final hj = await _out(['hostnamectl', '--json=short']);
    if (hj.isNotEmpty) {
      try {
        final v = jsonDecode(hj);
        if (v is Map) host = '${v['PrettyHostname'] ?? v['StaticHostname'] ?? v['Hostname'] ?? ''}';
      } on FormatException {
        // fall back to the file
      }
    }
    if (host.isEmpty || host == 'null') host = _read('/etc/hostname');

    String model = [_read('/sys/class/dmi/id/sys_vendor'), _read('/sys/class/dmi/id/product_name')].where((x) => x.isNotEmpty && !x.contains('To be filled')).join(' ');
    final board = [_read('/sys/class/dmi/id/board_vendor'), _read('/sys/class/dmi/id/board_name')].where((x) => x.isNotEmpty).join(' ');
    if (board.isNotEmpty && (model.isEmpty || RegExp(r'MS-\d|System Product Name|Default string').hasMatch(model))) model = board;

    final mem = RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(_proc('meminfo'))?.group(1);
    final cpuinfo = _proc('cpuinfo');
    final cpu = RegExp(r'^model name\s*:\s*(.+)$', multiLine: true).firstMatch(cpuinfo)?.group(1)?.trim();
    final threads = RegExp(r'^processor\s*:', multiLine: true).allMatches(cpuinfo).length;

    final gpus = [
      for (final l in (await _out(['lspci'])).split('\n'))
        if (RegExp(r'VGA compatible controller|3D controller|Display controller').hasMatch(l)) gpuName(l),
    ];

    var disk = 0;
    final lsblk = await _out(['lsblk', '-b', '-d', '-J', '-o', 'NAME,SIZE,TYPE']);
    if (lsblk.isNotEmpty) {
      try {
        for (final d in ((jsonDecode(lsblk) as Map)['blockdevices'] as List? ?? const [])) {
          final m = d as Map;
          if (m['type'] != 'disk' || '${m['name']}'.startsWith('zram') || '${m['name']}'.startsWith('loop')) continue;
          disk += (m['size'] as num?)?.toInt() ?? 0;
        }
      } on FormatException {
        // no disks then
      }
    }

    final os = RegExp(r'^PRETTY_NAME="?([^"\n]+)"?', multiLine: true).firstMatch(_read('/etc/os-release'))?.group(1);
    final kernel = _proc('sys/kernel/osrelease').trim();
    final arch = (await _out(['uname', '-m'])).trim();
    return {
      'hostname': host,
      'model': model,
      // Memory in GiB, as COSMIC shows it (disks in GB, as they are sold).
      'memory': mem == null ? '' : '${(int.parse(mem) / 1048576).toStringAsFixed(1)} GiB',
      'processor': cpu == null ? '' : (threads > 1 ? '$cpu × $threads' : cpu),
      'graphics': gpus,
      'disk': disk == 0 ? '' : size(disk),
      'os': os ?? '',
      'arch': arch,
      'kernel': kernel,
      'desktop': ctx.environment['XDG_CURRENT_DESKTOP'] ?? '',
      'session': ctx.environment['XDG_SESSION_TYPE'] ?? '',
    };
  }
}
