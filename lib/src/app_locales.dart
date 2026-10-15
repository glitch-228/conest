/// The languages Conest ships, by code, with their own names.
library;

import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

const Map<String, String> appLanguageNames = {
  'en': 'English',
  'ar': 'العربية',
  'fa': 'فارسی',
  'id': 'Bahasa Indonesia',
  'ru': 'Русский',
  'zh': '简体中文',
};

/// Languages translated with AI (marked in Settings and the README) until
/// people review them on Weblate.
const Set<String> aiTranslatedLanguages = {'ar', 'fa', 'id', 'ru', 'zh'};

/// The app's strings for [context]; English where no localizations are
/// set up above it (a widget shown on its own, as in tests).
AppLocalizations l10nOf(BuildContext? context) =>
    (context == null ? null : Localizations.of<AppLocalizations>(context, AppLocalizations)) ??
    lookupAppLocalizations(const Locale('en'));
