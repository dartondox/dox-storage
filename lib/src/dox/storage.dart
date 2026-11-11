import 'dart:io';
import 'dart:typed_data';

import 'package:dox_core/dox_core.dart';
import 'package:mime/mime.dart';

import '../disk.dart';
import '../drive_manager.dart';
import '../driver_contract.dart';
import '../drivers/local_driver.dart';
import '../exceptions.dart';
import '../types.dart';
import 'storage_config.dart';
import 'storage_file_controller.dart';

/// Storage facade for Dox apps.
///
/// Disks come from `StorageProvider`. Without it, `Storage()` has one
/// `local` disk in the `storage` folder. Files are read as streams, so a
/// big file is never loaded into memory to send it.
/// ```
/// String path = await Storage().put('images', bytes, extension: 'png');
/// await Storage().put('notes/a.txt', 'hello', exact: true);
/// return Storage().disk('s3').download(path);
/// Disk s3 = Storage().use('s3'); // full dox_storage API
/// ```
class Storage {
  /// [manager] is the `dox_storage` DriveManager. Default is
  /// [Storage.manager].
  Storage({this._manager});

  static DriveManager? _shared;

  /// The disks of this isolate. `StorageProvider` sets them at start.
  /// Replace one disk in tests with `Storage.manager.fake('s3')`.
  static DriveManager get manager {
    return _shared ??= StorageDiskFactory.fromApp().create(
      const StorageConfig(),
    );
  }

  static set manager(DriveManager value) => _shared = value;

  /// serve files of a storage disk at `GET <path>/<key>`.
  /// with [signed] (default) only URLs from `Storage().signedUrl()` work,
  /// others get 403. set the disk `url` option to the full url of [path].
  /// [signed] needs a local disk. on another disk every request gets 403,
  /// and the exception handler
  /// reports why.
  ///
  /// html, svg, xml and javascript files are always sent as a download in
  /// a sandbox, so an uploaded file can not run script on the app origin.
  /// with [download] every file is sent as a download
  /// (`Content-Disposition: attachment`). use it for user uploads.
  /// ```
  /// Storage.route('files'); // GET /files/{key*}
  /// Storage.route('uploads', download: true);
  /// String url = await Storage().signedUrl('images/a.png');
  /// ```
  static Route route(
    String path, {
    String? disk,
    bool signed = true,
    bool download = false,
  }) {
    return Route.get(
      '$path/{key*}',
      StorageFileController(disk, signed, download: download).serve,
    );
  }

  final DriveManager? _manager;
  String? _disk;

  /// set the disk name
  /// ```
  /// Storage().disk('local').get('image.jpg');
  /// ```
  Storage disk(String disk) {
    _disk = disk;
    return this;
  }

  /// The `dox_storage` disk, for the full API (copy, move, list, ...).
  Disk use([String? name]) {
    return (_manager ?? manager).use(name ?? _disk);
  }

  /// store the request file into storage, with a new uuid file name.
  /// a temp file on the local disk is moved, not read into memory.
  /// ```
  /// RequestFile file = req.input('avatar');
  /// String path = await Storage().putRequestFile('images/avatar', file);
  /// ```
  ///
  /// the extension comes from the file name, unless the bytes are a known
  /// format that does not match it. then the extension of the bytes is
  /// used, so a png named `a.html` is stored as `.png`, not served as html.
  Future<String> putRequestFile(String folder, RequestFile requestFile) async {
    String? extension = await _extension(requestFile);
    return _storeRequestFile(_newKey(folder, extension), requestFile);
  }

  /// store the request file into storage with the given [name], like
  /// Laravel `putFileAs`. an old file with the same name is replaced.
  /// do not pass the raw client file name. make your own name, like
  /// `u1.png`. the returned path is the cleaned key (`a\b.png` gives
  /// `/a/b.png`), and a name like `../x.png` throws [InvalidKeyException].
  /// ```
  /// String path = await Storage().putRequestFileAs('avatars', 'u1.png', file);
  /// ```
  Future<String> putRequestFileAs(
    String folder,
    String name,
    RequestFile requestFile,
  ) {
    return _storeRequestFile(_join(folder, name), requestFile);
  }

