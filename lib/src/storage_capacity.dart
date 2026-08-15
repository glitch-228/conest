import 'package:disk_space_2/disk_space_2.dart';

class StorageCapacity {
  const StorageCapacity({required this.freeBytes, required this.totalBytes});

  final int freeBytes;
  final int totalBytes;

  bool canAllocate(int bytes, {double reserveFraction = 0.10}) {
    if (bytes < 0 || freeBytes < bytes || totalBytes <= 0) return false;
    final reserve = (totalBytes * reserveFraction).ceil();
    return freeBytes - bytes >= reserve;
  }
}

typedef StorageCapacityProvider =
    Future<StorageCapacity?> Function(String path);

Future<StorageCapacity?> defaultStorageCapacityProvider(String path) async {
  try {
    final freeMiB = await DiskSpace.getFreeDiskSpaceForPath(path);
    final totalMiB = await DiskSpace.getTotalDiskSpace;
    if (freeMiB == null || totalMiB == null) return null;
    const bytesPerMiB = 1024 * 1024;
    return StorageCapacity(
      freeBytes: (freeMiB * bytesPerMiB).floor(),
      totalBytes: (totalMiB * bytesPerMiB).floor(),
    );
  } catch (_) {
    return null;
  }
}
