import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:dox_http_client/http.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart';

import '../../clock.dart';
import '../../constants/storage_constants.dart';
import '../../driver_contract.dart';
import '../../exceptions.dart';
import '../../types.dart';
import 'azure_blob_client.dart';
import 'azure_blob_driver_config.dart';
import 'azure_block_upload.dart';

/// Stores files in Azure Blob Storage (block blobs), or in Azurite.
///
/// Azure sets public access per container, not per file. So
/// [getVisibility] returns the container level, [setVisibility] throws
/// [UnsupportedOperationException], and the visibility of [WriteOptions]
/// is ignored.
class AzureBlobDriver implements DriverContract {
  final AzureBlobDriverConfig config;
  final AzureBlobClient client;

  /// Pass [httpClient] to reuse a client or to mock Azure in tests. With
  /// none, the driver uses the native client of `dox_http_client`.
  AzureBlobDriver(
    this.config, {
    http.Client? httpClient,
    Clock clock = const Clock(),
  }) : client = AzureBlobClient(
         config,
         httpClient: httpClient ?? DoxHttpPackageClient(),
         clock: clock,
       ) {
    if (config.blockSize <= 0 ||
        config.blockSize > StorageConstants.azureMaxBlockSize) {
      throw ArgumentError.value(
        config.blockSize,
        'blockSize',
        'must be from 1 byte to 4000 MiB',
      );
    }
  }

  /// Close the HTTP client.
  void close() {
    client.httpClient.close();
  }

  String _contentType(String key, WriteOptions options) {
    return options.contentType ??
        lookupMimeType(key) ??
        StorageConstants.defaultContentType;
  }

  /// Headers of a Put Blob. The visibility of [options] is ignored: Azure
  /// has no per-blob access level.
  Map<String, String> _putHeaders(String key, WriteOptions options) {
    return <String, String>{
      'x-ms-blob-type': 'BlockBlob',
      'content-type': _contentType(key, options),
    };
  }

  @override
  Future<bool> exists(String key) async {
    http.Response response = await client.send('HEAD', client.blobUri(key));
    if (client.blobMissing(response)) {
      return false;
    }
    client.check(response, key);
    return true;
  }

  @override
  Future<Uint8List> get(String key) async {
    http.Response response = await client.send('GET', client.blobUri(key));
    client.check(response, key);
    return response.bodyBytes;
  }

  @override
  Future<Stream<List<int>>> getStream(String key) async {
    http.StreamedResponse response = await client.sendStreamed(
      'GET',
      client.blobUri(key),
    );
    if (response.statusCode != 200) {
      client.fail(
        response.statusCode,
        await client.readBody(response),
        key,
        response.headers,
      );
    }
    return response.stream;
  }

