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
    Route.get('/size', (DoxRequest req) async {
      return await Storage().size(req.input('key') as String);
    });
    Route.get('/modified', (DoxRequest req) async {
      return await Storage().lastModified(req.input('key') as String);
    });
    Route.get('/download-as', (DoxRequest req) {
      return Storage().download(
        req.input('key') as String,
        name: req.input('name') as String,
      );
    });
    Route.get('/download-headers', (DoxRequest req) async {
      DownloadableFile file = await Storage().download(
        req.input('key') as String,
        name: 'report.txt',
      );
      return response(file).header('Cache-Control', 'no-store');
    });
    Route.get('/copy-missing', (DoxRequest req) {
      return Storage().copy('nope/missing.txt', 'nope/b.txt');
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
    test('putFile keeps the uuid file name and the old path shape', () async {
      String path = await Storage().putFile('images', <int>[
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

    test('put writes to the exact path', () async {
      for (String name in <String>['local', 'memory']) {
        Storage disk = Storage().disk(name);
        await disk.put('exact/a.txt', 'text');
        await disk.put('/exact/b.bin', <int>[1, 2]);
        await disk.put(
          'exact/c.txt',
          Stream<List<int>>.value(utf8.encode('stream')),
        );
        expect(utf8.decode((await disk.get('exact/a.txt'))!), 'text');
        expect(await disk.get('exact/b.bin'), <int>[1, 2]);
        expect(utf8.decode((await disk.get('exact/c.txt'))!), 'stream');
        await disk.put('exact/a.txt', 'new');
        expect(utf8.decode((await disk.get('exact/a.txt'))!), 'new');
        await expectLater(
          disk.put('../escape.txt', 'x'),
          throwsA(isA<InvalidKeyException>()),
        );
        await expectLater(disk.put('exact/d.txt', 42), throwsArgumentError);
        await disk.deleteDirectory('exact');
      }
      expect(File('$root/../escape.txt').existsSync(), isFalse);
    });

    test('putFileAs with bytes or text, putFile with a wrong type', () async {
      Storage memory = Storage().disk('memory');
      expect(await memory.putFileAs('as', <int>[7], 'a.bin'), '/as/a.bin');
      expect(await memory.putFileAs('/', 'hi', 'b.txt'), '/b.txt');
      expect(await memory.get('as/a.bin'), <int>[7]);
      expect(utf8.decode((await memory.get('b.txt'))!), 'hi');
      await expectLater(
        memory.putFileAs('as', 'x', '../c.txt'),
        throwsA(isA<InvalidKeyException>()),
      );
      await expectLater(memory.putFile('as', 'text'), throwsArgumentError);
      await memory.delete('b.txt');
      await memory.deleteDirectory('as');
    });

    test('copy, move, missing, files, allFiles, directories', () async {
      for (String name in <String>['local', 'memory']) {
        Storage disk = Storage().disk(name);
        await disk.put('list/a.txt', 'a');
        await disk.put('list/sub/b.txt', 'b');
        await disk.put('list/sub/deep/c.txt', 'c');

        expect(await disk.files('list'), <String>['/list/a.txt'], reason: name);
        expect(await disk.allFiles('/list'), <String>[
          '/list/a.txt',
          '/list/sub/b.txt',
          '/list/sub/deep/c.txt',
        ], reason: name);
        expect(await disk.directories('list'), <String>['/list/sub']);
        expect(await disk.directories('list/sub'), <String>['/list/sub/deep']);
        expect(await disk.files('list/none'), isEmpty);

        await disk.copy('/list/a.txt', 'list/copy/a.txt');
        expect(await disk.missing('list/a.txt'), isFalse);
        expect(utf8.decode((await disk.get('list/copy/a.txt'))!), 'a');

        await disk.move('list/a.txt', 'list/moved/a.txt');
        expect(await disk.missing('list/a.txt'), isTrue);
        expect(utf8.decode((await disk.get('list/moved/a.txt'))!), 'a');

        await expectLater(
          disk.copy('list/sub/b.txt', '../b.txt'),
          throwsA(isA<InvalidKeyException>()),
        );
        await expectLater(
          disk.move('../pubspec.yaml', 'list/p.yaml'),
          throwsA(isA<InvalidKeyException>()),
        );
        await expectLater(
          disk.copy('list/nope.txt', 'list/b.txt'),
          throwsA(isA<FileNotFoundException>()),
        );

        await disk.deleteDirectory('list/sub');
        expect(await disk.allFiles('list'), <String>[
          '/list/copy/a.txt',
          '/list/moved/a.txt',
        ]);
        await disk.deleteDirectory('list/none'); // a missing folder is fine
        for (String bad in <String>['', '/', '.', '../list']) {
          await expectLater(
            disk.deleteDirectory(bad),
            throwsA(isA<InvalidKeyException>()),
            reason: bad,
          );
        }
        expect(await disk.exists('list/copy/a.txt'), isTrue);
        await disk.deleteDirectory('list');
        expect(await disk.allFiles('list'), isEmpty);
      }
      expect(Directory('$root/list').existsSync(), isFalse);
      expect(File('pubspec.yaml').existsSync(), isTrue);
    });

    test('deleteDirectory of the root throws and keeps the files', () async {
      await Storage().put('keep/a.txt', 'a');
      await expectLater(
        Storage().deleteDirectory('/'),
        throwsA(isA<InvalidKeyException>()),
      );
      expect(await Storage().exists('keep/a.txt'), isTrue);
      await Storage().deleteDirectory('keep');
    });

    test('a missing file in copy is 404', () async {
      http.Response res = await http.get(Uri.parse('$baseUrl/copy-missing'));
      expect(res.statusCode, 404);
    });

    test('getVisibility and setVisibility', () async {
      Storage memory = Storage().disk('memory');
      await memory.put('vis/a.txt', 'a');
      expect(await memory.getVisibility('vis/a.txt'), Visibility.public);
      await memory.setVisibility('/vis/a.txt', Visibility.private);
      expect(await memory.getVisibility('vis/a.txt'), Visibility.private);
      await expectLater(
        memory.getVisibility('vis/none.txt'),
        throwsA(isA<FileNotFoundException>()),
      );

      // a local disk without `permissions` keeps the old behavior
      await Storage().put('vis/a.txt', 'a');
      await Storage().setVisibility('vis/a.txt', Visibility.private);
      expect(await Storage().getVisibility('vis/a.txt'), Visibility.public);
      await Storage().deleteDirectory('vis');
      await memory.deleteDirectory('vis');
    });

    test('download with a file name, safe header', () async {
      await Storage().put('dl/a.txt', 'a');
      Map<String, String> names = <String, String>{
        'Invoice 42.txt': 'attachment; filename="Invoice 42.txt"',
        'a"b.txt': r'attachment; filename="a\"b.txt"',
        'a\r\nSet-Cookie: x=1.txt':
            'attachment; filename="a__Set-Cookie: x=1.txt"',
        'résumé.txt':
            'attachment; filename="r_sum_.txt"; '
            "filename*=UTF-8''r%C3%A9sum%C3%A9.txt",
      };
      for (MapEntry<String, String> entry in names.entries) {
        http.Response res = await http.get(
          Uri.parse('$baseUrl/download-as').replace(
            queryParameters: <String, String>{
              'key': 'dl/a.txt',
              'name': entry.key,
            },
          ),
        );
        expect(res.statusCode, 200, reason: entry.key);
        expect(res.body, 'a');
        expect(res.headers['content-disposition'], entry.value);
        expect(res.headers['set-cookie'], isNull);
      }

      http.Response res = await http.get(
        Uri.parse('$baseUrl/download-headers?key=dl/a.txt'),
      );
      expect(res.body, 'a');
      expect(res.headers['cache-control'], 'no-store');
      expect(
        res.headers['content-disposition'],
        'attachment; filename="report.txt"',
      );
      await Storage().deleteDirectory('dl');
    });

    test('download streams with length and file name', () async {
      List<int> bytes = List<int>.generate(300000, (int i) => i % 256);
      String path = await Storage().putFile('big', bytes, extension: 'bin');
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

    test('size and lastModified of a missing file are 404', () async {
      for (String path in <String>['size', 'modified']) {
        http.Response res = await http.get(
          Uri.parse('$baseUrl/$path?key=/nope/missing.png'),
        );
        expect(res.statusCode, 404, reason: path);
        expect(jsonDecode(res.body), <String, dynamic>{
          'code': 'not_found',
          'message': 'file not found',
        });
      }
      await expectLater(
        Storage().size('nope/missing.png'),
        throwsA(isA<FileNotFoundException>()),
      );
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
          .putFile('notes', utf8.encode('hello'), extension: 'txt');
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

      String path = await Storage().putFile('tmp', <int>[1], extension: 'bin');
      String url = await Storage().temporaryUrl(path);
      expect(url, startsWith('$baseUrl/files/tmp/'));
      expect((await http.get(Uri.parse(url))).statusCode, 200);
    });

    test('signed local URL is served, a bad one is 403', () async {
      String path = await Storage().putFile(
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
