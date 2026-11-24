import 'dart:convert';
import 'dart:io' show HttpDate, stderr;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dox_http_client/http.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import '../../clock.dart';
import '../../constants/storage_constants.dart';
import '../../driver_contract.dart';
import '../../exceptions.dart';
import '../../types.dart';
import 's3_client.dart';
import 's3_driver_config.dart';
import 's3_multipart_upload.dart';
import 'sigv4_signer.dart';

/// Stores files in AWS S3 or an S3-compatible service.
class S3Driver implements DriverContract {
  final S3DriverConfig config;
  final S3Client client;

  /// Pass [httpClient] to reuse a client or to mock S3 in tests. With
  /// none, the driver uses the native client of `dox_http_client`.
  ///
  /// When [S3DriverConfig.multipartPartSize] is not from 5 MiB to 5 GiB,
  /// it does not throw, so an app that only uploads small files keeps
  /// working. It writes one warning to [warnings] (stderr by default).
  S3Driver(
    this.config, {
    http.Client? httpClient,
    Clock clock = const Clock(),
    StringSink? warnings,
  }) : client = S3Client(
         config,
         httpClient: httpClient ?? DoxHttpPackageClient(),
         clock: clock,
       ) {
    int size = config.multipartPartSize;
    if (size < StorageConstants.minMultipartPartSize ||
        size > StorageConstants.maxMultipartPartSize) {
      (warnings ?? stderr).writeln(
        'WARNING dox_storage: multipartPartSize is $size bytes. '
        'The allowed range is 5 MiB to 5 GiB '
        '(${StorageConstants.minMultipartPartSize} to '
        '${StorageConstants.maxMultipartPartSize} bytes). '
        'S3 will refuse a multipart upload with parts under 5 MiB.',
      );
    }
  }

  /// Close the HTTP client.
  void close() {
    client.httpClient.close();
  }

  Map<String, String> _writeHeaders(String key, WriteOptions options) {
    Map<String, String> headers = <String, String>{
      'content-type':
          options.contentType ??
          lookupMimeType(key) ??
          StorageConstants.defaultContentType,
    };
    if (config.supportsAcl) {
      headers['x-amz-acl'] = _acl(options.visibility ?? config.visibility);
    }
    return headers;
  }

  String _acl(Visibility visibility) {
    return visibility == Visibility.public ? 'public-read' : 'private';
  }

  @override
  Future<bool> exists(String key) async {
    http.Response response = await client.send('HEAD', client.objectUri(key));
    if (response.statusCode == 404) {
      return false;
    }
    client.check(response, key);
    return true;
  }

  @override
  Future<Uint8List> get(String key) async {
    http.Response response = await client.send('GET', client.objectUri(key));
    client.check(response, key);
    return response.bodyBytes;
  }

  @override
  Future<Stream<List<int>>> getStream(String key) async {
    ObjectStream file = await getStreamWithMetaData(key);
    return file.stream;
  }

  /// [getStream] and [getMetaData] in one GET request. The metadata comes
  /// from the GET response headers, so no HEAD request is needed.
  Future<ObjectStream> getStreamWithMetaData(String key) async {
    http.StreamedResponse response = await client.sendStreamed(
      'GET',
      client.objectUri(key),
    );
    if (response.statusCode != 200) {
      client.fail(response.statusCode, await client.readBody(response), key);
    }
    return ObjectStream(response.stream, _metaData(response.headers));
  }

  @override
  Future<ObjectMetaData> getMetaData(String key) async {
    http.Response response = await client.send('HEAD', client.objectUri(key));
    client.check(response, key);
    return _metaData(response.headers);
  }

  ObjectMetaData _metaData(Map<String, String> headers) {
    String? lastModified = headers['last-modified'];
    return ObjectMetaData(
      size: int.tryParse(headers['content-length'] ?? '') ?? 0,
      contentType:
          headers['content-type'] ?? StorageConstants.defaultContentType,
      lastModified: lastModified == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : HttpDate.parse(lastModified),
      etag: (headers['etag'] ?? '').replaceAll('"', ''),
    );
  }

  @override
  Future<Visibility> getVisibility(String key) async {
    if (!config.supportsAcl) {
      return config.visibility;
    }
    http.Response response = await client.send(
      'GET',
      client.objectUri(key, <String, String>{'acl': ''}),
    );
    client.check(response, key);
    for (String grant in client.xml.all(client.text(response), 'Grant')) {
      bool everyone = grant.contains(StorageConstants.s3AllUsersGroup);
      String? permission = client.xml.first(grant, 'Permission');
      if (everyone && (permission == 'READ' || permission == 'FULL_CONTROL')) {
        return Visibility.public;
      }
    }
    return Visibility.private;
  }

