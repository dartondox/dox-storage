import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../clock.dart';
import '../../exceptions.dart';
import '../s3/s3_xml.dart';
import '../s3/sigv4_signer.dart';
import 'azure_blob_driver_config.dart';
import 'shared_key_signer.dart';

/// Builds, signs and sends Azure Blob requests. Maps Azure errors to
/// storage errors.
class AzureBlobClient {
  final AzureBlobDriverConfig config;
  final http.Client httpClient;
  final Clock clock;
  final AzureSharedKeySigner signer;
  final S3Xml xml;

  AzureBlobClient(
    this.config, {
    required this.httpClient,
    this.clock = const Clock(),
    this.xml = const S3Xml(),
  }) : signer = AzureSharedKeySigner(
         accountName: config.accountName,
         accountKey: config.accountKey,
       );

  /// The container URL is the same for every call, so it is made once.
  late final String containerUrl = _makeContainerUrl();

  String _makeContainerUrl() {
    String value =
        config.endpoint ??
        'https://${config.accountName}.blob.core.windows.net';
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return '$value/${config.container}';
  }

  /// URL of a blob, with an optional query.
  Uri blobUri(String key, [Map<String, String>? query]) {
    return _withQuery('$containerUrl/${encodeKey(key)}', query);
  }

  /// URL of the container, with an optional query. `restype=container`
  /// is always added.
  Uri containerUri([Map<String, String>? query]) {
    return _withQuery(containerUrl, <String, String>{
      'restype': 'container',
      ...?query,
    });
  }

  /// Percent-encode each part of a key, keep `/`.
  String encodeKey(String key) {
    return SigV4Signer.encode(key, encodeSlash: false);
  }

  Uri _withQuery(String url, Map<String, String>? query) {
    if (query == null || query.isEmpty) {
      return Uri.parse(url);
    }
    List<String> parts = <String>[];
    query.forEach((String name, String value) {
      parts.add('${SigV4Signer.encode(name)}=${SigV4Signer.encode(value)}');
    });
    return Uri.parse('$url?${parts.join('&')}');
  }

  /// Send a signed request with a buffered body.
  Future<http.Response> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Uint8List? body,
  }) async {
    return http.Response.fromStream(
      await sendStreamed(method, uri, headers: headers, body: body),
    );
  }

  /// Send a signed request and keep the response body as a stream.
  Future<http.StreamedResponse> sendStreamed(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Uint8List? body,
  }) async {
    Uint8List payload = body ?? Uint8List(0);
    http.Request request = http.Request(method, uri);
    request.headers.addAll(_sign(method, uri, headers, payload.length));
    request.bodyBytes = payload;
    return httpClient.send(request);
  }

  /// Send a signed request whose body is [chunks], in order, with no copy.
  Future<http.Response> sendChunks(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    required List<Uint8List> chunks,
  }) async {
    int length = 0;
    for (Uint8List chunk in chunks) {
      length += chunk.length;
    }
    http.StreamedRequest request = http.StreamedRequest(method, uri);
    request.headers.addAll(_sign(method, uri, headers, length));
    for (Uint8List chunk in chunks) {
      request.sink.add(chunk);
    }
    request.contentLength = length;
    unawaited(request.sink.close());
    return http.Response.fromStream(await httpClient.send(request));
  }

  Map<String, String> _sign(
    String method,
    Uri uri,
    Map<String, String> headers,
    int length,
  ) {
    return signer.sign(
      method: method,
      uri: uri,
      now: clock.now(),
      headers: headers,
      contentLength: length,
    );
  }

  /// Throw unless the status is 2xx.
  void check(http.Response response, String key) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      fail(response.statusCode, text(response), key, response.headers);
    }
  }

  /// Map an Azure error response to a storage exception. A HEAD error
  /// has no body, so the code also comes from `x-ms-error-code`.
  Never fail(
    int status,
    String body,
    String key, [
    Map<String, String> headers = const <String, String>{},
  ]) {
    String? code = headers['x-ms-error-code'] ?? xml.first(body, 'Code');
    String? message = xml.first(body, 'Message');
    String detail =
        'Azure $status${code == null ? '' : ' $code'}'
        '${message == null ? '' : ': ${message.split('\n').first}'}';
    if (status == 404 && code != 'ContainerNotFound') {
      throw FileNotFoundException(key, cause: detail);
    }
    if (status == 403) {
      throw PermissionDeniedException(key, cause: detail);
    }
    throw DriverException(key, detail);
  }

  /// Response body as UTF-8.
  String text(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// Read a streamed error body as text.
  Future<String> readBody(http.StreamedResponse response) async {
    return utf8.decode(await response.stream.toBytes(), allowMalformed: true);
  }
}
