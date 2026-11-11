import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../clock.dart';
import '../constants/storage_constants.dart';
import '../driver_contract.dart';
import '../exceptions.dart';
import '../key_normalizer.dart';
import '../types.dart';
import 'listing.dart';
import 'local_url_signer.dart';

/// Settings for [LocalDriver].
class LocalDriverConfig {
  /// Folder where files are stored. Relative paths use the current folder.
  final String root;

  /// Public URL base, for example `https://app.test/uploads`.
  /// Needed for `getSignedUrl`. When null, `getUrl` gives
  /// `/storage/<key>`, like Laravel.
  final String? urlBase;

  /// Secret for signed URLs (use your APP_KEY). Needed for `getSignedUrl`.
  final String? appKey;

  /// The default visibility of new files. Without [permissions], the
  /// local disk has no per-file access rules, and `getVisibility` returns
  /// this value for every file.
  final Visibility visibility;

  /// Off (null) by default: `setVisibility` does nothing and file modes
  /// are not changed.
  ///
  /// When set, visibility is the file mode, like Laravel: `setVisibility`
  /// runs `chmod` on a file or folder, and `getVisibility` reads the mode.
  /// A mode equal to the private mode is private; any other mode is
  /// public, like Laravel.
  ///
  /// `put` and `putStream` set the mode before the content is written, so
  /// a private file is never open to others. A new file gets the write
  /// visibility, or [visibility]. A file that is there keeps its mode,
  /// unless the write gives a visibility. This is safer than Laravel: an
  /// overwrite does not make a private file public. `copy` and `move` keep
  /// the mode of the source, unless a write visibility is given. Folders
  /// that a write makes get the folder mode of the write visibility.
  /// Folders that were there before keep their mode.
  ///
  /// Visibility does not follow symlinks: `getVisibility` and
  /// `setVisibility` on a link throw [UnsupportedOperationException].
  /// When `chmod` fails, a file that the write made is deleted.
  ///
  /// Windows has no `chmod`. There it stays off, even when set.
  final LocalPermissions? permissions;

  /// Name of the disk. Signed URLs include it, so a URL signed for one
  /// local disk does not work on another. `StorageDiskFactory` sets it.
  final String disk;

  /// Off by default: `put` and `putStream` write straight into the file,
  /// like 3.0.1.
  ///
  /// When on, they write to a temp file in the same folder, then rename
  /// it to the file. A failed or stopped upload never leaves a partial
  /// file, and the old file stays. Temp file names end with
  /// `.dox-upload.tmp`, and `listAll` hides them.
  ///
  /// The rename makes a new file. So the folder must be writable, the
  /// file gets the default mode and the owner of the app, a hard link to
  /// the old file keeps the old content, and a symlink is replaced by a
  /// normal file.
  final bool atomicWrites;

  const LocalDriverConfig({
    required this.root,
    this.disk = '',
    this.atomicWrites = false,
    this.urlBase,
    this.appKey,
    this.visibility = Visibility.public,
    this.permissions,
  });
}

/// File and folder modes for [LocalDriverConfig.permissions].
/// The defaults are the Laravel ones: public file 0644, private file 0600,
/// public folder 0755, private folder 0700. Dart has no octal numbers, so
/// they are written in hex here.
class LocalPermissions {
  final int filePublic;
  final int filePrivate;
  final int dirPublic;
  final int dirPrivate;

  const LocalPermissions({
    this.filePublic = 0x1a4,
    this.filePrivate = 0x180,
    this.dirPublic = 0x1ed,
    this.dirPrivate = 0x1c0,
  });
}

/// Stores files in a folder on the local disk.
class LocalDriver implements DriverContract {
  final LocalDriverConfig config;
  final Clock clock;
  final KeyEncoder encoder;

  /// Absolute, normalized root folder.
  final String root;

  final LocalUrlSigner? signer;
  final Listing _listing = const Listing();
  final Random _random = Random();

