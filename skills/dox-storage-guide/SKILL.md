---
name: dox-storage-guide
description: Use when you save, read, delete, list, stream, download or serve files in a Dox (Dart) app, store request uploads, add a local, S3 or memory disk, make signed URLs, or fake storage in tests with dox_storage.
---

# dox_storage guide

`dox_storage` gives one file API for the local disk, AWS S3 (also R2, MinIO, Spaces) and memory.
In a Dox app you use the `Storage()` facade. Outside Dox you use `DriveManager` and `Disk`.
For routes, controllers and `RequestFile` basics, see the dox-core-guide skill.

## Set up

```bash
dox add storage              # local disk (default)
dox add storage --disk=s3    # also adds the s3 disk and the AWS_* keys
```

It writes `lib/config/storage.dart`, the provider, the `storage` folder, the `STORAGE_DISK` key and the `AppEnv` getters. It never overwrites a file, so it is safe to run twice. The steps below show the same files by hand.

## Install and register

```bash
dart pub add dox_storage
```

1. Config in `lib/config/storage.dart`:

```dart
import 'package:dox_storage/dox_storage.dart';

StorageConfig storageConfig = StorageConfig(
  defaultDisk: 'local',
  disks: <String, Map<String, dynamic>>{
    'local': <String, dynamic>{
      'driver': 'local',
      'root': 'storage/app',
      'url': 'http://localhost:3000/files', // base for url() and signedUrl()
    },
    's3': <String, dynamic>{
      'driver': 's3',
      'bucket': 'my-bucket',
      'region': 'us-east-1',
      'key': 'AKIA...',
      'secret': '...',
    },
    'memory': <String, dynamic>{'driver': 'memory'},
  },
);
```

2. Provider in `lib/providers/storage_provider.dart`. The generated container finds it, so you do not register it by hand.

```dart
import 'package:dox_storage/dox_storage.dart';

import '../config/storage.dart';

class AppStorageProvider extends StorageProvider {
  AppStorageProvider() : super(storageConfig);
}
```

Without a provider, `Storage()` has one `local` disk in the `storage` folder.
After you add a provider file, run `dart run build_runner build` so the container sees it.
Read secrets from the app `env` class in `lib/config/env.dart`, never hard-code them.

## Disk options

| Driver | Options |
| --- | --- |
| `local` | `root` (default `storage`), `url`, `visibility` (default public), `atomic_writes`, `permissions`, `app_key` |
| `s3` | `bucket`, `key`, `secret` (these three are required), `region` (default `us-east-1`), `token`, `endpoint`, `path_style`, `url`, `visibility` (default private), `acl`, `batch_delete` |
| `memory` | none |

A missing required S3 setting, or an unknown `driver`, throws `ArgumentError` at start.
For R2, MinIO and Spaces set `endpoint`. For MinIO set `'path_style': true`. For R2 set `'acl': false`.

## Recipes

### 1. Store an upload

```dart
import 'package:dox_core/dox_core.dart';
import 'package:dox_storage/dox_storage.dart';

class AvatarController {
  Future<Map<String, dynamic>> upload(DoxRequest req) async {
    RequestFile file = req.input('avatar');
    String path = await Storage().putFile('avatars', file); // '/avatars/<uuid>.png'
    return <String, dynamic>{'path': path};
  }
}
```

- `putFile(folder, file)` makes a new uuid file name. The extension comes from the file content.
- `putFileAs(folder, file, 'user-1.png')` uses your name.
- `file.store('avatars')` and `file.storeAs('avatars', 'user-1.png')` do the same. Both take `disk:`.
- Every call returns the path with a leading `/`. Save that string in your database.

### 2. Write, read and delete by path

```dart
await Storage().put('notes/a.txt', 'hello', exact: true); // exact path
Uint8List? bytes = await Storage().get('/notes/a.txt');   // null when missing
bool has = await Storage().exists('notes/a.txt');
await Storage().append('notes/a.txt', 'more');
await Storage().copy('notes/a.txt', 'notes/b.txt');
await Storage().move('notes/b.txt', 'archive/b.txt');
await Storage().delete('notes/a.txt'); // a missing file is not an error
List<String> all = await Storage().allFiles('notes'); // paths with a leading '/'
```

