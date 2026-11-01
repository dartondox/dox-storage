import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../clock.dart';
import '../constants/storage_constants.dart';
import '../exceptions.dart';
import '../key_normalizer.dart';

/// Signs and checks local file URLs with HMAC-SHA256 and an app key.
///
/// A signed URL looks like `<base>/<key>?expires=<ms>&signature=<hex>`.
/// Your route checks it with [verify] before it serves the file.
///
/// The signature covers [disk], so a URL signed for one disk does not
/// work on the route of another disk.
///
/// [verify] also accepts the old format (`key\nexpires`, no disk) from
/// 3.0.1 and older, so URLs made before an upgrade keep working until
/// they expire. Like before, such an old URL works on the route of any
/// local disk with the same app key. This ends when the old URLs expire.
class LocalUrlSigner {
  final List<int> _secret;

  /// Name of the disk this signer is for.
  final String disk;
  final Clock clock;
  final KeyNormalizer normalizer;
  final KeyEncoder encoder;

  LocalUrlSigner(
    String appKey, {
    this.disk = '',
    this.clock = const Clock(),
    this.normalizer = const KeyNormalizer(),
    this.encoder = const KeyEncoder(),
  }) : _secret = utf8.encode(appKey) {
    if (appKey.isEmpty) {
      throw ArgumentError.value(appKey, 'appKey', 'must not be empty');
    }
  }

  /// Build a signed URL for [key] under [urlBase].
  String sign(String urlBase, String key, Duration expiresIn) {
    String cleanKey = normalizer.key(key);
    int expires = clock.now().add(expiresIn).millisecondsSinceEpoch;
    String signature = _signature(cleanKey, expires);
    String base = urlBase.endsWith('/')
        ? urlBase.substring(0, urlBase.length - 1)
        : urlBase;
    return '$base/${encoder.urlPath(cleanKey)}'
        '?${StorageConstants.localExpiresParam}=$expires'
        '&${StorageConstants.localSignatureParam}=$signature';
  }

  /// True when [queryParameters] hold a valid, not expired signature
  /// for [key]. Pass the decoded key from the route path.
  bool verify(String key, Map<String, String> queryParameters) {
    String cleanKey;
    try {
      cleanKey = normalizer.key(key);
    } on InvalidKeyException {
      return false;
    }
    int? expires = int.tryParse(
      queryParameters[StorageConstants.localExpiresParam] ?? '',
    );
    String? signature = queryParameters[StorageConstants.localSignatureParam];
    if (expires == null || signature == null) {
      return false;
    }
    if (clock.now().millisecondsSinceEpoch > expires) {
      return false;
    }
    if (_constantTimeEquals(_signature(cleanKey, expires), signature)) {
      return true;
    }
    // old format of 3.0.1 and older: keeps URLs signed before the upgrade
    // working until they expire. Remove in the next major version.
    return _constantTimeEquals(_legacySignature(cleanKey, expires), signature);
  }

  String _signature(String key, int expires) {
    // the length prefix keeps disk `a` + key `b\nc` apart from
    // disk `a\nb` + key `c`. The null byte at the start keeps new text
    // apart from old text in both ways: a key can not hold a null byte,
    // so old text never starts with one. Without it, an old URL for key
    // `1:d\nk` would open key `k` on disk `d`, and the other way round.
    return _hmac('\u0000${disk.length}:$disk\n$key\n$expires');
  }

  String _legacySignature(String key, int expires) {
    return _hmac('$key\n$expires');
  }

  String _hmac(String text) {
    return Hmac(sha256, _secret).convert(utf8.encode(text)).toString();
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
