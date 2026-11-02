import 'dart:typed_data';

import 'package:dox_storage/dox_storage.dart';
import 'package:test/test.dart';

import 'support/disk_contract.dart';

void main() {
  runDiskContract('MemoryDriver', () async {
    return Disk(MemoryDriver());
  });

  group('MemoryDriver', () {
    test('makeDirectory does nothing and does not throw', () async {
      MemoryDriver driver = MemoryDriver();
      await Disk(driver).makeDirectory('a/b');
      expect(driver.keys, isEmpty);
    });

    test('visibility is stored per file', () async {
      Disk disk = Disk(MemoryDriver(visibility: Visibility.private));
      await disk.put('a.txt', 'a');
      expect(await disk.getVisibility('a.txt'), Visibility.private);
      await disk.setVisibility('a.txt', Visibility.public);
      expect(await disk.getVisibility('a.txt'), Visibility.public);
      await disk.put(
        'b.txt',
        'b',
        options: const WriteOptions(visibility: Visibility.public),
      );
      expect(await disk.getVisibility('b.txt'), Visibility.public);
    });

    test('visibility of a missing file throws', () async {
      Disk disk = Disk(MemoryDriver());
      expect(disk.getVisibility('x'), throwsA(isA<FileNotFoundException>()));
    });

    test('urls', () async {
      Disk disk = Disk(MemoryDriver(urlBase: 'https://cdn.test/'));
      expect(await disk.getUrl('a/b.txt'), 'https://cdn.test/a/b.txt');
      expect(await disk.getSignedUrl('a.txt'), contains('signature='));
      expect(await disk.getSignedUploadUrl('a.txt'), contains('upload=1'));
    });

    test('get returns a copy, put stores a copy', () async {
      MemoryDriver driver = MemoryDriver();
      Disk disk = Disk(driver);
      Uint8List input = Uint8List.fromList(<int>[1, 2, 3]);
      await disk.put('a.bin', input);
      input[0] = 9;
      Uint8List out = await disk.get('a.bin');
      out[1] = 9;
      expect(await disk.get('a.bin'), <int>[1, 2, 3]);
      expect(driver.keys, <String>['a.bin']);
    });

    test('metadata uses the clock and the stored content type', () async {
      FixedClock clock = FixedClock(DateTime.utc(2025, 3, 2));
      Disk disk = Disk(MemoryDriver(clock: clock));
      await disk.put('a.json', '{}');
      ObjectMetaData meta = await disk.getMetaData('a.json');
      expect(meta.size, 2);
      expect(meta.contentType, 'application/json');
      expect(meta.lastModified, DateTime.utc(2025, 3, 2));
      expect(await disk.getSignedUrl('a.json'), contains('expires='));
    });

    test('copy keeps type and visibility, options override them', () async {
      Disk disk = Disk(MemoryDriver());
      await disk.put(
        'a.txt',
        'a',
        options: const WriteOptions(visibility: Visibility.private),
      );
      await disk.copy('a.txt', 'b.txt');
      expect((await disk.getMetaData('b.txt')).contentType, 'text/plain');
      expect(await disk.getVisibility('b.txt'), Visibility.private);

      await disk.copy(
        'a.txt',
        'c.txt',
        options: const WriteOptions(
          contentType: 'text/csv',
          visibility: Visibility.public,
        ),
      );
      expect((await disk.getMetaData('c.txt')).contentType, 'text/csv');
      expect(await disk.getVisibility('c.txt'), Visibility.public);
    });

    test('move to the same key keeps the file', () async {
      Disk disk = Disk(MemoryDriver());
      await disk.put('a.txt', 'a');
      await disk.move('a.txt', 'a.txt');
      expect(await disk.getString('a.txt'), 'a');
    });

    test('deleteAll matches whole folder names', () async {
      Disk disk = Disk(MemoryDriver());
      await disk.put('a/x.txt', 'x');
      await disk.put('ab/y.txt', 'y');
      await disk.deleteAll('a');
      expect(await disk.exists('a/x.txt'), isFalse);
      expect(await disk.exists('ab/y.txt'), isTrue);
    });

    test('missing files throw on every read', () async {
      Disk disk = Disk(MemoryDriver());
      Matcher missing = throwsA(isA<FileNotFoundException>());
      await expectLater(disk.get('x'), missing);
      await expectLater(disk.getStream('x'), missing);
      await expectLater(disk.getMetaData('x'), missing);
      await expectLater(disk.setVisibility('x', Visibility.public), missing);
      await expectLater(disk.move('x', 'y'), missing);
    });
  });
}
