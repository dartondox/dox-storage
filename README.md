# dox_storage

File storage for Dart. One API for local disk, AWS S3 and S3-compatible services.

[![pub package](https://img.shields.io/pub/v/dox_storage.svg)](https://pub.dev/packages/dox_storage)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/dartondox/dox-storage/blob/main/LICENSE)

Part of [Dox](https://dartondox.dev), a web backend framework for Dart.
Source code: [github.com/dartondox/dox-storage](https://github.com/dartondox/dox-storage).

## Install

```bash
dart pub add dox_storage
```

To see what is ready and what may still change, read [Status and roadmap](https://dartondox.dev/latest/concepts/status-and-roadmap/).

## Use it

```dart
import 'dart:typed_data';

import 'package:dox_storage/dox_storage.dart';

void main() async {
  DriveManager drive = DriveManager(
    defaultDisk: 'local',
    disks: <String, DriverContract>{
      'local': LocalDriver(LocalDriverConfig(root: 'storage')),
      's3': S3Driver(S3DriverConfig(
        bucket: 'my-bucket',
        region: 'us-east-1',
        accessKeyId: 'AKIA...',
        secretAccessKey: '...',
      )),
    },
  );

  Disk disk = drive.use(); // the default disk
  await disk.put('notes/a.txt', 'hello');
  Uint8List data = await disk.get('notes/a.txt');
  print(await disk.exists('notes/a.txt')); // true
  await disk.append('notes/a.txt', 'world'); // "hello\nworld"
  print(await disk.size('notes/a.txt')); // 11
  await disk.delete('notes/a.txt');
}
```

## Use it in a Dox app

1. Set the disks in `lib/config/storage.dart`:

   ```dart
   import 'package:dox_storage/dox_storage.dart';

   StorageConfig storageConfig = StorageConfig(
     defaultDisk: 'local',
     disks: <String, Map<String, dynamic>>{
       'local': <String, dynamic>{'driver': 'local', 'root': 'storage'},
     },
   );
   ```

2. Register the provider in `lib/providers/storage_provider.dart`.
   The generated container finds it.

   ```dart
   import 'package:dox_storage/dox_storage.dart';

   import '../config/storage.dart';

   class AppStorageProvider extends StorageProvider {
     AppStorageProvider() : super(storageConfig);
   }
   ```

3. Use `Storage()`:

   ```dart
   RequestFile file = req.input('avatar');
   String path = await Storage().putFile('avatars', file); // new uuid name
   await Storage().put('notes/a.txt', 'hello'); // this exact path
   return Storage().download(path, name: 'avatar.png');
   ```

   Serve files with `Storage.route('files')` in a router.

Without the provider, `Storage()` has one `local` disk in the `storage` folder.

## Features

- Drivers: `LocalDriver`, `S3Driver` (AWS S3, Cloudflare R2, MinIO, DigitalOcean Spaces, GCS with HMAC keys) and `MemoryDriver`.
- `put`, `putStream`, `get`, `getStream`, `copy`, `move`, `delete`, `listAll`.
- `files`, `allFiles`, `directories`, `deleteDirectory` and `missing`, like Laravel. `deleteDirectory` refuses the root (`''` or `/`), so a bad path can not empty a disk.
- `Storage().put(path, contents)` writes to that exact path. `putFile(folder, file)` stores with a new uuid file name, and `putFileAs(folder, file, name)` with your name.
- `append`, `prepend`, `size`, `lastModified`, `makeDirectory` and `directoryExists`. `makeDirectory` does nothing on any disk that is not local (S3, memory, custom drivers), because they have no real folders. `directoryExists('')` (the root) is always true.
- Signed download URLs, and signed upload URLs on S3. A local signed URL only works on the route of its own disk.
- Opt-in atomic local writes (`atomicWrites: true`). A failed upload never leaves a partial file.
- Opt-in local file modes (`permissions: true`). Then visibility is the file mode, like Laravel: public file 0644, private file 0600, public folder 0755, private folder 0700. The mode is set before the content is written. An overwrite, `append` and `prepend` keep the mode of the file, unless the write gives a visibility. A copy gets the write visibility, or the mode of the source. New folders get the folder mode. Visibility does not follow symlinks. It does nothing on Windows.
- Big streams go up as a multipart upload. Only one part is in memory at a time.
- Keys are checked. `..`, absolute paths and null bytes throw `InvalidKeyException`.
- `file.storeAs(folder, name)` uses your name. Do not pass the raw client file name to `storeAs`. Make your own name, like `user-1.png`.
- `drive.fake('s3')` swaps a disk for memory in tests. Check it with `assertExists` and `assertMissing`.
- AWS Signature V4 is written in this package. There is no AWS SDK dependency.

## Documentation

- [Storage package](https://dartondox.dev/latest/packages/storage/)
- [File storage in a Dox app](https://dartondox.dev/latest/digging-deeper/file-storage/)
- [API reference](https://pub.dev/documentation/dox_storage/latest/)

## License

MIT. See [LICENSE](https://github.com/dartondox/dox-storage/blob/main/LICENSE).
