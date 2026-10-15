import '../app_locales.dart';
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
        title: Text(l10nOf(context).uiSendWithItsDetailsF287FB),
        content: Text(fileMetadataConsentText(fileName, partial: partial)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10nOf(context).uiSendAnyway911263),
          ),
        ],
      ),
    ) ??
    false;
