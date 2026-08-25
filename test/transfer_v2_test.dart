import 'package:conest/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('attachment protocol v2 policy', () {
    test('medium preset follows exact unmetered and metered boundaries', () {
      const mib = 1024 * 1024;
      expect(
        AutoDownloadPreset.medium.allows(
          mimeType: 'image/jpeg',
          sizeBytes: 10 * mib,
          network: NetworkCostClass.unmetered,
          verifiedContact: true,
        ),
        isTrue,
      );
      expect(
        AutoDownloadPreset.medium.allows(
          mimeType: 'image/jpeg',
          sizeBytes: 10 * mib + 1,
          network: NetworkCostClass.unmetered,
          verifiedContact: true,
        ),
        isFalse,
      );
      expect(
        AutoDownloadPreset.medium.allows(
          mimeType: 'video/mp4',
          sizeBytes: 5 * mib,
          network: NetworkCostClass.metered,
          verifiedContact: true,
        ),
        isTrue,
      );
      expect(
        AutoDownloadPreset.medium.allows(
          mimeType: 'application/pdf',
          sizeBytes: 1 * mib + 1,
          network: NetworkCostClass.metered,
          verifiedContact: true,
        ),
        isFalse,
      );
    });

    test('roaming and unverified contacts remain manual by default', () {
      expect(
        AutoDownloadPreset.medium.allows(
          mimeType: 'image/jpeg',
          sizeBytes: 32,
          network: NetworkCostClass.roaming,
          verifiedContact: true,
        ),
        isFalse,
      );
      expect(
        AutoDownloadPreset.high.allows(
          mimeType: 'image/jpeg',
          sizeBytes: 1024 * 1024,
          network: NetworkCostClass.roaming,
          verifiedContact: true,
        ),
        isTrue,
      );
      expect(
        AutoDownloadPreset.high.allows(
          mimeType: 'image/jpeg',
          sizeBytes: 1,
          network: NetworkCostClass.unmetered,
          verifiedContact: false,
        ),
        isFalse,
      );
    });

    test('exact progress remains byte based', () {
      const snapshot = TransferSnapshot(
        id: 'att-v2',
        phase: TransferPhase.transferring,
        direction: TransferDirection.inbound,
        bytesTransferred: 3,
        totalBytes: 10,
      );
      expect(snapshot.progress, 0.3);
      expect(snapshot.phase.isActive, isTrue);
      expect(TransferPhase.completed.isActive, isFalse);
    });

    test('auto-download preset survives connectivity persistence', () {
      const preferences = GlobalConnectivityPreferences(
        autoDownloadPreset: AutoDownloadPreset.high,
      );
      final restored = GlobalConnectivityPreferences.fromJson(
        preferences.toJson(),
      );
      expect(restored.autoDownloadPreset, AutoDownloadPreset.high);
    });
  });
}
