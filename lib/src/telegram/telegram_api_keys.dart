/// The api_id and api_hash of Conest's own registration at
/// my.telegram.org, compiled in from build-time defines (CI secrets). They
/// are empty in builds without them, and then the Telegram client is
/// hidden. Never put another app's keys here: Telegram's API terms forbid
/// it and accounts get banned for it.
class TelegramApiKeys {
  const TelegramApiKeys(this.apiId, this.apiHash);

  final int apiId;
  final String apiHash;

  /// From `--dart-define=CONEST_TELEGRAM_API_ID=...` and
  /// `CONEST_TELEGRAM_API_HASH=...`.
  static TelegramApiKeys? fromEnvironment() => TelegramApiKeys.parse(
    const String.fromEnvironment('CONEST_TELEGRAM_API_ID'),
    const String.fromEnvironment('CONEST_TELEGRAM_API_HASH'),
  );

  /// The keys, or null when either is missing or malformed.
  static TelegramApiKeys? parse(String id, String hash) {
    final apiId = int.tryParse(id.trim());
    final apiHash = hash.trim();
    if (apiId == null ||
        apiId <= 0 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(apiHash)) {
      return null;
    }
    return TelegramApiKeys(apiId, apiHash);
  }
}
