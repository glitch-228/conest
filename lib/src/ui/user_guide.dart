import '../messenger_controller.dart';

/// A page of the user guide (`docs/` in the repository), online.
Uri userGuideUrl([String page = 'README.md']) =>
    Uri.parse('https://github.com/glitch-228/conest/blob/main/docs/$page');

/// Opens [page] of the user guide in the system browser. A browser that
/// does not start is not an error worth showing: the guide is optional.
Future<void> openUserGuide(
  MessengerController controller, [
  String page = 'README.md',
]) async {
  try {
    await controller.openExternalUrl(userGuideUrl(page));
  } catch (_) {}
}
