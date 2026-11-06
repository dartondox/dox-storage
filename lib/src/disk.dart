import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'driver_contract.dart';
import 'drivers/local_driver.dart';
import 'exceptions.dart';
import 'key_normalizer.dart';
import 'types.dart';

/// The public API for one storage disk.
///
/// A disk wraps a [DriverContract]. It cleans every key with
/// [KeyNormalizer] and turns unknown driver errors into [StorageException]s.
class Disk {
  final DriverContract driver;
  final KeyNormalizer normalizer;

  const Disk(this.driver, {this.normalizer = const KeyNormalizer()});

  /// Write a file. [contents] can be a `String` (saved as UTF-8),
  /// a `List<int>` or a `Stream<List<int>>`.
  Future<void> put(
    String key,
    Object contents, {
    WriteOptions options = const WriteOptions(),
  }) async {
    if (contents is Stream<List<int>>) {
      return putStream(key, contents, options: options);
    }
    Uint8List bytes;
    if (contents is String) {
      bytes = Uint8List.fromList(utf8.encode(contents));
    } else if (contents is Uint8List) {
      bytes = contents;
    } else if (contents is List<int>) {
      bytes = Uint8List.fromList(contents);
    } else {
      throw ArgumentError.value(
        contents,
        'contents',
        'must be String, List<int> or Stream<List<int>>',
      );
    }
    String k = normalizer.key(key);
    try {
      await driver.put(k, bytes, options);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Write a file from a stream.
  Future<void> putStream(
    String key,
    Stream<List<int>> contents, {
    WriteOptions options = const WriteOptions(),
  }) async {
    String k = normalizer.key(key);
    try {
      await driver.putStream(k, contents, options);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Read a file as bytes.
  Future<Uint8List> get(String key) async {
    String k = normalizer.key(key);
    try {
      return await driver.get(k);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Read a file as a UTF-8 string.
  Future<String> getString(String key) async {
    return utf8.decode(await get(key));
  }

  /// Read a file as a stream.
  Future<Stream<List<int>>> getStream(String key) async {
    String k = normalizer.key(key);
    try {
      return await driver.getStream(k);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Size, content type, last modified time and etag.
  Future<ObjectMetaData> getMetaData(String key) async {
    String k = normalizer.key(key);
    try {
      return await driver.getMetaData(k);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Size of a file in bytes. A missing file throws
  /// [FileNotFoundException].
  Future<int> size(String key) async {
    ObjectMetaData meta = await getMetaData(key);
    return meta.size;
  }

  /// Last modified time of a file. A missing file throws
  /// [FileNotFoundException].
  Future<DateTime> lastModified(String key) async {
    ObjectMetaData meta = await getMetaData(key);
    return meta.lastModified;
  }

  /// Add [data] to the end of a file. A missing file is made.
  /// [separator] goes between the old text and [data], but only when the
  /// file is not empty.
  Future<void> append(
    String key,
    String data, {
    String separator = '\n',
  }) async {
    Uint8List? old = await _getOrNull(key);
    BytesBuilder out = BytesBuilder(copy: false);
    if (old != null && old.isNotEmpty) {
      out.add(old);
      out.add(utf8.encode(separator));
    }
    out.add(utf8.encode(data));
    await put(key, out.takeBytes(), options: await _keepOptions(key, old));
  }

  /// Add [data] to the start of a file. A missing file is made.
  /// [separator] goes between [data] and the old text, but only when the
  /// file is not empty.
  Future<void> prepend(
    String key,
    String data, {
    String separator = '\n',
  }) async {
    Uint8List? old = await _getOrNull(key);
    BytesBuilder out = BytesBuilder(copy: false)..add(utf8.encode(data));
    if (old != null && old.isNotEmpty) {
      out.add(utf8.encode(separator));
      out.add(old);
    }
    await put(key, out.takeBytes(), options: await _keepOptions(key, old));
  }

  /// Make a folder, with its parent folders. Only the local disk has real
  /// folders. On any disk that is not local (S3, memory, custom drivers)
  /// this does nothing.
  Future<void> makeDirectory(String path) async {
    String k = normalizer.key(path);
    DriverContract target = driver;
    // ponytail: only LocalDriver has real folders. A custom driver with
    // folders can add an opt-in interface later; no new abstract method.
    if (target is! LocalDriver) {
      return;
    }
    try {
      await Directory(target.pathFor(k)).create(recursive: true);
    } on PathAccessException catch (error, stack) {
      Error.throwWithStackTrace(
        PermissionDeniedException(k, cause: error),
        stack,
      );
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Read a file, or null when it does not exist.
  // ponytail: read then write, not atomic. Two writers at the same time
  // can lose a write. Use a lock or a real append if that matters.
  Future<Uint8List?> _getOrNull(String key) async {
    try {
      return await get(key);
    } on FileNotFoundException {
      return null;
    }
  }

  /// Write options that keep the visibility and content type of a file
  /// that already exists. So `append` does not make a private file public.
  /// A missing file ([old] is null) uses the disk defaults.
  Future<WriteOptions> _keepOptions(String key, Uint8List? old) async {
    // ponytail: a plain local disk keeps no per-file visibility or content
    // type, so skip the extra reads there. A subclass may override them,
    // so only the exact LocalDriver type is skipped.
    if (old == null || driver.runtimeType == LocalDriver) {
      return const WriteOptions();
    }
    try {
      Visibility? visibility;
      try {
        visibility = await getVisibility(key);
      } on UnsupportedOperationException {
        visibility = null;
      }
      ObjectMetaData meta = await getMetaData(key);
      return WriteOptions(
        contentType: meta.contentType,
        visibility: visibility,
      );
    } on FileNotFoundException {
      // Deleted after the read. Make it again with the disk defaults.
      return const WriteOptions();
    }
  }

  /// True when the file exists.
  Future<bool> exists(String key) async {
    String k = normalizer.key(key);
    try {
      return await driver.exists(k);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// True when the folder exists. On a local disk it checks the real
  /// folder. On other disks (S3, memory) a folder exists when at least one
  /// file has a key under it. [exists] stays true for files only.
  Future<bool> directoryExists(String path) async {
    String p = normalizer.prefix(path);
    DriverContract target = driver;
    try {
      if (target is LocalDriver) {
        return await Directory(target.pathFor(p)).exists();
      }
      ListResult result = await target.listAll(p, const ListOptions(limit: 1));
      return result.objects.isNotEmpty;
    } catch (error, stack) {
      _fail(error, stack, p);
    }
  }

  /// Test helper, like Laravel `Storage::assertExists`. Throws a
  /// [StateError] when the file does not exist.
  /// ```
  /// Disk fake = drive.fake('s3');
  /// await fake.assertExists('avatars/a.png');
  /// ```
  Future<void> assertExists(String key) async {
    if (!await exists(key)) {
      throw StateError('Expected file "$key" to exist, but it does not.');
    }
  }

  /// Test helper, like Laravel `Storage::assertMissing`. Throws a
  /// [StateError] when the file exists.
  Future<void> assertMissing(String key) async {
    if (await exists(key)) {
      throw StateError('Expected file "$key" to be missing, but it exists.');
    }
  }

  /// Delete a file. A missing file is not an error.
  Future<void> delete(String key) async {
    String k = normalizer.key(key);
    try {
      await driver.delete(k);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Delete every file under [prefix]. An empty prefix deletes everything.
  Future<void> deleteAll([String prefix = '']) async {
    String p = normalizer.prefix(prefix);
    try {
      await driver.deleteAll(p);
    } catch (error, stack) {
      _fail(error, stack, p);
    }
  }

  /// Copy a file to a new key.
  Future<void> copy(
    String source,
    String destination, {
    WriteOptions options = const WriteOptions(),
  }) async {
    String from = normalizer.key(source);
    String to = normalizer.key(destination);
    try {
      await driver.copy(from, to, options);
    } catch (error, stack) {
      _fail(error, stack, from);
    }
  }

  /// Move a file to a new key.
  Future<void> move(
    String source,
    String destination, {
    WriteOptions options = const WriteOptions(),
  }) async {
    String from = normalizer.key(source);
    String to = normalizer.key(destination);
    try {
      await driver.move(from, to, options);
    } catch (error, stack) {
      _fail(error, stack, from);
    }
  }

  /// List files and folders under [prefix].
  Future<ListResult> listAll([
    String prefix = '',
    ListOptions options = const ListOptions(),
  ]) async {
    String p = normalizer.prefix(prefix);
    try {
      return await driver.listAll(p, options);
    } catch (error, stack) {
      _fail(error, stack, p);
    }
  }

  /// Public URL of a file.
  Future<String> getUrl(String key) async {
    String k = normalizer.key(key);
    try {
      return await driver.getUrl(k);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Temporary URL to download a file.
  Future<String> getSignedUrl(
    String key, {
    SignedUrlOptions options = const SignedUrlOptions(),
  }) async {
    String k = normalizer.key(key);
    try {
      return await driver.getSignedUrl(k, options);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Temporary URL a client can `PUT` a file to directly.
  Future<String> getSignedUploadUrl(
    String key, {
    SignedUrlOptions options = const SignedUrlOptions(),
  }) async {
    String k = normalizer.key(key);
    try {
      return await driver.getSignedUploadUrl(k, options);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Get the visibility of a file.
  Future<Visibility> getVisibility(String key) async {
    String k = normalizer.key(key);
    try {
      return await driver.getVisibility(k);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Change the visibility of a file.
  Future<void> setVisibility(String key, Visibility visibility) async {
    String k = normalizer.key(key);
    try {
      await driver.setVisibility(k, visibility);
    } catch (error, stack) {
      _fail(error, stack, k);
    }
  }

  /// Rethrow storage errors as they are. Wrap everything else.
  Never _fail(Object error, StackTrace stack, String key) {
    if (error is StorageException) {
      Error.throwWithStackTrace(error, stack);
    }
    if (error is PathNotFoundException) {
      Error.throwWithStackTrace(
        FileNotFoundException(key, cause: error),
        stack,
      );
    }
    Error.throwWithStackTrace(
      DriverException(key, 'Driver operation failed', cause: error),
      stack,
    );
  }
}
