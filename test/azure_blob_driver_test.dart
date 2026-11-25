import 'package:dox_storage/dox_storage.dart';
import 'package:dox_storage/src/drivers/azure/azure_block_upload.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Azure answers from a list, in order. Every request is recorded.
class FakeAzure {
  final List<http.Response> answers;
  final List<http.Request> requests = <http.Request>[];

  FakeAzure(this.answers);

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    return answers.removeAt(0);
  }

  AzureBlobDriver driver({Duration? copyTimeout}) {
    return AzureBlobDriver(
      AzureBlobDriverConfig(
        accountName: 'acc',
        accountKey: 'a2V5',
        container: 'c',
        endpoint: 'http://azure.test',
        copyTimeout: copyTimeout ?? const Duration(minutes: 1),
      ),
      httpClient: MockClient(handle),
    );
  }
}

http.Response copyStatus(String status, {int code = 202}) {
  return http.Response(
    '',
    code,
    headers: <String, String>{
      'x-ms-copy-status': status,
      'x-ms-copy-id': 'id-1',
    },
  );
}

http.Response error(int status, String code) {
  return http.Response(
    '<?xml version="1.0"?><Error><Code>$code</Code>'
    '<Message>m</Message></Error>',
    status,
    headers: <String, String>{'x-ms-error-code': code},
  );
}

http.Response listPage(String blobs, String marker) {
  return http.Response(
    '<?xml version="1.0"?><EnumerationResults><Blobs>$blobs</Blobs>'
    '<NextMarker>$marker</NextMarker></EnumerationResults>',
    200,
  );
}