  LocalDriver(
    this.config, {
    this.clock = const Clock(),
    this.encoder = const KeyEncoder(),
  }) : root = p.normalize(p.absolute(config.root)),
       signer = config.appKey == null
           ? null
           : LocalUrlSigner(config.appKey!, disk: config.disk, clock: clock);

  /// Check a signed URL in the route that serves files.
  /// [key] is the decoded file key from the path.
  bool verifySignedUrl(String key, Map<String, String> queryParameters) {
    LocalUrlSigner? urlSigner = signer;
    if (urlSigner == null) {
      return false;
    }
    return urlSigner.verify(key, queryParameters);
  }

  /// Absolute path for a key. Blocks paths outside [root] as extra defense.
  String pathFor(String key) {
    String full = p.normalize(p.join(root, key));
    if (full != root && !p.isWithin(root, full)) {
      throw InvalidKeyException(key, 'path is outside the storage root');
    }
    return full;
  }

  /// Run a file system action and map its errors to storage errors.
  Future<T> _io<T>(String key, Future<T> action) async {
    try {
      return await action;
    } on PathNotFoundException catch (error) {
      throw FileNotFoundException(key, cause: error);
    } on PathAccessException catch (error) {
      throw PermissionDeniedException(key, cause: error);
    }
  }

  Future<File> _writableFile(String key) async {
    File file = File(pathFor(key));
    await _io(key, file.parent.create(recursive: true));
    return file;
  }

  @override
  Future<bool> exists(String key) async {
    return File(pathFor(key)).exists();
  }

  @override
  Future<Uint8List> get(String key) async {
    return _io(key, File(pathFor(key)).readAsBytes());
  }

  @override
  Future<Stream<List<int>>> getStream(String key) async {
    File file = File(pathFor(key));
    if (!await file.exists()) {
      throw FileNotFoundException(key);
    }
    return file.openRead();
  }

  @override
  Future<ObjectMetaData> getMetaData(String key) async {
    File file = File(pathFor(key));
    FileStat stat = await _io(key, file.stat());
    if (stat.type != FileSystemEntityType.file) {
      throw FileNotFoundException(key);
    }
    return ObjectMetaData(
      size: stat.size,
      contentType: lookupMimeType(key) ?? StorageConstants.defaultContentType,
      lastModified: stat.modified.toUtc(),
      etag:
          '${stat.size.toRadixString(16)}-'
          '${stat.modified.millisecondsSinceEpoch.toRadixString(16)}',
    );
  }

  /// The [LocalDriverConfig.permissions] in use. Null when off or on
  /// Windows.
  LocalPermissions? get _modes {
    return Platform.isWindows ? null : config.permissions;
  }

  @override
  Future<Visibility> getVisibility(String key) async {
    LocalPermissions? modes = _modes;
    if (modes == null) {
      if (!await exists(key)) {
        throw FileNotFoundException(key);
      }
      return config.visibility;
    }
    String path = pathFor(key);
    await _noLink(key, path);
    FileStat stat = await FileStat.stat(path);
    bool folder = stat.type == FileSystemEntityType.directory;
    if (!folder && stat.type != FileSystemEntityType.file) {
      throw FileNotFoundException(key);
    }
    int private = folder ? modes.dirPrivate : modes.filePrivate;
    return stat.mode & 0x1ff == private
        ? Visibility.private
        : Visibility.public;
  }

  @override
  Future<void> setVisibility(String key, Visibility visibility) async {
    if (_modes == null) {
      // ponytail: no per-file ACL on a local disk unless `permissions` is
      // set; protect files with routes.
      if (!await exists(key)) {
        throw FileNotFoundException(key);
      }
      return;
    }
    await _chmod(key, visibility);
  }

