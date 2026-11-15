import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../constants/storage_constants.dart';
import '../../exceptions.dart';
import 's3_client.dart';

/// One S3 multipart upload: start, upload parts, then complete or abort.
class S3MultipartUpload {
  final S3Client client;
  final String key;
  final String uploadId;
  final List<String> _etags = <String>[];

  S3MultipartUpload._(this.client, this.key, this.uploadId);

  /// Start an upload. [headers] are the object headers (content type, ACL).
  static Future<S3MultipartUpload> start(
    S3Client client,
    String key,
    Map<String, String> headers,
  ) async {
    http.Response response = await client.send(
      'POST',
      client.objectUri(key, <String, String>{'uploads': ''}),
      headers: headers,
    );
    client.checkBodyError(response, key);
    String? uploadId = client.xml.first(client.text(response), 'UploadId');
    if (uploadId == null) {
      throw DriverException(key, 'S3 did not return an UploadId');
    }
    return S3MultipartUpload._(client, key, uploadId);
  }

  /// Upload the next part.
  Future<void> uploadPart(S3PartBuffer part) async {
    int partNumber = _etags.length + 1;
    // ponytail: S3 caps uploads at 10,000 parts (~78 GiB with 8 MiB parts);
    // raise multipartPartSize for bigger files.
    if (partNumber > StorageConstants.maxMultipartParts) {
      throw DriverException(key, 'File is larger than 10,000 parts');
    }
    http.Response response = await client.sendChunks(
      'PUT',
      client.objectUri(key, <String, String>{
        'partNumber': '$partNumber',
        'uploadId': uploadId,
      }),
      chunks: part.chunks,
      hash: part.hash(),
    );
    client.check(response, key);
    String? etag = response.headers['etag'];
    if (etag == null) {
      throw DriverException(key, 'S3 did not return an ETag for a part');
    }
    _etags.add(etag);
  }

  /// Finish the upload.
  Future<void> complete() async {
    StringBuffer body = StringBuffer('<CompleteMultipartUpload>');
    for (int i = 0; i < _etags.length; i++) {
      body.write(
        '<Part><PartNumber>${i + 1}</PartNumber>'
        '<ETag>${client.xml.escape(_etags[i])}</ETag></Part>',
      );
    }
    body.write('</CompleteMultipartUpload>');
    http.Response response = await client.send(
      'POST',
      client.objectUri(key, <String, String>{'uploadId': uploadId}),
      headers: <String, String>{'content-type': 'application/xml'},
      body: utf8.encode(body.toString()),
    );
    client.checkBodyError(response, key);
  }

  /// Cancel the upload so S3 drops the stored parts.
  Future<void> abort() async {
    await client.send(
      'DELETE',
      client.objectUri(key, <String, String>{'uploadId': uploadId}),
    );
  }
}

/// The bytes of one part (or of a small file), kept as the chunks they
/// came in, with no copy. Each chunk is hashed when it is added, so the
/// part is never read twice. With `unsignedPayload` on, nothing is hashed.
class S3PartBuffer {
  final List<Uint8List> chunks = <Uint8List>[];
  final PayloadHasher? _hasher;
  int length = 0;

  S3PartBuffer({required bool unsignedPayload})
    : _hasher = unsignedPayload ? null : PayloadHasher();

  /// Add a chunk. A chunk over 1 MiB is hashed in slices of 1 MiB. The
  /// code lets other work run between slices, so a big chunk does not
  /// block the isolate for long.
  Future<void> add(Uint8List chunk) async {
    chunks.add(chunk);
    length += chunk.length;
    PayloadHasher? hasher = _hasher;
    if (hasher == null) {
      return;
    }
    const int slice = 1024 * 1024;
    if (chunk.length <= slice) {
      hasher.add(chunk);
      return;
    }
    for (int start = 0; start < chunk.length; start += slice) {
      int end = start + slice < chunk.length ? start + slice : chunk.length;
      hasher.add(Uint8List.sublistView(chunk, start, end));
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The `x-amz-content-sha256` value. Call it once, when the part is full.
  String hash() {
    if (length == 0) {
      return StorageConstants.emptyPayloadHash;
    }
    return _hasher?.close() ?? StorageConstants.unsignedPayload;
  }
}