void main() {
  const WriteOptions none = WriteOptions();

  group('AzureBlobDriver copy |', () {
    test('pending twice, then success', () async {
      FakeAzure azure = FakeAzure(<http.Response>[
        copyStatus('pending'),
        copyStatus('pending', code: 200),
        copyStatus('success', code: 200),
      ]);
      await azure.driver().copy('a.txt', 'b.txt', none);
      expect(azure.requests, hasLength(3));
      expect(azure.requests[1].method, 'HEAD');
      expect(azure.requests[2].url.path, '/c/b.txt');
    });

    test('a failed copy throws DriverException for the destination', () {
      FakeAzure azure = FakeAzure(<http.Response>[copyStatus('failed')]);
      expect(
        azure.driver().copy('a.txt', 'b.txt', none),
        throwsA(
          isA<DriverException>().having(
            (DriverException e) => e.key,
            'key',
            'b.txt',
          ),
        ),
      );
    });

    test('a copy still pending at the timeout is aborted', () async {
      FakeAzure azure = FakeAzure(<http.Response>[
        copyStatus('pending'),
        copyStatus('pending', code: 200),
        http.Response('', 204),
      ]);
      await expectLater(
        azure.driver(copyTimeout: Duration.zero).copy('a.txt', 'b.txt', none),
        throwsA(isA<DriverException>()),
      );
      http.Request abort = azure.requests.last;
      expect(abort.method, 'PUT');
      expect(abort.url.queryParameters, <String, String>{
        'comp': 'copy',
        'copyid': 'id-1',
      });
      expect(abort.headers['x-ms-copy-action'], 'abort');
    });

    test('a missing source is FileNotFoundException for the source', () {
      FakeAzure azure = FakeAzure(<http.Response>[
        error(404, 'CannotVerifyCopySource'),
      ]);
      expect(
        azure.driver().copy('a.txt', 'b.txt', none),
        throwsA(
          isA<FileNotFoundException>().having(
            (FileNotFoundException e) => e.key,
            'key',
            'a.txt',
          ),
        ),
      );
    });

    test('a 403 is PermissionDeniedException for the destination', () {
      FakeAzure azure = FakeAzure(<http.Response>[
        error(403, 'AuthorizationPermissionMismatch'),
      ]);
      expect(
        azure.driver().copy('a.txt', 'b.txt', none),
        throwsA(
          isA<PermissionDeniedException>().having(
            (PermissionDeniedException e) => e.key,
            'key',
            'b.txt',
          ),
        ),
      );
    });
  });

  group('AzureBlobDriver errors |', () {
    test('404 BlobNotFound is FileNotFoundException', () {
      FakeAzure azure = FakeAzure(<http.Response>[error(404, 'BlobNotFound')]);
      expect(
        azure.driver().get('a.txt'),
        throwsA(isA<FileNotFoundException>()),
      );
    });

    test('403 is PermissionDeniedException', () {
      FakeAzure azure = FakeAzure(<http.Response>[
        error(403, 'AuthenticationFailed'),
      ]);
      expect(
        azure.driver().get('a.txt'),
        throwsA(isA<PermissionDeniedException>()),
      );
    });

    test('a missing blob is not an error for exists and delete', () async {
      FakeAzure azure = FakeAzure(<http.Response>[
        http.Response(
          '',
          404,
          headers: <String, String>{'x-ms-error-code': 'BlobNotFound'},
        ),
        error(404, 'BlobNotFound'),
      ]);
      AzureBlobDriver driver = azure.driver();
      expect(await driver.exists('a.txt'), isFalse);
      await driver.delete('a.txt');
    });

    test('ContainerNotFound is DriverException everywhere', () {
      // HEAD has no body, so the code comes from the header.
      FakeAzure azure = FakeAzure(<http.Response>[
        http.Response(
          '',
          404,
          headers: <String, String>{'x-ms-error-code': 'ContainerNotFound'},
        ),
        error(404, 'ContainerNotFound'),
        error(404, 'ContainerNotFound'),
      ]);
      AzureBlobDriver driver = azure.driver();
      Matcher driverError = throwsA(
        allOf(isA<DriverException>(), isNot(isA<FileNotFoundException>())),
      );
      expect(driver.exists('a.txt'), driverError);
      expect(driver.delete('a.txt'), driverError);
      expect(driver.get('a.txt'), driverError);
    });
  });

  group('AzureBlockUpload |', () {
    test('block ids differ per upload and have one length', () {
      AzureBlobClient client = FakeAzure(<http.Response>[]).driver().client;
      AzureBlockUpload a = AzureBlockUpload(client, 'k');
      AzureBlockUpload b = AzureBlockUpload(client, 'k');
      expect(a.blockId(0), isNot(b.blockId(0)));
      expect(a.blockId(0), isNot(a.blockId(1)));
      expect(a.blockId(49999).length, a.blockId(0).length);
    });
  });

  test('a bad blockSize throws', () {
    expect(
      () => AzureBlobDriver(
        const AzureBlobDriverConfig(
          accountName: 'acc',
          accountKey: 'a2V5',
          container: 'c',
          blockSize: 0,
        ),
      ),
      throwsArgumentError,
    );
  });

  group('AzureBlobDriver listing |', () {
    test('a limit below 1 lists nothing and sends no request', () async {
      FakeAzure azure = FakeAzure(<http.Response>[]);
      for (int limit in <int>[0, -1]) {
        ListResult result = await azure.driver().listAll(
          '',
          ListOptions(limit: limit),
        );
        expect(result.objects, isEmpty);
        expect(result.paginationToken, isNull);
      }
      expect(azure.requests, isEmpty);
    });

    test('an Encoded="true" name is decoded', () async {
      FakeAzure azure = FakeAzure(<http.Response>[
        listPage(
          '<Blob><Name Encoded="true">a%01b.txt</Name></Blob>'
              '<Blob><Name Encoded="false">plain.txt</Name></Blob>',
          '',
        ),
      ]);
      ListResult result = await azure.driver().listAll(
        '',
        const ListOptions(recursive: true),
      );
      expect(result.objects.map((DriveEntry e) => e.key), <String>[
        'a\u0001b.txt',
        'plain.txt',
      ]);
    });

    test('a page empty after hiding folder markers goes on', () async {
      FakeAzure azure = FakeAzure(<http.Response>[
        listPage('<Blob><Name>dir/</Name></Blob>', 'm1'),
        listPage('<Blob><Name>dir/a.txt</Name></Blob>', 'm2'),
      ]);
      ListResult result = await azure.driver().listAll(
        'dir',
        const ListOptions(limit: 1),
      );
      expect(result.objects.single.key, 'dir/a.txt');
      expect(result.paginationToken, 'm2');
      expect(azure.requests[1].url.queryParameters['marker'], 'm1');
      expect(azure.requests[1].url.queryParameters['maxresults'], '1');
    });
  });
}
