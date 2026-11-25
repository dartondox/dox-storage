@Tags(<String>['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_storage/dox_storage.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/disk_contract.dart';

/// Runs against a real Azurite. Start it with:
///
/// docker run -d --rm --name dox-storage-azurite -p 10000:10000 \
///   mcr.microsoft.com/azure-storage/azurite \
///   azurite-blob --blobHost 0.0.0.0 --skipApiVersionCheck --loose
///
/// Skipped when Azurite is not reachable, but fails when CI=true. Override
/// with AZURITE_ENDPOINT, AZURITE_ACCOUNT and AZURITE_KEY.
String endpoint =
    Platform.environment['AZURITE_ENDPOINT'] ??
    'http://127.0.0.1:10000/devstoreaccount1';
String account = Platform.environment['AZURITE_ACCOUNT'] ?? 'devstoreaccount1';
// The public Azurite dev account key (a known false secret).
String accountKey =
    Platform.environment['AZURITE_KEY'] ??
    'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==';
const String container = 'dox-storage-test';

/// Any HTTP answer means Azurite is up.
Future<bool> azuriteIsUp() async {
  try {
    await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 2));
    return true;
  } catch (_) {
    return false;
  }
}

AzureBlobDriver azuriteDriver({String? key, int? blockSize}) {
  return AzureBlobDriver(
    AzureBlobDriverConfig(
      accountName: account,
      accountKey: key ?? accountKey,
      container: container,
      endpoint: endpoint,
      blockSize: blockSize ?? StorageConstants.azureDefaultBlockSize,
    ),
  );
}

Future<void> createContainer(AzureBlobDriver driver) async {
  http.Response response = await driver.client.send(
    'PUT',
    driver.client.containerUri(),
  );
  // 409 means the container is already there.
  if (response.statusCode != 201 && response.statusCode != 409) {
    throw StateError('Could not create container: ${response.body}');
  }
}

Future<void> setContainerAccess(AzureBlobDriver driver, bool public) async {
  http.Response response = await driver.client.send(
    'PUT',
    driver.client.containerUri(<String, String>{'comp': 'acl'}),
    headers: public
        ? <String, String>{'x-ms-blob-public-access': 'blob'}
        : const <String, String>{},
  );
  driver.client.check(response, container);
}

