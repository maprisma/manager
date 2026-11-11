/// Ask AI's generic part: which coding agents are there and signed in, and
/// one run of one of them (copied from Maprisma Theme's ask_ai.dart, which took
/// the helper table and pi/Hermes model detection from Maprisma Launcher's
/// ask_ai.dart).
///
/// - The agent has no tools (Claude Code, pi, Hermes) or a read-only sandbox
///   (Codex), which then runs in a bubblewrap jail that shows it no home
///   folder but its own config folder, as a throw-away overlay (only its
///   sign-in file is written through), and no session bus.
/// - It runs as an argv subprocess (no shell) in a new empty private folder
///   (0700), in its own process group (`setsid`), with a time limit, a hard
///   cap on every file it writes (`prlimit --fsize`, RLIMIT_FSIZE 256 MiB), the
///   private folder checked against 64 MiB and its answer read up to 256 KiB.
/// - Sign-in is judged only by whether a credentials file exists or an API key
///   variable is set; their content is never read.
/// - Local models (pi's loopback providers, Hermes's local default): run with
///   `--offline`; their port is used only when every listening socket on it
///   belongs to this user or a system service (asked from the kernel over
///   netlink sock_diag, as `ss` does); their user unit is started when they do
///   not answer; a model an Ask loaded is unloaded again on request.
library;

import '../translations.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'bounded.dart';
import 'posix.dart';


const askTimeout = Duration(seconds: 240);
const maxAnswerBytes = 256 * 1024;
const agentFileMax = 256 * 1024 * 1024;
const workMax = 64 * 1024 * 1024;
const jailTmpfs = 64 * 1024 * 1024;

