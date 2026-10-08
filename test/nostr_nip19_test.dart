import 'package:conest/src/nostr/nip19.dart';
import 'package:conest/src/nostr/secp256k1.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The examples in NIP-19.
  test('npub and nsec match the NIP-19 examples', () {
    const hex =
        '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e';
    const npub =
        'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';
    expect(Nip19.npub(hex), npub);
    expect(Nip19.decodeProfile(npub)?.publicKey, hex);
    expect(Nip19.decodeProfile('nostr:$npub')?.publicKey, hex);
    const secret =
        '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';
    const nsec =
        'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';
    expect(Nip19.nsec(hexDecode(secret)!), nsec);
    expect(hexEncode(Nip19.decodeSecret(nsec)!), secret);
    // A changed character breaks the checksum.
    expect(Nip19.decodeProfile(npub.replaceRange(10, 11, 'q')), isNull);
    expect(Nip19.decodeSecret(npub), isNull);
  });

  test('nprofile matches the NIP-19 example', () {
    const nprofile =
        'nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhx'
        'ue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p';
    final profile = Nip19.decodeProfile(nprofile)!;
    expect(
      profile.publicKey,
      '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d',
    );
    expect(profile.relays.map((uri) => uri.toString()), [
      'wss://r.x.com',
      'wss://djbas.sadkb.com',
    ]);
    expect(Nip19.nprofile(profile.publicKey, profile.relays), nprofile);
  });
}
