import 'dart:convert';

import 'package:xml/xml.dart'
    show XmlAttributeType, XmlDefaultEntityMapping, XmlEntityMapping;
import 'package:xml/xml_events.dart';

/// Namespaces Conest's XMPP code speaks.
abstract final class XmppNs {
  static const client = 'jabber:client';
  static const stream = 'http://etherx.jabber.org/streams';
  static const framing = 'urn:ietf:params:xml:ns:xmpp-framing';
  static const tls = 'urn:ietf:params:xml:ns:xmpp-tls';
  static const sasl = 'urn:ietf:params:xml:ns:xmpp-sasl';
  static const bind = 'urn:ietf:params:xml:ns:xmpp-bind';
  static const session = 'urn:ietf:params:xml:ns:xmpp-session';
  static const stanzas = 'urn:ietf:params:xml:ns:xmpp-stanzas';
  static const streams = 'urn:ietf:params:xml:ns:xmpp-streams';
  static const register = 'jabber:iq:register';
  static const registerFeature = 'http://jabber.org/features/iq-register';
  static const roster = 'jabber:iq:roster';
  static const sm = 'urn:xmpp:sm:3';
  static const csi = 'urn:xmpp:csi:0';
  static const carbons = 'urn:xmpp:carbons:2';
  static const hints = 'urn:xmpp:hints';
  static const forward = 'urn:xmpp:forward:0';
  static const delay = 'urn:xmpp:delay';
  static const mam = 'urn:xmpp:mam:2';
  static const dataForms = 'jabber:x:data';
  static const rsm = 'http://jabber.org/protocol/rsm';
  static const muc = 'http://jabber.org/protocol/muc';
  static const mucUser = 'http://jabber.org/protocol/muc#user';
  static const receipts = 'urn:xmpp:receipts';
  static const markers = 'urn:xmpp:chat-markers:0';
  static const correction = 'urn:xmpp:message-correct:0';
  static const retract = 'urn:xmpp:message-retract:1';
  static const reply = 'urn:xmpp:reply:0';
  static const reactions = 'urn:xmpp:reactions:0';
  static const blocking = 'urn:xmpp:blocking';
  static const httpUpload = 'urn:xmpp:http:upload:0';
  static const oob = 'jabber:x:oob';
  static const stanzaId = 'urn:xmpp:sid:0';
  static const discoInfo = 'http://jabber.org/protocol/disco#info';
  static const discoItems = 'http://jabber.org/protocol/disco#items';
  static const ping = 'urn:xmpp:ping';

  /// Conest's own frames inside a message (see the carrier).
  static const conestCarrier = 'urn:conest:carrier:1';
}

/// One XML element of an XMPP stream: its local name, resolved namespace,
/// attributes, children and text. Small on purpose: stanzas are bounded
/// and XMPP forbids mixed content beyond text inside leaf elements.
class XmppElement {
  XmppElement(
    this.name, {
    this.xmlns,
    Map<String, String>? attributes,
    List<XmppElement>? children,
    this.text = '',
  }) : attributes = attributes ?? <String, String>{},
       children = children ?? <XmppElement>[];

  final String name;

  /// The element's namespace, written as `xmlns` when it differs from the
  /// parent's.
  final String? xmlns;
  final Map<String, String> attributes;
  final List<XmppElement> children;
  String text;

  String? attr(String key) => attributes[key];

  /// The first child named [childName] (in [namespace], when given).
  XmppElement? child(String childName, [String? namespace]) {
    for (final element in children) {
      if (element.name == childName &&
          (namespace == null || element.xmlns == namespace)) {
        return element;
      }
    }
    return null;
  }

  Iterable<XmppElement> all(String childName, [String? namespace]) =>
      children.where(
        (element) =>
            element.name == childName &&
            (namespace == null || element.xmlns == namespace),
      );

