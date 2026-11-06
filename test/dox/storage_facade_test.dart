import 'dart:convert';
import 'dart:io';

import 'package:dox_core/dox_core.dart';
import 'package:dox_storage/dox_storage.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'free_port.dart';

/// a free port, known before the start: the storage disk URL needs it.
/// Set in setUpAll, before [config] is read.
late int port;
String get baseUrl => 'http://localhost:$port';
const String root = 'storage/test-disk';

class FileRouter extends Router {
  @override
  void register() {
    Storage.route('files');
    Storage.route('public-files', signed: false);
    Storage.route('memory-files', disk: 'memory');
    Route.get('/download', (DoxRequest req) {
      return Storage().download(req.input('key') as String);
    });
    Route.get('/memory', (DoxRequest req) {
      return Storage().disk('memory').stream(req.input('key') as String);
    });
  }
}

AppConfig config = AppConfig(
  appKey: '4HyiSrq4N5Nfg6bOadIhbFEI8zbUkpxt',

  serverPort: port,
  totalIsolate: 1,
  routers: <Router>[FileRouter()],
  providers: <DoxProvider>[
    StorageProvider(
      StorageConfig(
        disks: <String, Map<String, dynamic>>{
          'local': <String, dynamic>{
            'driver': 'local',
            'root': root,
            'url': '$baseUrl/files',
          },
          'memory': <String, dynamic>{'driver': 'memory'},
        },
      ),
    ),
  ],
  exceptionHandler: const _QuietExceptionHandler(),
);

