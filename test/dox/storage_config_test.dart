import 'package:dox_storage/dox_storage.dart';
import 'package:test/test.dart';

void main() {
  group('StorageDiskFactory |', () {
    StorageDiskFactory factory = const StorageDiskFactory();
    Map<String, dynamic> s3 = <String, dynamic>{
      'driver': 's3',
      'bucket': 'b',
      'key': 'k',
      'secret': 's',
    };

    test('s3 with all settings works', () {
      expect(factory.driver('s3', s3), isNotNull);
    });

    for (String key in <String>['bucket', 'key', 'secret']) {
      test('s3 without $key names the missing setting', () {
        Map<String, dynamic> options = <String, dynamic>{...s3}..remove(key);
        expect(
          () => factory.driver('files', options),
          throwsA(
            isA<ArgumentError>().having(
              (ArgumentError e) => e.message,
              'message',
              'Storage disk "files" needs the "$key" setting. '
                  'It is missing or empty.',
            ),
          ),
        );
      });
    }

    test('s3 with an empty value is missing too', () {
      Map<String, dynamic> options = <String, dynamic>{...s3, 'bucket': ''};
      expect(() => factory.driver('s3', options), throwsArgumentError);
    });

    test('a signed URL of one local disk fails on another', () async {
      StorageDiskFactory signing = const StorageDiskFactory(appKey: 'k');
      Map<String, dynamic> local = <String, dynamic>{
        'driver': 'local',
        'root': 'storage',
        'url': 'https://app.test/files',
      };
      LocalDriver a = signing.driver('a', local) as LocalDriver;
      LocalDriver b = signing.driver('b', local) as LocalDriver;
      Uri url = Uri.parse(
        await a.getSignedUrl('x.txt', const SignedUrlOptions()),
      );
      expect(a.verifySignedUrl('x.txt', url.queryParameters), isTrue);
      expect(b.verifySignedUrl('x.txt', url.queryParameters), isFalse);
    });
  });
}
