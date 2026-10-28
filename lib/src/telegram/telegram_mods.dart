import 'dart:convert';

import 'telegram_models.dart';

/// What a plugin may do. Declared by the plugin, shown to the user before
/// it is installed, and enforced here: a hook is only called when its
/// permission was declared.
enum TelegramPermission {
  /// Look at incoming messages (to hide them).
  readMessages,

  /// Change or block the text the user sends.
  editOutgoing,

  /// Add slash commands the user types in a chat.
  commands,
}

/// A Conest plugin for the Telegram client. Plugins never get a network,
/// files, the session or other accounts: only the text of messages through
/// these hooks. Built-in mods are plugins too.
abstract class TelegramPlugin {
  String get id;
  String get name;
  Set<TelegramPermission> get permissions;

  /// Whether to hide an incoming message locally.
  bool hideIncoming(TgMessage message) => false;

  /// The text to send instead of [text]; null blocks the message.
  String? filterOutgoing(String text) => text;

  /// The text a `/name args` command stands for; null if not its command.
  String? runCommand(String name, String args) => null;
}

/// A plugin written as data, not code, so it needs no script engine and
/// cannot do anything but these rules: hide messages containing a word,
/// replace literal text in outgoing messages, block outgoing words, and
/// expand `/commands`. Matching is literal and case-insensitive (no regular
/// expressions, so no plugin can stall the app).
class TelegramRulePlugin implements TelegramPlugin {
  TelegramRulePlugin._({
    required this.id,
    required this.name,
    required this.permissions,
    required this.hideWords,
    required this.replacements,
    required this.blockWords,
    required this.commands,
  });

  static const int maxRules = 100;
  static const int maxRuleChars = 200;
  static const int maxJsonChars = 64 * 1024;

  @override
  final String id;
  @override
  final String name;
  @override
  final Set<TelegramPermission> permissions;
  final List<String> hideWords;
  final List<(String, String)> replacements;
  final List<String> blockWords;
  final Map<String, String> commands;

  /// Parses a plugin document, or null when it is malformed or too big.
  /// Rules whose permission was not declared are dropped, not run.
  static TelegramRulePlugin? parse(String source) {
    if (source.length > maxJsonChars) return null;
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String ||
        !RegExp(r'^[a-z0-9._-]{1,64}$').hasMatch(id) ||
        name is! String ||
        name.isEmpty ||
        name.length > 80) {
      return null;
    }
    final permissions = <TelegramPermission>{};
    final declared = json['permissions'];
    if (declared is List) {
      for (final entry in declared.take(8)) {
        for (final permission in TelegramPermission.values) {
          if (permission.name == entry) permissions.add(permission);
        }
      }
    }
    final hide = <String>[];
    final replace = <(String, String)>[];
    final block = <String>[];
    final commands = <String, String>{};
    final rules = json['rules'];
    if (rules is List) {
      for (final rule in rules.take(maxRules)) {
        if (rule is! Map) continue;
        String? text(String key) {
          final value = rule[key];
          return value is String && value.length <= maxRuleChars ? value : null;
        }

        switch (rule['do']) {
          case 'hide':
            final word = text('contains');
            if (word != null &&
                word.trim().isNotEmpty &&
                permissions.contains(TelegramPermission.readMessages)) {
              hide.add(word.toLowerCase());
            }
          case 'replace':
            final from = text('from');
            final to = text('to');
            if (from != null &&
                from.isNotEmpty &&
                to != null &&
                permissions.contains(TelegramPermission.editOutgoing)) {
              replace.add((from.toLowerCase(), to));
            }
          case 'block':
            final word = text('contains');
            if (word != null &&
                word.trim().isNotEmpty &&
                permissions.contains(TelegramPermission.editOutgoing)) {
              block.add(word.toLowerCase());
            }
          case 'command':
            final command = text('name');
            final insert = text('insert');
            if (command != null &&
                RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(command) &&
                insert != null &&
                permissions.contains(TelegramPermission.commands)) {
              commands[command] = insert;
            }
        }
      }
    }
    return TelegramRulePlugin._(
      id: id,
      name: name,
      permissions: permissions,
      hideWords: hide,
      replacements: replace,
      blockWords: block,
      commands: commands,
    );
  }

  @override
  bool hideIncoming(TgMessage message) {
    if (hideWords.isEmpty || message.outgoing) return false;
    final text = message.content.text.toLowerCase();
    return hideWords.any(text.contains);
  }

  @override
  String? filterOutgoing(String text) {
    final lower = text.toLowerCase();
    if (blockWords.any(lower.contains)) return null;
    var result = text;
    for (final (from, to) in replacements) {
      result = _replaceInsensitive(result, from, to);
    }
    return result;
  }

  static String _replaceInsensitive(String text, String from, String to) {
    final lower = text.toLowerCase();
    // Lower-casing can change length for rare scripts; skip those.
    if (lower.length != text.length) return text;
    final out = StringBuffer();
    var index = 0;
    while (true) {
      final at = lower.indexOf(from, index);
      if (at < 0 || out.length > 64 * 1024) break;
      out
        ..write(text.substring(index, at))
        ..write(to);
      index = at + from.length;
    }
    out.write(text.substring(index));
    return out.toString();
  }

  @override
  String? runCommand(String name, String args) => commands[name];
}

