import 'dart:convert';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import 'xmpp_xml.dart';

/// Sign-up forms of XMPP servers (XEP-0077 in-band registration): the data
/// form with a CAPTCHA (XEP-0158, an image sent with XEP-0231), and servers
/// that send people to a web page instead (XEP-0066 `jabber:x:oob`). All of
/// it comes from the server, so every size is bounded and nothing is
/// followed or opened by itself.

const _bobNamespace = 'urn:xmpp:bob';
const _mediaNamespace = 'urn:xmpp:media-element';

/// The largest CAPTCHA image taken.
const int maxCaptchaImageBytes = 256 * 1024;

/// The most hidden fields sent back.
const int _maxHiddenFields = 16;

const Set<String> _imageTypes = {'image/png', 'image/jpeg', 'image/webp'};
// GIF is not taken: decoders grow the canvas to the first frame's
// rectangle, wherever it sits, whatever the header says.

/// The largest CAPTCHA picture taken, by side and by area.
const int maxCaptchaSide = 1024;
const int maxCaptchaPixels = 4 * 1000 * 1000;

/// The MIME type and size of an image, read from its header without
/// decoding (PNG, JPEG, WebP only); null for anything else or a
/// damaged header.
({String mime, int width, int height})? readImageHeader(Uint8List b) {
  int le16(int i) => b[i] | b[i + 1] << 8;
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4e &&
      b[3] == 0x47 &&
      b[4] == 0x0d &&
      b[5] == 0x0a &&
      b[6] == 0x1a &&
      b[7] == 0x0a &&
      b[12] == 0x49 && // IHDR
      b[13] == 0x48 &&
      b[14] == 0x44 &&
      b[15] == 0x52) {
    return (
      mime: 'image/png',
      width: b[16] << 24 | b[17] << 16 | b[18] << 8 | b[19],
      height: b[20] << 24 | b[21] << 16 | b[22] << 8 | b[23],
    );
  }
  if (b.length >= 4 && b[0] == 0xff && b[1] == 0xd8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xff) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xff) {
        i++;
        continue;
      }
      if (marker == 0xd8 ||
          marker == 0x01 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        i += 2;
        continue;
      }
      final length = b[i + 2] << 8 | b[i + 3];
      // Start of frame (not DHT, JPG or DAC).
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          marker != 0xc4 &&
          marker != 0xc8 &&
          marker != 0xcc) {
        return (
          mime: 'image/jpeg',
          height: b[i + 5] << 8 | b[i + 6],
          width: b[i + 7] << 8 | b[i + 8],
        );
      }
      if (length < 2) return null;
      i += 2 + length;
    }
    return null;
  }
  if (b.length >= 30 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    final kind = String.fromCharCodes(b.sublist(12, 16));
    if (kind == 'VP8X') {
      return (
        mime: 'image/webp',
        width: 1 + (b[24] | b[25] << 8 | b[26] << 16),
        height: 1 + (b[27] | b[28] << 8 | b[29] << 16),
      );
    }
    if (kind == 'VP8L' && b[20] == 0x2f) {
      final bits = b[21] | b[22] << 8 | b[23] << 16 | b[24] << 24;
      return (
        mime: 'image/webp',
        width: 1 + (bits & 0x3fff),
        height: 1 + ((bits >> 14) & 0x3fff),
      );
    }
    if (kind == 'VP8 ' && b[23] == 0x9d && b[24] == 0x01 && b[25] == 0x2a) {
      return (
        mime: 'image/webp',
        width: le16(26) & 0x3fff,
        height: le16(28) & 0x3fff,
      );
    }
  }
  return null;
}

/// A CAPTCHA the user answers by reading an image.
class XmppCaptchaChallenge {
  const XmppCaptchaChallenge({
    required this.image,
    required this.mimeType,
    required this.fieldVar,
    this.instructions,
    this.domain = '',
  });

  /// The server the answer goes to (set when the user is asked).
  final String domain;

  XmppCaptchaChallenge forDomain(String domain) => XmppCaptchaChallenge(
    image: image,
    mimeType: mimeType,
    fieldVar: fieldVar,
    instructions: instructions,
    domain: domain,
  );

  final Uint8List image;
  final String mimeType;

  /// The form field the answer goes to (often `ocr`).
  final String fieldVar;

  /// What the server says to do, as plain text.
  final String? instructions;
}