  /// Set the mode of a file or folder for [visibility]. Does nothing when
  /// [LocalDriverConfig.permissions] is off. A symlink throws
  /// [UnsupportedOperationException], so a link can not change the mode
  /// of a file outside the root.
  Future<void> _chmod(String key, Visibility visibility) async {
    LocalPermissions? modes = _modes;
    if (modes == null) {
      return;
    }
    String path = pathFor(key);
    await _noLink(key, path);
    FileSystemEntityType type = await FileSystemEntity.type(path);
    bool folder = type == FileSystemEntityType.directory;
    if (!folder && type != FileSystemEntityType.file) {
      throw FileNotFoundException(key);
    }
    int mode = folder
        ? _dirMode(modes, visibility)
        : _fileMode(modes, visibility);
    await _chmodPaths(key, <String>[path], mode);
  }

  /// Throw [UnsupportedOperationException] when [path] is a symlink.
  /// The mode of a link is the mode of its target, and the target can be
  /// outside the root. So visibility does not follow links.
  Future<void> _noLink(String key, String path) async {
    if (await FileSystemEntity.isLink(path)) {
      throw UnsupportedOperationException(
        key,
        'visibility of a symlink is not supported',
      );
    }
  }

  int _fileMode(LocalPermissions modes, Visibility visibility) {
    return visibility == Visibility.public
        ? modes.filePublic
        : modes.filePrivate;
  }

  int _dirMode(LocalPermissions modes, Visibility visibility) {
    return visibility == Visibility.public ? modes.dirPublic : modes.dirPrivate;
  }

  /// Run `chmod` on [paths].
  Future<void> _chmodPaths(String key, List<String> paths, int mode) async {
    // ponytail: dart:io has no chmod, so this starts a process. Only with
    // `permissions` on. Use FFI if many writes per second matter.
    ProcessResult result = await Process.run('chmod', <String>[
      mode.toRadixString(8),
      ...paths,
    ]);
    if (result.exitCode != 0) {
      throw PermissionDeniedException(key, cause: result.stderr);
    }
  }

  /// Make the parent folders of [file], with `permissions` on. The new
  /// folders get the folder mode of [visibility]. Folders that were there
  /// before, and the root, keep their mode.
  Future<void> _makeParents(
    String key,
    File file,
    LocalPermissions modes,
    Visibility visibility,
  ) async {
    List<String> created = <String>[];
    Directory folder = file.parent;
    while (folder.path != root && !await folder.exists()) {
      created.add(folder.path);
      folder = folder.parent;
    }
    await _io(key, file.parent.create(recursive: true));
    if (created.isNotEmpty) {
      await _chmodPaths(key, created, _dirMode(modes, visibility));
    }
  }

  @override
  Future<String> getUrl(String key) async {
    // ponytail: no route serves /storage by default. The app adds one,
    // like `Storage.route('storage', signed: false)`.
    String base = config.urlBase ?? '/storage';
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return '$base/${encoder.urlPath(key)}';
  }

  @override
  Future<String> getSignedUrl(String key, SignedUrlOptions options) async {
    String? base = config.urlBase;
    LocalUrlSigner? urlSigner = signer;
    if (base == null || urlSigner == null) {
      throw UnsupportedOperationException(
        key,
        'urlBase and appKey are needed for signed URLs',
      );
    }
    return urlSigner.sign(base, key, options.expiresIn);
  }

  @override
  Future<String> getSignedUploadUrl(
    String key,
    SignedUrlOptions options,
  ) async {
    throw UnsupportedOperationException(
      key,
      'LocalDriver does not support signed upload URLs',
    );
  }

  @override
  Future<void> put(String key, Uint8List contents, WriteOptions options) async {
    LocalPermissions? modes = _modes;
    if (modes != null) {
      return _putWithModes(key, contents, options, modes);
    }
    File file = await _writableFile(key);
    if (!config.atomicWrites) {
      await _io(key, file.writeAsBytes(contents, flush: true));
    } else {
      File temp = _tempFile(file);
      await _replace(key, file, temp, temp.writeAsBytes(contents, flush: true));
    }
  }

