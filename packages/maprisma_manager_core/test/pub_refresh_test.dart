import 'dart:convert';
import 'dart:io';

import 'package:maprisma_manager_core/src/pub_refresh.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('pub_refresh_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A fake Flutter SDK: bin/flutter (executable) and packages/flutter.
  String sdk(String name) {
    final root = p.join(tmp.path, name);
    Directory(p.join(root, 'packages', 'flutter')).createSync(recursive: true);
    final exe = File(p.join(root, 'bin', 'flutter'))..createSync(recursive: true);
    Process.runSync('chmod', ['+x', exe.path]);
    return root;
  }

  String pkg(String rel, {String pubspec = 'name: x\n', Map<String, dynamic>? config}) {
    final dir = p.join(tmp.path, 'app', rel);
    File(p.join(dir, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync(pubspec);
    if (config != null) {
      File(p.join(dir, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(config));
    }
    return dir;
  }

  test('finds packages, skips build output and hidden folders', () {
    pkg('.');
    pkg('flutter_app');
    pkg('packages/core');
    pkg('flutter_app/build/x');
    pkg('.hidden/y');
    expect(dartPackages(p.join(tmp.path, 'app')).map((d) => p.relative(d, from: p.join(tmp.path, 'app'))),
        ['.', 'flutter_app', 'packages/core']);
  });

  test('flutter root of an executable, through a link', () {
    final root = sdk('flutter');
    expect(flutterRootOf(p.join(root, 'bin', 'flutter')), Directory(root).resolveSymbolicLinksSync());
    final link = Link(p.join(tmp.path, 'flutter-link'))..createSync(p.join(root, 'bin', 'flutter'));
    expect(flutterRootOf(link.path), Directory(root).resolveSymbolicLinksSync());
    // a wrapper script with no SDK around it
    final wrapper = File(p.join(tmp.path, 'usr', 'bin', 'flutter'))..createSync(recursive: true);
    expect(flutterRootOf(wrapper.path), isNull);
    expect(flutterRootOf(null), isNull);
  });

  test('a cache that fits, or none yet, needs nothing', () {
    final ours = sdk('flutter');
    final root = flutterRootOf(p.join(ours, 'bin', 'flutter'));
    expect(stalePackageCache(pkg('none'), root), isNull);
    final fits = pkg('fits', config: {
      'flutterRoot': Uri.directory(ours).toString(),
      'packages': [
        {'name': 'flutter', 'rootUri': Uri.directory(p.join(ours, 'packages', 'flutter')).toString()},
        {'name': 'x', 'rootUri': '../'},
      ],
    });
    expect(stalePackageCache(fits, root), isNull);
    // a plain Dart package has no flutterRoot
    expect(stalePackageCache(pkg('dart', config: {'packages': []}), root), isNull);
  });

  test('a cache from a Flutter that is gone or another one', () {
    final ours = sdk('flutter');
    final other = sdk('other');
    final root = flutterRootOf(p.join(ours, 'bin', 'flutter'));
    final gone = pkg('gone', config: {'flutterRoot': 'file:///nowhere/.cache/flutter_sdk', 'packages': []});
    expect(stalePackageCache(gone, root), contains('/nowhere/.cache/flutter_sdk'));
    expect(stalePackageCache(gone, null), isNotNull, reason: 'gone is gone, whatever Flutter we have');
    final another = pkg('another', config: {'flutterRoot': Uri.directory(other).toString(), 'packages': []});
    expect(stalePackageCache(another, root), contains(other));
    expect(stalePackageCache(another, null), isNull, reason: 'our own root unknown: no comparison');
  });

  test('a package folder that is gone, or an unreadable cache', () {
    final missing = pkg('missing', config: {
      'packages': [
        {'name': 'y', 'rootUri': 'file:///nowhere/.pub-cache/hosted/pub.dev/y-1.0.0'},
      ],
    });
    expect(stalePackageCache(missing, null), contains('y-1.0.0'));
    final bad = pkg('bad');
    File(p.join(bad, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{not json');
    expect(stalePackageCache(bad, null), isNotNull);
  });

  test('workspace members and Flutter packages are told apart', () {
    expect(isWorkspaceMember(pkg('member', pubspec: 'name: m\nresolution: workspace\n')), isTrue);
    expect(isWorkspaceMember(pkg('plain')), isFalse);
    expect(usesFlutter(pkg('fl', pubspec: 'name: f\ndependencies:\n  flutter:\n    sdk: flutter\n')), isTrue);
    expect(usesFlutter(pkg('dt')), isFalse);
  });
}