  @override
  Future<void> setVisibility(String key, Visibility visibility) async {
    if (!config.supportsAcl) {
      return;
    }
    http.Response response = await client.send(
      'PUT',
      client.objectUri(key, <String, String>{'acl': ''}),
      headers: <String, String>{'x-amz-acl': _acl(visibility)},
    );
    client.check(response, key);
  }

  @override
  Future<String> getUrl(String key) async {
    String? base = config.urlBase;
    if (base == null) {
      return client.objectUri(key).toString();
    }
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return '$base/${SigV4Signer.encode(key, encodeSlash: false)}';
  }

  void _checkExpiry(String key, Duration expiresIn) {
    if (expiresIn <= Duration.zero ||
        expiresIn > StorageConstants.maxS3SignedUrlExpiry) {
      throw UnsupportedOperationException(
        key,
        'S3 signed URLs must expire within 1 second and 7 days',
      );
    }
  }

  @override
  Future<String> getSignedUrl(String key, SignedUrlOptions options) async {
    _checkExpiry(key, options.expiresIn);
    Map<String, String> query = <String, String>{};
    String? contentType = options.contentType;
    if (contentType != null) {
      query['response-content-type'] = contentType;
    }
    String? disposition = options.contentDisposition;
    if (disposition != null) {
      query['response-content-disposition'] = disposition;
    }
    Uri url = client.signer.presign(
      method: 'GET',
      uri: client.objectUri(key, query),
      now: client.clock.now(),
      expiresIn: options.expiresIn,
    );
    return url.toString();
  }

  @override
  Future<String> getSignedUploadUrl(
    String key,
    SignedUrlOptions options,
  ) async {
    _checkExpiry(key, options.expiresIn);
    Map<String, String> headers = <String, String>{};
    String? contentType = options.contentType;
    if (contentType != null) {
      headers['content-type'] = contentType;
    }
    Uri url = client.signer.presign(
      method: 'PUT',
      uri: client.objectUri(key),
      now: client.clock.now(),
      expiresIn: options.expiresIn,
      headers: headers,
    );
    return url.toString();
  }

  @override
  Future<void> put(String key, Uint8List contents, WriteOptions options) async {
    // ponytail: single PUT tops out at 5 GiB (S3 limit); use putStream for
    // bigger files, it switches to multipart.
    http.Response response = await client.send(
      'PUT',
      client.objectUri(key),
      headers: _writeHeaders(key, options),
      body: contents,
    );
    client.check(response, key);
  }

  @override
  Future<void> putStream(
    String key,
    Stream<List<int>> contents,
    WriteOptions options,
  ) async {
    // ponytail: keeps one part (multipartPartSize, 8 MiB by default) in
    // memory, as the chunks that came in, with no copy. Parts go up one
    // by one, not in parallel.
    int partSize = config.multipartPartSize;
    S3PartBuffer part = _newPart();
    S3MultipartUpload? upload;
    try {
      await for (List<int> chunk in contents) {
        Uint8List bytes = chunk is Uint8List
            ? chunk
            : Uint8List.fromList(chunk);
        while (part.length + bytes.length >= partSize) {
          int take = partSize - part.length;
          await part.add(Uint8List.sublistView(bytes, 0, take));
          bytes = Uint8List.sublistView(bytes, take);
          upload ??= await S3MultipartUpload.start(
            client,
            key,
            _writeHeaders(key, options),
          );
          await upload.uploadPart(part);
          part = _newPart();
        }
        if (bytes.isNotEmpty) {
          await part.add(bytes);
        }
      }
      if (upload == null) {
        http.Response response = await client.sendChunks(
          'PUT',
          client.objectUri(key),
          headers: _writeHeaders(key, options),
          chunks: part.chunks,
          hash: part.hash(),
        );
        client.check(response, key);
        return;
      }
      if (part.length > 0) {
        await upload.uploadPart(part);
      }
      await upload.complete();
    } catch (_) {
      // Keep the first error; a failed abort only leaves parts behind.
      try {
        await upload?.abort();
      } catch (_) {}
      rethrow;
    }
  }

  S3PartBuffer _newPart() {
    return S3PartBuffer(unsignedPayload: config.unsignedPayload);
  }

  @override
  Future<void> copy(
    String source,
    String destination,
    WriteOptions options,
  ) async {
    // ponytail: server-side CopyObject tops out at 5 GiB (S3 limit).
    Map<String, String> headers = <String, String>{
      'x-amz-copy-source':
          '/${config.bucket}/${SigV4Signer.encode(source, encodeSlash: false)}',
    };
    String? contentType = options.contentType;
    if (contentType != null) {
      headers['x-amz-metadata-directive'] = 'REPLACE';
      headers['content-type'] = contentType;
    }
    if (config.supportsAcl) {
      headers['x-amz-acl'] = _acl(options.visibility ?? config.visibility);
    }
    http.Response response = await client.send(
      'PUT',
      client.objectUri(destination),
      headers: headers,
    );
    client.checkBodyError(response, source);
  }

