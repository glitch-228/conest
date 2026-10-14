#!/usr/bin/env python3
"""Run Q4b behavior mutations only after the focused suite passes.

From the repository root: python3 tool/q4b_sabotage.py --flutter /path/to/flutter
Use --dry-run to validate mutation anchors without changing files.
Every mutated file is restored byte-for-byte in finally. Run the full suite
afterwards as well. Runtime startup/compilation errors are not sabotage proof.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys

MEDIA = 'test/media_sanitizer_test.dart'
CONTROLLER = 'test/messenger_controller_test.dart'
CONSENT = 'test/file_metadata_consent_test.dart'
SANITIZER = 'lib/src/media_sanitizer.dart'
ISO = 'lib/src/iso_media_sanitizer.dart'
OFFICE = 'lib/src/office_metadata_sanitizer.dart'
PDF = 'lib/src/pdf_metadata_sanitizer.dart'
CORE = 'lib/src/messenger_controller.dart'

# Each case disables one behavior and selects its regression test(s).
CASES = [
    ('uuid', MEDIA, 'MP4 meta/gpmd clears', ISO,
     "{'udta', 'uuid', 'sefd'}", "{'udta', 'uuix', 'sefd'}"),
    ('samsung-box', MEDIA, 'MP4 meta/gpmd clears', ISO,
     "{'udta', 'uuid', 'sefd'}", "{'udta', 'uuid', 'sefx'}"),
    ('samsung-trailer', MEDIA, 'MP4 meta/gpmd clears', ISO,
     "!= 'SEFT') { return null; }", "!= 'SEFX') { return null; }"),
    ('timed-metadata', MEDIA, 'MP4 meta/gpmd clears', ISO,
     "bool metadata(int description) => type == 'meta' || type == 'text' &&\n"
     "        const {'gpmd', 'mebx', 'camm'}.contains(descriptions[description - 1]);",
     'bool metadata(int description) => false;'),
    ('range-merge', MEDIA, 'MP4 repeated metadata offsets', ISO,
     'for (final range in merged)', 'for (final range in zeroRanges)'),
    ('heif-ids', MEDIA, 'HEIF duplicate item ID', ISO,
     'if (!declared.add(id))', 'if (false)'),
    ('heif-locations', MEDIA, 'HEIF missing metadata location', ISO,
     'if (!located.containsAll(metadata))', 'if (false)'),
    ('docx-authors', MEDIA, 'DOCX tracked changes', OFFICE,
     "{'author', 'initials'}.contains(key)", "{'otherAuthor', 'initials'}.contains(key)"),
    ('xlsx-authors', MEDIA, 'xl comment identities', OFFICE,
     "local == 'author')", "local == 'otherAuthor')"),
    ('odf-authors', MEDIA, 'ODF change-info', OFFICE,
     "if (inDetails && local == 'creator')", "if (false && local == 'creator')"),
    ('embedded-image', MEDIA, 'DOCX tracked changes', SANITIZER,
     'final cleaned = sanitizeBytes(image);', 'final cleaned = image;'),
    ('pdf-info', MEDIA, 'PDF cleans only Info', PDF,
     'for (final trailer in parser.trailers)', 'for (final trailer in <_PdfValue>[])'),
    ('pdf-xmp', MEDIA, 'PDF cleans only Info', PDF,
     "if (type == 'Metadata')", "if (type == 'OtherMetadata')"),
    ('pdf-jpeg', MEDIA, 'PDF JPEG APP1 payload', PDF,
     'if (marker == 0xe1)', 'if (marker == 0xe3)'),
    ('pdf-partial', MEDIA, 'PDF compressed object metadata requires', PDF,
     "'Author', 'Creator', 'Producer'", "'OtherAuthor', 'Creator', 'Producer'"),
    ('pdf-shared', MEDIA, 'PDF compressed shared encoding reference', PDF,
     'ordinaryReferences.contains(info.text)', 'false'),
    ('png-c2pa', MEDIA, 'PNG removes caBX', SANITIZER,
     "'tIME', 'caBX'", "'tIME', 'caBY'"),
    ('png-trailing', MEDIA, 'PNG removes caBX', SANITIZER,
     'if (index < data.length) removed = true;', 'if (false) removed = true;'),
    ('jpeg-jfxx', MEDIA, 'JPEG removes both thumbnail', SANITIZER,
     "0xe0 => startsWith('JFIF\\u0000'),",
     "0xe0 => startsWith('JFIF\\u0000') || startsWith('JFXX\\u0000'),"),
    ('jpeg-jfif', MEDIA, 'JPEG removes both thumbnail', SANITIZER,
     'if (body[12] != 0 || body[13] != 0)', 'if (false)'),
    ('zip-ratio', MEDIA, 'ZIP expansion ratio', OFFICE,
     'maxExpansionRatio = 100;', 'maxExpansionRatio = 1000000;'),
    ('zip-count', MEDIA, 'ZIP expansion ratio', OFFICE,
     'maxEntries = 2048;', 'maxEntries = 4096;'),
    ('iso-depth', MEDIA, 'ISO nesting, global box count', ISO,
     'maxDepth = 32;', 'maxDepth = 128;'),
    ('iso-count', MEDIA, 'ISO nesting, global box count', ISO,
     'maxBoxes = 20000;', 'maxBoxes = 40000;'),
    ('pdf-inflate', MEDIA, 'PDF inflate output cap', PDF,
     'maxInflatedBytes = 8 * 1024 * 1024;', 'maxInflatedBytes = 16 * 1024 * 1024;'),
    ('direct-consent', CONTROLLER, 'partial file cleaning requires consent', CORE,
     'throw const _MetadataNotRemoved(partial: true);', 'break;'),
    ('group-consent', CONTROLLER, 'partial file cleaning requires consent', CORE,
     'throw FileMetadataException(fileName, partial: true);', 'return copy.path;'),
    ('scheduled-dispatch', CONTROLLER, 'scheduled cleaning failure asks now', CORE,
     'cleanMetadata: !entry.attachmentPrivacyPrepared,', 'cleanMetadata: true,'),
    ('partial-wording', CONSENT, 'file metadata dialog uses partial wording',
     'lib/src/file_metadata_consent.dart',
     'Some details may remain in $fileName. Send it anyway?',
     'Details could not be removed from $fileName.'),
]


def run(flutter, files, pattern):
    command = [flutter, 'test', *files, '--name', pattern, '--reporter', 'expanded']
    return subprocess.run(command, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--case', action='append', default=[])
    args = parser.parse_args()
    cases = [case for case in CASES if not args.case or case[0] in args.case]
    if not cases:
        parser.error('No cases selected')
    for slug, _, _, path, old, _ in cases:
        if Path(path).read_text().count(old) != 1:
            parser.error(f'{slug}: mutation anchor is missing or not unique in {path}')
    if args.dry_run:
        print(f'{len(cases)} mutation anchors validated; no source changes or test claims')
        return 0
    baseline = run(args.flutter, [MEDIA, CONTROLLER, CONSENT],
                   r'Q4b privacy|File privacy|file metadata dialog|scheduled privacy flag')
    if baseline.returncode:
        print('BLOCKED: focused suite must pass before any mutations; no files changed.')
        print((baseline.stdout + baseline.stderr)[-6000:])
        return 2
    for slug, test_file, pattern, path, old, new in cases:
        target = Path(path)
        original = target.read_bytes()
        try:
            target.write_text(original.decode().replace(old, new))
            result = run(args.flutter, [test_file], re.escape(pattern))
            output = result.stdout + result.stderr
            if result.returncode == 0 or not re.search(r'Expected:|TestFailure|timed out', output):
                print(f'NOT PROVEN: {slug}\n{output[-6000:]}')
                return 1
            print(f'PROVEN: {slug} produced a regression test failure')
        finally:
            target.write_bytes(original)
    restored = run(args.flutter, [MEDIA, CONTROLLER, CONSENT],
                   r'Q4b privacy|File privacy|file metadata dialog|scheduled privacy flag')
    if restored.returncode:
        print('Restored focused suite failed:\n' + (restored.stdout + restored.stderr)[-6000:])
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
