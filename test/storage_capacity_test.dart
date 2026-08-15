import 'package:flutter_test/flutter_test.dart';

import 'package:conest/src/storage_capacity.dart';

void main() {
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