  Future<String> _storeRequestFile(String key, RequestFile requestFile) async {
    Disk target = use();
    String clean = target.normalizer.key(key);
    DriverContract driver = target.driver;
    // With `permissions` on, the stream write sets the mode before the
    // content is there. A rename would bring the mode of the temp file.
    if (driver is LocalDriver && driver.config.permissions == null) {
      await requestFile.moveTo(driver.pathFor(clean));
    } else {
      await target.putStream(clean, requestFile.stream());
    }
    return '/$clean';
  }

  /// store a file in [path] (a folder) with a new uuid file name and
  /// return its path. this is the same as [putFile]. [contents] is the
  /// bytes (`List<int>`) or a [RequestFile]. the extension is [extension],
  /// or it is guessed from the bytes.
  ///
  /// with `exact: true`, [contents] is written to exactly [path], like
  /// Laravel `Storage::put`. an old file at [path] is replaced. [contents]
  /// can be a `String` (saved as UTF-8), a `List<int>` or a
  /// `Stream<List<int>>`. the returned path is the cleaned key. do not
  /// pass [extension] with `exact: true`.
  /// ```
  /// String path = await Storage().put('images', bytes, extension: 'png');
  /// await Storage().put('reports/2026-11.csv', csv, exact: true);
  /// ```
  Future<String> put(
    String path,
    Object contents, {
    String? extension,
    bool exact = false,
  }) async {
    if (!exact) {
      return putFile(path, contents, extension: extension);
    }
    if (extension != null) {
      throw ArgumentError.value(
        extension,
        'extension',
        'is not used with exact: true',
      );
    }
    Disk target = use();
    String clean = target.normalizer.key(_key(path));
    await target.put(clean, contents);
    return '/$clean';
  }

  /// store a file in [folder] with a new uuid file name and return its
  /// path, like Laravel `putFile`. [file] is a [RequestFile] or the bytes
  /// (`List<int>`). [put] without `exact: true` does the same.
  ///
  /// for bytes, the extension is [extension], or it is guessed from the
  /// bytes. for a [RequestFile], see [putRequestFile]; [extension] is not
  /// used.
  /// ```
  /// String path = await Storage().putFile('avatars', file);
  /// String path = await Storage().putFile('images', bytes, extension: 'png');
  /// ```
  Future<String> putFile(
    String folder,
    Object file, {
    String? extension,
  }) async {
    if (file is RequestFile) {
      return putRequestFile(folder, file);
    }
    if (file is! List<int>) {
      throw ArgumentError.value(
        file,
        'file',
        'must be a RequestFile or List<int>',
      );
    }
    extension ??= lookupMimeType('', headerBytes: file)?.split('/').last;
    String key = _newKey(folder, extension);
    await use().put(key, file);
    return '/$key';
  }

  /// store a file in [folder] with the given [name] and return its path,
  /// like Laravel `putFileAs`. an old file with the same name is replaced.
  /// [file] is a [RequestFile], or anything `put(exact: true)` takes.
  ///
  /// do not pass the raw client file name. make your own name, like
  /// `u1.png`. the returned path is the cleaned key (`a\b.png` gives
  /// `/a/b.png`), and a name like `../x.png` throws [InvalidKeyException].
  /// ```
  /// String path = await Storage().putFileAs('avatars', file, 'u1.png');
  /// ```
  Future<String> putFileAs(String folder, Object file, String name) async {
    if (file is RequestFile) {
      return putRequestFileAs(folder, name, file);
    }
    Disk target = use();
    String clean = target.normalizer.key(_join(folder, name));
    await target.put(clean, file);
    return '/$clean';
  }

  /// get stored file as bytes, or null when it does not exist.
  /// prefer [stream] or [download] to send a file.
  Future<Uint8List?> get(String filename) async {
    try {
      return await use().get(_key(filename));
    } on FileNotFoundException {
      return null;
    }
  }

  /// check the file exists in storage
  Future<bool> exists(String filename) {
    return use().exists(_key(filename));
  }

  /// delete file from storage. a missing file is not an error.
  Future<void> delete(String filename) {
    return use().delete(_key(filename));
  }

  /// true when the file does not exist. the opposite of [exists].
  Future<bool> missing(String filename) {
    return use().missing(_key(filename));
  }

  /// copy a file to [to]. an old file at [to] is replaced. on S3 the copy
  /// is done by S3, the bytes do not pass through the app. an S3 copy
  /// works for files up to 5 GiB. a missing file throws a
  /// [FileNotFoundException] that Dox answers with 404.
  /// ```
  /// await Storage().copy('avatars/a.png', 'backup/a.png');
  /// ```
  Future<void> copy(String from, String to) {
    return _http404(use().copy(_key(from), _key(to)));
  }

