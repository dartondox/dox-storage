import 'dart:io';

import 'package:dox_annotation/install.dart';
import 'package:dox_storage/commands.dart';
import 'package:test/test.dart';

/// records the `dart` commands, runs nothing
class FakeRunner extends ProcessRunner {
  final List<String> calls = <String>[];

  @override
  Future<int> run(String executable, List<String> args, String folder) async {
    calls.add(args.join(' '));
    return 0;
  }
}

const String envDart = '''
abstract class AppEnv {
  // keep this comment
  String get appName => 'dox';
}
''';

void main() {
  late Directory root;
  late FakeRunner runner;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dox_storage_install_');
    File(
      '${root.path}/pubspec.yaml',
    ).writeAsStringSync('name: my_app\n\ndependencies:\n  dox_core: ^3.1.0\n');
    File('${root.path}/.env').writeAsStringSync('APP_KEY=x\n');
    File('${root.path}/lib/config/env.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync(envDart);
    runner = FakeRunner();
    exitCode = 0;
  });

  tearDown(() {
    exitCode = 0;
    root.deleteSync(recursive: true);
  });

  String read(String path) => File('${root.path}/$path').readAsStringSync();

  Future<void> install(List<String> args) {
    return StorageInstallCommand(root: root, runner: runner).run(args);
  }

  /// every file of the app and its text
  Map<String, String> snapshot() {
    Map<String, String> files = <String, String>{};
    for (FileSystemEntity f in root.listSync(recursive: true)) {
      if (f is File) files[f.path] = f.readAsStringSync();
    }
    return files;
  }

  test('sets up the local disk by default', () async {
    await install(<String>[]);
    expect(exitCode, 0);
    expect(runner.calls, <String>[
      'pub add dox_storage',
      'run build_runner build',
    ]);
    expect(
      read('lib/config/storage.dart'),
      contains("import 'package:my_app/config/env.dart';"),
    );
    expect(read('lib/config/storage.dart'), isNot(contains("'s3'")));
    expect(
      read('lib/providers/storage_provider.dart'),
      contains("import 'package:my_app/config/storage.dart';"),
    );
    expect(Directory('${root.path}/storage').existsSync(), isTrue);
    expect(read('.env'), contains('STORAGE_DISK=local\n'));
    expect(read('.env'), isNot(contains('AWS_')));
    expect(read('lib/config/env.dart'), contains("storageDisk => 'local'"));
    expect(read('lib/config/env.dart'), contains('// keep this comment'));
  });

  test('s3 adds its disk, getters and keys', () async {
    await install(<String>['--disk=s3']);
    expect(exitCode, 0);
    expect(read('lib/config/storage.dart'), contains("'driver': 's3'"));
    expect(read('lib/config/env.dart'), contains('String? get awsBucket;'));
    expect(read('.env'), contains('STORAGE_DISK=s3\n'));
    expect(read('.env'), contains('AWS_DEFAULT_REGION=us-east-1\n'));
    expect(read('.env'), contains('AWS_BUCKET=\n'));
  });

  test('a second run changes nothing', () async {
    await install(<String>['--disk', 's3']);
    File('${root.path}/lib/config/storage.dart').writeAsStringSync('mine');
    Map<String, String> before = snapshot();
    await install(<String>['--disk=local']);
    expect(snapshot(), before);
  });

  test('a bad option stops with exit code 1 and writes nothing', () async {
    for (List<String> args in <List<String>>[
      <String>['--disk=gcs'],
      <String>['--dsk=s3'],
      <String>['--disk'],
      <String>['--disk='],
      <String>['s3'],
    ]) {
      Map<String, String> before = snapshot();
      await install(args);
      expect(exitCode, 1, reason: '$args');
      expect(runner.calls, isEmpty, reason: '$args');
      expect(snapshot(), before, reason: '$args');
      exitCode = 0;
    }
  });

  test(
    'without AppEnv it gives a hint, exit code 1, and changes nothing',
    () async {
      for (String? env in <String?>[null, 'class Other {\n}\n']) {
        File file = File('${root.path}/lib/config/env.dart');
        if (env == null) {
          file.deleteSync();
        } else {
          file.writeAsStringSync(env);
        }
        Map<String, String> before = snapshot();
        await install(<String>[]);
        expect(exitCode, 1);
        expect(runner.calls, isEmpty);
        expect(snapshot(), before);
        exitCode = 0;
      }
    },
  );
}
