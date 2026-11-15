## Unreleased

- Fix: on S3, `directoryExists` said false for an empty folder made in the S3 console ("Create folder"). It also said false when the folder marker came first and the files after it. It now looks for any key under the folder, marker included. `listAll` still hides markers.
- Fix: on S3, `deleteDirectory` and `deleteAll` left the folder marker behind, so the folder still existed. They now delete the marker too.
- Check: `S3Driver` prints one warning to stderr when `multipartPartSize` is not from 5 MiB to 5 GiB. It does not throw, so an app that only uploads small files keeps working. S3 refuses a multipart upload with parts under 5 MiB.
- Faster: S3 `putStream` keeps one part in memory, not two or three. A part is kept as the chunks that came in, with no copy. Peak memory per upload goes from about 24 MiB to about 8 MiB.
- Faster: S3 bodies are hashed while a part fills, so the bytes are read once. A big `put` body (1 MiB or more) is still hashed in another isolate, as before. Parts of a `putStream` are hashed chunk by chunk. An empty body uses the known empty hash.
- New: opt-in `unsignedPayload` on `S3DriverConfig` (`unsigned_payload: true` in the disk config). It skips the body hash and sends `UNSIGNED-PAYLOAD`. Off by default. The signature then does not cover the body, so only use it over HTTPS.
- Faster: `Storage().stream()` and `download()` on S3 send one GET, not a HEAD and a GET. The size, type, date and etag come from the GET headers. A missing file still gives 404. New `Disk.getStreamWithMetaData()` and `ObjectStream` for this. `DriverContract` has no new methods.
- Faster: `append` on a local disk opens the file in append mode, so it does not read and write the whole file. With `atomicWrites` or `permissions` on, it works as before. `prepend` works as before.
- Less memory: S3 `deleteAll` lists and deletes one page of 1000 keys at a time, not all keys first.
- Faster: a recursive local `listAll` with a `limit` reads folders in key order and stops after the page. The order, the tokens and the results stay the same.
- Faster: S3 requests make the bucket URL once, and the XML reader and the signer make each pattern once.

## 3.2.1

- Fix: `dox storage:install` wrote the local disk root as `storage`. An unsigned `Storage.route` then served the whole `storage/` folder, including `storage/cache`. It now writes `storage/app` and makes that folder. The runtime default of `StorageConfig` is still `storage`, so existing apps keep their files. Docs now say: an unsigned route serves every file under the disk root.

## 3.2.0

- New: `dox storage:install [--disk=local|s3]`, run by `dox add storage`. It writes `lib/config/storage.dart`, `lib/providers/storage_provider.dart`, the `storage` folder, the `STORAGE_DISK` key and the `AppEnv` getters. `--disk=s3` adds the `s3` disk and the `AWS_*` keys. It never overwrites a file. dox_storage now depends on dox_annotation.
- Ships an AI agent skill (dox-storage-guide). Install it in your app with `dart run skills@ get`.
- New: `Storage().put(path, contents, exact: true)` writes to that exact path, like Laravel `Storage::put`. An old file at the path is replaced. `contents` is a `String`, a `List<int>` or a `Stream<List<int>>`. It returns the path. Without `exact: true`, `put` works as it did: the first argument is a folder, the file gets a new uuid name, and the path is returned.
- New: `Storage().putFile(folder, file)` stores a file with a new uuid name and returns its path, like Laravel `putFile`. `Storage().putFileAs(folder, file, name)` stores it with your name, like Laravel `putFileAs`. `file` is a `RequestFile` or bytes. `file.store()` and `file.storeAs()` use them.
- New: `copy`, `move`, `files`, `allFiles`, `directories`, `deleteDirectory`, `missing`, `getVisibility` and `setVisibility` on `Storage()`, so you do not need `use()` for them. `files`, `allFiles`, `directories`, `deleteDirectory` and `missing` are on `Disk` too. `deleteDirectory` throws `InvalidKeyException` for the root (`''` or `/`), so a bad path can not empty a disk. `DriverContract` has no new methods, so custom drivers keep working.
- New: `Storage().download(path, name: 'Invoice 42.pdf')` sets the file name the browser saves. The header is safe for any name. To add headers, wrap it: `response(await Storage().download(path)).header('Cache-Control', 'no-store')`.
- New: the local disk option `permissions: true` (or `LocalDriverConfig(permissions: LocalPermissions())`). Then visibility is the file mode, like Laravel: `setVisibility` runs `chmod`, `getVisibility` reads the mode, and writes set the mode. The modes are public file 0644, private file 0600, public folder 0755, private folder 0700. Change them with a map like `{'file': {'private': 0x1a0}}`. It is off by default, so nothing changes. It does nothing on Windows.
  - The mode is set before the content is written, so a private file is never open to others. If `chmod` fails, a file that the write made is deleted.
  - An overwrite keeps the mode of the file, unless the write gives a visibility. So an overwrite does not make a private file public. A new file gets the write visibility, or the disk `visibility`.
  - Folders that a write makes get the folder mode. Folders that were there before keep their mode.
  - `append` and `prepend` keep the exact mode, also a custom one like 0640.
  - A copy is written to a temp file in the same folder, then renamed. So a copy never empties its own source, also through a symlink, a hard link or another case of the name. The rename replaces a symlink or hard link at the new path. `listAll`, `files` and `allFiles` hide the temp file, also with `atomicWrites` off.
  - A copy gets the mode of the write visibility, or else the mode of the source. This is also true over a file that is there. So a copy of a private file is private.
  - A `move` with a visibility sets the mode on the source before the rename. So a failed `move` does not lose the file at the new path. If the rename fails, the source gets its old mode back. A symlink source with a visibility throws before any folder is made.
  - When an overwrite fails, the file gets its old mode back. The owner can read and write while the content goes in, so modes like 0444 or 0200 work.
  - Each mode must be an int from 0 to 0o777 (0x1ff). Anything else, like the string `'0644'` or a setuid bit, throws `ArgumentError` when the disk is made.
  - Visibility does not follow symlinks. `getVisibility` and `setVisibility` on a link throw `UnsupportedOperationException`.
