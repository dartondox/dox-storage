import 'package:dox_core/dox_core.dart';

import 'storage.dart';
import 'storage_config.dart';

/// Sets up the disks of `Storage()` in every isolate. Extend it in `lib/`
/// so the generated container finds it:
/// ```
/// class AppStorageService extends StorageService {
///   AppStorageService() : super(storageConfig);
/// }
/// ```
/// Without it, `Storage()` has one `local` disk in the `storage` folder.
class StorageService implements DoxService {
  StorageService(this.config);

  final StorageConfig config;

  @override
  void setup() {
    Storage.manager = StorageDiskFactory(appKey: Dox().config.appKey)
        .create(config);
  }
}

/// `file.store(folder)` on an uploaded file.
extension RequestFileStore on RequestFile {
  /// store the file on the default disk, with a new uuid file name.
  /// returns its path.
  /// ```
  /// RequestFile image = req.input('image');
  /// String path = await image.store('images');
  /// ```
  Future<String> store(String folder) {
    return Storage().putRequestFile(folder, this);
  }
}