Future<void> main() async {
  bool up = await azuriteIsUp();
  if (!up && Platform.environment['CI'] == 'true') {
    test('Azurite is reachable in CI', () {
      fail('Azurite is not reachable at $endpoint');
    });
    return;
  }
  String? skip = up ? null : 'Azurite is not reachable at $endpoint';

  group('Azurite', () {
    AzureBlobDriver? contractDriver;

    runDiskContract(
      'AzureBlobDriver on Azurite',
      () async {
        contractDriver = azuriteDriver();
        await createContainer(contractDriver!);
        return Disk(contractDriver!);
      },
      cleanUp: () async {
        contractDriver?.close();
      },
    );

    group('AzureBlobDriver on Azurite extras', () {
      late AzureBlobDriver driver;
      late Disk disk;

      setUpAll(() async {
        driver = azuriteDriver(blockSize: 1024 * 1024);
        await createContainer(driver);
        disk = Disk(driver);
      });

      tearDownAll(() async {
        await disk.deleteAll('extras');
        driver.close();
      });

      test('signed GET URL works without credentials', () async {
        await disk.put('extras/signed.txt', 'secret content');
        String url = await disk.getSignedUrl(
          'extras/signed.txt',
          options: const SignedUrlOptions(
            contentDisposition: 'attachment; filename="s.txt"',
          ),
        );
        http.Response response = await http.get(Uri.parse(url));
        expect(response.statusCode, 200, reason: response.body);
        expect(response.body, 'secret content');
        expect(
          response.headers['content-disposition'],
          'attachment; filename="s.txt"',
        );
      });

      test('plain GET without a signature is denied', () async {
        await disk.put('extras/private.txt', 'x');
        http.Response response = await http.get(
          Uri.parse(await disk.getUrl('extras/private.txt')),
        );
        expect(response.statusCode, anyOf(403, 404));
      });

      test('signed upload URL accepts a PUT', () async {
        String url = await disk.getSignedUploadUrl('extras/uploaded file.json');
        http.Response response = await http.put(
          Uri.parse(url),
          headers: <String, String>{
            'x-ms-blob-type': 'BlockBlob',
            'content-type': 'application/json',
          },
          body: '{"ok":true}',
        );
        expect(response.statusCode, 201, reason: response.body);
        expect(
          await disk.getString('extras/uploaded file.json'),
          '{"ok":true}',
        );
        ObjectMetaData meta = await disk.getMetaData(
          'extras/uploaded file.json',
        );
        expect(meta.contentType, startsWith('application/json'));
      });

      test('signed upload URL can not read', () async {
        await disk.put('extras/read.txt', 'x');
        String url = await disk.getSignedUploadUrl('extras/read.txt');
        http.Response response = await http.get(Uri.parse(url));
        expect(response.statusCode, 403);
      });

      test('putStream with several blocks', () async {
        int size = 3 * 1024 * 1024 + 123;
        Uint8List data = Uint8List(size);
        for (int i = 0; i < size; i++) {
          data[i] = i % 251;
        }
        Stream<List<int>> chunks() async* {
          for (int i = 0; i < size; i += 700 * 1024) {
            int end = i + 700 * 1024 < size ? i + 700 * 1024 : size;
            yield Uint8List.sublistView(data, i, end);
          }
        }

        await disk.putStream(
          'extras/big.bin',
          chunks(),
          options: const WriteOptions(contentType: 'application/x-test'),
        );
        ObjectMetaData meta = await disk.getMetaData('extras/big.bin');
        expect(meta.size, size);
        expect(meta.contentType, 'application/x-test');
        expect(await disk.get('extras/big.bin'), data);
        http.Response blocks = await driver.client.send(
          'GET',
          driver.client.blobUri('extras/big.bin', <String, String>{
            'comp': 'blocklist',
          }),
        );
        driver.client.check(blocks, 'extras/big.bin');
        expect(
          driver.client.xml.all(driver.client.text(blocks), 'Block'),
          hasLength(4),
        );
      }, timeout: const Timeout(Duration(minutes: 2)));

      test('listAll paginates with the Azure marker', () async {
        for (int i = 0; i < 7; i++) {
          await disk.put('extras/pages/$i.txt', '$i');
        }
        List<String> seen = <String>[];
        String? token;
        int pages = 0;
        do {
          ListResult result = await disk.listAll(
            'extras/pages',
            ListOptions(recursive: true, limit: 3, paginationToken: token),
          );
          for (DriveEntry entry in result.objects) {
            seen.add(entry.key);
          }
          token = result.paginationToken;
          pages++;
        } while (token != null);
        expect(seen, hasLength(7));
        expect(pages, 3);
        expect((await disk.listAll('extras/pages')).objects, hasLength(7));
      });

      test('copy keeps or changes the content type', () async {
        await disk.put('extras/copy-src.json', '{}');
        await disk.copy('extras/copy-src.json', 'extras/copy-a.json');
        expect(
          (await disk.getMetaData('extras/copy-a.json')).contentType,
          'application/json',
        );
        await disk.copy(
          'extras/copy-src.json',
          'extras/copy-b.txt',
          options: const WriteOptions(contentType: 'text/plain'),
        );
        expect(
          (await disk.getMetaData('extras/copy-b.txt')).contentType,
          'text/plain',
        );
        expect(await disk.getString('extras/copy-b.txt'), '{}');
      });

      test('visibility comes from the container', () async {
        await disk.put('extras/vis.txt', 'v');
        expect(await disk.getVisibility('extras/vis.txt'), Visibility.private);
        await setContainerAccess(driver, true);
        addTearDown(() => setContainerAccess(driver, false));
        expect(await disk.getVisibility('extras/vis.txt'), Visibility.public);
        expect(
          disk.setVisibility('extras/vis.txt', Visibility.private),
          throwsA(isA<UnsupportedOperationException>()),
        );
      });

      test('wrong key gives PermissionDeniedException', () async {
        AzureBlobDriver bad = azuriteDriver(
          key: base64.encode(utf8.encode('wrong-key')),
        );
        addTearDown(bad.close);
        expect(
          Disk(bad).get('extras/signed.txt'),
          throwsA(isA<PermissionDeniedException>()),
        );
      });

      test('special characters in keys', () async {
        String key = "extras/a+b=c&d/it's (1) ~ ü.txt";
        await disk.put(key, 'weird');
        expect(await disk.getString(key), 'weird');
        ListResult result = await disk.listAll('extras/a+b=c&d');
        expect(result.objects.single.key, key);
        String url = await disk.getSignedUrl(key);
        expect((await http.get(Uri.parse(url))).body, 'weird');
      });
    });
  }, skip: skip);
}
