import 'dart:convert';

import 'package:dox_core/dox_core.dart';

import '../drive_manager.dart';
import '../driver_contract.dart';
import '../drivers/local_driver.dart';
import '../drivers/memory_driver.dart';
import '../drivers/s3/s3_driver.dart';
import '../drivers/s3/s3_driver_config.dart';
import '../types.dart';

/// Storage disks for `Storage()`.
///
/// Each disk is a map of options with a `driver` key, so the config can be
/// sent to every isolate. Drivers: `local`, `s3` and `memory`.
/// ```
/// StorageConfig(
///   defaultDisk: 'local',
///   disks: {
///     'local': {'driver': 'local', 'root': 'storage', 'url': 'http://localhost:3000/files'},
///     's3': {'driver': 's3', 'bucket': 'my-bucket', 'region': 'us-east-1',
///            'key': '...', 'secret': '...'},
///     'memory': {'driver': 'memory'},
///   },
/// );
/// ```
class StorageConfig {
  /// Disk used by `Storage()` when no disk is given.
  final String defaultDisk;

  /// Disk name to options.
  final Map<String, Map<String, dynamic>> disks;

  const StorageConfig({
    this.defaultDisk = 'local',
    this.disks = const <String, Map<String, dynamic>>{
      'local': <String, dynamic>{'driver': 'local', 'root': 'storage'},
    },
  });
}

/// Builds a `dox_storage` [DriveManager] from a [StorageConfig].
class StorageDiskFactory {
  /// [appKey] signs local URLs when a disk has no `app_key` option.
  const StorageDiskFactory({this.appKey});

  /// A factory for the Dox app. Local URLs are signed with a key made
  /// from `APP_KEY` for signed URLs only (see [KeyDerivation]), not with
  /// `APP_KEY` itself.
  factory StorageDiskFactory.fromApp() {
    return StorageDiskFactory(
      appKey: base64.encode(KeyDerivation.forAppKey(KeyDerivation.signedUrl)),
    );
  }

  final String? appKey;

  /// A manager with one disk for each entry of [config].
  DriveManager create(StorageConfig config) {
    DriveManager manager = DriveManager(defaultDisk: config.defaultDisk);
    config.disks.forEach((String name, Map<String, dynamic> options) {
      manager.register(name, driver(name, options));
    });
    return manager;
  }

  /// One driver from its options.
  DriverContract driver(String name, Map<String, dynamic> options) {
    String? type = options['driver'] as String?;
    switch (type) {
      case 'local':
        return LocalDriver(
          LocalDriverConfig(
            root: options['root'] as String? ?? 'storage',
            disk: name,
            atomicWrites: options['atomic_writes'] == true,
            urlBase: _text(options['url']),
            appKey: _text(options['app_key']) ?? _text(appKey),
            visibility: _visibility(options['visibility'], Visibility.public),
            permissions: _permissions(options['permissions']),
          ),
        );
      case 's3':
        return S3Driver(
          S3DriverConfig(
            bucket: _required(name, options, 'bucket'),
            region: options['region'] as String? ?? 'us-east-1',
            accessKeyId: _required(name, options, 'key'),
            secretAccessKey: _required(name, options, 'secret'),
            sessionToken: _text(options['token']),
            endpoint: _text(options['endpoint']),
            forcePathStyle: options['path_style'] as bool? ?? false,
            urlBase: _text(options['url']),
            visibility: _visibility(options['visibility'], Visibility.private),
            supportsAcl: options['acl'] as bool? ?? true,
            supportsBatchDelete: options['batch_delete'] as bool? ?? true,
          ),
        );
      case 'memory':
        return MemoryDriver();
    }
    throw ArgumentError('Storage disk "$name" has unknown driver "$type"');
  }

  /// a setting the driver can not work without.
  /// a missing or empty value fails with a clear message.
  String _required(String name, Map<String, dynamic> options, String key) {
    String? value = _text(options[key]);
    if (value == null) {
      throw ArgumentError(
        'Storage disk "$name" needs the "$key" setting. It is missing or empty.',
      );
    }
    return value;
  }

  String? _text(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }

  /// `true` turns on the Laravel modes. A map in the Laravel shape,
  /// `{'file': {'public': 0x1a4, 'private': 0x180}, 'dir': {...}}`,
  /// changes them. Anything else leaves it off.
  LocalPermissions? _permissions(Object? value) {
    if (value == true) return const LocalPermissions();
    if (value is! Map) return null;
    const LocalPermissions base = LocalPermissions();
    Object? file = value['file'];
    Object? dir = value['dir'];
    LocalPermissions modes = LocalPermissions(
      filePublic: _mode(file, 'public', base.filePublic),
      filePrivate: _mode(file, 'private', base.filePrivate),
      dirPublic: _mode(dir, 'public', base.dirPublic),
      dirPrivate: _mode(dir, 'private', base.dirPrivate),
    );
    modes.check();
    return modes;
  }

  /// A mode from the `permissions` map. A value that is not an int, like
  /// the string `'0644'`, throws [ArgumentError]. The range (0 to 0o777)
  /// is checked by [LocalPermissions.check].
  int _mode(Object? group, String name, int fallback) {
    if (group is! Map || !group.containsKey(name)) return fallback;
    Object? mode = group[name];
    if (mode is! int) {
      throw ArgumentError.value(
        mode,
        'permissions',
        'a mode must be an int, like 0x1a4 for 0644',
      );
    }
    return mode;
  }

  Visibility _visibility(Object? value, Visibility fallback) {
    if (value == 'public') return Visibility.public;
    if (value == 'private') return Visibility.private;
    return fallback;
  }
}
