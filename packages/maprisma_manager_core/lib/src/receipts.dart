import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'paths.dart';

/// One input repo as it was built.
final class ReceiptInput {
  ReceiptInput(this.repo, this.commit, this.dirty, this.fingerprint);
  final String repo;
  final String? commit;
  final bool dirty;

  /// A content hash of the working tree when it was dirty (step 3 decides its recipe).
  final String? fingerprint;

  Map<String, dynamic> toJson() => {'repo': repo, 'commit': commit, 'dirty': dirty, if (fingerprint != null) 'fingerprint': fingerprint};
}

/// What an install through the Manager recorded (plan: "Ownership"):
/// `~/.local/state/maprisma-manager/installed/<id>.json`
/// `{"schema":1, "id", "at", "version"?, "inputs":[{repo, commit, dirty, fingerprint?}],
///   "paths":[{path, sha256} | {path, link} | {path, dir:true}], "displaced":[{path, backup}]}`.
/// Read here only; written by the job engine (step 3).
final class Receipt {
  Receipt({required this.id, required this.at, required this.inputs, required this.paths, required this.displaced, this.version, this.source});

  final String id;
  final DateTime at;
  final String? version;
  final List<ReceiptInput> inputs;
  final List<Map<String, dynamic>> paths;
  final List<Map<String, dynamic>> displaced;

  /// How it was built: `{kind: folder}` or `{kind: release, tag, asset, sha256, url?}`; null in
  /// receipts from before step 4b (= folder).
  final Map<String, dynamic>? source;

  bool get fromRelease => source?['kind'] == 'release';

  ReceiptInput? input(String repo) {
    for (final i in inputs) {
      if (i.repo == repo) return i;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    if (version != null) 'version': version,
    'inputs': [for (final i in inputs) i.toJson()],
    'paths': paths.length,
    'displaced': displaced.length,
    if (source != null) 'source': source,
  };

  static Receipt parse(String id, Object? data) {
    if (data is! Map) throw const FormatException('not an object');
    if (data['id'] != id) throw const FormatException('id does not match the file');
    final at = data['at'] is String ? DateTime.tryParse(data['at']) : null;
    if (at == null) throw const FormatException('at');
    final rawInputs = data['inputs'];
    if (rawInputs is! List || rawInputs.isEmpty) throw const FormatException('inputs');
    final inputs = <ReceiptInput>[];
    for (final i in rawInputs) {
      if (i is! Map || !_nonEmpty(i['repo']) || !_isCommit(i['commit']) || i['dirty'] is! bool) {
        throw const FormatException('inputs entry');
      }
      if (i['fingerprint'] != null && !_nonEmpty(i['fingerprint'])) throw const FormatException('fingerprint');
      if (inputs.any((x) => x.repo == i['repo'])) throw const FormatException('duplicate input');
      inputs.add(ReceiptInput(i['repo'], i['commit'], i['dirty'], i['fingerprint']));
    }
    List<Map<String, dynamic>> maps(String key, bool Function(Map e) valid) {
      final v = data[key] ?? const [];
      if (v is! List || v.any((e) => e is! Map || !_nonEmpty(e['path']) || !valid(e))) throw FormatException(key);
      return [for (final e in v) Map<String, dynamic>.from(e as Map)];
    }

    // Each owned path is exactly one of: a file with its hash, a link with its target, a folder.
    bool owned(Map e) {
      final kinds = [
        if (e.containsKey('sha256')) e['sha256'] is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(e['sha256']),
        if (e.containsKey('link')) _nonEmpty(e['link']),
        if (e.containsKey('dir')) e['dir'] == true,
      ];
      return kinds.length == 1 && kinds.single;
    }

    final rawSource = data['source'];
    Map<String, dynamic>? source;
    if (rawSource != null) {
      if (rawSource is! Map) throw const FormatException('source');
      final kind = rawSource['kind'];
      if (kind == 'release') {
        if (!_nonEmpty(rawSource['tag']) || !_nonEmpty(rawSource['asset']) ||
            rawSource['sha256'] is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(rawSource['sha256'])) {
          throw const FormatException('source');
        }
      } else if (kind != 'folder') {
        throw const FormatException('source.kind');
      }
      source = Map<String, dynamic>.from(rawSource);
    }
    return Receipt(
      id: id,
      source: source,
      at: at,
      version: data['version'] is String ? data['version'] : null,
      inputs: inputs,
      paths: maps('paths', owned),
      displaced: maps('displaced', (e) => _nonEmpty(e['backup'])),
    );
  }
}

/// The receipt, null when there is none; a broken one is reported, never trusted.
({Receipt? receipt, String? error}) readReceipt(Paths paths, String id) {
  final f = File(p.join(paths.receipts, '$id.json'));
  if (!f.existsSync()) return (receipt: null, error: null);
  try {
    return (receipt: Receipt.parse(id, jsonDecode(f.readAsStringSync())), error: null);
  } on FormatException catch (e) {
    return (receipt: null, error: 'invalid receipt: ${e.message}');
  } on FileSystemException catch (e) {
    return (receipt: null, error: 'unreadable receipt: ${e.osError?.message ?? e.message}');
  }
}

bool _nonEmpty(Object? v) => v is String && v.isNotEmpty;
bool _isCommit(Object? v) => v is String && RegExp(r'^[0-9a-f]{40}([0-9a-f]{24})?$').hasMatch(v);
