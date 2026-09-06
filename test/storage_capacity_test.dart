import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/storage_capacity.dart';
import 'package:conest/src/models.dart';

void main() {
  test('disabled reserve still requires enough actual free bytes', () {
    const capacity = StorageCapacity(freeBytes: 200, totalBytes: 10000);
    expect(capacity.canAllocate(200, reserveFraction: 0), isTrue);
    expect(capacity.canAllocate(201, reserveFraction: 0), isFalse);
    expect(capacity.canAllocate(1), isFalse);
  });

  test('storage reserve defaults on and its disabled setting round-trips', () {
    expect(
      GlobalConnectivityPreferences.fromJson({}).storageReserveEnabled,
      isTrue,
    );
    final prefs = const GlobalConnectivityPreferences().copyWith(
      storageReserveEnabled: false,
    );
    expect(
      GlobalConnectivityPreferences.fromJson(
        prefs.toJson(),
      ).storageReserveEnabled,
      isFalse,
    );
    expect(prefs.copyWith(lanEnabled: false).storageReserveEnabled, isFalse);
  });
  test('allocation preserves an exact ten-percent disk reserve', () {
    const capacity = StorageCapacity(freeBytes: 2000, totalBytes: 10000);

    expect(capacity.canAllocate(1000), isTrue);
    expect(capacity.canAllocate(1001), isFalse);
  });

  test('allocation rejects invalid or unmeasurable capacity', () {
    expect(
      const StorageCapacity(freeBytes: 1000, totalBytes: 0).canAllocate(1),
      isFalse,
    );
    expect(
      const StorageCapacity(freeBytes: 1000, totalBytes: 10000).canAllocate(-1),
      isFalse,
    );
  });
}
