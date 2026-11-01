import 'dart:io';

import 'package:dox_core/dox_core.dart';

import '../driver_contract.dart';
import '../drivers/local_driver.dart';
import 'storage.dart';

/// Serves files of a disk for `Storage.route()`.
/// Checks the signature of local signed URLs.
class StorageFileController {
  StorageFileController(this.disk, this.signed, {this.download = false});

  /// disk name, null for the default disk
  final String? disk;

  /// only signed URLs work
  final bool signed;

  /// send every file as a download (`Content-Disposition: attachment`)
  final bool download;

  /// `GET <path>/{key*}`
  /// Dox core already decodes [key]. Do not decode it again.
  /// A missing file or a key outside the disk answers 404 (see `stream`).
  Future<dynamic> serve(DoxRequest req, String key) async {
    String fileKey = key;
    if (signed && !_verify(fileKey, req.uri.queryParameters)) {
      return response('invalid or expired signature')
          .statusCode(HttpStatus.forbidden);
    }
    Storage storage = Storage().disk(disk ?? Storage.manager.defaultDisk);
    if (download) return storage.download(fileKey);
    return storage.stream(fileKey);
  }

  bool _verify(String key, Map<String, String> query) {
    DriverContract driver = Storage().use(disk).driver;
    if (driver is! LocalDriver) {
      // a setup error, not a bad URL. Keep the 403 of 3.0.1, but say why
      // in the log.
      String name = disk ?? Storage.manager.defaultDisk;
      Logger.danger(
        'Storage.route() with signed: true only works with a local disk. '
        'Disk "$name" uses ${driver.runtimeType}, so every request gets 403. '
        'Use signed: false, or send users to the URL from signedUrl() on '
        'that disk.',
      );
      return false;
    }
    return driver.verifySignedUrl(key, query);
  }
}