/// A short reason why an Ask did not get an answer.
final class AskError implements Exception {
  AskError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One helper: how it runs without tools, how its sign-in is recognised.
typedef Helper = ({
  String id,
  String name,
  List<String> argv,
  List<String> files,
  List<String> env,
  String login,
  String note,
  // Codex can read files: it runs in bubblewrap with an empty home, where
  // the folders in `fresh` are new and empty (none of the real ones'
  // sessions, config or MCP setup) and only the files in `keep` (its
  // sign-in) are bound in from the real home, written through.
  ({List<String> fresh, List<String> keep})? jail,
  // Web search for wallpapers: these arguments of argv (`off`, its "no tools")
  // are swapped for `on` (only its web search and web fetch tools); null when
  // the helper has no web tools. A helper (local ones too) that gains web
  // search only needs this filled in.
  ({List<String> off, List<String> on})? web,
});

List<Helper> get helpers => [
  (
    id: 'claude',
    name: 'Claude Code',
    argv: [
      'claude',
      '-p',
      '--tools',
      '',
      '--strict-mcp-config',
      '--no-session-persistence',
      '--disable-slash-commands',
      '--output-format',
      'text',
      '--settings',
      '{"disableAllHooks": true}',
    ],
    files: ['.claude/.credentials.json'],
    env: ['ANTHROPIC_API_KEY'],
    login: 'claude auth login',
    note: tr("No tools: it only reads what Maprisma Manager sends."),
    jail: null,
    web: (off: ['--tools', ''], on: ['--tools', 'WebSearch,WebFetch', '--allowedTools', 'WebSearch,WebFetch']),
  ),
  (
    id: 'codex',
    name: 'Codex',
    argv: [
      'codex',
      'exec',
      '--sandbox',
      'read-only',
      '--skip-git-repo-check',
      // no session saved, no user config or rules, no web search
      '--ephemeral',
      '--ignore-user-config',
      '--ignore-rules',
      '-c',
      'web_search="disabled"',
      // no tools: it only answers
      for (final feature in codexOff) ...['--disable', feature],
      '--output-last-message',
      '{answer}',
      '-',
    ],
    files: ['.codex/auth.json'],
    env: ['OPENAI_API_KEY'],
    login: 'codex login',
    note: tr("Read-only sandbox, inside a bubblewrap jail that shows it none of your files."),
    jail: (fresh: ['.codex'], keep: ['.codex/auth.json']),
    web: null,
  ),
  (
    id: 'pi',
    name: 'pi',
    argv: ['pi', '-p', '--no-session', '--no-tools', '--no-mcp', '--no-extensions', '--no-context-files', '--no-approve'],
    files: ['.pi/agent/auth.json'],
    env: ['ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'GEMINI_API_KEY'],
    login: 'pi',
    note: tr("No tools, MCP servers, extensions or project files."),
    jail: null,
    web: null,
  ),
  (
    id: 'hermes',
    name: 'Hermes',
    argv: ['hermes', 'chat', '--query-file', '-', '--oneshot', '-t', 'todo', '--ignore-rules'],
    files: ['.hermes/auth.json'],
    env: ['OPENROUTER_API_KEY', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY'],
    login: 'hermes',
    note: tr("Only its in-memory task list: no files, terminal, web or MCP."),
    jail: null,
    web: null,
  ),
];

/// Codex features turned off for an Ask: its tools (shell, exec, code mode,
/// images, browser, computer use, sleep, goals) and its integrations. Names
/// Codex 0.167 knows; an unknown name stops it, so only remove names here.
/// Checked live 2026-11-11: it can't run a command ("code-mode host is
/// disabled"). Its spawn_agent tool has no switch in 0.167; a spawned agent
/// has the same limits, and --ephemeral makes the spawn fail anyway.
const codexOff = [
  'shell_tool', 'unified_exec', 'shell_snapshot', 'code_mode_host', 'view_image', 'image_generation',
  'browser_use', 'computer_use', 'multi_agent', 'sleep_tool', 'goals', 'tool_suggest', 'apps', 'plugins',
  'hooks',
];

/// Whether the helper with this id (`pi:<provider>/<model>` too) can search the web.
bool canSearchWeb(String helperId) => helperFor(helperId)?.web != null;

/// [argv] with the helper's web tools instead of none (unchanged without).
List<String> withWebTools(Helper helper, List<String> argv) {
  final web = helper.web;
  if (web == null) return argv;
  for (var i = 0; i + web.off.length <= argv.length; i++) {
    var match = true;
    for (var j = 0; j < web.off.length && match; j++) {
      match = argv[i + j] == web.off[j];
    }
    if (match) return [...argv.sublist(0, i), ...web.on, ...argv.sublist(i + web.off.length)];
  }
  return argv;
}

Helper? helperFor(String id) {
  final base = id.startsWith('pi:') ? 'pi' : id;
  for (final h in helpers) {
    if (h.id == base) return h;
  }
  return null;
}

// --- local models ---------------------------------------------------------------------

typedef LocalModel = ({String provider, String model, String host, int port});

const localHosts = {'127.0.0.1', 'localhost', '::1'};
const localUnits = {8080: 'llama-server.service', 11434: 'ollama.service'};
final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$');
final _notChat = RegExp(
  r'tts|whisper|embed|rerank|tokenizer|mmproj|clip|vae|diffusion|flux|sdxl|stable-?diffusion|speech|asr|vision-encoder',
  caseSensitive: false,
);

(String, int)? _localUrl(Object? value) {
  final url = Uri.tryParse('${value ?? ''}');
  if (url == null || !localHosts.contains(url.host)) return null;
  return (url.host, url.hasPort ? url.port : (url.scheme == 'https' ? 443 : 80));
}

String localHelperId(LocalModel m) => 'pi:${m.provider}/${m.model}';
String localKey(LocalModel m) => '${m.host}|${m.port}|${m.model}';

/// pi's local chat models (~/.pi/agent/models.json, providers on loopback)
/// and its default provider and model (settings.json); bounded reads.
({List<LocalModel> local, String? provider, String? model}) piModels(String home) {
  Map? read(String name) {
    final bytes = Posix.instance.readRegular(p.join(home, '.pi/agent', name), 1024 * 1024, follow: false);
    if (bytes == null) return null;
    try {
      final data = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return data is Map ? data : null;
    } on FormatException {
      return null;
    }
  }

  final local = <LocalModel>[];
  final providers = read('models.json')?['providers'];
  if (providers is Map) {
    for (final e in providers.entries) {
      final provider = '${e.key}';
      final conf = e.value;
      if (conf is! Map || !_name.hasMatch(provider)) continue;
      final where = _localUrl(conf['baseUrl']);
      if (where == null) continue;
      final seen = <String>{};
      final models = conf['models'];
      for (final m in models is List ? models : const []) {
        final id = m is Map ? '${m['id'] ?? ''}' : '$m';
        if (!_name.hasMatch(id) || _notChat.hasMatch(id) || !seen.add(id)) continue;
        local.add((provider: provider, model: id, host: where.$1, port: where.$2));
      }
    }
  }
  final settings = read('settings.json');
  final provider = settings?['defaultProvider'], model = settings?['defaultModel'];
  return (
    local: local.take(40).toList(),
    provider: provider is String && _name.hasMatch(provider) ? provider : null,
    model: model is String && _name.hasMatch(model) ? model : null,
  );
}

/// Hermes's default model (~/.hermes/config.yaml, a few YAML lines read by
/// indentation) and, when it runs on this PC, where.
({String? model, LocalModel? local}) hermesModel(String home) {
  final bytes = Posix.instance.readRegular(p.join(home, '.hermes/config.yaml'), 1024 * 1024, follow: false);
  if (bytes == null) return (model: null, local: null);
  String? model, provider;
  final apis = <String, String>{};
  final path = <(int, String)>[];
  for (final raw in utf8.decode(bytes, allowMalformed: true).split('\n')) {
    final line = raw.replaceAll('\t', '        ');
    final m = RegExp(r'^(\s*)([A-Za-z0-9_.-]+):\s*(.*?)\s*$').firstMatch(line);
    if (m == null || line.trimLeft().startsWith('#')) continue;
    final indent = m[1]!.length, key = m[2]!;
    var value = m[3]!;
    if (value.startsWith('"') || value.startsWith("'")) {
      final close = value.indexOf(value[0], 1);
      value = close > 0 ? value.substring(1, close) : value.substring(1);
    } else {
      final hash = value.indexOf(' #');
      if (hash >= 0) value = value.substring(0, hash).trimRight();
    }
    while (path.isNotEmpty && path.last.$1 >= indent) {
      path.removeLast();
    }
    final parents = [for (final (_, k) in path) k];
    if (parents.length == 1 && parents[0] == 'model') {
      if (key == 'default') model = value;
      if (key == 'provider') provider = value;
    } else if (parents.length == 2 && parents[0] == 'providers' && key == 'api') {
      apis[parents[1]] = value;
    }
    path.add((indent, key));
  }
  if (model == null || !_name.hasMatch(model)) return (model: null, local: null);
  final where = provider != null && _name.hasMatch(provider) ? _localUrl(apis[provider]) : null;
  return (model: model, local: where == null ? null : (provider: provider!, model: model, host: where.$1, port: where.$2));
}

/// Every supported agent: installed? signed in? (no tokens spent). Codex is
/// installed only when bubblewrap is there to jail it.
List<Map<String, dynamic>> helperStates(String home, Map<String, String> environment) {
  bool has(String program) => which(program, environment) != null;
  final jail = has('bwrap');
  final pi = has('pi') ? piModels(home) : null;
  final hermes = has('hermes') ? hermesModel(home) : null;
  final piLocalDefault = pi != null && pi.local.any((m) => m.provider == pi.provider && m.model == pi.model);
  final out = <Map<String, dynamic>>[];
  for (final h in helpers) {
    final installed = has(h.argv.first) && (jail || h.jail == null);
    final signedIn =
        h.env.any((e) => (environment[e] ?? '').isNotEmpty) ||
        h.files.any((f) => FileSystemEntity.typeSync(p.join(home, f), followLinks: false) != FileSystemEntityType.notFound);
    var name = h.name;
    var local = false;
    if (h.id == 'pi' && pi?.model != null) {
      name = 'pi · ${pi!.model}';
      local = piLocalDefault;
    } else if (h.id == 'hermes' && hermes?.model != null) {
      name = 'Hermes · ${hermes!.model}';
      local = hermes.local != null;
    }
    out.add({
      'id': h.id,
      'name': name,
      'installed': installed,
      'signed_in': installed && (signedIn || local),
      'local': local,
      'login': h.login,
      'note': h.jail != null && !jail && has(h.argv.first) ? 'Needs bubblewrap (bwrap) to run jailed.' : h.note,
    });
  }
  for (final m in pi?.local ?? const <LocalModel>[]) {
    if (m.provider == pi!.provider && m.model == pi.model) continue; // the "pi" entry already
    out.add({
      'id': localHelperId(m),
      'name': 'pi · ${m.model}',
      'installed': true,
      'signed_in': true,
      'local': true,
      'login': '',
      'note': trf("On this PC ({0}): no tokens, nothing leaves the computer.", [m.provider]),
    });
  }
  return out;
}

/// The local model a helper runs on, or null (an online agent, or unknown).
LocalModel? localModelOf(String? helperId, String home) {
  if (helperId == null) return null;
  if (helperId == 'pi' || helperId.startsWith('pi:')) {
    final pi = piModels(home);
    if (helperId == 'pi') {
      return pi.local.where((m) => m.provider == pi.provider && m.model == pi.model).firstOrNull;
    }
    return pi.local.where((m) => localHelperId(m) == helperId).firstOrNull;
  }
  if (helperId == 'hermes') return hermesModel(home).local;
  return null;
}

// --- who listens on a port (netlink sock_diag) ------------------------------------------

final _libc = DynamicLibrary.open('libc.so.6');
final _socket = _libc.lookupFunction<Int Function(Int, Int, Int), int Function(int, int, int)>('socket');
final _close = _libc.lookupFunction<Int Function(Int), int Function(int)>('close');
final _sendto = _libc
    .lookupFunction<
      IntPtr Function(Int, Pointer<Uint8>, Size, Int, Pointer<Uint8>, Uint32),
      int Function(int, Pointer<Uint8>, int, int, Pointer<Uint8>, int)
    >('sendto');
final _recv = _libc.lookupFunction<IntPtr Function(Int, Pointer<Uint8>, Size, Int), int Function(int, Pointer<Uint8>, int, int)>('recv');
final _setsockopt = _libc
    .lookupFunction<Int Function(Int, Int, Int, Pointer<Uint8>, Uint32), int Function(int, int, int, Pointer<Uint8>, int)>('setsockopt');
final _kill = _libc.lookupFunction<Int Function(Int, Int), int Function(int, int)>('kill');

const _netlinkDeadline = Duration(seconds: 2);
const _netlinkMaxSockets = 200000;

/// (family, owner uid) of every listening TCP socket on [port], IPv4 and
/// IPv6, from the kernel (NETLINK_SOCK_DIAG, as `ss`). Only a dump the kernel
/// ended (NLMSG_DONE with error 0) counts; anything else returns null.
List<(int, int)>? listeners(int port) {
  final fd = _socket(16 /* AF_NETLINK */, 2 /* SOCK_DGRAM */ | 0x80000 /* CLOEXEC */, 4 /* SOCK_DIAG */);
  if (fd < 0) return null;
  final buffer = calloc<Uint8>(65536);
  final addr = calloc<Uint8>(12);
  final tv = calloc<Uint8>(16);
  try {
    ByteData.sublistView(addr.asTypedList(12)).setUint16(0, 16, Endian.host); // nl_family
    final deadline = DateTime.now().add(_netlinkDeadline);
    final found = <(int, int)>[];
    var seq = 0;
    for (final family in const [2 /* AF_INET */, 10 /* AF_INET6 */]) {
      seq++;
      // nlmsghdr + inet_diag_req_v2 (family, TCP, no extensions, LISTEN only).
      final req = ByteData(16 + 56);
      req.setUint32(0, 72, Endian.host);
      req.setUint16(4, 20 /* SOCK_DIAG_BY_FAMILY */, Endian.host);
      req.setUint16(6, 0x1 | 0x300 /* REQUEST|DUMP */, Endian.host);
      req.setUint32(8, seq, Endian.host);
      req.setUint8(16, family);
      req.setUint8(17, 6 /* IPPROTO_TCP */);
      req.setUint32(20, 1 << 10 /* TCP_LISTEN */, Endian.host);
      buffer.asTypedList(72).setAll(0, req.buffer.asUint8List());
      if (_sendto(fd, buffer, 72, 0, addr, 12) != 72) return null;
      var done = false, count = 0;
      while (!done) {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) return null;
        final t = ByteData.sublistView(tv.asTypedList(16));
        t.setInt64(0, left.inSeconds, Endian.host);
        t.setInt64(8, left.inMicroseconds % 1000000, Endian.host);
        if (_setsockopt(fd, 1 /* SOL_SOCKET */, 20 /* SO_RCVTIMEO */, tv, 16) != 0) return null;
        final n = _recv(fd, buffer, 65536, 0);
        if (n <= 0) return null;
        final data = ByteData.sublistView(Uint8List.fromList(buffer.asTypedList(n)));
        var offset = 0;
        while (offset + 16 <= n) {
          final length = data.getUint32(offset, Endian.host);
          final kind = data.getUint16(offset + 4, Endian.host);
          final flags = data.getUint16(offset + 6, Endian.host);
          final gotSeq = data.getUint32(offset + 8, Endian.host);
          if (length < 16 || offset + length > n || gotSeq != seq) return null;
          if (flags & 0x10 != 0) return null; // NLM_F_DUMP_INTR: may have missed sockets
          if (kind == 3) {
            // NLMSG_DONE: complete only with error 0.
            if (length < 20 || data.getInt32(offset + 16, Endian.host) != 0) return null;
            done = true;
            break;
          }
          if (kind != 20 || length < 16 + 72) return null;
          final msg = offset + 16;
          final sport = data.getUint16(msg + 4, Endian.big);
          final uid = data.getUint32(msg + 64, Endian.host);
          if (++count > _netlinkMaxSockets) return null;
          if (data.getUint8(msg + 1) == 10 && sport == port) found.add((family, uid));
          offset += (length + 3) & ~3;
        }
      }
    }
    return found;
  } finally {
    calloc.free(buffer);
    calloc.free(addr);
    calloc.free(tv);
    _close(fd);
  }
}

const systemUidMax = 999;

/// Whether every socket listening on [port] is this user's or a system
/// service's: null when nothing listens, false when another person's
/// account does or the kernel's list was not complete.
bool? portIsTrusted(int port, {List<(int, int)>? Function(int)? lister}) {
  final found = (lister ?? listeners)(port);
  if (found == null) return false;
  if (found.isEmpty) return null;
  final mine = Posix.instance.uid;
  return found.every((l) => l.$2 == mine || l.$2 <= systemUidMax);
}

Future<bool> _portOpen(String host, int port) async {
  try {
    final s = await Socket.connect(host, port, timeout: const Duration(milliseconds: 500));
    s.destroy();
    return true;
  } on Object {
    return false;
  }
}

/// One small JSON request to a loopback model server: HTTP/1.0, one 3 s
/// deadline for all of it, the reply capped at 1 MiB; null on any failure,
/// and when the port is not provably the user's own.
Future<Object?> localJson(String method, String host, int port, String path, [Object? body]) async {
  if (!localHosts.contains(host) || port <= 0 || port >= 65536) return null;
  if (portIsTrusted(port) != true) return null;
  final data = body == null ? const <int>[] : utf8.encode(jsonEncode(body));
  final head =
      '$method $path HTTP/1.0\r\nHost: $host\r\nAccept: application/json\r\n'
      '${body == null ? '' : 'Content-Type: application/json\r\nContent-Length: ${data.length}\r\n'}'
      'Connection: close\r\n\r\n';
  final reply = BytesBuilder(copy: false);
  Socket? socket;
  try {
    final work = () async {
      socket = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      socket!.add([...utf8.encode(head), ...data]);
      await for (final chunk in socket!) {
        reply.add(chunk);
        if (reply.length > 1024 * 1024) throw FormatException(tr("too large"));
      }
    }();
    await work.timeout(const Duration(seconds: 3));
  } on Object {
    socket?.destroy();
    return null;
  }
  socket?.destroy();
  final bytes = reply.takeBytes();
  var split = -1;
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
      split = i;
      break;
    }
  }
  if (split < 0) return null;
  final lines = latin1.decode(bytes.sublist(0, split)).split('\r\n');
  final status = lines.first.split(' ');
  if (status.length < 2 || !status[0].startsWith('HTTP/1.')) return null;
  final code = int.tryParse(status[1]);
  if (code == null || code >= 300) return null;
  var payload = bytes.sublist(split + 4);
  if (lines.skip(1).any((l) => l.toLowerCase().startsWith('transfer-encoding:') && l.toLowerCase().contains('chunked'))) {
    final un = unchunk(payload);
    if (un == null) return null;
    payload = un;
  }
  final text = utf8.decode(payload, allowMalformed: true);
  if (text.trim().isEmpty) return const {};
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

/// A chunked body, parsed by offsets with a chunk count cap; null if malformed.
Uint8List? unchunk(Uint8List payload, {int maxChunks = 4096}) {
  final out = BytesBuilder(copy: false);
  var pos = 0;
  for (var n = 0; n < maxChunks; n++) {
    var end = -1;
    for (var i = pos; i + 1 < payload.length; i++) {
      if (payload[i] == 13 && payload[i + 1] == 10) {
        end = i;
        break;
      }
    }
    if (end < 0) return null;
    final sizeText = latin1.decode(payload.sublist(pos, end)).split(';').first.trim();
    final size = int.tryParse(sizeText, radix: 16);
    if (size == null || size < 0) return null;
    if (size == 0) return out.takeBytes();
    final start = end + 2;
    if (payload.length < start + size + 2) return null;
    out.add(payload.sublist(start, start + size));
    pos = start + size + 2;
  }
  return null;
}

/// (kind, loaded?) of a local model on its server: "llama" (llama.cpp
/// router) or "ollama"; loaded null when it cannot be told.
Future<(String?, bool?)> localState(LocalModel m) async {
  final routed = await localJson('GET', m.host, m.port, '/models');
  if (routed is Map && routed['data'] is List && (routed['data'] as List).any((e) => e is Map && e.containsKey('status'))) {
    final entry = (routed['data'] as List).whereType<Map>().where((e) => e['id'] == m.model).firstOrNull;
    if (entry == null) return ('llama', null);
    final status = entry['status'];
    final value = status is Map ? status['value'] : status;
    return ('llama', value is String ? const {'loaded', 'loading', 'sleeping'}.contains(value) : null);
  }
  final running = await localJson('GET', m.host, m.port, '/api/ps');
  if (running is Map && running['models'] is List) {
    final names = {for (final e in (running['models'] as List).whereType<Map>()) '${e['name'] ?? e['model'] ?? ''}'};
    return ('ollama', names.contains(m.model) || names.contains('${m.model}:latest'));
  }
  return (null, null);
}

// --- running a helper -------------------------------------------------------------------

const passedEnv = [
  'PATH',
  'LANG',
  'LC_ALL',
  'LC_MESSAGES',
  'LC_CTYPE',
  'TERM',
  'USER',
  'LOGNAME',
  'TZ',
  'HTTPS_PROXY',
  'HTTP_PROXY',
  'NO_PROXY',
  'ALL_PROXY',
  'https_proxy',
  'http_proxy',
  'no_proxy',
  'all_proxy',
  'SSL_CERT_FILE',
  'SSL_CERT_DIR',
];

/// Only what an agent needs: no other provider's key, no session secrets.
Map<String, String> helperEnv(Helper h, Map<String, String> environment, String home) => {
  for (final k in passedEnv)
    if (environment[k] != null) k: environment[k]!,
  'HOME': home,
  for (final k in h.env)
    if ((environment[k] ?? '').isNotEmpty) k: environment[k]!,
};

/// The agent's real program (a mise shim needs mise's own writable state,
/// which the jail does not have).
Future<String?> realBinary(String command, Map<String, String> environment) async {
  final found = which(command, environment);
  if (found == null) return null;
  String real;
  try {
    real = File(found).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
  if (p.basename(real) == 'mise') {
    final mise = which('mise', environment);
    if (mise == null) return null;
    final out = (await readBoundedText(
      [mise, 'which', command],
      maxBytes: 4096,
      timeout: const Duration(seconds: 10),
      environment: environment,
    ))?.trim();
    if (out == null || out.isEmpty || !FileSystemEntity.isFileSync(out)) return null;
    return File(out).resolveSymbolicLinksSync();
  }
  return real;
}

/// argv inside bubblewrap: the system read-only, an empty home with only the
/// agent's own folders (new and empty, its sign-in bound in and written through),
/// the private work folder, the network; no session bus.
Future<List<String>> jailArgv(Helper h, List<String> argv, String work, String home, Map<String, String> environment) async {
  final binary = await realBinary(argv.first, environment);
  if (binary == null) throw AskError(tr("helper not found"));
  final bwrap = which('bwrap', environment);
  if (bwrap == null) throw AskError(tr("bubblewrap (bwrap) is needed for this helper"));
  final jail = h.jail!;
  final args = [
    bwrap,
    '--ro-bind',
    '/usr',
    '/usr',
    '--ro-bind',
    '/etc',
    '/etc',
    '--symlink',
    'usr/lib',
    '/lib',
    '--symlink',
    'usr/lib64',
    '/lib64',
    '--symlink',
    'usr/bin',
    '/bin',
    '--symlink',
    'usr/bin',
    '/sbin',
    '--unshare-pid',
    '--proc',
    '/proc',
    '--dev',
    '/dev',
    '--size',
    '$jailTmpfs',
    '--tmpfs',
    '/tmp',
    '--ro-bind-try',
    '/run/systemd/resolve',
    '/run/systemd/resolve',
    '--size',
    '$jailTmpfs',
    '--tmpfs',
    home,
    '--bind',
    work,
    work,
  ];
  if (p.isWithin(home, binary)) {
    // Its install folder (mise keeps every version under installs/); a
    // program right in the home folder is bound alone, never the home.
    final installs = p.join(home, '.local/share/mise/installs');
    var root = p.isWithin(installs, binary) ? installs : p.dirname(binary);
    if (p.equals(root, home) || p.isWithin(root, home)) root = binary;
    args.addAll(['--ro-bind', root, root]);
  }
  // Its own folders new and empty on the jail's home (a tmpfs): nothing of
  // the real ones (old sessions, config, MCP servers) is there to read.
  for (final name in jail.fresh) {
    args.addAll(['--perms', '0700', '--dir', p.join(home, name)]);
  }
  for (final name in jail.keep) {
    final path = p.join(home, name);
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file) {
      args.addAll(['--bind', path, path]);
    }
  }
  args.addAll(['--unsetenv', 'DBUS_SESSION_BUS_ADDRESS']);
  args.addAll(['--setenv', 'HOME', home, '--die-with-parent', '--new-session', '--chdir', work, '--', binary, ...argv.skip(1)]);
  return args;
}

/// Removes the Ask's private folder. overlayfs leaves its work folder
/// unreadable (mode 000), so `chmod -R u+rwx` gives the owner access back
/// first, then `rm -rf` removes it: separate processes (argv only; neither
/// follows a link inside the tree), each with a time limit, so a huge tree
/// never holds up the core. What is left after the limit stays in the temp
/// folder (never fatal).
Future<void> removeWork(String work) async {
  if (!work.startsWith('/') || FileSystemEntity.typeSync(work, followLinks: false) != FileSystemEntityType.directory) {
    return;
  }
  await runBounded(['chmod', '-R', 'u+rwx', '--', work], timeout: const Duration(seconds: 30));
  await runBounded(['rm', '-rf', '--', work], timeout: const Duration(seconds: 30));
}

/// All regular files in [folder] together (links not followed); too many
/// entries count as too large. Streamed one folder at a time, stopping at
/// [maxEntries]; an unreadable folder (overlayfs' work folder) is skipped.
Future<int> folderSize(String folder, {int maxEntries = 2000}) async {
  var total = 0, seen = 0;
  final stack = [folder];
  while (stack.isNotEmpty) {
    try {
      await for (final e in Directory(stack.removeLast()).list(followLinks: false)) {
        if (++seen > maxEntries) return workMax + 1;
        if (e is Directory) {
          stack.add(e.path);
        } else if (e is File) {
          try {
            total += (await e.stat()).size;
          } on FileSystemException {
            continue;
          }
        }
      }
    } on FileSystemException {
      continue;
    }
  }
  return total;
}

/// One Ask at a time: the agent in a private folder, bounded in time,
/// output and disk; local models' servers started and their loads tracked.
final class AskRunner {
  AskRunner({required this.home, required this.environment});
  final String home;
  final Map<String, String> environment;

