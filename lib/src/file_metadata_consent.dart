/// Shared by direct, group and scheduled file consent.
String fileMetadataConsentText(String fileName, {bool partial = false}) =>
    partial
        ? 'Some details may remain in $fileName. Send it anyway?'
        : 'The location, camera, author and date details of $fileName '
              'could not be removed. Send it with them?';
