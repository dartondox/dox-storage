import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  Directory? atomicDir;
  runDiskContract(
    'LocalDriver with atomicWrites',
    () async {
      atomicDir = await Directory.systemTemp.createTemp('dox_storage_');
      return Disk(
        LocalDriver(
          LocalDriverConfig(root: atomicDir!.path, atomicWrites: true),
        ),
      );
    },
    cleanUp: () async {
      await atomicDir?.delete(recursive: true);
    },
  );

  Directory? modesDir;
  runDiskContract(
    'LocalDriver with permissions',
    () async {
      modesDir = await Directory.systemTemp.createTemp('dox_storage_');
      return Disk(
        LocalDriver(
          LocalDriverConfig(
            root: modesDir!.path,
            permissions: const LocalPermissions(),
          ),
        ),
      );
    },
    cleanUp: () async {
      await modesDir?.delete(recursive: true);
    },
  );

  group('LocalDriver permissions', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dox_storage_');
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    Disk modes({Visibility visibility = Visibility.public}) {
      return Disk(
        LocalDriver(
          LocalDriverConfig(
            root: dir.path,
            visibility: visibility,
            permissions: const LocalPermissions(),
          ),
        ),
      );
    }

    String mode(String key) {
      int bits = File(p.join(dir.path, key)).statSync().mode & 0x1ff;
      return bits.toRadixString(8);
    }

    test('setVisibility runs chmod, getVisibility reads the mode', () async {
      Disk disk = modes();
      await disk.put('a.txt', 'a');
      expect(mode('a.txt'), '644');
      expect(await disk.getVisibility('a.txt'), Visibility.public);
      await disk.setVisibility('a.txt', Visibility.private);
      expect(mode('a.txt'), '600');
      expect(await disk.getVisibility('a.txt'), Visibility.private);
      await disk.setVisibility('a.txt', Visibility.public);
      expect(mode('a.txt'), '644');
      expect(
        disk.setVisibility('nope.txt', Visibility.private),
        throwsA(isA<FileNotFoundException>()),
      );
      expect(
        disk.getVisibility('nope.txt'),
        throwsA(isA<FileNotFoundException>()),
      );
      expect(
        disk.setVisibility('../a.txt', Visibility.private),
        throwsA(isA<InvalidKeyException>()),
      );
    });

    test('folders use the folder modes', () async {
      Disk disk = modes();
      await disk.put('dir/a.txt', 'a');
      await disk.setVisibility('dir', Visibility.private);
      expect(mode('dir'), '700');
      expect(await disk.getVisibility('dir'), Visibility.private);
      await disk.setVisibility('dir', Visibility.public);
      expect(mode('dir'), '755');
      expect(await disk.getVisibility('dir'), Visibility.public);
    });

    test('writes use the write visibility, then the disk one', () async {
      Disk disk = modes(visibility: Visibility.private);
      await disk.put('a.txt', 'a');
      expect(mode('a.txt'), '600');
      await disk.putStream('s.txt', Stream<List<int>>.value(<int>[1]));
      expect(mode('s.txt'), '600');
      await disk.put(
        'b.txt',
        'b',
        options: const WriteOptions(visibility: Visibility.public),
      );
      expect(mode('b.txt'), '644');
      await disk.copy('a.txt', 'copy.txt');
      expect(mode('copy.txt'), '600', reason: 'a copy keeps the mode');
      await disk.move(
        'copy.txt',
        'moved.txt',
        options: const WriteOptions(visibility: Visibility.public),
      );
      expect(mode('moved.txt'), '644');
      await disk.append('a.txt', 'more');
      expect(mode('a.txt'), '600', reason: 'append keeps the mode');
      await disk.setVisibility('b.txt', Visibility.private);
      await disk.prepend('b.txt', 'more');
      expect(mode('b.txt'), '600', reason: 'prepend keeps the mode');
    });

    test('custom modes from the disk config', () async {
      DriverContract driver = const StorageDiskFactory().driver(
        'local',
        <String, dynamic>{
          'driver': 'local',
          'root': dir.path,
          'permissions': <String, dynamic>{
            'file': <String, int>{'private': 0x1a0}, // 0640
          },
        },
      );
      Disk disk = Disk(driver);
      await disk.put('a.txt', 'a');
      await disk.setVisibility('a.txt', Visibility.private);
      expect(mode('a.txt'), '640');
      expect(await disk.getVisibility('a.txt'), Visibility.private);
      LocalPermissions? on = (const StorageDiskFactory().driver(
        'x',
        <String, dynamic>{'driver': 'local', 'permissions': true},
      ) as LocalDriver).config.permissions;
      expect(on?.filePublic, 0x1a4);
      LocalDriver off = const StorageDiskFactory().driver(
        'x',
        <String, dynamic>{'driver': 'local'},
      ) as LocalDriver;
      expect(off.config.permissions, isNull);
    });

    /// A stream that, before its first chunk, saves the mode of the file
    /// that is being written: [key] itself, or the atomic temp file.
    Stream<List<int>> spy(String key, List<String> seen) async* {
      List<String> temps = dir
          .listSync()
          .map((FileSystemEntity e) => p.basename(e.path))
          .where((String n) => n.endsWith('.dox-upload.tmp'))
          .toList();
      for (String name in temps.isEmpty ? <String>[key] : temps) {
        seen.add(mode(name));
      }
      yield utf8.encode('secret');
    }

    for (bool atomic in <bool>[false, true]) {
      test('the mode is set before the content (atomic: $atomic)', () async {
        Disk disk = Disk(
          LocalDriver(
            LocalDriverConfig(
              root: dir.path,
              atomicWrites: atomic,
              visibility: Visibility.private,
              permissions: const LocalPermissions(),
            ),
          ),
        );
        List<String> seen = <String>[];
        await disk.putStream('new.txt', spy('new.txt', seen));
        expect(seen, <String>['600']);
        expect(mode('new.txt'), '600');

        // overwrite a public file as private: never public with new content
        await disk.put(
          'old.txt',
          'old',
          options: const WriteOptions(visibility: Visibility.public),
        );
        seen.clear();
        await disk.putStream(
          'old.txt',
          spy('old.txt', seen),
          options: const WriteOptions(visibility: Visibility.private),
        );
        expect(seen.last, '600');
        expect(mode('old.txt'), '600');
        expect(await disk.getString('old.txt'), 'secret');
      });

      test('a failed chmod leaves no new file (atomic: $atomic)', () async {
        Disk disk = Disk(
          LocalDriver(
            LocalDriverConfig(
              root: dir.path,
              atomicWrites: atomic,
              // not a valid mode, so chmod fails
              permissions: const LocalPermissions(filePublic: 0x10000),
            ),
          ),
        );
        await expectLater(
          disk.put('a.txt', 'a'),
          throwsA(isA<PermissionDeniedException>()),
        );
        await expectLater(
          disk.putStream('b.txt', Stream<List<int>>.value(<int>[1])),
          throwsA(isA<PermissionDeniedException>()),
        );
        expect(dir.listSync(), isEmpty);
      });

      test('an overwrite keeps the mode (atomic: $atomic)', () async {
        Disk disk = Disk(
          LocalDriver(
            LocalDriverConfig(
              root: dir.path,
              atomicWrites: atomic,
              permissions: const LocalPermissions(),
            ),
          ),
        );
        await disk.put(
          'a.txt',
          'a',
          options: const WriteOptions(visibility: Visibility.private),
        );
        await disk.put('a.txt', 'b');
        expect(mode('a.txt'), '600');
        await disk.putStream('a.txt', Stream<List<int>>.value(<int>[1]));
        expect(mode('a.txt'), '600');
        await disk.put(
          'a.txt',
          'c',
          options: const WriteOptions(visibility: Visibility.public),
        );
        expect(mode('a.txt'), '644');
        await disk.put('new.txt', 'n');
        expect(mode('new.txt'), '644');
      });
    }

    test('visibility does not follow a symlink out of the root', () async {
      Directory outside = await Directory.systemTemp.createTemp('dox_out_');
      try {
        File target = File(p.join(outside.path, 'target.txt'))
          ..writeAsStringSync('x');
        Process.runSync('chmod', <String>['644', target.path]);
        Link(p.join(dir.path, 'link.txt')).createSync(target.path);
        Disk disk = modes();
        await expectLater(
          disk.setVisibility('link.txt', Visibility.private),
          throwsA(isA<UnsupportedOperationException>()),
        );
        await expectLater(
          disk.getVisibility('link.txt'),
          throwsA(isA<UnsupportedOperationException>()),
        );
        await expectLater(
          disk.put(
            'link.txt',
            'y',
            options: const WriteOptions(visibility: Visibility.private),
          ),
          throwsA(isA<UnsupportedOperationException>()),
        );
        expect(target.statSync().mode & 0x1ff, 0x1a4);
        expect(target.readAsStringSync(), 'x');
      } finally {
        await outside.delete(recursive: true);
      }
    });

    test('new folders get the folder mode, old ones keep theirs', () async {
      Process.runSync('chmod', <String>['750', dir.path]);
      Directory(p.join(dir.path, 'old')).createSync();
      Process.runSync('chmod', <String>['711', p.join(dir.path, 'old')]);
      Disk disk = modes();
      await disk.put(
        'old/a/b/c.txt',
        'c',
        options: const WriteOptions(visibility: Visibility.private),
      );
      expect(mode('old'), '711');
      expect(mode('old/a'), '700');
      expect(mode('old/a/b'), '700');
      await disk.putStream('pub/d.txt', Stream<List<int>>.value(<int>[1]));
      expect(mode('pub'), '755');
      await disk.copy(
        'pub/d.txt',
        'cp/d.txt',
        options: const WriteOptions(visibility: Visibility.private),
      );
      expect(mode('cp'), '700');
      expect(mode('.'), '750', reason: 'the root keeps its mode');
    });
  }, testOn: '!windows');

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

    test('copy and move of a missing file make no folders', () async {
      await expectLater(
        disk.copy('nope.txt', 'a/b/c.txt'),
        throwsA(isA<FileNotFoundException>()),
      );
      await expectLater(
        disk.move('nope.txt', 'd/e.txt'),
        throwsA(isA<FileNotFoundException>()),
      );
      expect(await disk.directories(), isEmpty);
    });

    test('makeDirectory makes the folder and its parents', () async {
      await disk.makeDirectory('a/b/c');
      expect(Directory(p.join(dir.path, 'a', 'b', 'c')).existsSync(), true);
      await disk.makeDirectory('a/b/c');
    });

    test('makeDirectory on a path that is a file throws', () async {
      File(p.join(dir.path, 'taken')).writeAsStringSync('x');
      await expectLater(
        disk.makeDirectory('taken'),
        throwsA(isA<DriverException>()),
      );
    });

    test('makeDirectory in a read-only folder is permission denied', () async {
      Directory locked = Directory(p.join(dir.path, 'locked'))..createSync();
      await Process.run('chmod', <String>['555', locked.path]);
      addTearDown(() => Process.run('chmod', <String>['755', locked.path]));
      bool canWrite = true;
      try {
        Directory(p.join(locked.path, 'probe')).createSync();
      } on FileSystemException {
        canWrite = false;
      }
      if (canWrite) {
        markTestSkipped('this user can write a read-only folder, like root');
        return;
      }
      await expectLater(
        disk.makeDirectory('locked/sub'),
        throwsA(isA<PermissionDeniedException>()),
      );
    }, testOn: '!windows');

    test('directoryExists finds folders, exists finds files only', () async {
      await disk.put('a/b.txt', 'x');
      await disk.makeDirectory('empty');
      expect(await disk.directoryExists('a'), isTrue);
      expect(await disk.directoryExists('empty'), isTrue);
      expect(await disk.directoryExists(''), isTrue);
      expect(await disk.directoryExists('a/b.txt'), isFalse);
      expect(await disk.directoryExists('none'), isFalse);
      expect(await disk.exists('a'), isFalse);
      expect(await disk.exists('empty'), isFalse);
    });

    test('append uses the visibility and metadata of a subclass', () async {
      _CountingLocalDriver counting = _CountingLocalDriver(
        LocalDriverConfig(root: dir.path),
      );
      Disk sub = Disk(counting);
      await sub.put('log.txt', 'one');
      await sub.append('log.txt', 'two');
      expect(counting.visibilityReads, 1);
      expect(counting.metaDataReads, 1);
      expect(await sub.getString('log.txt'), 'one\ntwo');
    });

    test('atomicWrites works with a long file name', () async {
      Disk atomic = Disk(
        LocalDriver(LocalDriverConfig(root: dir.path, atomicWrites: true)),
      );
      String name = '${'n' * 240}.txt';
      await atomic.put(name, 'long');
      await atomic.putStream(
        'dir/$name',
        Stream<List<int>>.value(utf8.encode('stream')),
      );
      expect(File(p.join(dir.path, name)).readAsStringSync(), 'long');
      expect(File(p.join(dir.path, 'dir', name)).readAsStringSync(), 'stream');
      expect(dir.listSync().whereType<File>().length, 1);
    });

    test('append on a file with text adds a newline', () async {
      File file = File(p.join(dir.path, 'log.txt'));
      file.writeAsStringSync('one');
      await disk.append('log.txt', 'two');
      expect(file.readAsStringSync(), 'one\ntwo');
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

    test('getUrl without urlBase gives /storage/<key>', () async {
      Disk plain = Disk(LocalDriver(LocalDriverConfig(root: dir.path)));
      expect(
        await plain.getUrl('my dir/a b.png'),
        '/storage/my%20dir/a%20b.png',
      );
    });

    test('getSignedUrl without urlBase is unsupported', () async {
      Disk plain = Disk(LocalDriver(LocalDriverConfig(root: dir.path)));
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

    test(
      'atomicWrites: a failed stream upload leaves no partial file',
      () async {
        Disk disk = _atomic(dir);
        await disk.put('up/a.txt', 'old');
        StreamController<List<int>> upload = StreamController<List<int>>();
        Future<void> write = disk.putStream('up/a.txt', upload.stream);
        upload.add(<int>[1, 2, 3]);
        upload.addError(StateError('client went away'));
        await upload.close();
        await expectLater(write, throwsA(anything));
        expect(await disk.getString('up/a.txt'), 'old');
        expect(
          Directory(p.join(dir.path, 'up')).listSync().map(_name),
          <String>['a.txt'],
        );

        StreamController<List<int>> fresh = StreamController<List<int>>();
        Future<void> other = disk.putStream('up/new.txt', fresh.stream);
        fresh.addError(StateError('client went away'));
        await fresh.close();
        await expectLater(other, throwsA(anything));
        expect(await disk.exists('up/new.txt'), isFalse);
        expect(
          Directory(p.join(dir.path, 'up')).listSync().map(_name),
          <String>['a.txt'],
        );
      },
    );

    test('atomicWrites: listAll hides temp files of uploads', () async {
      Disk disk = _atomic(dir);
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

    test('by default a write goes into the file, like 3.0.1', () async {
      await disk.put('h/a.txt', 'old');
      String path = p.join(dir.path, 'h', 'a.txt');
      // hard link: both names see the new content
      await Process.run('ln', <String>[path, p.join(dir.path, 'h', 'b.txt')]);
      // mode set by hand stays
      await Process.run('chmod', <String>['600', path]);
      await disk.put('h/a.txt', 'new');
      expect(await disk.getString('h/b.txt'), 'new');
      expect(File(path).statSync().mode & 511, 384); // 0600
      await disk.putStream('h/a.txt', Stream<List<int>>.value(<int>[65]));
      expect(await disk.getString('h/b.txt'), 'A');

      // a dangling symlink stays a link, and its target is made
      Link link = Link(p.join(dir.path, 'h', 'link.txt'));
      await link.create(p.join(dir.path, 'h', 'target.txt'));
      await disk.put('h/link.txt', 'via link');
      expect(await FileSystemEntity.isLink(link.path), isTrue);
      expect(await disk.getString('h/target.txt'), 'via link');

      // no temp files are hidden from listAll
      await disk.put('h/x${StorageConstants.localTempSuffix}', 'mine');
      ListResult list = await disk.listAll('h');
      expect(
        list.objects.map(_key),
        contains('h/x${StorageConstants.localTempSuffix}'),
      );
    }, testOn: '!windows');

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

      test('an old format URL from 3.0.1 still works until it expires', () {
        LocalUrlSigner signer = LocalUrlSigner(
          'test-app-key',
          disk: 'backups',
          clock: clock,
        );
        Map<String, String> query = _oldQuery('a.pdf', clock, 10);
        expect(signer.verify('a.pdf', query), isTrue);
        expect(driver.verifySignedUrl('a.pdf', query), isTrue);
        expect(driver.verifySignedUrl('b.pdf', query), isFalse);
        clock.time = clock.time.add(const Duration(minutes: 11));
        expect(signer.verify('a.pdf', query), isFalse);
      });

      test('a new URL does not open a key that looks like new text', () {
        LocalUrlSigner signer = LocalUrlSigner(
          'test-app-key',
          disk: 'd',
          clock: clock,
        );
        Uri url = Uri.parse(
          signer.sign('https://app.test', 'k', const Duration(minutes: 5)),
        );
        expect(signer.verify('k', url.queryParameters), isTrue);
        expect(signer.verify('1:d\nk', url.queryParameters), isFalse);
      });

      test('an old URL for key `1:d\\nk` does not open key k on disk d', () {
        LocalUrlSigner signer = LocalUrlSigner(
          'test-app-key',
          disk: 'd',
          clock: clock,
        );
        Map<String, String> query = _oldQuery('1:d\nk', clock, 10);
        expect(signer.verify('1:d\nk', query), isTrue);
        expect(signer.verify('k', query), isFalse);
      });

      test('LocalUrlSigner needs an app key', () {
        expect(() => LocalUrlSigner(''), throwsArgumentError);
      });
    });
  });
}

Disk _atomic(Directory dir) {
  return Disk(
    LocalDriver(LocalDriverConfig(root: dir.path, atomicWrites: true)),
  );
}

/// Query of a signed URL in the 3.0.1 format: HMAC of `key\nexpires`.
Map<String, String> _oldQuery(String key, FixedClock clock, int minutes) {
  int expires = clock.time
      .add(Duration(minutes: minutes))
      .millisecondsSinceEpoch;
  String signature = Hmac(
    sha256,
    utf8.encode('test-app-key'),
  ).convert(utf8.encode('$key\n$expires')).toString();
  return <String, String>{'expires': '$expires', 'signature': signature};
}

String _name(FileSystemEntity entity) => p.basename(entity.path);

String _key(DriveEntry entry) => entry.key;

/// A LocalDriver with its own visibility and metadata, to check `append`
/// still reads them.
class _CountingLocalDriver extends LocalDriver {
  _CountingLocalDriver(super.config);

  int visibilityReads = 0;
  int metaDataReads = 0;

  @override
  Future<Visibility> getVisibility(String key) {
    visibilityReads++;
    return super.getVisibility(key);
  }

  @override
  Future<ObjectMetaData> getMetaData(String key) {
    metaDataReads++;
    return super.getMetaData(key);
  }
}
