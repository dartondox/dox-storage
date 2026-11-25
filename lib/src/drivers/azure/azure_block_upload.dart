import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../constants/storage_constants.dart';
import '../../exceptions.dart';
import 'azure_blob_client.dart';

/// One block blob upload: Put Block for each block, then Put Block List.
///
/// Azure has no abort call. Blocks that are never committed are removed
/// by Azure after 7 days.
class AzureBlockUpload {
  final AzureBlobClient client;
  final String key;
  final List<String> _ids = <String>[];

  AzureBlockUpload(this.client, this.key);

  /// Upload the next block. [chunks] are sent as they are, with no copy.
  Future<void> putBlock(List<Uint8List> chunks) async {
    if (_ids.length >= StorageConstants.azureMaxBlocks) {
      throw DriverException(key, 'File is larger than 50,000 blocks');
    }
    // Every block id of a blob must have the same length.
    String id = base64.encode(
      utf8.encode('block-${_ids.length.toString().padLeft(6, '0')}'),
    );
    http.Response response = await client.sendChunks(
      'PUT',
      client.blobUri(key, <String, String>{'comp': 'block', 'blockid': id}),
      chunks: chunks,
    );
    client.check(response, key);
    _ids.add(id);
  }

  /// Commit the blocks in order. [headers] are the blob headers, like
  /// `x-ms-blob-content-type`.
  Future<void> commit(Map<String, String> headers) async {
    StringBuffer body = StringBuffer(
      '<?xml version="1.0" encoding="utf-8"?><BlockList>',
    );
    for (String id in _ids) {
      body.write('<Latest>$id</Latest>');
    }
    body.write('</BlockList>');
    http.Response response = await client.send(
      'PUT',
      client.blobUri(key, <String, String>{'comp': 'blocklist'}),
      headers: headers,
      body: utf8.encode(body.toString()),
    );
    client.check(response, key);
  }
}