/// The user's mod settings, kept in the vault.
class TelegramMods {
  TelegramMods({
    this.hiddenWords = const [],
    this.deletedNotice = true,
    this.translateTo = '',
    this.plugins = const [],
    this.pluginSources = const {},
  });

  /// Words that hide incoming messages locally (a built-in filter).
  List<String> hiddenWords;

  /// Show "deleted by sender" where a message was deleted. The deleted
  /// content itself is dropped, never kept.
  bool deletedNotice;

  /// Language code messages are translated into on request; empty = the
  /// app language.
  String translateTo;

  /// Installed plugins and their sources (kept to save them).
  List<TelegramPlugin> plugins;
  Map<String, String> pluginSources;

  static const int maxHiddenWords = 200;
  static const int maxPlugins = 16;

  Iterable<TelegramPlugin> _with(TelegramPermission permission) =>
      plugins.where((plugin) => plugin.permissions.contains(permission));

  bool hidden(TgMessage message) {
    if (message.outgoing || message.content.kind == TgContentKind.deleted) {
      return false;
    }
    final text = message.content.text.toLowerCase();
    if (hiddenWords.any((word) => text.contains(word.toLowerCase()))) {
      return true;
    }
    return _with(
      TelegramPermission.readMessages,
    ).any((plugin) => plugin.hideIncoming(message));
  }

  /// Applies command expansion and filters to outgoing [text]; null blocks.
  String? outgoing(String text) {
    var result = text;
    if (result.startsWith('/')) {
      final space = result.indexOf(' ');
      final name = result.substring(1, space < 0 ? null : space);
      final args = space < 0 ? '' : result.substring(space + 1);
      for (final plugin in _with(TelegramPermission.commands)) {
        final expanded = plugin.runCommand(name, args);
        if (expanded != null) {
          result = args.isEmpty ? expanded : '$expanded $args';
          break;
        }
      }
    }
    for (final plugin in _with(TelegramPermission.editOutgoing)) {
      final next = plugin.filterOutgoing(result);
      if (next == null) return null;
      result = next;
    }
    return result.trim().isEmpty ? null : result;
  }

  /// Installs (or replaces) a rule plugin; false when it does not parse or
  /// the limit is reached.
  bool install(String source) {
    final plugin = TelegramRulePlugin.parse(source);
    if (plugin == null) return false;
    final others = plugins.where((other) => other.id != plugin.id).toList();
    if (others.length >= maxPlugins) return false;
    plugins = [...others, plugin];
    pluginSources = {...pluginSources, plugin.id: source};
    return true;
  }

  void remove(String id) {
    plugins = plugins.where((plugin) => plugin.id != id).toList();
    pluginSources = {...pluginSources}..remove(id);
  }

  Map<String, Object?> toJson() => {
    'hidden': hiddenWords,
    'deletedNotice': deletedNotice,
    'translate': translateTo,
    'plugins': pluginSources.values.toList(),
  };

  static TelegramMods fromJson(Object? json) {
    final mods = TelegramMods();
    if (json is! Map) return mods;
    final hidden = json['hidden'];
    if (hidden is List) {
      mods.hiddenWords = [
        for (final word in hidden.take(maxHiddenWords))
          if (word is String && word.isNotEmpty && word.length <= 200) word,
      ];
    }
    mods.deletedNotice = json['deletedNotice'] != false;
    final translate = json['translate'];
    if (translate is String && translate.length <= 8) {
      mods.translateTo = translate;
    }
    final plugins = json['plugins'];
    if (plugins is List) {
      for (final source in plugins.take(maxPlugins)) {
        if (source is String) mods.install(source);
      }
    }
    return mods;
  }
}