  /// Text of the first child named [childName], if any.
  String? childText(String childName, [String? namespace]) =>
      child(childName, namespace)?.text;

  XmppElement add(XmppElement element) {
    children.add(element);
    return this;
  }

  /// The element as XML text. [parentNamespace] decides whether `xmlns`
  /// needs writing.
  String toXml({String? parentNamespace}) {
    final out = StringBuffer();
    _write(out, parentNamespace);
    return out.toString();
  }

  void _write(StringBuffer out, String? parentNamespace) {
    out
      ..write('<')
      ..write(name);
    if (xmlns != null && xmlns != parentNamespace) {
      out
        ..write(' xmlns="')
        ..write(xmppEscape(xmlns!))
        ..write('"');
    }
    for (final MapEntry(:key, :value) in attributes.entries) {
      out
        ..write(' ')
        ..write(key)
        ..write('="')
        ..write(xmppEscape(value))
        ..write('"');
    }
    if (children.isEmpty && text.isEmpty) {
      out.write('/>');
      return;
    }
    out.write('>');
    if (text.isNotEmpty) out.write(xmppEscape(text));
    final namespace = xmlns ?? parentNamespace;
    for (final element in children) {
      element._write(out, namespace);
    }
    out
      ..write('</')
      ..write(name)
      ..write('>');
  }

  @override
  String toString() => toXml(parentNamespace: XmppNs.client);
}

/// Escapes text and attribute values.
String xmppEscape(String value) {
  final out = StringBuffer();
  for (final unit in value.runes) {
    switch (unit) {
      case 0x26:
        out.write('&amp;');
      case 0x3c:
        out.write('&lt;');
      case 0x3e:
        out.write('&gt;');
      case 0x22:
        out.write('&quot;');
      case 0x27:
        out.write('&apos;');
      default:
        // Characters XML 1.0 cannot carry are dropped.
        if (unit == 0x9 ||
            unit == 0xa ||
            unit == 0xd ||
            (unit >= 0x20 && unit <= 0xd7ff) ||
            (unit >= 0xe000 && unit <= 0xfffd) ||
            unit >= 0x10000) {
          out.writeCharCode(unit);
        }
    }
  }
  return out.toString();
}

/// What the parser reports: the stream header (TCP), a complete top-level
/// element, or the end of the stream.
sealed class XmppStreamEvent {
  const XmppStreamEvent();
}

class XmppStreamOpened extends XmppStreamEvent {
  const XmppStreamOpened(this.attributes);
  final Map<String, String> attributes;
}

class XmppStreamElement extends XmppStreamEvent {
  const XmppStreamElement(this.element);
  final XmppElement element;
}

class XmppStreamClosed extends XmppStreamEvent {
  const XmppStreamClosed();
}

/// The server broke XMPP's rules or a limit: the stream is closed.
class XmppProtocolException implements Exception {
  const XmppProtocolException(this.message);
  final String message;
  @override
  String toString() => 'XMPP: $message';
}

/// Parses an XMPP stream incrementally, with bounded memory: a top-level
/// element may be at most [maxElementChars] characters and nest at most
/// [maxDepth] deep; anything bigger (or a DOCTYPE, which XMPP forbids)
/// ends the stream with [XmppProtocolException].
///
/// With [framed] (WebSocket, RFC 7395) every message is a whole element
/// and there is no enclosing `<stream:stream>`.
class XmppStreamParser {
  XmppStreamParser({
    this.framed = false,
    this.maxElementChars = 512 * 1024,
    this.maxDepth = 32,
    this.maxChildren = 4096,
  }) {
    _reset();
  }

  final bool framed;
  final int maxElementChars;
  final int maxDepth;
  final int maxChildren;

  late StringConversionSink _decoder;
  late ByteConversionSink _bytes;
  final List<XmppStreamEvent> _ready = [];
  final List<XmppElement> _stack = [];
  final List<Map<String, String>> _scopes = [];