  @override
  Future<void> move(
    String source,
    String destination,
    WriteOptions options,
  ) async {
    if (source == destination) {
      return;
    }
    await copy(source, destination, options);
    await delete(source);
  }

  @override
  Future<void> delete(String key) async {
    http.Response response = await client.send('DELETE', client.objectUri(key));
    if (response.statusCode == 404) {
      return;
    }
    client.check(response, key);
  }

  @override
  Future<void> deleteAll(String prefix) async {
    // One page of keys (at most 1000) at a time: list a page, delete it,
    // then list the next one. The continuation token points after the
    // last key of the page, so deleted keys do not move the next page.
    // Folder markers (like "photos/") must go too. If one stays, the
    // folder still exists after the delete.
    String? token;
    do {
      _Page page = await _listPage(
        prefix,
        recursive: true,
        markers: true,
        token: token,
        maxKeys: StorageConstants.s3DeleteBatchSize,
      );
      List<String> keys = <String>[];
      for (DriveEntry entry in page.entries) {
        keys.add(entry.key);
      }
      if (!config.supportsBatchDelete) {
        for (String key in keys) {
          await delete(key);
        }
      } else if (keys.isNotEmpty) {
        await _deleteBatch(prefix, keys);
      }
      token = page.token;
    } while (token != null);
  }

  Future<void> _deleteBatch(String prefix, List<String> keys) async {
    StringBuffer xml = StringBuffer('<Delete><Quiet>true</Quiet>');
    for (String key in keys) {
      xml.write('<Object><Key>${client.xml.escape(key)}</Key></Object>');
    }
    xml.write('</Delete>');
    Uint8List body = utf8.encode(xml.toString());
    http.Response response = await client.send(
      'POST',
      client.bucketUri(<String, String>{'delete': ''}),
      headers: <String, String>{
        'content-type': 'application/xml',
        'content-md5': base64.encode(md5.convert(body).bytes),
      },
      body: body,
    );
    client.checkBodyError(response, prefix);
  }

  @override
  Future<ListResult> listAll(String prefix, ListOptions options) async {
    List<DriveEntry> entries = <DriveEntry>[];
    String? token = options.paginationToken;
    int? limit = options.limit;
    while (true) {
      _Page page = await _listPage(
        prefix,
        recursive: options.recursive,
        markers: false,
        token: token,
        maxKeys: limit ?? 1000,
      );
      entries.addAll(page.entries);
      token = page.token;
      if (token == null || limit != null) {
        break;
      }
    }
    entries.sort(_compareKeys);
    return ListResult(entries, paginationToken: token);
  }

  /// True when any key starts with `prefix/`. A folder marker like
  /// `photos/` counts. [listAll] hides markers, so it can not tell an empty
  /// folder from a missing one.
  Future<bool> directoryExists(String prefix) async {
    http.Response response = await client.send(
      'GET',
      client.bucketUri(<String, String>{
        'list-type': '2',
        'prefix': prefix.isEmpty ? '' : '$prefix/',
        'max-keys': '1',
      }),
    );
    client.check(response, prefix);
    return client.xml.all(client.text(response), 'Contents').isNotEmpty;
  }

  /// One ListObjectsV2 request. With [markers] true, keys that end with
  /// `/` come back as files.
  Future<_Page> _listPage(
    String prefix, {
    required bool recursive,
    required bool markers,
    required String? token,
    required int maxKeys,
  }) async {
    Map<String, String> query = <String, String>{
      'list-type': '2',
      'prefix': prefix.isEmpty ? '' : '$prefix/',
      'max-keys': '$maxKeys',
    };
    if (!recursive) {
      query['delimiter'] = '/';
    }
    if (token != null) {
      query['continuation-token'] = token;
    }
    http.Response response = await client.send('GET', client.bucketUri(query));
    client.check(response, prefix);
    String body = client.text(response);
    List<DriveEntry> entries = <DriveEntry>[];
    for (String item in client.xml.all(body, 'Contents')) {
      String key = client.xml.first(item, 'Key')!;
      // Skip "folder marker" objects like "photos/".
      if (markers || !key.endsWith('/')) {
        entries.add(DriveFile(key));
      }
    }
    for (String item in client.xml.all(body, 'CommonPrefixes')) {
      String folder = client.xml.first(item, 'Prefix')!;
      entries.add(DriveDirectory(folder.substring(0, folder.length - 1)));
    }
    bool truncated = client.xml.first(body, 'IsTruncated') == 'true';
    return _Page(
      entries,
      truncated ? client.xml.first(body, 'NextContinuationToken') : null,
    );
  }

  static int _compareKeys(DriveEntry a, DriveEntry b) {
    return a.key.compareTo(b.key);
  }
}

/// One page of a listing and the token of the next page.
class _Page {
  final List<DriveEntry> entries;
  final String? token;

  const _Page(this.entries, this.token);
}
