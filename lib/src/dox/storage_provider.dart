import 'package:dox_core/dox_core.dart';

import 'storage.dart';
import 'storage_config.dart';

/// Sets up the disks of `Storage()` in every isolate. Extend it in `lib/`
/// so the generated container finds it:
/// ```
/// class AppStorageProvider extends StorageProvider {
///   AppStorageProvider() : super(storageConfig);
/// }
/// ```
/// Without it, `Storage()` has one `local` disk in the `storage` folder.
class StorageProvider extends DoxProvider {
  StorageProvider(this.config);

  final StorageConfig config;

  @override
  void setup() {
    Storage.manager = StorageDiskFactory.fromApp().create(config);
  }
}

/// `file.store(folder)` on an uploaded file.
extension RequestFileStore on RequestFile {
  /// store the file with a new uuid file name and return its path.
  /// [disk] picks the disk. without it, the default disk is used.
  /// ```
  /// RequestFile image = req.input('image');
  /// String path = await image.store('images');
  /// String path = await image.store('images', disk: 's3');
  /// ```
  Future<String> store(String folder, {String? disk}) {
    return _storage(disk).putFile(folder, this);
  }

  /// store the file with the given [name] and return its path.
  /// an old file with the same name is replaced.
  /// do not pass the raw client file name. make your own name, like
  /// `user-1.png`. a name like `../x.png` throws [InvalidKeyException].
  /// ```
  /// String path = await image.storeAs('avatars', 'user-1.png');
  /// ```
  Future<String> storeAs(String folder, String name, {String? disk}) {
    return _storage(disk).putFileAs(folder, this, name);
  }

  Storage _storage(String? disk) {
    return disk == null ? Storage() : Storage().disk(disk);
  }
}
