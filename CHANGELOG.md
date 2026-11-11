## Unreleased

- Breaking: `Storage().put(path, contents)` writes to that exact path, like Laravel `Storage::put`. Before, the first argument was a folder and the file got a new uuid name. To keep the old behavior, call `putFile`: `Storage().putFile('images', bytes, extension: 'png')`. `put` takes a `String`, a `List<int>` or a `Stream<List<int>>`, and returns nothing.
- New: `Storage().putFile(folder, file)` stores a file with a new uuid name and returns its path, like Laravel `putFile`. `Storage().putFileAs(folder, file, name)` stores it with your name, like Laravel `putFileAs`. `file` is a `RequestFile` or bytes. `file.store()` and `file.storeAs()` use them.
- New: `copy`, `move`, `files`, `allFiles`, `directories`, `deleteDirectory`, `missing`, `getVisibility` and `setVisibility` on `Storage()`, so you do not need `use()` for them. `files`, `allFiles`, `directories`, `deleteDirectory` and `missing` are on `Disk` too. `deleteDirectory` throws `InvalidKeyException` for the root (`''` or `/`), so a bad path can not empty a disk. `DriverContract` has no new methods, so custom drivers keep working.
- New: `Storage().download(path, name: 'Invoice 42.pdf')` sets the file name the browser saves. The header is safe for any name. To add headers, wrap it: `response(await Storage().download(path)).header('Cache-Control', 'no-store')`.
- New: the local disk option `permissions: true` (or `LocalDriverConfig(permissions: LocalPermissions())`). Then visibility is the file mode, like Laravel: `setVisibility` runs `chmod`, `getVisibility` reads the mode, and writes set the mode. The modes are public file 0644, private file 0600, public folder 0755, private folder 0700. Change them with a map like `{'file': {'private': 0x1a0}}`. It is off by default, so nothing changes. It does nothing on Windows.
  - The mode is set before the content is written, so a private file is never open to others. If `chmod` fails, a file that the write made is deleted.
  - An overwrite keeps the mode of the file, unless the write gives a visibility. So an overwrite does not make a private file public. A new file gets the write visibility, or the disk `visibility`.
  - Folders that a write makes get the folder mode. Folders that were there before keep their mode.
  - `append` and `prepend` keep the exact mode, also a custom one like 0640.
  - A copy gets the mode of the write visibility, or else the mode of the source. This is also true over a file that is there. So a copy of a private file is private.
  - A `move` with a visibility sets the mode on the source before the rename. So a failed `move` does not lose the file at the new path.
  - When an overwrite fails, the file gets its old mode back. A read-only mode like 0444 works.
  - A mode in the `permissions` map below 0 or above 0o7777 throws `ArgumentError`.
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
