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
   String path = await file.store('avatars');
   return Storage().download(path);
   ```

   Serve files with `Storage.route('files')` in a router.

Without the provider, `Storage()` has one `local` disk in the `storage` folder.

## Features

- Drivers: `LocalDriver`, `S3Driver` (AWS S3, Cloudflare R2, MinIO, DigitalOcean Spaces, GCS with HMAC keys) and `MemoryDriver`.
- `put`, `putStream`, `get`, `getStream`, `copy`, `move`, `delete`, `listAll`.
- Signed download URLs, and signed upload URLs on S3.
- Big streams go up as a multipart upload. Only one part is in memory at a time.
- Keys are checked. `..`, absolute paths and null bytes throw `InvalidKeyException`.
- `drive.fake('s3')` swaps a disk for memory in tests.
- AWS Signature V4 is written in this package. There is no AWS SDK dependency.

## Documentation

- [Storage package](https://dartondox.dev/latest/packages/storage/)
- [File storage in a Dox app](https://dartondox.dev/latest/digging-deeper/file-storage/)
- [API reference](https://pub.dev/documentation/dox_storage/latest/)

## License

MIT. See [LICENSE](https://github.com/dartondox/dox-storage/blob/main/LICENSE).