Without `exact: true`, `put(folder, bytes)` stores `List<int>` or a `RequestFile` under a new uuid name.
A `String` or a `Stream` needs `exact: true`, or an `ArgumentError` is thrown.

### 3. Pick another disk

```dart
await Storage().disk('s3').put('reports/2026.pdf', bytes, exact: true);
Disk s3 = Storage().use('s3'); // the full Disk API
```

`Disk` has `put`, `putStream`, `get`, `getString`, `getStream`, `getMetaData`, `size`, `lastModified`, `copy`, `move`, `delete`, `deleteAll`, `files`, `allFiles`, `directories`, `listAll`, `getUrl`, `getSignedUrl`, `getSignedUploadUrl`, `getVisibility`, `setVisibility`. Keys have no leading `/`.

### 4. Send a file in a response

```dart
Future<DownloadableFile> download() async {
  return Storage().download('/avatars/a.png', name: 'avatar.png'); // attachment
}

Future<StreamFile> show() async {
  return Storage().stream('/avatars/a.png'); // inline, streamed
}
```

A missing file answers 404.

### 5. Serve files over HTTP and make URLs

```dart
Storage.route('files');                          // GET /files/{key*}, signed URLs only
Storage.route('public', signed: false);          // any file of the disk
Storage.route('uploads', disk: 'memory', signed: false);
Storage.route('dl', download: true);             // every file is a download

String url = await Storage().url('/avatars/a.png');
String link = await Storage().signedUrl('/avatars/a.png', expiresIn: const Duration(minutes: 10));
```

An unsigned route serves every file under the disk root. Keep the root a folder that holds only public uploads.
Add `Storage.route(...)` inside a route group or router, as any other route.
For a local signed URL, set the disk `url` to the host plus the route path, for example `http://localhost:3000/files`.
`Storage.route` with `signed: true` only works on a local disk.
A local disk with no `url` gives `/storage/<path>` from `url()`. Serve it with `Storage.route('storage', signed: false)`.
For direct client uploads on S3, use `Storage().use('s3').getSignedUploadUrl(key)` (the client sends `PUT`).

### 6. Use storage without Dox

```dart
DriveManager drive = DriveManager(
  defaultDisk: 'local',
  disks: <String, DriverContract>{
    'local': LocalDriver(LocalDriverConfig(root: 'storage')),
  },
);
Disk disk = drive.use();
```

### 7. Test with a fake disk

```dart
Disk fake = Storage.manager.fake('s3'); // memory disk instead of the real one
await Storage().disk('s3').put('a.txt', 'x', exact: true);
await fake.assertExists('a.txt');
await fake.assertMissing('b.txt');
Storage.manager.restore('s3');
```

`fake()` with no name fakes the default disk. `restore()` puts the real disk back.
The manager also has `restoreAll()` to remove every fake.
A `memory` disk in config is also fine for tests.

## Errors

All errors extend `StorageException` (it has `key`, `message`, `cause`):

- `FileNotFoundException`: no such file. `Storage().get` returns null instead. `Storage().size`, `copy`, `move` and visibility calls turn it into an HTTP 404.
- `InvalidKeyException`: the key uses `..`, an absolute path or a null byte.
- `PermissionDeniedException`, `UnsupportedOperationException`, `DriverException`: other failures.

## Gotchas

- Everything is async. Always `await`.
- Never pass the raw client file name to `storeAs`. Make your own name, like `user-1.png`.
- `deleteDirectory` refuses the root and throws `InvalidKeyException`. To empty a disk on purpose use `Storage().use().deleteAll()`.
- `makeDirectory` only works on the local disk. On S3 and memory it does nothing. A folder exists there when a file is under it.
- `Storage().get` returns `Uint8List?`. `Disk.get` throws when the file is missing.
- `append` and `prepend` read the file and write it back. They are not safe for two writers at the same time.
- Local `setVisibility` needs the `permissions` option. With `'acl': false` on S3 it does nothing.
- Local `atomic_writes: true` writes a temp file and renames it, so a failed upload leaves no partial file. It is off by default.
- `copy` and `move` replace a file that is already at the target.
- S3 signing is built in. Do not add the AWS SDK.
