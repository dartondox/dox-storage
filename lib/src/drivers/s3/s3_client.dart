import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../clock.dart';
import '../../constants/storage_constants.dart';
import '../../exceptions.dart';
import 's3_driver_config.dart';
import 's3_xml.dart';
import 'sigv4_signer.dart';

/// Builds, signs and sends S3 requests. Maps S3 errors to storage errors.
class S3Client {
  final S3DriverConfig config;
  final http.Client httpClient;
  final Clock clock;
  final SigV4Signer signer;
  final S3Xml xml;

  S3Client(
    this.config, {
    required this.httpClient,
    this.clock = const Clock(),
    this.xml = const S3Xml(),
  }) : signer = SigV4Signer(
         credentials: AwsCredentials(
           accessKeyId: config.accessKeyId,
           secretAccessKey: config.secretAccessKey,
           sessionToken: config.sessionToken,
         ),
         region: config.region,
       );

  /// Service endpoint without trailing slash.
  Uri get endpoint {
    String value =
        config.endpoint ?? 'https://s3.${config.region}.amazonaws.com';
    if (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return Uri.parse(value);
  }

  /// The bucket URL is the same for every call, so it is made once.
  late final String _bucketUrl = _makeBucketUrl();

  /// URL of the bucket root, without query.
  String bucketUrl() {
    return _bucketUrl;
  }

  String _makeBucketUrl() {
    Uri base = endpoint;
    if (config.forcePathStyle) {
      return '${base.scheme}://${base.authority}/${config.bucket}';
    }
    return '${base.scheme}://${config.bucket}.${base.authority}';
  }

  /// URL of an object, with an optional query.
  Uri objectUri(String key, [Map<String, String>? query]) {
    String path = SigV4Signer.encode(key, encodeSlash: false);
    return _withQuery('${bucketUrl()}/$path', query);
  }

  /// URL of the bucket, with an optional query.
  Uri bucketUri([Map<String, String>? query]) {
    return _withQuery('${bucketUrl()}/', query);
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
    http.StreamedResponse response = await sendStreamed(
      method,
      uri,
      headers: headers,
      body: body,
    );
    return http.Response.fromStream(response);
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
    request.headers.addAll(
      _sign(method, uri, headers, await payloadHash(payload)),
    );
    request.bodyBytes = payload;
    return httpClient.send(request);
  }

  /// Send a signed request whose body is [chunks], in order. The chunks
  /// are sent as they are, with no copy. [hash] is the payload hash of
  /// all chunks together (see [payloadHash]).
  Future<http.Response> sendChunks(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    required List<Uint8List> chunks,
    required String hash,
  }) async {
    http.StreamedRequest request = http.StreamedRequest(method, uri);
    request.headers.addAll(_sign(method, uri, headers, hash));
    int length = 0;
    for (Uint8List chunk in chunks) {
      length += chunk.length;
      request.sink.add(chunk);
    }
    request.contentLength = length;
    unawaited(request.sink.close());
    return http.Response.fromStream(await httpClient.send(request));
  }

  /// Signed headers for a request, without `host`.
  Map<String, String> _sign(
    String method,
    Uri uri,
    Map<String, String> headers,
    String hash,
  ) {
    Map<String, String> signed = signer.sign(
      method: method,
      uri: uri,
      now: clock.now(),
      headers: <String, String>{...headers, 'x-amz-content-sha256': hash},
      payloadHash: hash,
    );
    // The HTTP client sets Host itself from the URL.
    signed.remove('host');
    return signed;
  }

  /// The `x-amz-content-sha256` value for [body].
  ///
  /// An empty body uses the known empty hash. With
  /// [S3DriverConfig.unsignedPayload] on, it is `UNSIGNED-PAYLOAD`. A body
  /// of [StorageConstants.isolateHashBytes] or more is hashed in another
  /// isolate, so the event loop is not blocked.
  Future<String> payloadHash(Uint8List body) async {
    if (body.isEmpty) {
      return StorageConstants.emptyPayloadHash;
    }
    if (config.unsignedPayload) {
      return StorageConstants.unsignedPayload;
    }
    if (body.length < StorageConstants.isolateHashBytes) {
      return SigV4Signer.sha256Hex(body);
    }
    return Isolate.run(() => SigV4Signer.sha256Hex(body));
  }

  /// Throw unless the status is 2xx.
  void check(http.Response response, String key) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      fail(response.statusCode, text(response), key);
    }
  }

  /// Some S3 calls (copy, complete multipart) return 200 with an error body.
  void checkBodyError(http.Response response, String key) {
    check(response, key);
    String body = text(response);
    if (body.contains('<Error>')) {
      fail(500, body, key);
    }
  }

  /// Map an S3 error response to a storage exception.
  Never fail(int status, String body, String key) {
    String? code = xml.first(body, 'Code');
    String? message = xml.first(body, 'Message');
    String detail =
        'S3 $status${code == null ? '' : ' $code'}'
        '${message == null ? '' : ': $message'}';
    if (code == 'NoSuchKey' || (status == 404 && code != 'NoSuchBucket')) {
      throw FileNotFoundException(key, cause: detail);
    }
    if (status == 403) {
      throw PermissionDeniedException(key, cause: detail);
    }
    throw DriverException(key, detail);
  }

  /// Response body as UTF-8. S3 sends XML without a charset, and
  /// `http.Response.body` would then decode it as Latin-1.
  String text(http.Response response) {
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// Read a streamed error body as text.
  Future<String> readBody(http.StreamedResponse response) async {
    return utf8.decode(await response.stream.toBytes(), allowMalformed: true);
  }
}

/// SHA-256 of a body that comes in chunks. Each chunk is hashed when it
/// is added, so the body is never read twice.
class PayloadHasher {
  // Only gets the result; [close] closes the input that feeds it.
  // ignore: close_sinks
  final _DigestSink _digest = _DigestSink();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_digest);
  int _length = 0;

  /// Hash the next chunk.
  void add(List<int> chunk) {
    _length += chunk.length;
    _input.add(chunk);
  }

  /// Lowercase hex hash of all chunks. An empty body gives the known
  /// empty hash.
  String close() {
    if (_length == 0) {
      return StorageConstants.emptyPayloadHash;
    }
    _input.close();
    return _digest.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
