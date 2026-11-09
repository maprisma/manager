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
  Receipt({required this.id, required this.at, required this.inputs, required this.paths, required this.displaced, this.version});

  final String id;
  final DateTime at;
  final String? version;
  final List<ReceiptInput> inputs;
  final List<Map<String, dynamic>> paths;
  final List<Map<String, dynamic>> displaced;

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
      if (i is! Map || i['repo'] is! String || (i['commit'] != null && i['commit'] is! String) || i['dirty'] is! bool) {
        throw const FormatException('inputs entry');
      }
      inputs.add(ReceiptInput(i['repo'], i['commit'], i['dirty'], i['fingerprint'] is String ? i['fingerprint'] : null));
    }
    List<Map<String, dynamic>> maps(String key) {
      final v = data[key] ?? const [];
      if (v is! List || v.any((e) => e is! Map || e['path'] is! String)) throw FormatException(key);
      return [for (final e in v) Map<String, dynamic>.from(e as Map)];
    }

    return Receipt(
      id: id,
      at: at,
      version: data['version'] is String ? data['version'] : null,
      inputs: inputs,
      paths: maps('paths'),
      displaced: maps('displaced'),
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