void main() {
  setUpAll(() async {
    port = await freePort();
    Dox().initialize(config);
    await Dox().startServer();
  });

  tearDownAll(() async {
    await Dox().server.close(force: true);
    if (Directory(root).existsSync()) {
      Directory(root).deleteSync(recursive: true);
    }
  });

  group('Storage facade |', () {
    test('put keeps the uuid file name and the old path shape', () async {
      String path = await Storage().put('images', <int>[
        1,
        2,
        3,
      ], extension: 'bin');
      expect(path, matches(RegExp(r'^/images/[0-9a-f-]+\.bin$')));
      expect(await Storage().exists(path), isTrue);
      expect(await Storage().get(path), <int>[1, 2, 3]);
      expect(File('$root$path').existsSync(), isTrue);

      await Storage().delete(path);
      expect(await Storage().exists(path), isFalse);
      expect(await Storage().get(path), isNull);
    });

    test('download streams with length and file name', () async {
      List<int> bytes = List<int>.generate(300000, (int i) => i % 256);
      String path = await Storage().put('big', bytes, extension: 'bin');
      http.Response res = await http.get(
        Uri.parse('$baseUrl/download?key=$path'),
      );
      expect(res.statusCode, 200);
      expect(res.bodyBytes, bytes);
      expect(res.headers['content-length'], '300000');
      expect(
        res.headers['content-disposition'],
        'attachment; filename="${path.split('/').last}"',
      );
    });

    test('missing file is 404', () async {
      http.Response res = await http.get(
        Uri.parse('$baseUrl/download?key=/nope/missing.png'),
      );
      expect(res.statusCode, 404);
    });

    test('a key outside the disk is 404, not 500', () async {
      List<String> urls = <String>[
        '$baseUrl/public-files/..%2Fpubspec.yaml',
        '$baseUrl/download?key=..%2Fpubspec.yaml',
      ];
      for (String url in urls) {
        http.Response res = await http.get(Uri.parse(url));
        expect(res.statusCode, 404, reason: url);
        expect(res.body, isNot(contains('dox_storage')), reason: url);
      }
    });

    test('a key with a real percent is decoded once', () async {
      await Storage().use().put('pct/100%.txt', utf8.encode('pct'));
      http.Response res = await http.get(
        Uri.parse('$baseUrl/public-files/pct/100%25.txt'),
      );
      expect(res.statusCode, 200);
      expect(res.body, 'pct');
    });

    test('unsigned and signed routes answer 404 for a missing file', () async {
      http.Response res = await http.get(
        Uri.parse('$baseUrl/public-files/nope/missing.txt'),
      );
      expect(res.statusCode, 404);
      String url = await Storage().signedUrl('/nope/missing.txt');
      expect((await http.get(Uri.parse(url))).statusCode, 404);
    });

    test(
      'signed route is 403 for a bad signature, before any file read',
      () async {
        http.Response res = await http.get(
          Uri.parse('$baseUrl/files/nope/missing.txt?signature=bad&expires=1'),
        );
        expect(res.statusCode, 403);
        http.Response outside = await http.get(
          Uri.parse('$baseUrl/files/..%2Fpubspec.yaml'),
        );
        expect(outside.statusCode, 403);
      },
    );

    test('a signed route on a non-local disk is 403 and reports why', () async {
      _QuietExceptionHandler.lastError = null;
      http.Response res = await http.get(
        Uri.parse('$baseUrl/memory-files/a.txt?signature=x&expires=1'),
      );
      expect(res.statusCode, 403);
      expect(
        _QuietExceptionHandler.lastError,
        isA<UnsupportedOperationException>().having(
          (UnsupportedOperationException e) => e.message,
          'message',
          contains('Disk "memory" uses MemoryDriver'),
        ),
      );
    });

    test('memory disk works through the same facade', () async {
      String path = await Storage()
          .disk('memory')
          .put('notes', utf8.encode('hello'), extension: 'txt');
      http.Response res = await http.get(
        Uri.parse('$baseUrl/memory?key=$path'),
      );
      expect(res.body, 'hello');
      expect(res.headers['content-type'], startsWith('text/plain'));
    });

    test('append, prepend, size, lastModified, makeDirectory', () async {
      Storage memory = Storage().disk('memory');
      await memory.append('/facade/log.txt', 'b');
      await memory.append('/facade/log.txt', 'c');
      await memory.prepend('/facade/log.txt', 'a');
      expect(utf8.decode((await memory.get('/facade/log.txt'))!), 'a\nb\nc');
      expect(await memory.size('/facade/log.txt'), 5);
      expect(await memory.lastModified('/facade/log.txt'), isA<DateTime>());
      await memory.makeDirectory('/facade/dir');
      await Storage().makeDirectory('facade-dir/sub');
      expect(Directory('$root/facade-dir/sub').existsSync(), true);
      await Directory('$root/facade-dir').delete(recursive: true);
    });

    test('directoryExists and temporaryUrl', () async {
      Storage memory = Storage().disk('memory');
      await memory.append('/dirs/a/b.txt', 'x');
      expect(await memory.directoryExists('/dirs/a'), isTrue);
      expect(await memory.exists('/dirs/a'), isFalse);
      expect(await memory.directoryExists('/dirs/none'), isFalse);

      await Storage().makeDirectory('facade-empty');
      expect(await Storage().directoryExists('/facade-empty'), isTrue);
      expect(await Storage().exists('/facade-empty'), isFalse);
      await Directory('$root/facade-empty').delete();

      String path = await Storage().put('tmp', <int>[1], extension: 'bin');
      String url = await Storage().temporaryUrl(path);
      expect(url, startsWith('$baseUrl/files/tmp/'));
      expect((await http.get(Uri.parse(url))).statusCode, 200);
    });

    test('signed local URL is served, a bad one is 403', () async {
      String path = await Storage().put(
        'secret',
        utf8.encode('top'),
        extension: 'txt',
      );
      String url = await Storage().signedUrl(path);
      expect(url, startsWith('$baseUrl/files/secret/'));

      http.Response ok = await http.get(Uri.parse(url));
      expect(ok.statusCode, 200);
      expect(ok.body, 'top');

      http.Response bad = await http.get(
        Uri.parse(url.replaceFirst('signature=', 'signature=x')),
      );
      expect(bad.statusCode, 403);

      http.Response unsigned = await http.get(Uri.parse('$baseUrl/files$path'));
      expect(unsigned.statusCode, 403);

      http.Response open = await http.get(
        Uri.parse('$baseUrl/public-files$path'),
      );
      expect(open.body, 'top');
    });
  });
}

/// does not log the errors the tests cause on purpose
class _QuietExceptionHandler extends ExceptionHandler {
  const _QuietExceptionHandler();

  /// the last error, so a test can check it
  static Object? lastError;

  @override
  void report(Object error, StackTrace stackTrace) {
    lastError = error;
  }
}
