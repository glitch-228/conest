import 'dart:convert';
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

const Set<String> _imageTypes = {'image/png', 'image/jpeg', 'image/gif'};

/// A CAPTCHA the user answers by reading an image.
class XmppCaptchaChallenge {
  const XmppCaptchaChallenge({
    required this.image,
    required this.mimeType,
    required this.fieldVar,
    this.instructions,
  });

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

String _plain(String text, int max) {
  final cleaned = text.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '');
  return cleaned.length > max ? cleaned.substring(0, max) : cleaned;
}

/// An `https` address the server named, or null.
String? _httpsUrl(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.length > 512) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
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
