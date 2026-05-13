# Conest release notes

This file is read by `tool/release_manifest.dart` when CI builds a **stable**
tag, and its contents are baked into the signed `RELEASE-MANIFEST.json` as
the `releaseNotes` field. Stable update prompts render this text in the
"What's new" section before the user installs the update. Nightly builds
ignore this file entirely.

When cutting a stable release, replace the body below with a short, user-facing
changelog for the new version. Bullet lines render acceptably as plain text in
the in-app dialog.

---

(no stable notes pending — update this section when cutting the next stable
release)