  @override
  Future<void> putStream(
    String key,
    Stream<List<int>> contents,
    WriteOptions options,
  ) async {
    LocalPermissions? modes = _modes;
    if (modes != null) {
      return _putWithModes(key, contents, options, modes);
    }
    File file = await _writableFile(key);
    if (!config.atomicWrites) {
      await _writeStream(file, contents);
    } else {
      File temp = _tempFile(file);
      await _replace(key, file, temp, _writeStream(temp, contents));
    }
  }

  /// [put] and [putStream] with `permissions` on. The mode is set before
  /// the content is there, so a private file is never open to others.
  /// The mode comes from the write visibility. Without one, a file that
  /// is there keeps its mode, and a new file gets the disk visibility.
  Future<void> _putWithModes(
    String key,
    Object contents,
    WriteOptions options,
    LocalPermissions modes,
  ) async {
    Visibility? visibility = options.visibility;
    File file = File(pathFor(key));
    await _makeParents(key, file, modes, visibility ?? config.visibility);
    FileStat stat = await file.stat();
    int? oldMode = stat.type == FileSystemEntityType.file
        ? stat.mode & 0x1ff
        : null;
    int mode = visibility != null
        ? _fileMode(modes, visibility)
        : oldMode ?? _fileMode(modes, config.visibility);
    if (config.atomicWrites) {
      File temp = _tempFile(file);
      await _replace(key, file, temp, _writeNew(key, temp, contents, mode));
      return;
    }
    if (oldMode == null) {
      await _noLink(key, file.path);
      await _writeNew(key, file, contents, mode);
      return;
    }
    if (mode == oldMode) {
      await _io(key, _writeTo(file, contents));
      return;
    }
    // Overwrite with a new mode. First keep only the bits that both modes
    // have, then write, then set the new mode. So no one can read the old
    // or the new content who should not.
    await _noLink(key, file.path);
    int both = mode & oldMode;
    if (both != oldMode) {
      await _chmodPaths(key, <String>[file.path], both);
    }
    await _io(key, _writeTo(file, contents));
    if (both != mode) {
      await _chmodPaths(key, <String>[file.path], mode);
    }
  }

  /// Make [file] as an empty file with [mode], then write [contents].
  /// When `chmod` fails, the new file is deleted.
  Future<void> _writeNew(
    String key,
    File file,
    Object contents,
    int mode,
  ) async {
    await _io(key, file.writeAsBytes(const <int>[], flush: true));
    try {
      await _chmodPaths(key, <String>[file.path], mode);
    } catch (_) {
      await _deleteQuietly(file);
      rethrow;
    }
    await _io(key, _writeTo(file, contents));
  }

