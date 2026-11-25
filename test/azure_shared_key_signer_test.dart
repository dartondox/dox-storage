import 'package:dox_storage/dox_storage.dart';
import 'package:test/test.dart';

// The public Azurite dev account key (a known false secret).
const String devKey =
    'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==';

// Microsoft publishes no fixed Shared Key vector. The expected strings and
// signatures below come from an independent Python reference (hmac,
// hashlib, base64) written from the Microsoft REST docs
// ("Authorize with Shared Key", "Create a service SAS").
void main() {
  AzureSharedKeySigner signer = AzureSharedKeySigner(
    accountName: 'devstoreaccount1',
    accountKey: devKey,
  );
  DateTime now = DateTime.utc(2023, 1, 2, 3, 4, 5);

  test('Shared Key string-to-sign and signature', () {
    Uri uri = Uri.parse(
      'http://127.0.0.1:10000/devstoreaccount1/photos/my%20dir/a.txt'
      '?comp=block&blockid=YmxvY2stMDAwMDAw',
    );
    Map<String, String> signed = signer.sign(
      method: 'PUT',
      uri: uri,
      now: now,
      headers: <String, String>{
        'X-Ms-Blob-Type': 'BlockBlob',
        'Content-Type': 'text/plain',
      },
      contentLength: 11,
    );
    expect(signed['x-ms-date'], 'Mon, 02 Jan 2023 03:04:05 GMT');
    expect(signed['x-ms-version'], '2023-11-03');
    expect(
      signer.stringToSign(
        method: 'PUT',
        uri: uri,
        headers: signed..remove('authorization'),
        contentLength: 11,
      ),
      'PUT\n\n\n11\n\ntext/plain\n\n\n\n\n\n\n'
      'x-ms-blob-type:BlockBlob\n'
      'x-ms-date:Mon, 02 Jan 2023 03:04:05 GMT\n'
      'x-ms-version:2023-11-03\n'
      '/devstoreaccount1/devstoreaccount1/photos/my%20dir/a.txt\n'
      'blockid:YmxvY2stMDAwMDAw\n'
      'comp:block',
    );
    expect(
      signer.sign(
        method: 'PUT',
        uri: uri,
        now: now,
        headers: <String, String>{
          'x-ms-blob-type': 'BlockBlob',
          'content-type': 'text/plain',
        },
        contentLength: 11,
      )['authorization'],
      'SharedKey devstoreaccount1:'
      'txqe5dGjGoAaI9gdrkYUmuY1H5KAhTJepnRbyRTwTHo=',
    );
  });

  test('empty body leaves the Content-Length line empty', () {
    String text = signer.stringToSign(
      method: 'get',
      uri: Uri.parse('https://a.blob.core.windows.net/c/k'),
      headers: <String, String>{},
    );
    expect(text, startsWith('GET\n\n\n\n'));
    expect(text, endsWith('\n/devstoreaccount1/c/k'));
  });

  test('service SAS for a blob download', () {
    Map<String, String> query = Uri.splitQueryString(
      signer.blobSas(
        container: 'photos',
        blob: 'my dir/a.txt',
        permissions: 'r',
        expiry: now.add(const Duration(minutes: 30)),
        contentType: 'text/plain',
        contentDisposition: 'attachment; filename="a.txt"',
      ),
    );
    expect(query, <String, String>{
      'sv': '2023-11-03',
      'sr': 'b',
      'sp': 'r',
      'se': '2023-01-02T03:34:05Z',
      'rscd': 'attachment; filename="a.txt"',
      'rsct': 'text/plain',
      'sig': '+iWClIpOdGwsTSwLxmUTNMFEk8+1829h0T/SynD32o0=',
    });
  });

  test('driver SAS URLs use the fixed clock', () async {
    AzureBlobDriver driver = AzureBlobDriver(
      const AzureBlobDriverConfig(
        accountName: 'devstoreaccount1',
        accountKey: devKey,
        container: 'photos',
        endpoint: 'http://127.0.0.1:10000/devstoreaccount1/',
      ),
      clock: FixedClock(now),
    );
    addTearDown(driver.close);
    Uri upload = Uri.parse(
      await driver.getSignedUploadUrl(
        'my dir/a.txt',
        const SignedUrlOptions(contentType: 'text/plain'),
      ),
    );
    expect(upload.path, '/devstoreaccount1/photos/my%20dir/a.txt');
    expect(upload.queryParameters['sp'], 'cw');
    expect(upload.queryParameters.containsKey('rsct'), isFalse);
    expect(upload.queryParameters['se'], '2023-01-02T03:34:05Z');
    expect(
      driver.getSignedUrl(
        'a.txt',
        const SignedUrlOptions(expiresIn: Duration.zero),
      ),
      throwsA(isA<UnsupportedOperationException>()),
    );
    expect(
      await driver.getUrl('my dir/a.txt'),
      'http://127.0.0.1:10000/devstoreaccount1/photos/my%20dir/a.txt',
    );
    expect(
      driver.setVisibility('a.txt', Visibility.public),
      throwsA(isA<UnsupportedOperationException>()),
    );
  });
}
