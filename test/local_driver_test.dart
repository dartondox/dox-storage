import 'dart:async';
import 'dart:io';

import 'package:dox_storage/dox_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/disk_contract.dart';

void main() {
  Directory? contractDir;

  runDiskContract(
    'LocalDriver',
    () async {
      contractDir = await Directory.systemTemp.createTemp('dox_storage_');
      return Disk(LocalDriver(LocalDriverConfig(root: contractDir!.path)));
    },
    cleanUp: () async {
      await contractDir?.delete(recursive: true);
    },
  );

  group('LocalDriver', () {
    late Directory dir;
    late FixedClock clock;
    late LocalDriver driver;
    late Disk disk;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dox_storage_');
      clock = FixedClock(DateTime.utc(2025, 1, 1, 12));
      driver = LocalDriver(
        LocalDriverConfig(
          root: dir.path,
          urlBase: 'https://app.test/uploads/',
          appKey: 'test-app-key',
        ),
        clock: clock,
      );
      disk = Disk(driver);
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    test('writes files under the root folder', () async {
      await disk.put('a/b.txt', 'hi');
      expect(File(p.join(dir.path, 'a', 'b.txt')).readAsStringSync(), 'hi');
    });

    test('pathFor blocks paths outside the root', () {
      expect(() => driver.pathFor('../x'), throwsA(isA<InvalidKeyException>()));
      expect(
        () => driver.pathFor('a/../../x'),
        throwsA(isA<InvalidKeyException>()),
      );
      expect(driver.pathFor('a/b'), p.join(driver.root, 'a', 'b'));
    });

    test('a traversal key never touches files outside the root', () async {
      File outside = File(p.join(dir.parent.path, 'dox_outside.txt'));
      expect(
        disk.put('../dox_outside.txt', 'bad'),
        throwsA(isA<InvalidKeyException>()),
      );
      expect(outside.existsSync(), isFalse);
    });

    test('deleteAll() keeps the root folder', () async {
      await disk.put('a/b.txt', 'x');
      await disk.deleteAll();
      expect(dir.existsSync(), isTrue);
      expect(dir.listSync(), isEmpty);
    });

    test('getUrl uses urlBase and encodes the key', () async {
      expect(
        await disk.getUrl('my dir/a b.png'),
        'https://app.test/uploads/my%20dir/a%20b.png',
      );
    });

    test('getUrl without urlBase is unsupported', () async {
      Disk plain = Disk(LocalDriver(LocalDriverConfig(root: dir.path)));
      expect(
        plain.getUrl('a.txt'),
        throwsA(isA<UnsupportedOperationException>()),
      );
      expect(
        plain.getSignedUrl('a.txt'),
        throwsA(isA<UnsupportedOperationException>()),
      );
    });

    test('signed upload URL is unsupported', () async {
      expect(
        disk.getSignedUploadUrl('a.txt'),
        throwsA(isA<UnsupportedOperationException>()),
      );
    });

    test('visibility comes from config', () async {
      await disk.put('a.txt', 'a');
      expect(await disk.getVisibility('a.txt'), Visibility.public);
      await disk.setVisibility('a.txt', Visibility.private);
      expect(await disk.getVisibility('a.txt'), Visibility.public);
      expect(disk.getVisibility('nope'), throwsA(isA<FileNotFoundException>()));
    });

    test('permission errors map to PermissionDeniedException', () async {
      await disk.put('locked/a.txt', 'secret');
      File file = File(p.join(dir.path, 'locked', 'a.txt'));
      await Process.run('chmod', <String>['000', file.path]);
      addTearDown(() async {
        await Process.run('chmod', <String>['644', file.path]);
      });
      // root can read a file with mode 000, so there is nothing to test.
      try {
        file.readAsBytesSync();
        markTestSkipped('this user can read a mode 000 file (root?)');
        return;
      } on FileSystemException {
        // the file is locked, as expected
      }
      expect(
        disk.get('locked/a.txt'),
        throwsA(isA<PermissionDeniedException>()),
      );
    }, testOn: '!windows');

    test('a failed stream upload leaves no partial file', () async {
      await disk.put('up/a.txt', 'old');
      StreamController<List<int>> upload = StreamController<List<int>>();
      Future<void> write = disk.putStream('up/a.txt', upload.stream);
      upload.add(<int>[1, 2, 3]);
      upload.addError(StateError('client went away'));
      await upload.close();
      await expectLater(write, throwsA(anything));
      expect(await disk.getString('up/a.txt'), 'old');
      expect(Directory(p.join(dir.path, 'up')).listSync().map(_name), <String>[
        'a.txt',
      ]);

      StreamController<List<int>> fresh = StreamController<List<int>>();
      Future<void> other = disk.putStream('up/new.txt', fresh.stream);
      fresh.addError(StateError('client went away'));
      await fresh.close();
      await expectLater(other, throwsA(anything));
      expect(await disk.exists('up/new.txt'), isFalse);
      expect(Directory(p.join(dir.path, 'up')).listSync().map(_name), <String>[
        'a.txt',
      ]);
    });

    test('listAll hides temp files of running uploads', () async {
      await disk.put('up/a.txt', 'a');
      StreamController<List<int>> upload = StreamController<List<int>>();
      Future<void> write = disk.putStream('up/b.txt', upload.stream);
      upload.add(<int>[1]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        Directory(p.join(dir.path, 'up')).listSync().length,
        2,
        reason: 'the temp file is on disk while the upload runs',
      );
      ListResult flat = await disk.listAll('up');
      expect(flat.objects.map(_key), <String>['up/a.txt']);
      ListResult deep = await disk.listAll(
        '',
        const ListOptions(recursive: true),
      );
      expect(deep.objects.map(_key), <String>['up/a.txt']);
      await upload.close();
      await write;
      expect(await disk.getString('up/b.txt'), '\x01');
    });

    group('signed URLs', () {
      Future<Uri> signed(String key) async {
        String url = await disk.getSignedUrl(
          key,
          options: const SignedUrlOptions(expiresIn: Duration(minutes: 10)),
        );
        return Uri.parse(url);
      }

      test('verify accepts a fresh URL', () async {
        Uri url = await signed('reports/q1 final.pdf');
        expect(url.path, '/uploads/reports/q1%20final.pdf');
        String key = Uri.decodeComponent(
          url.path.substring('/uploads/'.length),
        );
        expect(driver.verifySignedUrl(key, url.queryParameters), isTrue);
      });

      test('verify rejects another key', () async {
        Uri url = await signed('a.pdf');
        expect(driver.verifySignedUrl('b.pdf', url.queryParameters), isFalse);
      });

      test('verify rejects a changed signature or expiry', () async {
        Uri url = await signed('a.pdf');
        Map<String, String> query = Map<String, String>.of(url.queryParameters);
        query['signature'] = '0' * 64;
        expect(driver.verifySignedUrl('a.pdf', query), isFalse);

        query = Map<String, String>.of(url.queryParameters);
        query['expires'] = '${int.parse(query['expires']!) + 1000}';
        expect(driver.verifySignedUrl('a.pdf', query), isFalse);
      });

      test('verify rejects an expired URL', () async {
        Uri url = await signed('a.pdf');
        clock.time = clock.time.add(const Duration(minutes: 11));
        expect(driver.verifySignedUrl('a.pdf', url.queryParameters), isFalse);
      });

      test('verify rejects missing params and bad keys', () async {
        expect(driver.verifySignedUrl('a.pdf', <String, String>{}), isFalse);
        Uri url = await signed('a.pdf');
        expect(
          driver.verifySignedUrl('../a.pdf', url.queryParameters),
          isFalse,
        );
      });

      test('a URL signed with another app key fails', () async {
        Uri url = await signed('a.pdf');
        LocalUrlSigner other = LocalUrlSigner('other-key', clock: clock);
        expect(other.verify('a.pdf', url.queryParameters), isFalse);
      });

      test('a URL signed for one disk fails on another disk', () async {
        Uri url = await signed('a.pdf');
        LocalUrlSigner other = LocalUrlSigner(
          'test-app-key',
          disk: 'backups',
          clock: clock,
        );
        expect(other.verify('a.pdf', url.queryParameters), isFalse);
        LocalUrlSigner same = LocalUrlSigner('test-app-key', clock: clock);
        expect(same.verify('a.pdf', url.queryParameters), isTrue);
      });

      test('LocalUrlSigner needs an app key', () {
        expect(() => LocalUrlSigner(''), throwsArgumentError);
      });
    });
  });
}

String _name(FileSystemEntity entity) => p.basename(entity.path);

String _key(DriveEntry entry) => entry.key;
