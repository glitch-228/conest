import 'package:flutter/material.dart';

import '../file_metadata_consent.dart';

Future<bool> showFileMetadataConsent(
  BuildContext context,
  String fileName, {
  bool partial = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Send with its details?'),
        content: Text(fileMetadataConsentText(fileName, partial: partial)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Send anyway'),
          ),
        ],
      ),
    ) ??
    false;
