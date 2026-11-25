import '../../constants/storage_constants.dart';

/// Settings for [AzureBlobDriver].
///
/// - Azure: only [accountName], [accountKey] and [container].
/// - Azurite: `endpoint: 'http://127.0.0.1:10000/devstoreaccount1'`.
class AzureBlobDriverConfig {
  /// The storage account name.
  final String accountName;

  /// The account key (base64), as shown in the Azure portal.
  final String accountKey;

  /// The blob container. The driver does not create it.
  final String container;

  /// Blob service URL without the container. Defaults to
  /// `https://<accountName>.blob.core.windows.net`.
  final String? endpoint;

  /// Public URL base for `getUrl`, for example a CDN. When null, the
  /// container URL is used.
  final String? urlBase;

  /// Block size for `putStream` (Put Block). Azure allows up to 4000 MiB
  /// per block and 50,000 blocks per blob.
  final int blockSize;

  /// How long `copy` waits for a pending Copy Blob. Then the copy is
  /// aborted and `copy` throws.
  final Duration copyTimeout;

  const AzureBlobDriverConfig({
    required this.accountName,
    required this.accountKey,
    required this.container,
    this.endpoint,
    this.urlBase,
    this.blockSize = StorageConstants.azureDefaultBlockSize,
    this.copyTimeout = StorageConstants.azureDefaultCopyTimeout,
  });
}