  /// move a file to [to]. an old file at [to] is replaced. a missing file
  /// throws a [FileNotFoundException] that Dox answers with 404.
  /// ```
  /// await Storage().move('tmp/a.png', 'avatars/a.png');
  /// ```
  Future<void> move(String from, String to) {
    return _http404(use().move(_key(from), _key(to)));
  }

  /// paths of the files directly in [folder], like Laravel `files`.
  /// files in sub-folders are not in the list; see [allFiles].
  /// each path starts with `/`, like the path of [putFile].
  /// ```
  /// List<String> paths = await Storage().files('avatars');
  /// ```
  Future<List<String>> files([String folder = '']) async {
    return _paths(await use().files(_key(folder)));
  }

  /// paths of every file under [folder], in all sub-folders too.
  Future<List<String>> allFiles([String folder = '']) async {
    return _paths(await use().allFiles(_key(folder)));
  }

  /// paths of the folders directly in [folder], like Laravel
  /// `directories`. on S3 and memory disks a folder is there when a file
  /// is under it.
  Future<List<String>> directories([String folder = '']) async {
    return _paths(await use().directories(_key(folder)));
  }

  /// delete a folder and every file in it. a missing folder is not an
  /// error. the root (`''` or `/`) throws [InvalidKeyException], so a bad
  /// path can not empty the disk. use `Storage().use().deleteAll()` for
  /// that.
  Future<void> deleteDirectory(String folder) {
    return use().deleteDirectory(_key(folder));
  }

  /// visibility of a file: [Visibility.public] or [Visibility.private].
  /// on a local disk it is the disk `visibility` option, unless the disk
  /// has the `permissions` option.
  Future<Visibility> getVisibility(String filename) {
    return _http404(use().getVisibility(_key(filename)));
  }

  /// change the visibility of a file. on S3 it sets the ACL. on a local
  /// disk it does nothing, unless the disk has the `permissions` option:
  /// then it changes the file mode.
  /// ```
  /// await Storage().setVisibility('avatars/a.png', Visibility.private);
  /// ```
  Future<void> setVisibility(String filename, Visibility visibility) {
    return _http404(use().setVisibility(_key(filename), visibility));
  }

  List<String> _paths(List<String> keys) {
    List<String> paths = <String>[];
    for (String key in keys) {
      paths.add('/$key');
    }
    return paths;
  }

  /// add text to the end of a file. a missing file is made.
  /// [separator] is added only when the file is not empty.
  Future<void> append(String filename, String data, {String separator = '\n'}) {
    return use().append(_key(filename), data, separator: separator);
  }

  /// add text to the start of a file. a missing file is made.
  /// [separator] is added only when the file is not empty.
  Future<void> prepend(
    String filename,
    String data, {
    String separator = '\n',
  }) {
    return use().prepend(_key(filename), data, separator: separator);
  }

  /// make a folder on a local disk. on other disks it does nothing.
  Future<void> makeDirectory(String path) {
    return use().makeDirectory(_key(path));
  }

  /// size of a file in bytes. a missing file throws a
  /// [FileNotFoundException] that Dox answers with 404, like [stream].
  Future<int> size(String filename) {
    return _http404(use().size(_key(filename)));
  }

  /// last modified time of a file. a missing file throws a
  /// [FileNotFoundException] that Dox answers with 404, like [stream].
  Future<DateTime> lastModified(String filename) {
    return _http404(use().lastModified(_key(filename)));
  }

  Future<T> _http404<T>(Future<T> future) async {
    try {
      return await future;
    } on FileNotFoundException catch (error, stack) {
      Error.throwWithStackTrace(
        _FileNotFoundHttpException(error.key, cause: error.cause),
        stack,
      );
    }
  }

  /// public URL of a file (needs `url` in the disk config)
  Future<String> url(String filename) {
    return use().getUrl(_key(filename));
  }

  /// a URL that works for [expiresIn]. For the local disk, serve it with
  /// `Storage.route('files')` and set the disk `url` to that path.
  Future<String> signedUrl(
    String filename, {
    Duration expiresIn = const Duration(minutes: 30),
  }) {
    return use().getSignedUrl(
      _key(filename),
      options: SignedUrlOptions(expiresIn: expiresIn),
    );
  }