  Future<void> _writeTo(File file, Object contents) {
    if (contents is Uint8List) {
      return file.writeAsBytes(contents, flush: true);
    }
    return _writeStream(file, contents as Stream<List<int>>);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // already gone or locked: keep the first error
    }
  }

  Future<void> _writeStream(File file, Stream<List<int>> contents) async {
    IOSink sink = file.openWrite();
    try {
      await sink.addStream(contents);
    } finally {
      await sink.close();
    }
  }

  /// A new temp file next to [file], for [LocalDriverConfig.atomicWrites].
  /// Same folder, so the rename in [_replace] does not cross file systems.
  /// A long file name is left out of the temp name, so the temp name
  /// still fits the file system limit. The final name does not change.
  File _tempFile(File file) {
    String unique =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${_random.nextInt(1 << 32)}${StorageConstants.localTempSuffix}';
    String name = '.${p.basename(file.path)}.$unique';
    if (utf8.encode(name).length > StorageConstants.localMaxNameBytes) {
      name = '.$unique';
    }
    return File(p.join(file.parent.path, name));
  }

  /// Wait for [write] into [temp], then rename [temp] to [file].
  /// Readers see the old file or the full new file, never a partial one.
  /// On error the temp file is deleted.
  Future<void> _replace(
    String key,
    File file,
    File temp,
    Future<void> write,
  ) async {
    try {
      await _io(key, write);
      await _io(key, temp.rename(file.path));
    } catch (_) {
      await _deleteQuietly(temp);
      rethrow;
    }
  }

  /// True for a temp file of [_tempFile]. A crash can leave one behind.
  /// Only checked with [LocalDriverConfig.atomicWrites], so other disks
  /// list every file like 3.0.1.
  bool _isTempFile(String path) {
    return config.atomicWrites &&
        p.basename(path).endsWith(StorageConstants.localTempSuffix);
  }

  @override
  Future<void> copy(
    String source,
    String destination,
    WriteOptions options,
  ) async {
    String from = await _source(source);
    String to = pathFor(destination);
    bool existed = await _prepareDestination(destination, options);
    await _io(source, File(from).copy(to));
    // The copy keeps the mode of the source, unless a visibility is given.
    Visibility? visibility = options.visibility;
    if (visibility == null) {
      return;
    }
    try {
      await _chmod(destination, visibility);
    } catch (_) {
      if (!existed) {
        await _deleteQuietly(File(to));
      }
      rethrow;
    }
  }

  @override
  Future<void> move(
    String source,
    String destination,
    WriteOptions options,
  ) async {
    String from = await _source(source);
    String to = pathFor(destination);
    await _prepareDestination(destination, options);
    await _io(source, File(from).rename(to));
    Visibility? visibility = options.visibility;
    if (visibility == null) {
      return;
    }
    try {
      await _chmod(destination, visibility);
    } catch (_) {
      // Put the file back, so a failed move does not lose it.
      await _io(source, File(to).rename(from));
      rethrow;
    }
  }

  /// Path of the source of [copy] or [move]. A missing source throws
  /// [FileNotFoundException] before any folder is made.
  Future<String> _source(String key) async {
    String path = pathFor(key);
    if (await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
      throw FileNotFoundException(key);
    }
    return path;
  }

  /// Make the parent folders of [key] for [copy] and [move]. Returns true
  /// when a file is there already. Only used with `permissions` on.
  Future<bool> _prepareDestination(String key, WriteOptions options) async {
    LocalPermissions? modes = _modes;
    if (modes == null) {
      await _writableFile(key);
      return false;
    }
    File file = File(pathFor(key));
    Visibility visibility = options.visibility ?? config.visibility;
    await _makeParents(key, file, modes, visibility);
    return file.exists();
  }

  @override
  Future<void> delete(String key) async {
    File file = File(pathFor(key));
    if (await file.exists()) {
      await _io(key, file.delete());
    }
  }

  @override
  Future<void> deleteAll(String prefix) async {
    Directory directory = Directory(pathFor(prefix));
    if (!await directory.exists()) {
      return;
    }
    if (prefix.isNotEmpty) {
      await _io(prefix, directory.delete(recursive: true));
      return;
    }
    // Keep the root folder itself, delete what is inside.
    await for (FileSystemEntity entity in directory.list()) {
      await _io(prefix, entity.delete(recursive: true));
    }
  }

  @override
  Future<ListResult> listAll(String prefix, ListOptions options) async {
    Directory directory = Directory(pathFor(prefix));
    List<DriveEntry> entries = <DriveEntry>[];
    if (!await directory.exists()) {
      return ListResult(entries);
    }
    Stream<FileSystemEntity> items = directory.list(
      recursive: options.recursive,
      followLinks: false,
    );
    await for (FileSystemEntity entity in items) {
      String key = p.split(p.relative(entity.path, from: root)).join('/');
      if (entity is File) {
        if (_isTempFile(entity.path)) continue;
        entries.add(DriveFile(key));
      } else if (entity is Directory && !options.recursive) {
        entries.add(DriveDirectory(key));
      }
    }
    return _listing.paginate(entries, options);
  }
}
