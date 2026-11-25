import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:crypto/crypto.dart';

import '../../constants/storage_constants.dart';
import '../s3/sigv4_signer.dart';

/// Azure Storage Shared Key auth and service SAS for the Blob service.
///
/// [sign] adds the `Authorization: SharedKey ...` header to a request.
/// [blobSas] makes the query string of a service SAS for one blob.
class AzureSharedKeySigner {
  final String accountName;

  /// The account key as Azure shows it (base64).
  final String accountKey;

  /// The `x-ms-version` sent with each request and the `sv` of a SAS.
  final String version;

  AzureSharedKeySigner({
    required this.accountName,
    required this.accountKey,
    this.version = StorageConstants.azureApiVersion,
  }) : _key = base64.decode(accountKey);

  final List<int> _key;

  /// Return [headers] plus `x-ms-date`, `x-ms-version` and
  /// `authorization`. All names are lowercase. [contentLength] is the
  /// body size the client will send.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    required DateTime now,
    Map<String, String> headers = const <String, String>{},
    int contentLength = 0,
  }) {
    Map<String, String> all = <String, String>{};
    headers.forEach((String name, String value) {
      all[name.toLowerCase()] = value;
    });
    all['x-ms-date'] = HttpDate.format(now);
    all['x-ms-version'] = version;
    String text = stringToSign(
      method: method,
      uri: uri,
      headers: all,
      contentLength: contentLength,
    );
    all['authorization'] = 'SharedKey $accountName:${hmac(text)}';
    return all;
  }

  /// The Shared Key string-to-sign (version 2015-02-21 and later).
  /// [headers] must have lowercase names.
  String stringToSign({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    int contentLength = 0,
  }) {
    StringBuffer out = StringBuffer()
      ..write('${method.toUpperCase()}\n')
      ..write('${headers['content-encoding'] ?? ''}\n')
      ..write('${headers['content-language'] ?? ''}\n')
      // Zero is sent as an empty line.
      ..write('${contentLength == 0 ? '' : contentLength}\n')
      ..write('${headers['content-md5'] ?? ''}\n')
      ..write('${headers['content-type'] ?? ''}\n')
      // `x-ms-date` is used, so the Date line stays empty.
      ..write('\n')
      ..write('${headers['if-modified-since'] ?? ''}\n')
      ..write('${headers['if-match'] ?? ''}\n')
      ..write('${headers['if-none-match'] ?? ''}\n')
      ..write('${headers['if-unmodified-since'] ?? ''}\n')
      ..write('${headers['range'] ?? ''}\n');
    List<String> names = <String>[];
    for (String name in headers.keys) {
      if (name.startsWith('x-ms-')) {
        names.add(name);
      }
    }
    names.sort();
    for (String name in names) {
      out.write('$name:${_fold(headers[name]!)}\n');
    }
    out.write('/$accountName${uri.path.isEmpty ? '/' : uri.path}');
    Map<String, List<String>> query = <String, List<String>>{};
    uri.queryParametersAll.forEach((String name, List<String> values) {
      query
          .putIfAbsent(name.toLowerCase(), _newList)
          .addAll(values.toList()..sort());
    });
    List<String> params = query.keys.toList()..sort();
    for (String name in params) {
      out.write('\n$name:${query[name]!.join(',')}');
    }
    return out.toString();
  }

  /// Query string (without `?`) of a service SAS for one blob.
  ///
  /// [permissions] are SAS letters in Azure order, for example `r` or
  /// `cw`. [contentType] and [contentDisposition] become the `rsct` and
  /// `rscd` response headers of a download.
  String blobSas({
    required String container,
    required String blob,
    required String permissions,
    required DateTime expiry,
    String? contentType,
    String? contentDisposition,
  }) {
    String expires = _isoDate(expiry);
    String resource = '/blob/$accountName/$container/$blob';
    // Field order of the 2020-12-06+ service SAS string-to-sign: sp, st,
    // se, resource, si, sip, spr, sv, sr, snapshot, ses, rscc, rscd, rsce,
    // rscl, rsct.
    String text = <String>[
      permissions,
      '',
      expires,
      resource,
      '',
      '',
      '',
      version,
      'b',
      '',
      '',
      '',
      contentDisposition ?? '',
      '',
      '',
      contentType ?? '',
    ].join('\n');
    List<List<String>> query = <List<String>>[
      <String>['sv', version],
      <String>['sr', 'b'],
      <String>['sp', permissions],
      <String>['se', expires],
    ];
    if (contentDisposition != null) {
      query.add(<String>['rscd', contentDisposition]);
    }
    if (contentType != null) {
      query.add(<String>['rsct', contentType]);
    }
    query.add(<String>['sig', hmac(text)]);
    List<String> parts = <String>[];
    for (List<String> pair in query) {
      parts.add('${pair[0]}=${SigV4Signer.encode(pair[1])}');
    }
    return parts.join('&');
  }

  /// Base64 HMAC-SHA256 of [text] with the account key.
  String hmac(String text) {
    return base64.encode(Hmac(sha256, _key).convert(utf8.encode(text)).bytes);
  }

  /// Header values: line breaks and repeated spaces become one space.
  static String _fold(String value) {
    return value.trim().replaceAll(_spaces, ' ');
  }

  static final RegExp _spaces = RegExp(r'\s+');

  static List<String> _newList() {
    return <String>[];
  }

  /// ISO 8601 date without fractions, like `2024-01-02T03:04:05Z`.
  static String _isoDate(DateTime time) {
    DateTime t = time.toUtc();
    return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-'
        '${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}Z';
  }

  static String _two(int value) {
    return value.toString().padLeft(2, '0');
  }
}