  /// the same as [signedUrl]. Laravel calls it `temporaryUrl`.
  Future<String> temporaryUrl(
    String filename, {
    Duration expiresIn = const Duration(minutes: 30),
  }) {
    return signedUrl(filename, expiresIn: expiresIn);
  }

  /// true when the folder exists. [exists] is true for files only.
  /// on S3 and memory disks a folder exists when a file is under it.
  /// the root (`''` or `/`) is always true.
  Future<bool> directoryExists(String path) {
    return use().directoryExists(_key(path));
  }

  /// return the file as a stream, from any disk.
  /// ```
  /// return await Storage().stream('images/avatar/sample.jpeg');
  /// ```
  Future<StreamFile> stream(String filename) async {
    String key = _key(filename);
    Disk target = use();
    try {
      ObjectMetaData meta = await target.getMetaData(key);
      return StreamFile(
        ContentType.parse(meta.contentType),
        await target.getStream(key),
        length: meta.size,
      );
    } on FileNotFoundException {
      // the Dox error handler turns it into a 404 response
      // ignore: only_throw_errors
      throw NotFoundHttpException(message: 'file not found');
    } on InvalidKeyException {
      // a key like `../pubspec.yaml` points outside the disk.
      // answer 404, the same as a missing file.
      // ignore: only_throw_errors
      throw NotFoundHttpException(message: 'file not found');
    }
  }

  /// return the file as a download (Content-Disposition: attachment).
  /// [name] is the file name the browser saves, like Laravel
  /// `download($path, $name)`. without it, the last part of the path is
  /// used. any name is safe: quotes are escaped, control characters
  /// (like a new line) become `_`, and a non-ASCII name is also sent as
  /// `filename*=UTF-8''...`.
  /// ```
  /// return await Storage().download('invoices/42.pdf', name: 'Invoice 42.pdf');
  /// ```
  /// to add headers, wrap it in a response:
  /// ```
  /// return response(await Storage().download('a.pdf'))
  ///     .header('Cache-Control', 'no-store');
  /// ```
  Future<DownloadableFile> download(String filename, {String? name}) async {
    StreamFile file = await stream(filename);
    return DownloadableFile(
      file.contentType,
      file.stream,
      name ?? filename.split('/').last,
      length: file.length,
    );
  }

  /// old paths start with `/`. dox_storage keys do not.
  String _key(String filename) {
    int start = 0;
    while (start < filename.length && filename.codeUnitAt(start) == 47) {
      start++;
    }
    return filename.substring(start);
  }

  String _newKey(String folder, String? extension) {
    if (extension == null) throw ArgumentError('invalid file');
    return _join(folder, '${uuid.v4()}.$extension');
  }

  String _join(String folder, String name) {
    String dir = _key(folder);
    return dir.isEmpty ? name : '$dir/$name';
  }

  /// byte formats whose name is not a file extension
  static const Map<String, String> _formatExtensions = <String, String>{
    'ftyp': 'mp4',
    'ole': 'bin',
  };

  Future<String?> _extension(RequestFile file) async {
    String name = file.extension;
    String? format = FileTypes.sniff(file.head);
    if (format != null &&
        (name.isEmpty || !FileTypes.matches(file, <String>[name]))) {
      return _formatExtensions[format] ?? format;
    }
    return name.isEmpty ? await _sniff(file.stream()) : name;
  }

  Future<String?> _sniff(Stream<List<int>> stream) async {
    List<int> head = <int>[];
    await for (List<int> chunk in stream) {
      head.addAll(chunk);
      if (head.length >= defaultMagicNumbersMaxLength) break;
    }
    return lookupMimeType('', headerBytes: head)?.split('/').last;
  }
}

/// A [FileNotFoundException] that Dox answers with 404, not 500.
/// `on FileNotFoundException` still catches it.
class _FileNotFoundHttpException extends FileNotFoundException
    implements IHttpException {
  _FileNotFoundHttpException(super.key, {super.cause});

  @override
  int code = HttpStatus.notFound;

  @override
  String errorCode = 'not_found';

  // ponytail: the message is fixed, like the one of [Storage.stream].
  @override
  set message(dynamic value) {}

  @override
  dynamic toResponse() {
    return <String, dynamic>{'code': errorCode, 'message': 'file not found'};
  }
}
