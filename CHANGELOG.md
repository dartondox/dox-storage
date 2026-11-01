## Unreleased

- Fix: a local signed URL for one disk also worked on the route of another local disk with the same file key. New signed URLs now include the disk name in the signature, so they only work on their own disk. Signed URLs made before this version still work until they expire. Like before, such an old URL works on the route of any local disk. `LocalDriverConfig` has a new optional `disk` option; `StorageDiskFactory` sets it to the disk name.
- Fix: `LocalDriver.put()` and `putStream()` wrote straight into the file. A failed or stopped upload left a partial file, or broke the old file. They now write to a temp file in the same folder and rename it when the write is done. On an error the temp file is deleted and the old file stays. Temp file names end with `.dox-upload.tmp`, and `listAll()` hides them, also one that a crash left behind. File modes stay the same as before: a new file gets the default mode, and an overwrite keeps the mode of the old file. A write to a symlink still goes to the file it points to.
- Fix: a signed `Storage.route()` on a disk that is not local answered 403 with no reason. Only local disks can check these signatures. It still answers 403, and now it also logs an error that names the disk and its driver.

## 3.0.1

- Fix: `Storage.route()` decoded the file key a second time. A key with a real `%`, like `100%.txt`, gave the wrong file or a 500. Dox core 3.0.1 already decodes the path, so the route now uses the key as it is.
- Needs `dox_core` 3.0.1 or newer.

## 3.0.0

- The first stable release.

## 3.0.0-rc.1

- Breaking: in a Dox app, local signed URLs are signed with a key made from `APP_KEY` for signed URLs only, not with `APP_KEY` itself. Signed URLs made before this version stop working. A disk with its own `app_key` option still uses it as it is.
- Fix: `Storage().stream()`, `download()` and `Storage.route()` answered 500 for a key outside the disk, like `../pubspec.yaml`. They now answer 404. No file was leaked before.
- Tests: the permission test is skipped when the user can read a locked file, like root. The free port helper falls back to IPv4 on hosts with no IPv6.

## 3.0.0-alpha.13

- `StorageProvider` (was a DoxService): extend it in your app, `shutdown()` is optional.

## 3.0.0-alpha.12

- The package now lives in its own repo: [dartondox/dox-storage](https://github.com/dartondox/dox-storage).
- Breaking: the Dox glue moved here from `dox_core`. Add `dox_storage` to your app and import `package:dox_storage/dox_storage.dart`.
  - `Storage()`, `StorageConfig` and `StorageDiskFactory` are now in this package.
  - New `StorageService`. Extend it to set the disks: `class AppStorageService extends StorageService { AppStorageService() : super(storageConfig); }`. It replaces `AppConfig.storage`.
  - `Route.files('files')` is now `Storage.route('files')`.
  - `Dox().storage` is now `Storage.manager`.
  - `file.store(folder)` on a `RequestFile` still works. It needs this import.

## 3.0.0-alpha.11

- Version bump only, to match the other packages.

## 3.0.0-alpha.10

- Version bump only, to match the other packages.

## 3.0.0-alpha.9

- Version bump only, to match the other packages.

## 3.0.0-alpha.8

- Version bump only, to match the other packages.

## 3.0.0-alpha.7

- Perf: the S3 driver keeps the SigV4 signing key for each day. Before, every request ran 4 extra HMACs to make it again.
- Perf: the S3 driver hashes a body of 1 MiB or more (eg. an 8 MiB multipart part) in another isolate. Before, the sha256 blocked the event loop.

## 3.0.0-alpha.6

- Version bump only, to match the other packages.

## 3.0.0-alpha.5

- Version bump only, to match the other packages.

## 3.0.0-alpha.4

- Version bump only, to match the other packages.

## 3.0.0-alpha.3

- Version bump only, to match the other packages.

## 3.0.0-alpha.2

- Needs Dart 3.13 or newer.
- All dependencies updated to their latest versions.

## 3.0.0-alpha.1

- Initial version.
- `DriveManager` and `Disk` with a FlyDrive-like API.
- Drivers: `LocalDriver`, `S3Driver` (AWS S3, R2, MinIO, Spaces, GCS interop), `MemoryDriver`.
- AWS Signature V4 signing, presigned download and upload URLs, multipart upload.
- `DriveManager.fake()` for tests.