  @override
  Future<ObjectMetaData> getMetaData(String key) async {
    http.Response response = await client.send('HEAD', client.blobUri(key));
    client.check(response, key);
    Map<String, String> headers = response.headers;
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

  /// The public access level of the container: public when anonymous
  /// read is on (`blob` or `container`), else private. The same for every
  /// key; the blob itself is not checked.
  @override
  Future<Visibility> getVisibility(String key) async {
    http.Response response = await client.send('HEAD', client.containerUri());
    client.check(response, key);
    return response.headers.containsKey('x-ms-blob-public-access')
        ? Visibility.public
        : Visibility.private;
  }

  /// Azure has no per-blob access level. Set it on the container.
  @override
  Future<void> setVisibility(String key, Visibility visibility) async {
    throw UnsupportedOperationException(
      key,
      'Azure Blob sets public access per container, not per file',
    );
  }

  @override
  Future<String> getUrl(String key) async {
    String? base = config.urlBase;
    if (base == null) {
      return client.blobUri(key).toString();
    }
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return '$base/${client.encodeKey(key)}';
  }

  String _sasUrl(
    String key,
    String permissions,
    SignedUrlOptions options, {
    bool responseHeaders = false,
  }) {
    if (options.expiresIn <= Duration.zero) {
      throw UnsupportedOperationException(
        key,
        'Azure signed URLs must expire in the future',
      );
    }
    String sas = client.signer.blobSas(
      container: config.container,
      blob: key,
      permissions: permissions,
      expiry: client.clock.now().add(options.expiresIn),
      contentType: responseHeaders ? options.contentType : null,
      contentDisposition: responseHeaders ? options.contentDisposition : null,
    );
    return '${client.blobUri(key)}?$sas';
  }

  @override
  Future<String> getSignedUrl(String key, SignedUrlOptions options) async {
    return _sasUrl(key, 'r', options, responseHeaders: true);
  }

  /// A SAS URL with create and write rights. The client must send
  /// `x-ms-blob-type: BlockBlob` with the PUT. Azure does not lock the
  /// content type: [SignedUrlOptions.contentType] is not enforced.
  @override
  Future<String> getSignedUploadUrl(
    String key,
    SignedUrlOptions options,
  ) async {
    return _sasUrl(key, 'cw', options);
  }

  @override
  Future<void> put(String key, Uint8List contents, WriteOptions options) async {
    // ponytail: one Put Blob tops out at 5000 MiB (Azure limit); use
    // putStream for bigger files, it switches to blocks.
    http.Response response = await client.send(
      'PUT',
      client.blobUri(key),
      headers: _putHeaders(key, options),
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
    // ponytail: keeps one block (blockSize, 8 MiB by default) in memory,
    // as the chunks that came in, with no copy. Blocks go up one by one.
    int blockSize = config.blockSize;
    List<Uint8List> block = <Uint8List>[];
    int length = 0;
    AzureBlockUpload? upload;
    await for (List<int> chunk in contents) {
      Uint8List bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      while (length + bytes.length >= blockSize) {
        int take = blockSize - length;
        block.add(Uint8List.sublistView(bytes, 0, take));
        bytes = Uint8List.sublistView(bytes, take);
        upload ??= AzureBlockUpload(client, key);
        await upload.putBlock(block);
        block = <Uint8List>[];
        length = 0;
      }
      if (bytes.isNotEmpty) {
        block.add(bytes);
        length += bytes.length;
      }
    }
    if (upload == null) {
      http.Response response = await client.sendChunks(
        'PUT',
        client.blobUri(key),
        headers: _putHeaders(key, options),
        chunks: block,
      );
      client.check(response, key);
      return;
    }
    if (length > 0) {
      await upload.putBlock(block);
    }
    await upload.commit(<String, String>{
      'x-ms-blob-content-type': _contentType(key, options),
    });
  }

  /// Copy Blob inside the account. The copy keeps the content type of
  /// [source] unless [WriteOptions.contentType] is given. The visibility
  /// of [options] is ignored.
  @override
  Future<void> copy(
    String source,
    String destination,
    WriteOptions options,
  ) async {
    http.Response response = await client.send(
      'PUT',
      client.blobUri(destination),
      headers: <String, String>{
        'x-ms-copy-source': client.blobUri(source).toString(),
      },
    );
    // A 404 is about the source. Other errors are about the destination.
    client.check(response, response.statusCode == 404 ? source : destination);
    String? status = response.headers['x-ms-copy-status'];
    // A copy inside one account is usually done at once. A pending copy is
    // polled until it ends or copyTimeout runs out, then it is aborted.
    Stopwatch waited = Stopwatch()..start();
    while (status == 'pending') {
      if (waited.elapsed >= config.copyTimeout) {
        await _abortCopy(destination, response.headers['x-ms-copy-id']);
        throw DriverException(
          destination,
          'Azure copy was still pending after ${config.copyTimeout}',
        );
      }
      await Future<void>.delayed(StorageConstants.azureCopyPollInterval);
      http.Response head = await client.send(
        'HEAD',
        client.blobUri(destination),
      );
      client.check(head, destination);
      status = head.headers['x-ms-copy-status'];
    }
    if (status != null && status != 'success') {
      throw DriverException(
        destination,
        'Azure copy ended with status $status',
      );
    }
    String? contentType = options.contentType;
    if (contentType != null) {
      // Set Blob Properties also clears content headers it is not given
      // (encoding, language, disposition, cache control).
      http.Response set = await client.send(
        'PUT',
        client.blobUri(destination, <String, String>{'comp': 'properties'}),
        headers: <String, String>{'x-ms-blob-content-type': contentType},
      );
      client.check(set, destination);
    }
  }

  /// Abort Copy Blob. A failed abort is ignored: the timeout error is
  /// the one that matters.
  Future<void> _abortCopy(String destination, String? copyId) async {
    if (copyId == null) {
      return;
    }
    try {
      await client.send(
        'PUT',
        client.blobUri(destination, <String, String>{
          'comp': 'copy',
          'copyid': copyId,
        }),
        headers: <String, String>{'x-ms-copy-action': 'abort'},
      );
    } catch (_) {}
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
    http.Response response = await client.send(
      'DELETE',
      client.blobUri(key),
      headers: <String, String>{'x-ms-delete-snapshots': 'include'},
    );
    if (client.blobMissing(response)) {
      return;
    }
    client.check(response, key);
  }

  @override
  Future<void> deleteAll(String prefix) async {
    // One page of names at a time: list a page, delete it, then list the
    // next one. The marker points after the last name of the page, so
    // deleted names do not move the next page. Names that end with "/"
    // go too, so no empty folder stays.
    // ponytail: no Blob Batch API (multipart/mixed); blobs are deleted
    // azureDeleteConcurrency at a time.
    String? marker;
    do {
      _Page page = await _listPage(
        prefix,
        recursive: true,
        markers: true,
        marker: marker,
        maxResults: 5000,
      );
      List<DriveEntry> entries = page.entries;
      for (int i = 0; i < entries.length;) {
        List<Future<void>> deletes = <Future<void>>[];
        int end = i + StorageConstants.azureDeleteConcurrency;
        for (; i < end && i < entries.length; i++) {
          deletes.add(delete(entries[i].key));
        }
        await Future.wait(deletes);
      }
      marker = page.marker;
    } while (marker != null);
  }

  @override
  Future<ListResult> listAll(String prefix, ListOptions options) async {
    List<DriveEntry> entries = <DriveEntry>[];
    String? marker = options.paginationToken;
    int? limit = options.limit;
    while (true) {
      _Page page = await _listPage(
        prefix,
        recursive: options.recursive,
        markers: false,
        marker: marker,
        maxResults: limit == null ? 5000 : limit - entries.length,
      );
      entries.addAll(page.entries);
      marker = page.marker;
      // Hidden folder markers (`dir/`) can leave a page short or empty,
      // so keep going until the page is full.
      if (marker == null || (limit != null && entries.length >= limit)) {
        break;
      }
    }
    entries.sort(_compareKeys);
    return ListResult(entries, paginationToken: marker);
  }

  /// One List Blobs request. With [markers] true, names that end with
  /// `/` come back as files.
  Future<_Page> _listPage(
    String prefix, {
    required bool recursive,
    required bool markers,
    required String? marker,
    required int maxResults,
  }) async {
    Map<String, String> query = <String, String>{
      'comp': 'list',
      'prefix': prefix.isEmpty ? '' : '$prefix/',
      'maxresults': '$maxResults',
    };
    if (!recursive) {
      query['delimiter'] = '/';
    }
    if (marker != null) {
      query['marker'] = marker;
    }
    http.Response response = await client.send(
      'GET',
      client.containerUri(query),
    );
    client.check(response, prefix);
    String body = client.text(response);
    List<DriveEntry> entries = <DriveEntry>[];
    for (String item in client.xml.all(body, 'Blob')) {
      String key = _name(item);
      if (markers || !key.endsWith('/')) {
        entries.add(DriveFile(key));
      }
    }
    for (String item in client.xml.all(body, 'BlobPrefix')) {
      String folder = _name(item);
      entries.add(DriveDirectory(folder.substring(0, folder.length - 1)));
    }
    String? next = client.xml.first(body, 'NextMarker');
    return _Page(entries, next == null || next.isEmpty ? null : next);
  }

  /// The `<Name>` of a `<Blob>` or `<BlobPrefix>`. A name with
  /// characters XML can not hold comes percent-encoded, with
  /// `Encoded="true"`.
  String _name(String item) {
    String name = client.xml.first(item, 'Name')!;
    if (item.contains('<Name Encoded="true">')) {
      return Uri.decodeComponent(name);
    }
    return name;
  }

  static int _compareKeys(DriveEntry a, DriveEntry b) {
    return a.key.compareTo(b.key);
  }
}

/// One page of a listing and the marker of the next page.
class _Page {
  final List<DriveEntry> entries;
  final String? marker;

  const _Page(this.entries, this.marker);
}