  /// Raw (still escaped) text of each open element.
  final List<StringBuffer> _raw = [];
  static const _entities = XmlDefaultEntityMapping.xml();
  bool _inStream = false;
  int _charsInElement = 0;
  int _childCount = 0;

  /// Starts over, for a stream restart after TLS or SASL.
  void reset() => _reset();

  void _reset() {
    _stack.clear();
    _scopes
      ..clear()
      ..add(const {'xml': 'http://www.w3.org/XML/1998/namespace'});
    _inStream = framed;
    _charsInElement = 0;
    _childCount = 0;
    _raw.clear();
    // Entities are resolved here, per element: the chunked decoder would
    // resolve them per chunk, and one split across chunks stayed literal.
    _decoder = XmlEventDecoder(
      entityMapping: const _RawEntities(),
    ).startChunkedConversion(_EventSink(_onEvents));
    _bytes = utf8.decoder.startChunkedConversion(_decoder);
  }

  /// Feeds received bytes; returns the events they completed.
  List<XmppStreamEvent> addBytes(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    _charsInElement += bytes.length;
    _checkSize();
    _bytes.add(bytes);
    return _drain();
  }

  /// Feeds one WebSocket text message.
  List<XmppStreamEvent> addText(String text) {
    _charsInElement += text.length;
    _checkSize();
    _decoder.add(text);
    return _drain();
  }

  void _checkSize() {
    if (_charsInElement > maxElementChars) {
      throw const XmppProtocolException('A stanza is too large.');
    }
  }

  List<XmppStreamEvent> _drain() {
    if (_ready.isEmpty) return const [];
    final events = List.of(_ready);
    _ready.clear();
    return events;
  }

  void _onEvents(List<XmlEvent> events) {
    for (final event in events) {
      switch (event) {
        case XmlStartElementEvent():
          _start(event);
        case XmlEndElementEvent():
          _end(event.name);
        case XmlTextEvent():
          if (_raw.isNotEmpty) {
            _raw.last.write(event.value);
          } else if (event.value.trim().isEmpty) {
            // Whitespace keepalives between stanzas do not add up.
            _charsInElement = 0;
          }
        case XmlCDATAEvent():
          if (_raw.isNotEmpty) _raw.last.write(xmppEscape(event.value));
        case XmlDoctypeEvent():
          throw const XmppProtocolException('A DOCTYPE is not allowed.');
        case XmlDeclarationEvent() || XmlCommentEvent() || XmlProcessingEvent():
          // The XML declaration is allowed; comments and processing
          // instructions are ignored.
          break;
      }
    }
  }

  Map<String, String> _scopeFor(XmlStartElementEvent event) {
    final parent = _scopes.last;
    Map<String, String>? scope;
    for (final attribute in event.attributes) {
      if (attribute.name == 'xmlns') {
        (scope ??= {...parent})[''] = _entities.decode(attribute.value);
      } else if (attribute.name.startsWith('xmlns:')) {
        (scope ??= {...parent})[attribute.name.substring(6)] = _entities.decode(
          attribute.value,
        );
      }
    }
    return scope ?? parent;
  }

  void _start(XmlStartElementEvent event) {
    final scope = _scopeFor(event);
    final colon = event.name.indexOf(':');
    final prefix = colon < 0 ? '' : event.name.substring(0, colon);
    final local = colon < 0 ? event.name : event.name.substring(colon + 1);
    final namespace = scope[prefix];
    final attributes = <String, String>{
      for (final attribute in event.attributes)
        if (attribute.name != 'xmlns' && !attribute.name.startsWith('xmlns:'))
          attribute.name: _entities.decode(attribute.value),
    };
    if (!_inStream) {
      if (local != 'stream' || namespace != XmppNs.stream) {
        throw const XmppProtocolException('Expected a stream header.');
      }
      _inStream = true;
      _scopes.add(scope);
      _ready.add(XmppStreamOpened(attributes));
      _charsInElement = 0;
      return;
    }
    if (_stack.length >= maxDepth) {
      throw const XmppProtocolException('A stanza nests too deeply.');
    }
    if (++_childCount > maxChildren) {
      throw const XmppProtocolException('A stanza has too many elements.');
    }
    final element = XmppElement(
      local,
      xmlns: namespace,
      attributes: attributes,
    );
    if (_stack.isNotEmpty) _stack.last.children.add(element);
    if (event.isSelfClosing) {
      if (_stack.isEmpty) _complete(element);
      return;
    }
    _stack.add(element);
    _raw.add(StringBuffer());
    _scopes.add(scope);
  }