/// Asks the user the CAPTCHA; the answer, or null when they give up.
typedef XmppCaptchaSolver =
    Future<String?> Function(XmppCaptchaChallenge challenge);

/// The server signs people up on a web page.
class XmppRegistrationRedirect implements Exception {
  const XmppRegistrationRedirect(this.url);

  /// An `https` address.
  final String url;

  @override
  String toString() => 'XMPP: sign-up is on the server\'s website ($url)';
}

/// The user cancelled the sign-up (at a CAPTCHA): setup stops.
class XmppRegistrationCancelled implements Exception {
  const XmppRegistrationCancelled();

  @override
  String toString() => 'Sign-up cancelled.';
}

/// The server asks for a CAPTCHA and none was answered.
class XmppCaptchaRequired implements Exception {
  const XmppCaptchaRequired();

  @override
  String toString() => 'XMPP: the server asks for a CAPTCHA';
}

/// The server asks for more than Conest can give (an email address, a
/// phone number, an invite).
class XmppRegistrationNeedsMore extends XmppProtocolException {
  const XmppRegistrationNeedsMore(this.fields)
    : super('The server needs more than a name and password to register.');

  /// The names of the extra required fields (bounded).
  final List<String> fields;
}

/// What a server's sign-up form asks for.
class XmppRegistrationForm {
  const XmppRegistrationForm({
    this.redirect,
    this.captcha,
    this.unsupported = const [],
    this.hasNameAndPassword = false,
    this.dataForm = false,
    this.formType,
    this.hidden = const [],
  });

  /// The web page to sign up on, when the server wants that.
  final String? redirect;
  final XmppCaptchaChallenge? captcha;

  /// Required fields beyond name, password and the CAPTCHA.
  final List<String> unsupported;
  final bool hasNameAndPassword;

  /// Whether the server sent a data form (to be answered as one).
  final bool dataForm;
  final String? formType;

  /// Hidden fields (`var`, value) the answer sends back unchanged.
  final List<(String, String)> hidden;
}

final RegExp _unsafeText = RegExp(
  r'[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]',
);

/// Text from a server made safe to show or log: no control, bidi or
/// zero-width characters, at most [max] characters.
String serverText(String text, [int max = 200]) {
  final cleaned = text.replaceAll(_unsafeText, '');
  return cleaned.length > max ? cleaned.substring(0, max) : cleaned;
}

String _plain(String text, int max) => serverText(text, max);

/// Whether [url] is an `https` address of a public host name that is safe
/// to offer: no IP address, no user info, no local or single-label name.
bool isPublicHttpsUrl(String url) {
  if (url.isEmpty || url.length > 512) return false;
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty) {
    return false;
  }
  var host = uri.host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  final labels = host.split('.');
  final last = labels.last;
  if (host.isEmpty ||
      labels.any((label) => label.isEmpty) ||
      RegExp(r'^(0x[0-9a-f]*|[0-9]+)$').hasMatch(last)) {
    return false;
  }
  if (InternetAddress.tryParse(host) != null ||
      host.contains(':') ||
      !host.contains('.') ||
      host == 'localhost' ||
      RegExp(
        r'\.(local|localhost|localdomain|internal|lan|home|corp|intranet|onion|arpa)\.?$',
      ).hasMatch(host) ||
      RegExp(r'^[0-9.]+$').hasMatch(host)) {
    return false;
  }
  return true;
}

/// An `https` address the server named, or null.
String? _httpsUrl(String? text) {
  final trimmed = text?.trim();
  if (trimmed == null || !isPublicHttpsUrl(trimmed)) return null;
  return Uri.parse(trimmed).toString();
}