  Process? _running;
  var _cancelled = false;
  bool get busy => _busy;
  var _busy = false;

  /// Models an Ask loaded: key -> server kind ("llama"/"ollama"), null
  /// while an Ask is still loading it.
  final owned = <String, (LocalModel, String?)>{};
  Future<void> _unloading = Future.value();

  void cancel() {
    _cancelled = true;
    final proc = _running;
    if (proc != null) _killGroup(proc);
  }

  static void _killGroup(Process proc) {
    if (_kill(-proc.pid, 9) != 0) proc.kill(ProcessSignal.sigkill);
  }

  /// One answer from [helperId] for [prompt]; throws [AskError].
  /// [web]: the helper may search and read the web (only helpers with web
  /// tools, see [Helper.web]); otherwise it has none.
  Future<String> run(String helperId, String prompt, {Duration timeout = askTimeout, bool web = false}) async {
    if (_busy) throw AskError(tr("another Ask is running"));
    _busy = true;
    _cancelled = false;
    try {
      final helper = helperFor(helperId);
      if (helper == null) throw AskError(tr("unknown helper"));
      final local = localModelOf(helperId, home);
      if (helper.id == 'pi' && helperId != 'pi' && local == null) throw AskError(tr("unknown helper"));
      final extra = <String>[];
      bool? before;
      if (local != null) {
        await _unloading; // an unload in flight ends first
        before = await _portOpen(local.host, local.port) ? (await localState(local)).$2 : false;
        if (before == false) owned.putIfAbsent(localKey(local), () => (local, null));
        try {
          await ensureLocalServer(local);
        } on AskError {
          await _remember(local, before);
          rethrow;
        }
        if (helper.id == 'pi') extra.addAll(['--offline', '--provider', local.provider, '--model', local.model]);
      }
      try {
        return await _runHelper(helper, extra, prompt, timeout, web: web && helper.web != null);
      } finally {
        if (local != null) await _remember(local, before);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _remember(LocalModel m, bool? before) async {
    if (before != false) return;
    final (kind, now) = await localState(m);
    final key = localKey(m);
    if (kind != null && now == true) {
      owned[key] = (m, kind);
    } else if (owned[key]?.$2 == null) {
      owned.remove(key); // it never loaded
    }
  }

  /// Unloads every model an Ask loaded, except [keep] (a localKey); a failed
  /// unload stays recorded and is tried again. Never during an Ask.
  Future<List<String>> release({String? keep}) {
    final done = <String>[];
    final job = _unloading.then((_) async {
      if (_busy) return;
      for (final e in owned.entries.toList()) {
        if (e.key == keep) continue;
        final m = e.value.$1;
        final kind = e.value.$2 ?? (await localState(m)).$1;
        final reply = switch (kind) {
          'llama' => await localJson('POST', m.host, m.port, '/models/unload', {'model': m.model}),
          'ollama' => await localJson('POST', m.host, m.port, '/api/generate', {'model': m.model, 'prompt': '', 'keep_alive': 0}),
          _ => null,
        };
        if (reply != null) {
          owned.remove(e.key);
          done.add(e.key);
        }
      }
    });
    _unloading = job.catchError((_) {});
    return job.then((_) => done, onError: (_) => done);
  }

  /// The model's server answers and is the user's (or a system service's),
  /// or its user unit is started and waited for (up to a minute).
  Future<void> ensureLocalServer(LocalModel m, {Duration wait = const Duration(seconds: 60)}) async {
    if (await _portOpen(m.host, m.port)) {
      if (portIsTrusted(m.port) != true) throw AskError(trf("port {0} is not your model server: not used", [m.port]));
      return;
    }
    final unit = localUnits[m.port];
    final systemctl = which('systemctl', environment);
    if (unit == null || systemctl == null) throw AskError(trf("the local model server ({0}) is not running", [m.provider]));
    final (code, _) = await runBounded(
      [systemctl, '--user', 'start', '--no-block', unit],
      timeout: const Duration(seconds: 10),
      environment: environment,
    );
    if (code == null) throw AskError(trf("could not start {0}", [unit]));
    final end = DateTime.now().add(wait);
    while (DateTime.now().isBefore(end)) {
      if (_cancelled) throw AskError('cancelled');
      if (await _portOpen(m.host, m.port)) {
        if (portIsTrusted(m.port) != true) throw AskError(trf("port {0} is not your model server: not used", [m.port]));
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw AskError(trf("{0} did not answer", [unit]));
  }

  Future<String> _runHelper(Helper helper, List<String> extra, String prompt, Duration timeout, {bool web = false}) async {
    final setsid = which('setsid', environment), prlimit = which('prlimit', environment);
    if (setsid == null || prlimit == null) throw AskError(tr("setsid and prlimit (util-linux) are needed"));
    final binary = which(helper.argv.first, environment);
    if (binary == null) throw AskError(tr("not installed"));
    final work = Directory.systemTemp.createTempSync('maprisma-manager-ask-').path;
    chmodPath(work, 448);
    final answerFile = p.join(work, 'answer.txt');
    Process? process;
    try {
      var argv = [for (final a in helper.argv) a == '{answer}' ? answerFile : a, ...extra];
      if (web) argv = withWebTools(helper, argv);
      if (helper.jail != null) {
        argv = await jailArgv(helper, argv, work, home, environment);
      } else {
        argv = [binary, ...argv.skip(1)];
      }
      // Its own process group (setsid execs it, so pid = group), and a hard
      // cap on every file it writes, inherited by all it starts.
      final full = [setsid, prlimit, '--fsize=$agentFileMax:$agentFileMax', '--', ...argv];
      if (_cancelled) throw AskError('cancelled');
      process = _running = await Process.start(
        full.first,
        full.sublist(1),
        workingDirectory: work,
        environment: helperEnv(helper, environment, home),
        includeParentEnvironment: false,
      );
      final proc = process;
      final out = BytesBuilder(copy: false);
      var errTail = <int>[];
      var errBytes = 0;
      var tooLong = false;
      final outDone = proc.stdout
          .listen((chunk) {
            if (out.length + chunk.length > maxAnswerBytes) {
              tooLong = true;
              _killGroup(proc);
            } else {
              out.add(chunk);
            }
          })
          .asFuture<void>()
          .catchError((_) {});
      final errDone = proc.stderr
          .listen((chunk) {
            errBytes += chunk.length;
            if (errBytes > maxAnswerBytes) {
              tooLong = true;
              _killGroup(proc);
              return;
            }
            errTail = [...errTail, ...chunk];
            if (errTail.length > 4096) errTail = errTail.sublist(errTail.length - 4096);
          })
          .asFuture<void>()
          .catchError((_) {});
      proc.stdin.done.ignore();
      try {
        proc.stdin.add(utf8.encode(prompt));
      } on Object {
        // it went away; its exit code says how
      }
      unawaited(proc.stdin.close().catchError((_) {}));
      int? code;
      unawaited(proc.exitCode.then((c) => code = c));
      final started = DateTime.now();
      while (code == null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (code != null) break;
        if (_cancelled) {
          _killGroup(proc);
          await proc.exitCode;
          throw AskError('cancelled');
        }
        if (DateTime.now().difference(started) > timeout) {
          _killGroup(proc);
          await proc.exitCode;
          throw AskError(tr("no answer in time"));
        }
        if (tooLong || _fileSize(answerFile) > maxAnswerBytes || await folderSize(work) > workMax) {
          _killGroup(proc);
          await proc.exitCode;
          throw AskError(tr("the answer is too long"));
        }
      }
      // Leftovers of its group (anything it started) go too.
      _kill(-proc.pid, 9);
      await outDone.timeout(const Duration(seconds: 2), onTimeout: () {});
      await errDone.timeout(const Duration(seconds: 2), onTimeout: () {});
      if (_cancelled) throw AskError('cancelled');
      if (tooLong || _fileSize(answerFile) > maxAnswerBytes) throw AskError(tr("the answer is too long"));
      String text;
      if (FileSystemEntity.typeSync(answerFile, followLinks: false) != FileSystemEntityType.notFound) {
        final bytes = Posix.instance.readRegular(answerFile, maxAnswerBytes, follow: false);
        if (bytes == null) throw AskError(tr("the answer file is not a regular file within the size limit"));
        text = utf8.decode(bytes, allowMalformed: true);
      } else {
        text = utf8.decode(out.takeBytes(), allowMalformed: true);
      }
      if (code != 0 && text.trim().isEmpty) {
        var tail = utf8.decode(errTail, allowMalformed: true).trim();
        if (tail.length > 400) tail = tail.substring(tail.length - 400);
        throw AskError(tail.isEmpty ? trf('exit {0}', [code]) : tail);
      }
      return text;
    } on ProcessException catch (e) {
      throw AskError(e.message);
    } finally {
      final proc = process;
      if (proc != null) _kill(-proc.pid, 9); // whatever went wrong, the agent does not outlive the Ask
      _running = null;
      await removeWork(work);
    }
  }

  static int _fileSize(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 0;
    if (type != FileSystemEntityType.file) return maxAnswerBytes + 1; // replaced by a link or folder
    try {
      return File(path).lengthSync();
    } on FileSystemException {
      return maxAnswerBytes + 1;
    }
  }
}