  void _end(String name) {
    if (_stack.isEmpty) {
      // The end of the stream itself.
      if (!framed && _inStream) {
        _ready.add(const XmppStreamClosed());
        _inStream = false;
        return;
      }
      throw const XmppProtocolException('Unbalanced end tag.');
    }
    final element = _stack.removeLast();
    element.text = _entities.decode(_raw.removeLast().toString());
    _scopes.removeLast();
    if (_stack.isEmpty) _complete(element);
  }

  void _complete(XmppElement element) {
    _charsInElement = 0;
    _childCount = 0;
    if (framed &&
        element.xmlns == XmppNs.framing &&
        (element.name == 'open' || element.name == 'close')) {
      _ready.add(
        element.name == 'open'
            ? XmppStreamOpened(element.attributes)
            : const XmppStreamClosed(),
      );
      return;
    }
    _ready.add(XmppStreamElement(element));
  }
}

/// Leaves every entity as written, for [XmppStreamParser] to resolve.
class _RawEntities extends XmlEntityMapping {
  const _RawEntities();
  @override
  String? decodeEntity(String input) => null;
  @override
  String encodeText(String input) => input;
  @override
  String encodeAttributeValue(String input, XmlAttributeType type) => input;
}

class _EventSink implements Sink<List<XmlEvent>> {
  _EventSink(this._onEvents);
  final void Function(List<XmlEvent>) _onEvents;
  @override
  void add(List<XmlEvent> data) => _onEvents(data);
  @override
  void close() {}
}

/// Parses one complete element from text (tests, WebSocket fallbacks).
XmppElement parseXmppElement(String xml) {
  final parser = XmppStreamParser(framed: true);
  final events = parser.addText(xml);
  for (final event in events) {
    if (event is XmppStreamElement) return event.element;
  }
  throw const XmppProtocolException('No element.');
}

/// A bare JID (`local@domain`) from any JID; null when it is not one.
String? bareJid(String? jid) {
  if (jid == null) return null;
  final slash = jid.indexOf('/');
  final bare = (slash < 0 ? jid : jid.substring(0, slash)).toLowerCase();
  return isValidBareJid(bare) || isValidDomainJid(bare) ? bare : null;
}

/// The resource part of a full JID, if any.
String? jidResource(String jid) {
  final slash = jid.indexOf('/');
  return slash < 0 ? null : jid.substring(slash + 1);
}

/// `local@domain`, bounded and without characters XMPP forbids there.
bool isValidBareJid(String jid) {
  if (jid.length > 1023 + 1 + 253) return false;
  final at = jid.indexOf('@');
  if (at <= 0 || at != jid.lastIndexOf('@')) return false;
  final local = jid.substring(0, at);
  final domain = jid.substring(at + 1);
  if (local.length > 1023 ||
      RegExp('[\\s"&\'/:<>@\\x00-\\x1f\\x7f]').hasMatch(local)) {
    return false;
  }
  return isValidDomainJid(domain);
}

/// A server name: letters, digits, dots and hyphens (or a bracketed IP).
bool isValidDomainJid(String domain) =>
    domain.isNotEmpty &&
    domain.length <= 253 &&
    RegExp(
      r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$',
    ).hasMatch(domain.toLowerCase());
