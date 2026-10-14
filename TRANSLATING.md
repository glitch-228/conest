# Translating Conest

Conest's interface text lives in ARB files in `lib/l10n/`:

- `app_en.arb` is the source (English). Every string there has a
  description for translators (`@key` → `description`).
- `app_<code>.arb` holds one language each.

The languages shipped today are English, Arabic (`ar`), Persian (`fa`),
Indonesian (`id`), Russian (`ru`) and Simplified Chinese (`zh`). The
translations other than English were made with AI. Each AI-made file has
`"@@x-ai-translated": true` near the top; Settings → Personal → Language
says so to users while that flag is set.

## Helping on Weblate

Translations are managed on Weblate. Fix wording there rather than in pull
requests where you can, so changes from different people do not collide.

When a person has reviewed a whole language, remove its
`"@@x-ai-translated": true` line (and its code from
`aiTranslatedLanguages` in `lib/src/app_locales.dart`), so the AI note goes
away for that language.

## Rules for translators

- Keep placeholders such as `{time}` or `{minutes}` exactly as they are;
  move them wherever the sentence needs them.
- Keep product and network names as they are: Conest, Tor, Nostr, Matrix,
  LoRa, Weblate, Iroh.
- Menu paths (such as Settings → Connectivity) must match what the
  translated Settings screen says.
- Plurals use ICU syntax (`{count, plural, one{…} other{…}}`); add the
  plural categories your language needs.
- Keep the tone short and plain: the text often sits on a phone screen.

## Weblate component settings (for maintainers)

- File format: ARB file (`arb`)
- File mask: `lib/l10n/app_*.arb`
- Monolingual base language file: `lib/l10n/app_en.arb`
- Template for new translations: `lib/l10n/app_en.arb`
- Language code style: as used here (`zh`, not `zh_Hans`)
- Push branch: a separate branch, merged by the maintainers after CI.

## Adding a language

1. Copy `app_en.arb` to `app_<code>.arb`, set `"@@locale"` and translate
   (or add the language on Weblate).
2. Add the code and its own name to `appLanguageNames` in
   `lib/src/app_locales.dart`.
3. Run `flutter test test/l10n_test.dart`: it checks that every language has
   every string with the same placeholders, and renders key screens in
   every language at phone width (right to left for Arabic and Persian).