- Fix: `copy()` and `move()` of a missing file on a local disk made the folders of the new path first. They now throw `FileNotFoundException` and make nothing.
- Fix: `Storage().size()` and `Storage().lastModified()` of a missing file made Dox answer 500. They now answer 404, like `Storage().stream()`. The error is still a `FileNotFoundException`, so `on FileNotFoundException` keeps working.
- Fix: `storeAs()` and `putRequestFileAs()` returned the raw name, not the stored key. A name like `a\b.png` is stored as `a/b.png`, and now the returned path is `/a/b.png` too.
- Fix: `directoryExists('')` was true on a local disk, but false on an empty S3 or memory disk. The root is now always true, on every disk.
- Docs: do not pass the raw client file name to `storeAs()`. Make your own name.

## 3.1.0

- New: `directoryExists()` is true when a folder exists. On a local disk it checks the real folder. On S3 and memory disks a folder exists when a file is under it. `exists()` does not change: it is still true for files only.
- New: `temporaryUrl()` on the `Storage` helper. It is the same as `signedUrl()`, with the Laravel name.
- New: `assertExists()` and `assertMissing()` on a disk, for tests. Use them on a fake: `drive.fake('s3').assertExists('a.png')`. They throw a `StateError` when the check fails.
- New: `file.store(folder, disk: 's3')` stores an uploaded file on another disk. `file.storeAs(folder, name)` stores it with your own file name. `Storage().putRequestFileAs()` does the same.
- Fix: with `atomic_writes`, a long file name made the temp name too long, and the write failed with a raw "file name too long" error. A long name is now left out of the temp name. The final file name does not change.
- Fix: `append()` and `prepend()` threw `FileNotFoundException` when another writer deleted the file between the read and the write. They now make the file again, with the disk defaults.
- Fix: `append()` and `prepend()` skipped the `getVisibility` and `getMetaData` of a `LocalDriver` subclass. They now call them.
- New: `append()` and `prepend()` add text to the end or start of a file. A missing file is made. A newline goes between the old and new text, but only when the file is not empty. Change it with `separator`. They keep the visibility and content type of a file that already exists. They read the file and write it back, so two writers at the same time can lose a write.
- New: `size()` and `lastModified()` give the size and the last modified time of a file. A missing file throws `FileNotFoundException`.
- New: `makeDirectory()` makes a folder on a local disk. On any disk that is not local (S3, memory, custom drivers) it does nothing, because they have no real folders. A permission error throws `PermissionDeniedException`.
- The `Storage` helper in Dox apps has the same five methods. `DriverContract` has no new methods, so custom drivers keep working.
- Fix: `url()` on a local disk with no `url` option now gives `/storage/<path>`, like Laravel. Before, it threw `UnsupportedOperationException`. Dox does not serve `/storage` by itself. Add a route for it, like `Storage.route('storage', signed: false)`, or set the disk `url` option. `signedUrl()` still needs `url`.
- Fix: a local signed URL for one disk also worked on the route of another local disk with the same file key. New signed URLs now include the disk name in the signature, so they only work on their own disk. Signed URLs made before this version still work until they expire. Like before, such an old URL works on the route of any local disk. New URLs do not work on 3.0.1, so after a downgrade, or during a rolling deploy, they get 403 until they expire. `LocalDriverConfig` has a new optional `disk` option; `StorageDiskFactory` sets it to the disk name.
- New: `LocalDriverConfig(atomicWrites: true)`, or the disk option `atomic_writes: true`. `put()` and `putStream()` then write to a temp file in the same folder and rename it when the write is done. A failed or stopped upload never leaves a partial file, and the old file stays. Temp file names end with `.dox-upload.tmp`, and `listAll()` hides them. The rename makes a new file: the folder must be writable, the file gets the default mode and the owner of the app, a hard link keeps the old content, and a symlink is replaced. It is off by default, so writes work like 3.0.1.
- Fix: a signed `Storage.route()` on a disk that is not local answered 403 with no reason. Only local disks can check these signatures. It still answers 403, and now it also reports an `UnsupportedOperationException` to the exception handler. The error names the disk and its driver.

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