XmppCaptchaChallenge? _challenge(
  XmppElement query,
  XmppElement field,
  XmppElement? form,
) {
  final media = field.child('media', _mediaNamespace);
  if (media == null) return null;
  final cids = <String>[];
  for (final uri in media.all('uri').take(8)) {
    final value = uri.text.trim();
    if (value.startsWith('cid:')) cids.add(value.substring(4));
  }
  final blobs = [
    ...query.all('data', _bobNamespace),
    if (form != null) ...form.all('data', _bobNamespace),
  ];
  for (final cid in cids) {
    for (final blob in blobs.take(8)) {
      if (blob.attr('cid') != cid) continue;
      final type = (blob.attr('type') ?? '').toLowerCase();
      if (!_imageTypes.contains(type)) continue;
      final encoded = blob.text.replaceAll(RegExp(r'\s'), '');
      // Base64 is a third larger than what it carries.
      if (encoded.length > maxCaptchaImageBytes * 4 ~/ 3 + 8) continue;
      try {
        final bytes = base64.decode(encoded);
        if (bytes.isEmpty || bytes.length > maxCaptchaImageBytes) continue;
        // What the bytes are, and how big, from the header alone: the
        // declared type is not trusted, and nothing is decoded that
        // would need more than a few megapixels.
        final header = readImageHeader(Uint8List.fromList(bytes));
        if (header == null ||
            header.mime != type ||
            header.width < 1 ||
            header.height < 1 ||
            header.width > maxCaptchaSide ||
            header.height > maxCaptchaSide ||
            header.width * header.height > maxCaptchaPixels) {
          continue;
        }
        final label = field.attr('label');
        final instructions = form?.childText('instructions') ?? '';
        final text = [
          if (instructions.trim().isNotEmpty) instructions.trim(),
          if (label != null && label.trim().isNotEmpty) label.trim(),
        ].join('\n');
        return XmppCaptchaChallenge(
          image: Uint8List.fromList(bytes),
          mimeType: type,
          fieldVar: field.attr('var') ?? 'ocr',
          instructions: text.isEmpty ? null : _plain(text, 500),
        );
      } on FormatException {
        continue;
      }
    }
  }
  return null;
}

/// Reads the answer to a registration request (the `query` element).
XmppRegistrationForm parseRegistrationForm(XmppElement query) {
  final form = query.child('x', XmppNs.dataForms);
  final redirect = _httpsUrl(query.child('x', XmppNs.oob)?.childText('url'));
  final legacy =
      query.child('username') != null && query.child('password') != null;
  var inForm = false;
  String? formType;
  XmppCaptchaChallenge? captcha;
  var captchaAsked = false;
  final unsupported = <String>[];
  final hidden = <(String, String)>[];
  if (form != null) {
    final names = <String>{};
    for (final field in form.all('field').take(64)) {
      final name = field.attr('var') ?? '';
      if (name.isEmpty || name.length > 64) continue;
      names.add(name);
      final value = field.childText('value') ?? '';
      if (name == 'FORM_TYPE') {
        formType = _plain(value, 128);
      } else if (name == 'username' || name == 'password') {
        continue;
      } else if (field.attr('type') == 'hidden') {
        if (hidden.length < _maxHiddenFields && value.length <= 1024) {
          hidden.add((name, value));
        }
      } else if (field.child('media', _mediaNamespace) != null ||
          name == 'ocr') {
        captchaAsked = true;
        captcha ??= _challenge(query, field, form);
      } else if (field.child('required') != null) {
        if (unsupported.length < 8) unsupported.add(_plain(name, 64));
      }
    }
    inForm = names.contains('username') && names.contains('password');
  }
  return XmppRegistrationForm(
    redirect: redirect,
    // A CAPTCHA the form asks for but the image of which did not parse is
    // one that cannot be answered.
    captcha: captcha,
    unsupported: [
      ...unsupported,
      if (captchaAsked && captcha == null) 'captcha',
    ],
    hasNameAndPassword: legacy || inForm,
    dataForm: form != null,
    formType: formType,
    hidden: hidden,
  );
}

/// The `query` element that signs up [username] with [password]; as a data
/// form, with the CAPTCHA [answer], when the server asked for one.
XmppElement registrationSubmission(
  XmppRegistrationForm form, {
  required String username,
  required String password,
  String? answer,
}) {
  final query = XmppElement(
    'query',
    xmlns: XmppNs.register,
    children: [
      XmppElement('username', text: username),
      XmppElement('password', text: password),
    ],
  );
  if (form.captcha == null) return query;
  XmppElement field(String name, String value) => XmppElement(
    'field',
    xmlns: XmppNs.dataForms,
    attributes: {'var': name},
    children: [XmppElement('value', xmlns: XmppNs.dataForms, text: value)],
  );
  query.add(
    XmppElement(
      'x',
      xmlns: XmppNs.dataForms,
      attributes: {'type': 'submit'},
      children: [
        if (form.formType != null) field('FORM_TYPE', form.formType!),
        for (final (name, value) in form.hidden) field(name, value),
        field('username', username),
        field('password', password),
        field(form.captcha!.fieldVar, answer ?? ''),
      ],
    ),
  );
  return query;
}
