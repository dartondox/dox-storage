import 'dart:io';

import 'package:dox_annotation/install.dart';
import 'package:dox_core/command.dart';

/// `dox storage:install [--disk=local|s3]`. `dox add storage` runs it. It
/// sets up the storage config, the provider, the `storage` folder and the
/// `.env` keys. It never overwrites a file, so it is safe to run twice.
class StorageInstallCommand extends Command {
  /// [root] is the app folder (the current folder by default). [runner]
  /// runs `dart`, tests pass a fake one.
  StorageInstallCommand({this.root, this.runner});

  final Directory? root;
  final ProcessRunner? runner;

  static const List<String> disks = <String>['local', 's3'];

  @override
  String get name => 'storage:install';

  @override
  String get description => 'Set up file storage in this app';

  @override
  String get usage => 'storage:install [--disk=local|s3]';

  @override
  Future<void> run(List<String> args) async {
    String? disk = _disk(args);
    if (disk == null) {
      print(
        'Unknown option. Use --disk=local or --disk=s3 '
        '(local when not given).',
      );
      exitCode = 1;
      return;
    }
    Installer installer = Installer(root: root, runner: runner);
    String app = installer.appName;

    /// first, so an app without the AppEnv class gets the hint and
    /// nothing else is changed
    for (String getter in envGetters(disk)) {
      installer.addEnvGetter(getter);
    }
    if (!installer.ok) {
      installer.printSummary(<String>[
        'lib/config/env.dart has no `abstract class AppEnv`. Run '
            '`dox env:generate` to make it, then run this again.',
      ]);
      return;
    }

    await installer.addDependency('dox_storage');

    installer.writeFile('lib/config/storage.dart', storageConfig(app, disk));
    installer.writeFile(
      'lib/providers/storage_provider.dart',
      storageProvider(app),
    );
    installer.makeFolder('storage');

    Map<String, String> keys = envKeys(disk);
    for (String key in keys.keys) {
      installer.addEnv(key, keys[key]!);
    }

    await installer.buildRunner();
    String config = File('${installer.root.path}/lib/config/storage.dart')
        .readAsStringSync();
    installer.printSummary(<String>[
      if (disk == 's3')
        'Fill in AWS_BUCKET, AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in '
            '.env (and AWS_ENDPOINT for R2, MinIO or Spaces). A key that was '
            'already there is not changed.',
      if (!config.contains("'driver': '$disk'"))
        "lib/config/storage.dart has no '$disk' disk. Add one, see the "
            'file storage docs.',
      if (disk != 'local')
        'Check STORAGE_DISK=$disk in .env. A key that was already there is '
            'not changed.',
      'Save a file: `await Storage().put(...)`. See the file storage docs.',
    ]);
  }

  /// the value of `--disk=x` or `--disk x`, local when not given. Null for
  /// an unknown option, a missing value or an unknown disk.
  String? _disk(List<String> args) {
    String disk = 'local';
    for (int i = 0; i < args.length; i++) {
      if (args[i].startsWith('--disk=')) {
        disk = args[i].substring('--disk='.length);
      } else if (args[i] == '--disk' && i + 1 < args.length) {
        disk = args[++i];
      } else {
        return null;
      }
    }
    return disks.contains(disk) ? disk : null;
  }

  /// the getters of `AppEnv` that `lib/config/storage.dart` reads
  static List<String> envGetters(String disk) {
    return <String>[
      '/// local, s3 or memory\n'
          "  String get storageDisk => 'local';",
      if (disk == 's3') ...<String>[
        'String? get awsBucket;',
        "String get awsDefaultRegion => 'us-east-1';",
        'String? get awsAccessKeyId;',
        'String? get awsSecretAccessKey;',
        '/// R2, MinIO or Spaces. Null for AWS.\n'
            '  String? get awsEndpoint;',
      ],
    ];
  }

  /// the `.env` keys of [disk]
  static Map<String, String> envKeys(String disk) {
    return <String, String>{
      'STORAGE_DISK': disk,
      if (disk == 's3') ...<String, String>{
        'AWS_BUCKET': '',
        'AWS_DEFAULT_REGION': 'us-east-1',
        'AWS_ACCESS_KEY_ID': '',
        'AWS_SECRET_ACCESS_KEY': '',
        'AWS_ENDPOINT': '',
      },
    };
  }

  /// `lib/config/storage.dart`, the same as the app template. The `s3`
  /// disk is added when [disk] is `s3`.
  static String storageConfig(String app, String disk) {
    return '''
import 'package:dox_storage/dox_storage.dart';
import 'package:$app/config/env.dart';

/// Storage disks
/// -------------------------------
/// `Storage()` uses the default disk. `Storage().disk('local')` picks one.
/// Drivers: local, s3 (also R2, MinIO, Spaces), memory.
StorageConfig storageConfig = StorageConfig(
  defaultDisk: env.storageDisk,
  disks: <String, Map<String, dynamic>>{
    /// files in the `storage` folder
    'local': <String, dynamic>{'driver': 'local', 'root': 'storage'},
${disk == 's3' ? _s3Disk : ''}  },
);
''';
  }

  static const String _s3Disk = '''

    /// only when AWS_BUCKET is set
    if (env.awsBucket != null)
      's3': <String, dynamic>{
        'driver': 's3',
        'bucket': env.awsBucket,
        'region': env.awsDefaultRegion,
        'key': env.awsAccessKeyId,
        'secret': env.awsSecretAccessKey,
        'endpoint': env.awsEndpoint, // R2, MinIO, Spaces
      },
''';

  /// `lib/providers/storage_provider.dart`, the same as the app template
  static String storageProvider(String app) {
    return '''
import 'package:$app/config/storage.dart';
import 'package:dox_storage/dox_storage.dart';

/// Storage provider
/// --------------------------
/// Sets up the storage disks from config/storage.dart.
/// If this project does not store files, delete this file
/// (Dox finds every DoxProvider class, see lib/generated/container.g.dart).
class AppStorageProvider extends StorageProvider {
  AppStorageProvider() : super(storageConfig);
}
''';
  }
}
