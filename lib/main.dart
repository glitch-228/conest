import 'src/ui/localized_labels.dart';
import 'src/ui/localized_ui_text.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:path/path.dart' as p;

import 'src/app_storage.dart';
import 'src/adaptive_chat_dialog.dart';
import 'src/group_file_tile.dart';
import 'src/attachment_safety.dart';
import 'src/build_info.dart';
import 'src/chat_message_search.dart';
import 'src/chat_day_separator.dart';
import 'src/conest_theme.dart';
import 'src/conversation_sidebar_divider.dart';
import 'src/desktop_beam_scanner.dart';
import 'src/lan_direct.dart';
import 'src/iroh_ffi_bridge.dart';
import 'src/iroh_transport.dart';
import 'src/media_picker_sheet.dart';
import 'src/ui/file_metadata_consent.dart';
import 'src/ui/internet_transports.dart';
import 'src/network_errors.dart';
import 'src/matrix_service.dart';
import 'src/messenger_controller.dart';
import 'src/models.dart';
import 'src/platform_bridge.dart';
import 'src/qr_scan_screen.dart';
import 'src/ui/app_mode_selector.dart';
import 'src/ui/group_call_screen.dart';
import 'src/ui/read_sweep.dart';
import 'src/ui/forwarding.dart';
import 'src/relay_link.dart';
import 'src/ui/crash_notice.dart';
import 'src/crash_catcher.dart';
import 'src/native_crash_reports.dart';
import 'src/ui/matrix_account_panel.dart';
import 'src/ui/bitchat_carrier_panel.dart';
import 'src/ui/email_carrier_panel.dart';
import 'src/ui/meshcore_carrier_panel.dart';
import 'src/ui/meshtastic_carrier_panel.dart';
import 'src/ui/nostr_carrier_panel.dart';
import 'src/ui/nostr_chats_screen.dart';
import 'src/ui/delta_chats_screen.dart';
import 'src/ui/delta_attachment_card.dart';
import 'src/ui/message_info_dialog.dart';
import 'l10n/app_localizations.dart';
import 'src/app_locales.dart';
import 'src/ui/calls_list.dart';
import 'src/ui/devices_panel.dart';
import 'src/ui/connections_screen.dart';
import 'src/ui/error_history_screen.dart';
import 'src/debug_auto_run.dart';
import 'src/ui/route_test_panel.dart';
import 'src/ui/user_mode_screen.dart';
import 'src/ui/user_guide.dart';
import 'src/windows_firewall.dart';
import 'src/ui/reticulum_carrier_panel.dart';
import 'src/ui/matrix_home_screen.dart';
import 'src/ui/matrix_room_screen.dart';
import 'src/ui/network_chat_sources.dart';
import 'src/ui/matrix_verification_dialog.dart';
import 'src/relay_client.dart';
import 'src/storage.dart';
import 'src/voice_message_service.dart';
import 'src/swipe_to_reply.dart';
import 'src/transport.dart';
import 'src/ui/seal_avatar.dart';
import 'src/ui/delta_content_widgets.dart' show deltaListAvatar;
import 'src/ui/signature_decoration.dart';
import 'src/ui/signature_panels.dart';
import 'src/ui/signature_widgets.dart';
import 'src/ui/tor_carrier_panel.dart';
import 'src/update_service.dart';

export 'src/conest_theme.dart'
    show
        ConestPalette,
        ConestThemeController,
        ConestThemeMode,
        ThemePreferenceStore;

/// A debug build started for automatic tests (`--debug-run=routes`, or the
/// Android `conestDebugRun` extra) runs them and writes a report.
Future<void> _startDebugRunIfAsked(
  MessengerController controller, {
  required String dataRoot,
}) async {
  final request = _debugRequest;
  if (request == null) return;
  try {
    final path = await runDebugRequest(
      controller,
      request,
      // Private to the app (on Android, pulled with `adb exec-out run-as`).
      defaultReportPath: () async => Platform.isAndroid
          ? '${(await getApplicationSupportDirectory()).path}/conest-debug-report.json'
          : '$dataRoot/conest-debug-report.json',
    );
    stdout.writeln('Conest debug report: $path');
  } catch (error) {
    controller.recordError('test', 'Automatic run failed: $error');
  }
  if (request.exitAfter && !Platform.isAndroid) {
    controller.savePendingChangesForLifecycle();
    await controller.flushErrorHistory();
    // Time for the vault to reach the disk.
    await Future<void>.delayed(const Duration(seconds: 2));
    CrashCatcher.instance.markStopped();
    exit(0);
  }
}

/// What a debug build was started to do (read once, at start).
DebugRunRequest? _debugRequest;

/// Debug builds only: the automatic run asked for on the command line or,
/// on Android, in the launching intent.
Future<DebugRunRequest?> _readDebugRequest(List<String> args) async {
  final buildInfo = await ConestBuildInfo.load();
  if (buildInfo.channel != UpdateChannel.debug) return null;
  return DebugRunRequest.fromArgs(args) ??
      DebugRunRequest.fromExtra(await PlatformBridge().debugRunRequest());
}

/// Crash records go in the app's data folder; the native library and
/// Android add what they know of earlier runs.
Future<void> _startCrashRecords(CrashCatcher crashes, Directory root) async {
  final directory = Directory(p.join(root.path, 'crash'));
  // On Android the system ends apps in the background as a matter of
  // course: there a run counts as running only while in front.
  final info = await ConestBuildInfo.load();
  await crashes.attach(
    directory,
    markRunning: !Platform.isAndroid,
    build: '${info.version}+${info.buildNumber}@${info.commit ?? ''}',
  );
  try {
    startNativeCrashReports(p.join(directory.path, CrashCatcher.nativeName));
  } catch (error) {
    debugPrint('Native crash reports unavailable: $error');
  }
  if (Platform.isAndroid) {
    final exits = await PlatformBridge().takeAndroidExitReports();
    crashes.addPrevious([
      for (final exit in exits)
        if (exit['at'] case final int at)
          CrashRecord(
            at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
            kind: 'android',
            text: [
              'Android: ${exit['kind']}',
              if (exit['description'] case final String description
                  when description.isNotEmpty)
                description,
              if (exit['trace'] case final String trace when trace.isNotEmpty)
                trace,
            ].join('\n'),
          ),
    ]);
  }
}

/// Where a part of the screen failed to draw (release builds).
class _BrokenPart extends StatelessWidget {
  const _BrokenPart();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Text(
      l10nOf(context).brokenPartNotice,
      style: const TextStyle(color: Color(0xFFB00020), fontSize: 13),
    ),
  );
}

Future<void> main(List<String> args) async {
  // Every error nothing else caught is written down (crash_catcher.dart).
  final crashes = CrashCatcher.instance;
  await runZonedGuarded(() => _main(args, crashes), crashes.zoneError);
}

Future<void> _main(List<String> args, CrashCatcher crashes) async {
  WidgetsFlutterBinding.ensureInitialized();
  crashes.install();
  if (!kDebugMode) {
    // Instead of a grey box where a part of the screen failed to draw.
    ErrorWidget.builder = (details) => const _BrokenPart();
  }
  final storageResolver = AppStorageResolver();
  var storageResolution = await storageResolver.resolve();
  _debugRequest = await _readDebugRequest(args);
  if (_debugRequest?.setsUp == true) {
    // A lab device keeps its own data: beside the app on desktops (with its
    // key file), never a profile the user's own Conest uses there; in the
    // debug package's own storage on Android.
    if (Platform.isAndroid) {
      if (storageResolution.status == AppStorageResolutionStatus.needsSetup) {
        storageResolution = AppStorageResolution.ready(
          await storageResolver.createProfile(
            mode: AppStorageMode.device,
            unlockMode: VaultUnlockMode.secureStorage,
          ),
        );
      }
    } else if (storageResolution.profile?.mode != AppStorageMode.portable) {
      storageResolution = AppStorageResolution.ready(
        await storageResolver.createProfile(
          mode: AppStorageMode.portable,
          unlockMode: VaultUnlockMode.keyFile,
        ),
      );
    }
  }
  await _startCrashRecords(
    crashes,
    storageResolution.profile?.dataRoot ??
        await getApplicationSupportDirectory(),
  );
  if (storageResolution.status == AppStorageResolutionStatus.ready) {
    await _runConestWithProfile(storageResolution.profile!);
    return;
  }

  final bootstrapThemeController = ConestThemeController.memory();
  await bootstrapThemeController.initialize();
  runApp(
    ConestBootstrapApp(
      resolver: storageResolver,
      initialResolution: storageResolution,
      themeController: bootstrapThemeController,
    ),
  );
}

/// nightly.11: set during desktop boot to record whether the
/// video_player_media_kit platform impl initialized successfully (i.e.
/// libmpv is present on this Linux/Windows host). When false,
/// `_VideoPlayerScreen` skips inline playback and routes straight to
/// xdg-open / start. macOS/iOS/Android use the native impls and don't
/// gate on this — initialized to true via the constructor in main().
bool _mediaKitAvailable = true;

Future<void> _runConestWithProfile(
  AppStorageProfile profile, {
  String? passphrase,
}) async {
  final vaultStore = VaultStore(
    vaultFileProvider: () async => profile.vaultFile,
    keyProvider: _vaultKeyProviderFor(profile, passphrase: passphrase),
  );
  if (await profile.vaultFile.exists()) {
    await vaultStore.load();
  }
  final themeController = ConestThemeController(
    store: ThemePreferenceStore.forRoot(profile.dataRoot),
  );
  await themeController.initialize();
  final instanceLock = AppInstanceLock(directory: profile.dataRoot);
  if (!await instanceLock.acquire()) {
    runApp(ConestAlreadyRunningApp(themeController: themeController));
    return;
  }
  // Use the bundled media-kit implementation on Windows. Linux delegates to
  // the system player because a libmpv native crash cannot be caught in Dart.
  if (Platform.isLinux) {
    // libmpv can terminate the Linux process while loading or initializing,
    // which Dart's exception handler cannot recover from. Use the desktop's
    // registered video player instead of loading the native backend in Conest.
    _mediaKitAvailable = false;
  } else if (Platform.isWindows) {
    try {
      VideoPlayerMediaKit.ensureInitialized(linux: false, windows: true);
      _mediaKitAvailable = true;
    } catch (error) {
      _mediaKitAvailable = false;
      debugPrint('media_kit init failed: $error');
    }
  } else {
    _mediaKitAvailable = true;
  }
  final buildInfo = await ConestBuildInfo.load();
  final platformBridge = PlatformBridge();
  final controller = MessengerController(
    vaultStore: vaultStore,
    relayClient: const RelayClient(),
    platformBridge: platformBridge,
    // nightly.9: enable the LocalSend-style direct PUT fast-path for LAN
    // chunk delivery. Falls back to relay automatically if the platform
    // can't bind a port or peers don't advertise their endpoint.
    lanDirectChannel: HttpLanDirectChannel(),
    debugBuildId: buildInfo.debugProtocolId,
    keepErrorHistory: buildInfo.channel != UpdateChannel.stable,
    transportRegistryFactory: (identity) async {
      final privateKey = identity.signingPrivateKeyBase64;
      final endpointId = identity.irohEndpointId;
      final bridge = FfiNativeIrohBridge.tryCreate();
      if (privateKey == null || endpointId == null || bridge == null) {
        return null;
      }
      return TransportRegistry([
        IrohTransportAdapter(
          bridge: bridge,
          secretKeySeed: Uint8List.fromList(base64Decode(privateKey)),
          relayEnabled: identity.connectivity.irohRelayEnabled,
          relayUrls: identity.connectivity.irohRelayUrls,
          expectedEndpointId: endpointId,
        ),
      ]);
    },
  );
  final updateService = UpdateService(
    buildInfo: buildInfo,
    platformBridge: platformBridge,
    applicationSupportDirectoryProvider: () async => profile.dataRoot,
    tempDirectoryProvider: () async => profile.tempRoot,
    automaticStartupChecksEnabled: profile.automaticStartupChecksEnabled,
    // The installer or updater ends the app: save what is pending, and the
    // next start must not call it a crash.
    onHandOver: () {
      controller.savePendingChangesForLifecycle();
      CrashCatcher.instance.markUpdating();
    },
  );
  await controller.initialize();
  final crashes = CrashCatcher.instance;
  crashes.connect(
    (kind, text) => controller.recordError('crash', '$kind: $text'),
  );
  // Errors earlier runs lived through are in the error history now; only a
  // run that ended badly is worth a notice.
  if (!crashes.previousRun.crashed) crashes.dismissPrevious();
  if (buildInfo.channel == UpdateChannel.debug) {
    unawaited(
      _startDebugRunIfAsked(controller, dataRoot: profile.dataRoot.path),
    );
  }
  // nightly.9: forward platform connectivity changes (Wi-Fi ↔ VPN ↔
  // cellular) so the controller can re-probe in-flight transfers
  // immediately instead of waiting out the 60 s stall timer against a
  // stale interface. Best-effort: on platforms where connectivity_plus
  // refuses to bind we just skip the listener and the existing retry
  // path still recovers, just more slowly.
  try {
    Connectivity().onConnectivityChanged.listen((results) {
      final label = results.map((r) => r.name).join(',');
      controller.onConnectivityChanged(interfaceLabel: label);
    });
    // The network in use at start, for its history (no change handling).
    unawaited(
      Connectivity().checkConnectivity().then(
        (results) =>
            controller.noteNetwork(results.map((r) => r.name).join(',')),
        onError: (Object _) {},
      ),
    );
  } catch (error) {
    controller.appendDebugLog('connectivity_plus listener unavailable: $error');
  }
  runApp(
    ConestApp(
      controller: controller,
      updateService: updateService,
      instanceLock: instanceLock,
      themeController: themeController,
      buildInfo: buildInfo,
      onResetIdentity: () async {
        // Drop the existing instance lock so the relaunched bootstrap can
        // acquire its own. Best-effort — release errors don't block reset.
        try {
          await instanceLock.release();
        } catch (_) {}
        // Wipe the storage-profile JSON so AppStorageResolver.resolve()
        // returns needsSetup and FirstLaunchStorageScreen reappears.
        try {
          await profile.profileFile.delete();
        } on FileSystemException {
          // Already gone — fine.
        }
        // Restart the bootstrap layer. The current widget tree is torn
        // down by Flutter on the next frame. We re-resolve storage so
        // the bootstrap correctly lands on `needsSetup` after the
        // profile JSON delete above.
        final resolver = AppStorageResolver();
        final resolution = await resolver.resolve();
        final bootstrapThemeController = ConestThemeController.memory();
        await bootstrapThemeController.initialize();
        runApp(
          ConestBootstrapApp(
            resolver: resolver,
            initialResolution: resolution,
            themeController: bootstrapThemeController,
          ),
        );
      },
    ),
  );
}

VaultKeyProvider _vaultKeyProviderFor(
  AppStorageProfile profile, {
  String? passphrase,
}) {
  return switch (profile.unlockMode) {
    VaultUnlockMode.secureStorage => SecureStorageVaultKeyProvider(),
    VaultUnlockMode.keyFile => FileVaultKeyProvider(
      fileProvider: () async => profile.keyFile,
    ),
    VaultUnlockMode.passphrase => PassphraseVaultKeyProvider(
      passphrase:
          passphrase ?? (throw ArgumentError('Passphrase is required.')),
      config: profile.passphraseKdf!,
    ),
  };
}

class ConestAlreadyRunningApp extends StatelessWidget {
  const ConestAlreadyRunningApp({super.key, required this.themeController});

  final ConestThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return AnimatedBuilder(
          animation: themeController,
          builder: (context, _) {
            final palette = themeController.resolve(
              platformBrightness: _platformBrightness,
              lightDynamic: lightDynamic,
              darkDynamic: darkDynamic,
            );
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              // Evaluated below the app's own Localizations; these screens
              // come before the chosen language is known: the system's.
              onGenerateTitle: (context) => l10nOf(context).uiConest26885B,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: palette.themeData(
                courier: themeController.shell == ConestShell.courier,
              ),
              home: Scaffold(
                body: DecoratedBox(
                  decoration: BoxDecoration(gradient: palette.appGradient),
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.lock_clock,
                                color: palette.secondary,
                                size: 34,
                              ),
                              const SizedBox(height: 18),
                              Text(
                                l10nOf(context).uiConestIsAlreadyRunningEE8037,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                l10nOf(
                                  context,
                                ).uiCloseTheExistingConestWindow83B30B,
                                style: TextStyle(
                                  color: palette.inkSoft,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

const firstLaunchPassphraseFieldKey = Key('first-launch-passphrase');
const firstLaunchConfirmPassphraseFieldKey = Key(
  'first-launch-confirm-passphrase',
);
const unlockPassphraseFieldKey = Key('unlock-passphrase');

typedef CreateStorageProfile =
    Future<AppStorageProfile> Function({
      required AppStorageMode mode,
      required VaultUnlockMode unlockMode,
    });

class BootstrapProfileSelection {
  const BootstrapProfileSelection({required this.profile, this.passphrase});

  final AppStorageProfile profile;
  final String? passphrase;
}

class ConestBootstrapApp extends StatefulWidget {
  const ConestBootstrapApp({
    super.key,
    required this.resolver,
    required this.initialResolution,
    required this.themeController,
  });

  final AppStorageResolver resolver;
  final AppStorageResolution initialResolution;
  final ConestThemeController themeController;

  @override
  State<ConestBootstrapApp> createState() => _ConestBootstrapAppState();
}

class _ConestBootstrapAppState extends State<ConestBootstrapApp> {
  bool _starting = false;
  String? _error;

  Future<void> _start(BootstrapProfileSelection selection) async {
    if (_starting) {
      return;
    }
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await _runConestWithProfile(
        selection.profile,
        passphrase: selection.passphrase,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _starting = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return AnimatedBuilder(
          animation: widget.themeController,
          builder: (context, _) {
            final palette = widget.themeController.resolve(
              platformBrightness: _platformBrightness,
              lightDynamic: lightDynamic,
              darkDynamic: darkDynamic,
            );
            final body =
                widget.initialResolution.status ==
                    AppStorageResolutionStatus.needsPassphrase
                ? PassphraseUnlockScreen(
                    palette: palette,
                    profile: widget.initialResolution.profile!,
                    onUnlock: (passphrase) => _start(
                      BootstrapProfileSelection(
                        profile: widget.initialResolution.profile!,
                        passphrase: passphrase,
                      ),
                    ),
                    busy: _starting,
                    error: _error,
                  )
                : FirstLaunchStorageScreen(
                    palette: palette,
                    portableSupported: widget.resolver.portableSupported,
                    createProfile: widget.resolver.createProfile,
                    onProfileReady: _start,
                    busy: _starting,
                    startupError: _error,
                  );
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              // Evaluated below the app's own Localizations; these screens
              // come before the chosen language is known: the system's.
              onGenerateTitle: (context) => l10nOf(context).uiConest26885B,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: palette.themeData(
                courier: widget.themeController.shell == ConestShell.courier,
              ),
              home: body,
            );
          },
        );
      },
    );
  }
}

class FirstLaunchStorageScreen extends StatefulWidget {
  const FirstLaunchStorageScreen({
    super.key,
    required this.palette,
    required this.portableSupported,
    required this.createProfile,
    required this.onProfileReady,
    this.busy = false,
    this.startupError,
  });

  final ConestPalette palette;
  final bool portableSupported;
  final CreateStorageProfile createProfile;
  final ValueChanged<BootstrapProfileSelection> onProfileReady;
  final bool busy;
  final String? startupError;

  @override
  State<FirstLaunchStorageScreen> createState() =>
      _FirstLaunchStorageScreenState();
}

class _FirstLaunchStorageScreenState extends State<FirstLaunchStorageScreen> {
  final _passphraseController = TextEditingController();
  final _confirmPassphraseController = TextEditingController();
  AppStorageMode _mode = AppStorageMode.device;
  VaultUnlockMode _unlockMode = VaultUnlockMode.secureStorage;
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    _confirmPassphraseController.dispose();
    super.dispose();
  }

  void _setMode(AppStorageMode mode) {
    setState(() {
      _mode = mode;
      if (mode == AppStorageMode.portable &&
          _unlockMode == VaultUnlockMode.secureStorage) {
        _unlockMode = VaultUnlockMode.keyFile;
      }
      if (mode == AppStorageMode.device &&
          _unlockMode == VaultUnlockMode.keyFile) {
        _unlockMode = VaultUnlockMode.secureStorage;
      }
      _error = null;
    });
  }

  Future<void> _continue() async {
    if (widget.busy) {
      return;
    }
    final passphrase = _passphraseController.text;
    if (_unlockMode == VaultUnlockMode.passphrase) {
      if (passphrase.isEmpty) {
        setState(() => _error = 'Enter a passphrase.');
        return;
      }
      if (passphrase != _confirmPassphraseController.text) {
        setState(() => _error = 'Passphrases do not match.');
        return;
      }
    }
    setState(() => _error = null);
    try {
      final profile = await widget.createProfile(
        mode: _mode,
        unlockMode: _unlockMode,
      );
      widget.onProfileReady(
        BootstrapProfileSelection(
          profile: profile,
          passphrase: _unlockMode == VaultUnlockMode.passphrase
              ? passphrase
              : null,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final selectedPortable = _mode == AppStorageMode.portable;
    final error = _error ?? widget.startupError;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Card(
                  elevation: 0,
                  color: palette.paperStrong,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                    side: BorderSide(color: palette.stroke),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10nOf(context).uiChooseWhereConestStoresData0CF613,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10nOf(context).uiGhostModeIsBestEffort694912,
                          style: TextStyle(color: palette.inkSoft, height: 1.4),
                        ),
                        const SizedBox(height: 18),
                        RadioGroup<AppStorageMode>(
                          groupValue: _mode,
                          onChanged: (value) {
                            if (!widget.busy && value != null) {
                              _setMode(value);
                            }
                          },
                          child: Column(
                            children: [
                              RadioListTile<AppStorageMode>(
                                value: AppStorageMode.device,
                                title: Text(
                                  l10nOf(context).uiDefaultOnThisDevice10343F,
                                ),
                                subtitle: Text(
                                  l10nOf(context).uiUseTheNormalAppDataF44F79,
                                ),
                              ),
                              if (widget.portableSupported)
                                RadioListTile<AppStorageMode>(
                                  value: AppStorageMode.portable,
                                  title: Text(
                                    l10nOf(
                                      context,
                                    ).uiGhostPortableBesideTheApp31A40D,
                                  ),
                                  subtitle: Text(
                                    l10nOf(
                                      context,
                                    ).uiStoreConestControlledFilesIn7DA307,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const Divider(height: 28),
                        Text(
                          l10nOf(context).uiVaultUnlock602BF6,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        RadioGroup<VaultUnlockMode>(
                          groupValue: _unlockMode,
                          onChanged: (value) {
                            if (!widget.busy && value != null) {
                              setState(() => _unlockMode = value);
                            }
                          },
                          child: Column(
                            children: [
                              if (selectedPortable)
                                RadioListTile<VaultUnlockMode>(
                                  value: VaultUnlockMode.keyFile,
                                  title: Text(
                                    l10nOf(context).uiKeyFileAutoUnlock66AC4A,
                                  ),
                                  subtitle: Text(
                                    l10nOf(
                                      context,
                                    ).uiKeepsTheKeyBesideTheB045D9,
                                  ),
                                )
                              else
                                RadioListTile<VaultUnlockMode>(
                                  value: VaultUnlockMode.secureStorage,
                                  title: Text(
                                    l10nOf(
                                      context,
                                    ).uiAutoUnlockWithThisDeviceE7F781,
                                  ),
                                  subtitle: Text(
                                    l10nOf(context).uiStoresTheVaultKeyInC7B1CD,
                                  ),
                                ),
                              RadioListTile<VaultUnlockMode>(
                                value: VaultUnlockMode.passphrase,
                                title: Text(
                                  l10nOf(context).uiPassphraseUnlock13B14C,
                                ),
                                subtitle: Text(
                                  l10nOf(context).uiAskForAPassphraseOn4BA25C,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_unlockMode == VaultUnlockMode.passphrase) ...[
                          const SizedBox(height: 10),
                          TextField(
                            key: firstLaunchPassphraseFieldKey,
                            controller: _passphraseController,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: l10nOf(context).uiPassphrase89950C,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: firstLaunchConfirmPassphraseFieldKey,
                            controller: _confirmPassphraseController,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: l10nOf(
                                context,
                              ).uiConfirmPassphraseEBAAC0,
                            ),
                          ),
                        ],
                        if (error != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            error,
                            style: TextStyle(color: palette.secondary),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: widget.busy ? null : _continue,
                          child: widget.busy
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l10nOf(context).actionContinue),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PassphraseUnlockScreen extends StatefulWidget {
  const PassphraseUnlockScreen({
    super.key,
    required this.palette,
    required this.profile,
    required this.onUnlock,
    this.busy = false,
    this.error,
  });

  final ConestPalette palette;
  final AppStorageProfile profile;
  final ValueChanged<String> onUnlock;
  final bool busy;
  final String? error;

  @override
  State<PassphraseUnlockScreen> createState() => _PassphraseUnlockScreenState();
}

class _PassphraseUnlockScreenState extends State<PassphraseUnlockScreen> {
  final _passphraseController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _passphraseController.dispose();
    super.dispose();
  }

  void _unlock() {
    if (widget.busy) {
      return;
    }
    final passphrase = _passphraseController.text;
    if (passphrase.isEmpty) {
      setState(() => _error = 'Enter your passphrase.');
      return;
    }
    setState(() => _error = null);
    widget.onUnlock(passphrase);
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final error = _error ?? widget.error;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  elevation: 0,
                  color: palette.paperStrong,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                    side: BorderSide(color: palette.stroke),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10nOf(context).uiUnlockConest033EB6,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          l10nOf(context).uiEnterThePassphraseForThis891200,
                          style: TextStyle(color: palette.inkSoft),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          key: unlockPassphraseFieldKey,
                          controller: _passphraseController,
                          obscureText: true,
                          onSubmitted: (_) => _unlock(),
                          decoration: InputDecoration(
                            labelText: l10nOf(context).uiPassphrase89950C,
                          ),
                        ),
                        if (error != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            error,
                            style: TextStyle(color: palette.secondary),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: widget.busy ? null : _unlock,
                          child: widget.busy
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(l10nOf(context).uiUnlock1526A1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ConestApp extends StatefulWidget {
  const ConestApp({
    super.key,
    required this.controller,
    required this.updateService,
    required this.instanceLock,
    required this.themeController,
    required this.buildInfo,
    this.onResetIdentity,
  });

  final MessengerController controller;
  final UpdateService updateService;
  final AppInstanceLock instanceLock;
  final ConestThemeController themeController;

  /// Stable / nightly / debug — surfaced so the chrome can expose destructive
  /// transfer battle tests only in isolated debug artifacts.
  final ConestBuildInfo buildInfo;

  /// Wired by `_runConestWithProfile` (in the bootstrap layer). Called by
  /// the Settings dialog AFTER `controller.resetIdentity` wipes the vault,
  /// so the storage-profile JSON can be deleted and `ConestBootstrapApp`
  /// re-mounted — restoring the "choose storage mode" wizard instead of
  /// going straight back to the display-name onboarding screen.
  final Future<void> Function()? onResetIdentity;

  @override
  State<ConestApp> createState() => _ConestAppState();
}

class _ConestAppState extends State<ConestApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  // Closing the window is a proper end, not a crash.
  late final AppLifecycleListener _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      CrashCatcher.instance.markStopped();
      return AppExitResponse.exit;
    },
  );
  String? _activeUpdatePromptTag;
  late bool _controllerReady;
  late bool _controllerHasIdentity;
  late bool _controllerMatrixOnly;
  late bool _controllerNeedsMode;
  late UserMode _controllerUserMode;
  String? _controllerLocale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addTimingsCallback(_recordFrameTimings);
    _controllerReady = widget.controller.isReady;
    _controllerHasIdentity = widget.controller.hasIdentity;
    _controllerMatrixOnly = widget.controller.appMode == AppMode.matrixOnly;
    _controllerNeedsMode = widget.controller.needsUserModeChoice;
    _controllerUserMode = widget.controller.userMode;
    _controllerLocale = widget.controller.localeCode;
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.setAppForegroundState(true);
    widget.updateService.addListener(_handleUpdateServiceChanged);
    _exitListener;
    if (Platform.isAndroid) CrashCatcher.instance.markRunning();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.updateService.ensureStartupCheck());
      final messenger = _messengerKey.currentState;
      if (messenger != null) {
        showCrashNotice(
          messenger: messenger,
          crashes: CrashCatcher.instance,
          dialogContext: () => _navigatorKey.currentContext,
        );
      }
    });
  }

  @override
  void didUpdateWidget(covariant ConestApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
      _handleControllerChanged();
    }
  }

  void _handleControllerChanged() {
    final ready = widget.controller.isReady;
    final hasIdentity = widget.controller.hasIdentity;
    final matrixOnly = widget.controller.appMode == AppMode.matrixOnly;
    final needsMode = widget.controller.needsUserModeChoice;
    final userMode = widget.controller.userMode;
    final locale = widget.controller.localeCode;
    if (locale != _controllerLocale) {
      _controllerLocale = locale;
      if (mounted) setState(() {});
    }
    if (ready == _controllerReady &&
        hasIdentity == _controllerHasIdentity &&
        matrixOnly == _controllerMatrixOnly &&
        needsMode == _controllerNeedsMode &&
        userMode == _controllerUserMode) {
      return;
    }
    _controllerReady = ready;
    _controllerHasIdentity = hasIdentity;
    _controllerMatrixOnly = matrixOnly;
    _controllerNeedsMode = needsMode;
    _controllerUserMode = userMode;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      widget.controller.savePendingChangesForLifecycle();
    }
    final inForeground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    widget.controller.setAppForegroundState(inForeground);
    if (state == AppLifecycleState.detached) {
      CrashCatcher.instance.markStopped();
    } else if (Platform.isAndroid) {
      // Android may end it in the background; only a run in front that
      // vanishes is a crash (Android's own records catch the rest).
      inForeground
          ? CrashCatcher.instance.markRunning()
          : CrashCatcher.instance.markStopped();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_recordFrameTimings);
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_handleControllerChanged);
    widget.updateService.removeListener(_handleUpdateServiceChanged);
    _exitListener.dispose();
    CrashCatcher.instance
      ..disconnect()
      ..markStopped();
    widget.updateService.dispose();
    widget.controller.dispose();
    widget.themeController.dispose();
    unawaited(widget.instanceLock.release());
    super.dispose();
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      widget.controller.recordFrameTiming(
        buildMicros: timing.buildDuration.inMicroseconds,
        rasterMicros: timing.rasterDuration.inMicroseconds,
      );
    }
  }

  void _handleUpdateServiceChanged() {
    if (!mounted || !widget.updateService.shouldPromptForAvailableUpdate) {
      return;
    }
    final available = widget.updateService.availableUpdate;
    if (available == null) {
      return;
    }
    if (_activeUpdatePromptTag == available.release.tagName) {
      return;
    }
    final context = _navigatorKey.currentContext;
    if (context == null) {
      return;
    }
    _activeUpdatePromptTag = available.release.tagName;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      final dialogContext = _navigatorKey.currentContext;
      if (dialogContext == null) {
        _activeUpdatePromptTag = null;
        return;
      }
      await showDialog<void>(
        context: dialogContext,
        builder: (context) =>
            UpdatePromptDialog(updateService: widget.updateService),
      );
      _activeUpdatePromptTag = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return UserActivityForeground(
      isForeground: () => widget.controller.isAppForeground,
      onForeground: () => widget.controller.setAppForegroundState(true),
      child: _buildApp(context),
    );
  }

  Widget _buildApp(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return AnimatedBuilder(
          // Message and transfer updates belong to HomeScreen's narrower
          // listeners. Rebuilding MaterialApp here on every controller event
          // recreates the entire desktop chat shell during active transfers.
          animation: widget.themeController,
          builder: (context, _) {
            final palette = widget.themeController.resolve(
              platformBrightness: _platformBrightness,
              lightDynamic: lightDynamic,
              darkDynamic: darkDynamic,
            );
            // Network chats (Matrix, …) forward into Conest chats.
            forwardTextToConest = (context, text) =>
                _forwardPlainText(context, widget.controller, palette, text);
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              onGenerateTitle: (context) => l10nOf(context).uiConest26885B,
              navigatorKey: _navigatorKey,
              scaffoldMessengerKey: _messengerKey,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: _controllerLocale == null
                  ? null
                  : Locale(_controllerLocale!),
              theme: palette.themeData(
                courier: widget.themeController.shell == ConestShell.courier,
              ),
              // Simple mode reads larger.
              builder: (context, child) {
                if (_controllerUserMode != UserMode.minimal || child == null) {
                  return child ?? const SizedBox.shrink();
                }
                final media = MediaQuery.of(context);
                return MediaQuery(
                  data: media.copyWith(
                    textScaler: TextScaler.linear(
                      media.textScaler.scale(1) < 1.15
                          ? 1.15
                          : media.textScaler.scale(1),
                    ),
                  ),
                  child: child,
                );
              },
              home: _controllerReady
                  ? _controllerMatrixOnly
                        ? MatrixHomeScreen(
                            controller: widget.controller,
                            palette: palette,
                          )
                        : _controllerHasIdentity && _controllerNeedsMode
                        ? UserModeScreen(controller: widget.controller)
                        : _controllerHasIdentity
                        ? HomeScreen(
                            controller: widget.controller,
                            updateService: widget.updateService,
                            themeController: widget.themeController,
                            palette: palette,
                            buildInfo: widget.buildInfo,
                            onResetIdentity: widget.onResetIdentity,
                          )
                        : OnboardingScreen(
                            controller: widget.controller,
                            palette: palette,
                          )
                  : SplashScreen(palette: palette),
            );
          },
        );
      },
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key, required this.palette});

  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class UpdatePromptDialog extends StatelessWidget {
  const UpdatePromptDialog({super.key, required this.updateService});

  final UpdateService updateService;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: updateService,
      builder: (context, _) {
        final available = updateService.availableUpdate;
        if (available == null) {
          return AlertDialog(
            title: Text(l10nOf(context).settingsUpdates),
            content: Text(
              updateService.statusMessage ??
                  l10nOf(context).uiNoUpdateIsAvailableRightA5EB48,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10nOf(context).actionClose),
              ),
            ],
          );
        }
        final actionLabel =
            updateService.targetPlatform == UpdateTargetPlatform.android
            ? 'Download & Install'
            : 'Download & Restart';
        return AlertDialog(
          title: Text(l10nOf(context).uiUpdateAvailable67FD3A),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10nOf(context).uiValueIsAvailableOnTheD338C4(
                    (available.release.tagName).toString(),
                    (available.release.prerelease
                            ? l10nOf(context).releaseNightly
                            : l10nOf(context).releaseStable)
                        .toString(),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l10nOf(context).uiCurrentBuildValue2FD415(
                    (updateService.buildInfo.displayVersion).toString(),
                  ),
                ),
                if ((available.releaseNotes ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    l10nOf(context).uiWhatSNew4D8DC5,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 220),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        available.releaseNotes!.trim(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (updateService.isDownloading)
                  LinearProgressIndicator(
                    value: updateService.downloadProgress,
                  ),
                if (updateService.statusMessage != null) ...[
                  const SizedBox(height: 10),
                  Text(updateService.statusMessage!),
                ],
                if (updateService.lastError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    updateService.lastError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: updateService.isDownloading
                  ? null
                  : () {
                      updateService.dismissPromptForSession(
                        available.release.tagName,
                      );
                      Navigator.of(context).pop();
                    },
              child: Text(l10nOf(context).uiLater56E2F5),
            ),
            FilledButton(
              onPressed: updateService.isDownloading
                  ? null
                  : () async {
                      await updateService.downloadAndApplyAvailableUpdate();
                      if (context.mounted && !updateService.isDownloading) {
                        Navigator.of(context).pop();
                      }
                    },
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );
  }
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _displayNameController = TextEditingController();
  final _internetRelayHostController = TextEditingController();
  final _internetRelayPortController = TextEditingController(
    text: '$defaultRelayPort',
  );
  final _localRelayPortController = TextEditingController(
    text: '$defaultRelayPort',
  );
  bool _submitting = false;

  @override
  void dispose() {
    _displayNameController.dispose();
    _internetRelayHostController.dispose();
    _internetRelayPortController.dispose();
    _localRelayPortController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) {
      return;
    }
    final displayName = _displayNameController.text.trim();
    final internetRelayHost = _internetRelayHostController.text.trim();
    final internetRelayPort = int.tryParse(
      _internetRelayPortController.text.trim(),
    );
    final localRelayPort = int.tryParse(_localRelayPortController.text.trim());
    if (displayName.isEmpty || localRelayPort == null) {
      widget.controller.setStatus(l10nOf(context).onbNameRequired);
      return;
    }
    if (internetRelayHost.isNotEmpty && internetRelayPort == null) {
      widget.controller.setStatus(l10nOf(context).onbRelayPortInvalid);
      return;
    }
    setState(() {
      _submitting = true;
    });
    try {
      await widget.controller.createIdentity(
        displayName: displayName,
        internetRelayHost: internetRelayHost.isEmpty ? null : internetRelayHost,
        internetRelayPort: internetRelayPort,
        localRelayPort: localRelayPort,
        detectRelayProtocols: true,
      );
    } catch (error) {
      widget.controller.setStatus(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final relayModeNote = _isDesktopPlatform
        ? l10nOf(context).onbRelayDesktop
        : !kIsWeb && Platform.isAndroid
        ? l10nOf(context).onbRelayAndroid
        : l10nOf(context).onbRelayOther;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 24,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 380,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10nOf(context).uiConest26885B,
                                style: Theme.of(context).textTheme.displaySmall
                                    ?.copyWith(
                                      color: palette.textPrimary,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                l10nOf(
                                  context,
                                ).uiSERVERLESSSECUREMESSENGER1E1891,
                                style: TextStyle(
                                  fontFamily: ConestPalette.monoFont,
                                  fontSize: 11,
                                  letterSpacing: 2,
                                  color: palette.primary,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                l10nOf(context).onbTagline,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: palette.inkSoft,
                                      height: 1.4,
                                    ),
                              ),
                              const SizedBox(height: 24),
                              _FeatureStrip(
                                palette: palette,
                                items: [
                                  l10nOf(context).onbFeatureForwardSecret,
                                  l10nOf(context).onbFeatureDirect,
                                  l10nOf(context).onbFeatureFallbacks,
                                  l10nOf(context).onbFeatureMatrix,
                                ],
                              ),
                              const SizedBox(height: 18),
                              Text(
                                relayModeNote,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: palette.inkSoft,
                                      height: 1.4,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: Card(
                            elevation: 0,
                            color: palette.paperStrong,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                              side: BorderSide(color: palette.stroke),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    l10nOf(context).onbCreateTitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    l10nOf(context).onbCreateHelp,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: palette.inkSoft),
                                  ),
                                  const SizedBox(height: 18),
                                  TextField(
                                    controller: _displayNameController,
                                    decoration: InputDecoration(
                                      labelText: l10nOf(context).onbDisplayName,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _localRelayPortController,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      labelText: l10nOf(context).onbLocalPort,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _internetRelayHostController,
                                    decoration: InputDecoration(
                                      labelText: l10nOf(context).onbRelayHost,
                                      hintText: l10nOf(
                                        context,
                                      ).uiHostAutoDetectsTCPUDP663D30,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _internetRelayPortController,
                                    keyboardType: TextInputType.number,
                                    decoration: InputDecoration(
                                      labelText: l10nOf(context).onbRelayPort,
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  FilledButton.icon(
                                    onPressed: _submitting ? null : _submit,
                                    icon: _submitting
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.shield_moon_outlined,
                                          ),
                                    label: Text(
                                      l10nOf(context).onbCreateButton,
                                    ),
                                  ),
                                  if (widget.controller.matrixAvailable) ...[
                                    const SizedBox(height: 8),
                                    OutlinedButton.icon(
                                      onPressed: _submitting
                                          ? null
                                          : () => widget.controller.setAppMode(
                                              AppMode.matrixOnly,
                                            ),
                                      icon: const Icon(Icons.alternate_email),
                                      label: Text(
                                        l10nOf(context).onbMatrixInstead,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      l10nOf(context).onbMatrixHelp,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: palette.inkSoft),
                                    ),
                                  ],
                                  if (widget.controller.statusMessage !=
                                      null) ...[
                                    const SizedBox(height: 14),
                                    Text(
                                      localizedUiText(
                                        context,
                                        widget.controller.statusMessage!,
                                      ),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: palette.inkSoft),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.updateService,
    required this.themeController,
    required this.palette,
    required this.buildInfo,
    this.onResetIdentity,
  });

  final MessengerController controller;
  final UpdateService updateService;
  final ConestThemeController themeController;
  final ConestPalette palette;
  final ConestBuildInfo buildInfo;
  final Future<void> Function()? onResetIdentity;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription<Map<String, dynamic>>? _matrixVerificationRequests;

  /// Another of the user's Matrix sessions asks to verify this one.
  Future<void> _handleMatrixVerificationRequest(
    Map<String, dynamic> event,
  ) async {
    final client = widget.controller.matrixClient;
    final userId = event['userId'];
    final flowId = event['flowId'];
    if (event['type'] != 'verification_request' ||
        client == null ||
        userId is! String ||
        flowId is! String ||
        !mounted) {
      return;
    }
    // One request at a time, each once: more while a dialog is open are
    // left to time out.
    if (_verificationDialogOpen || !_verificationFlowsSeen.add(flowId)) return;
    if (_verificationFlowsSeen.length > 64) {
      _verificationFlowsSeen.remove(_verificationFlowsSeen.first);
    }
    _verificationDialogOpen = true;
    try {
      await _answerMatrixVerificationRequest(client, event, userId, flowId);
    } finally {
      _verificationDialogOpen = false;
    }
  }

  bool _verificationDialogOpen = false;
  final LinkedHashSet<String> _verificationFlowsSeen = LinkedHashSet();

  Future<void> _answerMatrixVerificationRequest(
    MatrixClientService client,
    Map<String, dynamic> event,
    String userId,
    String flowId,
  ) async {
    final own = userId == client.userId;
    final accept = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiVerificationRequestDA06F9),
        content: Text(
          own
              ? l10nOf(context).uiYourMatrixSessionValueWants580E45(
                  (event['fromDevice'] ?? '').toString(),
                )
              : l10nOf(
                  context,
                ).uiValueWantsToVerifyYou61FD9D((userId).toString()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10nOf(context).uiIgnore98F55D),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10nOf(context).uiVerifyDDA6AC),
          ),
        ],
      ),
    );
    if (accept != true) {
      unawaited(
        client.cancelVerification(userId, flowId).catchError((Object _) {}),
      );
      return;
    }
    if (!mounted) return;
    try {
      await client.acceptVerification(userId, flowId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10nOf(context).uiCouldNotVerifyValue3AE1C4((error).toString()),
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => MatrixVerificationDialog(
        client: client,
        userId: userId,
        flowId: flowId,
        weStarted: false,
        otherName: own ? null : userId,
      ),
    );
  }

  String? _selectedContactId;
  String? _selectedGroupId;
  bool _lanLobbySelected = false;
  bool _detailsPaneOpen = false;
  bool _callScreenMinimized = false;
  String? _callScreenSessionId;
  String? _dismissedCallId;
  String? _terminalCallTimerId;
  Timer? _terminalCallTimer;
  double _sidebarWidth = 380;
  final _courierKey = GlobalKey<_CourierHomeState>();
  final _composers = <(ConversationKind, String), TextEditingController>{};
  final _emptyComposer = TextEditingController();

  TextEditingController get _composerController {
    final (ConversationKind, String) key;
    if (_selectedContactId case final String id) {
      key = (ConversationKind.direct, id);
    } else if (_selectedGroupId case final String id) {
      key = (ConversationKind.group, id);
    } else if (_lanLobbySelected) {
      key = (ConversationKind.lanLobby, 'lobby');
    } else {
      return _emptyComposer;
    }
    return _composers.putIfAbsent(key, () {
      final composer = TextEditingController(
        text: widget.controller.conversationDraft(key.$1, key.$2),
      );
      composer.addListener(() {
        unawaited(
          widget.controller
              .setConversationDraft(key.$1, key.$2, composer.text)
              .catchError((Object error) {
                debugPrint('Could not save conversation draft: $error');
              }),
        );
      });
      return composer;
    });
  }

  ChatMessage? _replyTarget;

  @override
  void initState() {
    super.initState();
    _sidebarWidth = widget.themeController.sidebarWidth;
    _matrixVerificationRequests = widget
        .controller
        .matrixClient
        ?.verificationEvents
        .listen(_handleMatrixVerificationRequest);
    widget.controller.addListener(_handleControllerChanged);
    widget.controller.conversationRevision.addListener(
      _handleConversationRevision,
    );
    _userNoticeSubscription = widget.controller.userNotices.listen(
      _showUserNotice,
    );
    // Shared from another app's share menu: now, or at a cold start.
    _shareSubscription = widget.controller.shareAvailableEvents.listen(
      (_) => unawaited(_takeShare()),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_takeShare()),
    );
  }

  StreamSubscription<String>? _userNoticeSubscription;
  StreamSubscription<void>? _shareSubscription;

  /// Stages [files] in the selected chat: one to one into the composer,
  /// in a group shared at once (asking first if their details stay).
  Future<void> _stageFilesIntoSelected(
    List<({String path, String name, String mimeType})> files,
  ) async {
    if (files.isEmpty || !mounted) return;
    final contact = _selectedContact;
    final group = _selectedGroup;
    if (contact != null) {
      final items =
          <
            ({
              Uint8List? bytes,
              String? filePath,
              int sizeBytes,
              String fileName,
              String mimeType,
              String caption,
              Uint8List? poster,
            })
          >[];
      for (final file in files) {
        try {
          items.add((
            bytes: null,
            filePath: file.path,
            sizeBytes: await File(file.path).length(),
            fileName: file.name,
            mimeType: file.mimeType,
            caption: '',
            poster: null,
          ));
        } catch (error) {
          widget.controller.setStatus('Could not read ${file.name}: $error');
        }
      }
      if (items.isNotEmpty) {
        await _stageMultipleAttachments(contact: contact, items: items);
      }
    } else if (group != null) {
      for (final file in files) {
        if (!mounted) return;
        try {
          await publishGroupFileAsking(
            context,
            widget.controller,
            groupId: group.groupId,
            path: file.path,
            fileName: file.name,
            mimeType: file.mimeType,
          );
        } catch (error) {
          widget.controller.setStatus('Could not share ${file.name}: $error');
        }
      }
    }
  }

  /// An image or GIF the keyboard inserted (Android): staged like a paste.
  Future<void> _stageInsertedContent(KeyboardInsertedContent content) async {
    final data = content.data;
    if (data == null || data.isEmpty) return;
    final extension = switch (content.mimeType) {
      'image/png' => 'png',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final folder = await Directory.systemTemp.createTemp('conest-inserted-');
    final file = File('${folder.path}/keyboard.$extension');
    await file.writeAsBytes(data);
    await _stageFilesIntoSelected([
      (
        path: file.path,
        name: 'keyboard.$extension',
        mimeType: content.mimeType,
      ),
    ]);
  }

  /// Takes what another app shared: the user picks a chat, the files are
  /// staged (one to one) or shared (groups), and text goes into the
  /// composer.
  Future<void> _takeShare() async {
    final shared = await widget.controller.takePendingShare();
    if (shared == null || !mounted) return;
    final target = await showDialog<Object>(
      context: context,
      builder: (context) =>
          _ShareTargetDialog(controller: widget.controller, shared: shared),
    );
    if (target == null || !mounted) return;
    switch (target) {
      case ContactRecord contact:
        _selectHomeContact(contact);
      case GroupRecord group:
        _selectHomeGroup(group);
    }
    await _stageFilesIntoSelected(shared.files);
    final text = shared.text;
    if (mounted && text != null && text.isNotEmpty) {
      _composerController.text = text;
    }
  }

  /// Only the Signature sidebar renders [MessengerController.statusMessage];
  /// other shells would otherwise swallow errors from the action just taken.
  void _showUserNotice(String message) {
    if (!mounted || widget.themeController.shell == ConestShell.signature) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(localizedUiText(context, message))),
      );
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      oldWidget.controller.conversationRevision.removeListener(
        _handleConversationRevision,
      );
      widget.controller.addListener(_handleControllerChanged);
      widget.controller.conversationRevision.addListener(
        _handleConversationRevision,
      );
      unawaited(_userNoticeSubscription?.cancel());
      _userNoticeSubscription = widget.controller.userNotices.listen(
        _showUserNotice,
      );
    }
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  void _handleConversationRevision() {
    if (mounted) setState(() {});
  }

  void _saveSidebarWidth() {
    unawaited(
      widget.themeController.setSidebarWidth(_sidebarWidth).catchError((
        Object error,
      ) {
        widget.controller.setStatus('Could not save sidebar width: $error');
      }),
    );
  }

  void _minimizeOrDismissCall(VoiceCallSession call) {
    setState(() {
      if (call.state == VoiceCallState.ended) {
        _dismissedCallId = call.callId;
        _callScreenMinimized = false;
      } else {
        _callScreenMinimized = true;
      }
    });
  }

  Future<void> _chooseCallOutput() async {
    final service = widget.controller.voiceCallService;
    if (service == null) return;
    try {
      final devices = await service.availableOutputDevices();
      if (!mounted) return;
      if (devices.isEmpty) {
        widget.controller.setStatus('No audio output devices were found.');
        return;
      }
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10nOf(context).uiCallAudioOutput0C276F),
          content: SizedBox(
            width: 440,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final device in devices)
                  ListTile(
                    title: Text(device),
                    onTap: () => Navigator.of(context).pop(device),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10nOf(context).actionCancel),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;
      await service.selectOutputDevice(selected);
      widget.controller.setStatus('Call audio routed to $selected.');
    } catch (error) {
      widget.controller.setStatus('Could not change call audio output: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_userNoticeSubscription?.cancel());
    unawaited(_shareSubscription?.cancel());
    unawaited(_matrixVerificationRequests?.cancel());
    _terminalCallTimer?.cancel();
    widget.controller.removeListener(_handleControllerChanged);
    widget.controller.conversationRevision.removeListener(
      _handleConversationRevision,
    );
    for (final composer in _composers.values) {
      composer.dispose();
    }
    _emptyComposer.dispose();
    super.dispose();
  }

  ContactRecord? get _selectedContact {
    final current = _selectedContactId;
    if (current == null) {
      return null;
    }
    if (widget.controller.isSavedMessages(current)) {
      return widget.controller.savedMessagesContact;
    }
    for (final contact in widget.controller.contacts) {
      if (contact.deviceId == current) {
        return contact;
      }
    }
    return null;
  }

  GroupRecord? get _selectedGroup {
    final current = _selectedGroupId;
    if (current == null) {
      return null;
    }
    for (final group in widget.controller.groups) {
      if (group.groupId == current) {
        return group;
      }
    }
    return null;
  }

  bool _replyTargetMatchesContact(ContactRecord contact) {
    final target = _replyTarget;
    if (target == null) {
      return false;
    }
    return target.senderDeviceId == contact.deviceId ||
        target.recipientDeviceId == contact.deviceId;
  }

  bool _replyTargetMatchesGroup(GroupRecord group) {
    final target = _replyTarget;
    return target != null && target.conversationId == group.groupId;
  }

  // Shared home-column selection handlers — used by the Signature sidebar and
  // the Garrison/Courier shells so all three drive the same chat panels.
  /// The tab shown on phones in Standard mode (0 chats, 1 calls).
  int _phoneTab = 0;

  void _selectHomeContact(ContactRecord contact) {
    setState(() {
      _lanLobbySelected = false;
      _selectedGroupId = null;
      _selectedContactId = contact.deviceId;
      _detailsPaneOpen = false;
      if (!_replyTargetMatchesContact(contact)) {
        _replyTarget = null;
      }
    });
  }

  void _selectHomeGroup(GroupRecord group) {
    setState(() {
      _lanLobbySelected = false;
      _selectedContactId = null;
      _selectedGroupId = group.groupId;
      _detailsPaneOpen = false;
      if (!_replyTargetMatchesGroup(group)) {
        _replyTarget = null;
      }
    });
  }

  void _selectHomeLanLobby() {
    setState(() {
      _selectedContactId = null;
      _selectedGroupId = null;
      _lanLobbySelected = true;
      _detailsPaneOpen = false;
      _replyTarget = null;
    });
    unawaited(widget.controller.markLanLobbyRead());
  }

  Future<void> _showInvite() async {
    try {
      final invite = await widget.controller.buildInvite();
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => InviteScreen(
            controller: widget.controller,
            invite: invite,
            palette: widget.palette,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        widget.controller.setStatus('Could not open invite: $error');
      }
    }
  }

  Future<void> _showBeam() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => BeamHubScreen(
          controller: widget.controller,
          palette: widget.palette,
        ),
      ),
    );
  }

  Future<void> _showAddContact() async {
    final added = await showDialog<ContactRecord>(
      context: context,
      builder: (context) => AddContactDialog(
        fullscreenOnMobile: widget.themeController.shell == ConestShell.courier,
        controller: widget.controller,
        palette: widget.palette,
      ),
    );
    if (added == null || !mounted) return;
    setState(() {
      _selectedContactId = added.deviceId;
      _selectedGroupId = null;
      _lanLobbySelected = false;
      _replyTarget = null;
    });
  }

  Future<void> _showCreateGroup() async {
    final created = await showDialog<GroupRecord>(
      context: context,
      builder: (context) => CreateGroupDialog(
        fullscreenOnMobile: widget.themeController.shell == ConestShell.courier,
        controller: widget.controller,
        palette: widget.palette,
      ),
    );
    if (created == null || !mounted) {
      return;
    }
    setState(() {
      _selectedContactId = null;
      _selectedGroupId = created.groupId;
      _lanLobbySelected = false;
      _replyTarget = null;
    });
  }

  Future<void> _showGroupDetails(
    GroupRecord group, {
    bool forceDialog = false,
  }) async {
    final desktopCourier =
        !forceDialog &&
        widget.themeController.shell == ConestShell.courier &&
        MediaQuery.sizeOf(context).width > 920;
    if (desktopCourier) {
      setState(() {
        _selectedGroupId = group.groupId;
        _selectedContactId = null;
        _lanLobbySelected = false;
        _detailsPaneOpen = !_detailsPaneOpen;
      });
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => GroupDetailsDialog(
        fullscreenOnMobile: widget.themeController.shell == ConestShell.courier,
        controller: widget.controller,
        palette: widget.palette,
        group: group,
      ),
    );
    if (!mounted) {
      return;
    }
    if (_selectedGroupId != null &&
        !widget.controller.groups.any(
          (group) => group.groupId == _selectedGroupId,
        )) {
      setState(() {
        _selectedGroupId = null;
        _replyTarget = null;
      });
    }
  }

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        fullscreenOnMobile: widget.themeController.shell == ConestShell.courier,
        controller: widget.controller,
        updateService: widget.updateService,
        themeController: widget.themeController,
        palette: widget.palette,
        onResetIdentity: widget.onResetIdentity,
      ),
    );
    if (!mounted) {
      return;
    }
    final selected = _selectedContactId;
    if (selected != null &&
        !widget.controller.contacts.any(
          (contact) => contact.deviceId == selected,
        )) {
      setState(() {
        _selectedContactId = widget.controller.contacts.isEmpty
            ? null
            : widget.controller.contacts.first.deviceId;
      });
    }
  }

  Future<void> _showTransfers() async {
    final peerDeviceId = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (context) => _TransfersScreen(
          controller: widget.controller,
          palette: widget.palette,
        ),
      ),
    );
    if (!mounted || peerDeviceId == null) return;
    final contact = widget.controller.contactByDeviceId(peerDeviceId);
    if (contact != null) _selectHomeContact(contact);
  }

  Future<void> _showDebugMenu() async {
    // Channel gating happens at the button (HomeScreen.build), so
    // _showDebugMenu trusts its caller. Debug artifacts are isolated from
    // stable/nightly builds and are the only channel that exposes this UI.
    await showDialog<void>(
      context: context,
      builder: (context) => DebugMenuDialog(
        controller: widget.controller,
        palette: widget.palette,
      ),
    );
  }

  Future<void> _showContactProfile(
    ContactRecord contact, {
    bool forceDialog = false,
  }) async {
    final desktopCourier =
        !forceDialog &&
        widget.themeController.shell == ConestShell.courier &&
        MediaQuery.sizeOf(context).width > 920;
    if (desktopCourier) {
      setState(() {
        _selectedContactId = contact.deviceId;
        _selectedGroupId = null;
        _lanLobbySelected = false;
        _detailsPaneOpen = !_detailsPaneOpen;
      });
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => ContactProfileDialog(
        fullscreenOnMobile: widget.themeController.shell == ConestShell.courier,
        controller: widget.controller,
        palette: widget.palette,
        contact: contact,
      ),
    );
    if (!mounted) {
      return;
    }
    final selected = _selectedContactId;
    if (selected != null &&
        !widget.controller.contacts.any(
          (contact) => contact.deviceId == selected,
        )) {
      setState(() {
        _selectedContactId = null;
        _selectedGroupId = null;
        _replyTarget = null;
      });
    }
  }

  /// Empties the composer as soon as a message is handed over, so the next
  /// one can be typed while this one is still being delivered.
  void _takeComposer() {
    _composerController.clear();
    setState(() => _replyTarget = null);
  }

  /// Puts an unsent message back, unless something new has been typed.
  void _restoreComposer(String body, ChatMessage? replyTarget) {
    if (!mounted || _composerController.text.trim().isNotEmpty) return;
    _composerController.text = body;
    setState(() => _replyTarget = replyTarget);
  }

  Future<void> _sendCurrentMessage() async {
    final contact = _selectedContact;
    if (contact == null) return;
    final body = _composerController.text.trim();
    // nightly.10: when files are staged, Send commits the bundle (with
    // the typed text as caption on the first item). When no files are
    // staged, fall through to the text-only send path.
    final staged = widget.controller.stagedAttachmentsFor(contact.deviceId);
    if (staged.isNotEmpty) {
      final replyTarget = _replyTarget;
      _takeComposer();
      try {
        await widget.controller.sendStagedBundle(
          contact: contact,
          caption: body,
          confirmOriginalSourceFallback: _confirmOriginalSourceFallback,
        );
      } catch (error) {
        widget.controller.setStatus('Could not send attachment: $error');
        _restoreComposer(body, replyTarget);
      }
      return;
    }
    if (body.isEmpty) return;
    final replyTarget = _replyTarget;
    _takeComposer();
    try {
      await widget.controller.sendMessage(
        contact: contact,
        body: body,
        replyTo: replyTarget,
      );
    } catch (error) {
      widget.controller.setStatus('Could not send message: $error');
      _restoreComposer(body, replyTarget);
    }
  }

  Future<bool> _confirmOriginalSourceFallback(
    StagedAttachment attachment,
    AttachmentSpoolException error,
  ) async {
    if (!mounted) return false;
    if (error.partialMetadata) {
      return confirmSendingMetadata(
        context,
        attachment.fileName,
        partial: true,
      );
    }
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              error.keepsMetadata
                  ? l10nOf(context).uiSendWithItsDetailsF287FB
                  : l10nOf(context).uiSendWithoutResumableCopy0475F4,
            ),
            content: Text(
              l10nOf(context).uiValueCouldNotBeCopied06F61A(
                (attachment.fileName).toString(),
                (error).toString(),
                (error.keepsMetadata
                        ? '\n\n${l10nOf(context).fileOriginalMetadataWarning}'
                        : '')
                    .toString(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10nOf(context).actionCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10nOf(context).uiSendFromOriginalFFF29A),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _sendCurrentGroupMessage() async {
    final group = _selectedGroup;
    final body = _composerController.text.trim();
    if (group == null || body.isEmpty) {
      return;
    }
    final replyTarget = _replyTarget;
    _takeComposer();
    try {
      await widget.controller.sendGroupMessage(
        groupId: group.groupId,
        body: body,
        replyTo: replyTarget,
      );
    } catch (error) {
      widget.controller.setStatus('Could not send group message: $error');
      _restoreComposer(body, replyTarget);
    }
  }

  Future<void> _sendLanLobbyMessage() async {
    final body = _composerController.text.trim();
    if (body.isEmpty) {
      return;
    }
    _composerController.clear();
    try {
      await widget.controller.sendLanLobbyMessage(body);
    } catch (error) {
      widget.controller.setStatus('Could not send LAN lobby message: $error');
      _restoreComposer(body, null);
    }
  }

  Future<void> _handleDroppedFiles(List<XFile> files) async {
    final contact = _selectedContact;
    if (contact == null || files.isEmpty) {
      return;
    }
    final items =
        <
          ({
            Uint8List? bytes,
            String? filePath,
            int sizeBytes,
            String fileName,
            String mimeType,
            String caption,
            Uint8List? poster,
          })
        >[];
    for (final file in files) {
      try {
        final path = file.path;
        final sizeBytes = path.isNotEmpty
            ? await File(path).length()
            : await file.length();
        const maxPathlessDropBytes = 8 * 1024 * 1024;
        if (path.isEmpty && sizeBytes > maxPathlessDropBytes) {
          widget.controller.setStatus(
            'Could not stage ${file.name}: pathless drops are limited to '
            '8 MB to protect memory.',
          );
          continue;
        }
        items.add((
          bytes: path.isEmpty ? await file.readAsBytes() : null,
          filePath: path.isEmpty ? null : path,
          sizeBytes: sizeBytes,
          fileName: file.name,
          mimeType: _guessMimeType(file.name),
          caption: '',
          poster: null,
        ));
      } catch (error) {
        widget.controller.setStatus('Could not read ${file.name}: $error');
      }
    }
    await _stageMultipleAttachments(contact: contact, items: items);
  }

  /// Ctrl/Cmd+V handler that prefers binary paste. Tries the
  /// image-or-file path first; on no-binary-content, falls back to a
  /// manual text paste into the composer TextField so the keystroke
  /// still feels natural for plain-text content.
  Future<void> _handleSmartPaste() async {
    final didBinary = await _pasteFromClipboard();
    if (didBinary) return;
    // Fall back to text paste. The Shortcuts override consumed Ctrl+V
    // before the TextField could handle it, so we replay it ourselves.
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text;
      if (text == null || text.isEmpty) return;
      final tc = _composerController;
      final selection = tc.selection;
      final start = selection.start >= 0 ? selection.start : tc.text.length;
      final end = selection.end >= 0 ? selection.end : tc.text.length;
      final before = tc.text.substring(0, start);
      final after = tc.text.substring(end);
      tc.value = TextEditingValue(
        text: "${(before)}${(text)}${(after)}",
        selection: TextSelection.collapsed(offset: start + text.length),
      );
    } catch (error) {
      widget.controller.appendDebugLog('Text-paste fallback failed: $error');
    }
  }

  /// Pastes an image / file from the OS clipboard into the active chat.
  /// Returns true when something was sent so caller-side Shortcuts can
  /// consume the event; returns false for plain-text-only clipboard.
  Future<bool> _pasteFromClipboard() async {
    final contact = _selectedContact;
    final group = _selectedGroup;
    if (contact == null && group == null) return false;
    if (Platform.isAndroid) {
      // super_clipboard cannot read images on Android: the system
      // clipboard's content item, copied by the platform side.
      final file = await widget.controller.takeClipboardMedia();
      if (file == null) return false;
      await _stageFilesIntoSelected([file]);
      return true;
    }
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return false;
    final DataReader reader;
    try {
      reader = await clipboard.read();
    } catch (error) {
      widget.controller.appendDebugLog('Clipboard read failed: $error');
      return false;
    }
    // Try image formats first.
    final imageFormats = [Formats.png, Formats.jpeg, Formats.gif, Formats.webp];
    for (final fmt in imageFormats) {
      if (reader.canProvide(fmt)) {
        final completer = Completer<Uint8List?>();
        reader.getFile(fmt, (file) async {
          try {
            final stream = file.getStream();
            const maxClipboardImageBytes = 8 * 1024 * 1024;
            final builder = BytesBuilder(copy: false);
            var total = 0;
            await for (final chunk in stream) {
              total += chunk.length;
              if (total > maxClipboardImageBytes) {
                completer.complete(null);
                return;
              }
              builder.add(chunk);
            }
            completer.complete(builder.takeBytes());
          } catch (_) {
            completer.complete(null);
          }
        });
        final bytes = await completer.future;
        if (bytes == null || bytes.isEmpty) continue;
        final mime = sniffImageMimeType(bytes) ?? 'image/png';
        final ext = mime == 'image/jpeg' ? 'jpg' : mime.split('/').last;
        final fileName = 'pasted-${DateTime.now().millisecondsSinceEpoch}.$ext';
        if (contact != null) {
          await _sendAttachmentBytes(
            contact: contact,
            bytes: bytes,
            fileName: fileName,
            mimeType: mime,
          );
        } else {
          await _publishGroupClipboardBytes(
            group!,
            bytes: bytes,
            fileName: fileName,
            mimeType: mime,
          );
        }
        return true;
      }
    }
    // Fall through to file URI (Linux file managers / Windows Explorer).
    if (reader.canProvide(Formats.fileUri)) {
      final completer = Completer<Uri?>();
      reader.getValue(Formats.fileUri, (value) {
        completer.complete(value);
      });
      final uri = await completer.future;
      if (uri != null) {
        try {
          final file = File.fromUri(uri);
          final name = file.uri.pathSegments.isNotEmpty
              ? file.uri.pathSegments.last
              : 'pasted';
          if (contact != null) {
            await _stageMultipleAttachments(
              contact: contact,
              items: [
                (
                  bytes: null,
                  filePath: file.path,
                  sizeBytes: await file.length(),
                  fileName: name,
                  mimeType: _guessMimeType(name),
                  caption: '',
                  poster: null,
                ),
              ],
            );
          } else {
            await publishGroupFileAsking(
              context,
              widget.controller,
              groupId: group!.groupId,
              path: file.path,
              fileName: name,
              mimeType: _guessMimeType(name),
            );
          }
          return true;
        } catch (error) {
          widget.controller.appendDebugLog('Paste file read failed: $error');
        }
      }
    }
    return false;
  }

  Future<void> _publishGroupClipboardBytes(
    GroupRecord group, {
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    final temp = await Directory.systemTemp.createTemp('conest-group-paste-');
    final path = p.join(temp.path, fileName);
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      await publishGroupFileAsking(
        context,
        widget.controller,
        groupId: group.groupId,
        path: path,
        fileName: fileName,
        mimeType: mimeType,
      );
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  }

  void _handleDroppedFilesForGroup(List<XFile> files) {
    if (files.isEmpty) {
      return;
    }
    final group = _selectedGroup;
    if (group == null) {
      widget.controller.setStatus('Select a group before dropping files.');
      return;
    }
    unawaited(() async {
      for (final file in files) {
        final path = file.path;
        if (path.isEmpty) {
          widget.controller.setStatus(
            '${file.name}: local file path unavailable.',
          );
          continue;
        }
        try {
          await publishGroupFileAsking(
            context,
            widget.controller,
            groupId: group.groupId,
            path: path,
            fileName: file.name,
            mimeType: _guessMimeType(file.name),
          );
        } catch (error) {
          widget.controller.setStatus('Could not share ${file.name}: $error');
        }
      }
    }());
  }

  Future<void> _openMediaPicker() async {
    final contact = _selectedContact;
    if (contact == null) {
      if (_selectedGroup != null) await _openGroupMediaPicker();
      return;
    }
    final result = await showMediaPickerSheet(
      context: context,
      palette: widget.palette,
      // nightly.10: per-contact + LAN-aware cap.
      maxBytes: widget.controller.effectiveMaxAttachmentSizeFor(contact),
    );
    if (!mounted || result == null) {
      return;
    }
    if (result.fallbackToFilePicker) {
      await _pickAndSendAttachment();
      return;
    }
    if (result.items != null) {
      await _stageMultipleAttachments(contact: contact, items: result.items!);
      return;
    }
    await _sendAttachmentBytes(
      contact: contact,
      bytes: result.bytes,
      filePath: result.filePath,
      sizeBytes: result.sizeBytes!,
      fileName: result.fileName!,
      mimeType: result.mimeType ?? 'application/octet-stream',
    );
  }

  /// Photos and videos for a group: the same gallery sheet as in chats,
  /// shared as group files (no size cap: group files go by path).
  Future<void> _openGroupMediaPicker() async {
    final group = _selectedGroup;
    if (group == null) return;
    final result = await showMediaPickerSheet(
      context: context,
      palette: widget.palette,
      maxBytes: 1 << 40,
    );
    if (!mounted || result == null) return;
    if (result.fallbackToFilePicker) {
      await _pickAndShareGroupFiles();
      return;
    }
    final items = [
      ...?result.items,
      if (result.items == null)
        (
          bytes: result.bytes,
          filePath: result.filePath,
          sizeBytes: result.sizeBytes ?? 0,
          fileName: result.fileName ?? 'media',
          mimeType: result.mimeType ?? 'application/octet-stream',
          caption: '',
          poster: null,
        ),
    ];
    for (final item in items) {
      try {
        if (item.filePath case final path?) {
          try {
            await publishGroupFileAsking(
              context,
              widget.controller,
              groupId: group.groupId,
              path: path,
              fileName: item.fileName,
              mimeType: item.mimeType,
              caption: item.caption,
            );
          } on StateError catch (error) {
            // Some members cannot show captions: share it without one.
            if (item.caption.isEmpty) rethrow;
            widget.controller.setStatus('${error.message} Sent without it.');
            await publishGroupFileAsking(
              context,
              widget.controller,
              groupId: group.groupId,
              path: path,
              fileName: item.fileName,
              mimeType: item.mimeType,
            );
          }
        } else if (item.bytes case final bytes?) {
          await _publishGroupClipboardBytes(
            group,
            bytes: bytes,
            fileName: item.fileName,
            mimeType: item.mimeType,
          );
        }
      } catch (error) {
        widget.controller.setStatus('Could not share ${item.fileName}: $error');
      }
    }
  }

  Future<void> _pickAndShareGroupFiles() async {
    final group = _selectedGroup;
    if (group == null) return;
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: false,
    );
    if (!mounted || result == null) return;
    for (final file in result.files) {
      final path = file.path;
      if (path == null || path.isEmpty) {
        widget.controller.setStatus(
          '${file.name}: local file path unavailable.',
        );
        continue;
      }
      try {
        await publishGroupFileAsking(
          context,
          widget.controller,
          groupId: group.groupId,
          path: path,
          fileName: file.name,
          mimeType: _guessMimeType(file.name),
        );
      } catch (error) {
        widget.controller.setStatus('Could not share ${file.name}: $error');
      }
    }
  }

  Future<void> _scheduleGroupAttachment() async {
    final group = _selectedGroup;
    if (group == null) return;
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (!mounted || result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final path = file.path;
    if (path == null || path.isEmpty) {
      widget.controller.setStatus('${file.name}: local file path unavailable.');
      return;
    }
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null || !mounted) return;
    try {
      await widget.controller.scheduleGroupAttachment(
        groupId: group.groupId,
        confirmKeepingMetadata: (error) async =>
            mounted &&
            await confirmSendingMetadata(
              context,
              error.fileName,
              partial: error.partial,
            ),
        source: StagedAttachment(
          id: 'scheduled-file-${DateTime.now().microsecondsSinceEpoch}',
          fileName: file.name,
          mimeType: _guessMimeType(file.name),
          sizeBytes: file.size,
          filePath: path,
        ),
        scheduledAt: DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ),
      );
      widget.controller.setStatus('Group file scheduled.');
    } catch (error) {
      widget.controller.setStatus('Could not schedule ${file.name}: $error');
    }
  }

  Future<void> _pickAndSendAttachment() async {
    final contact = _selectedContact;
    if (contact == null) {
      return;
    }
    FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.any,
        withData: false,
        allowMultiple: true,
      );
    } catch (error) {
      widget.controller.setStatus('Could not open file picker: $error');
      return;
    }
    if (picked == null || picked.files.isEmpty) {
      return;
    }
    final items =
        <
          ({
            Uint8List? bytes,
            String? filePath,
            int sizeBytes,
            String fileName,
            String mimeType,
            String caption,
            Uint8List? poster,
          })
        >[];
    for (final file in picked.files) {
      final path = file.path;
      if (path == null || path.isEmpty) {
        widget.controller.setStatus('${file.name}: picker returned no data.');
        continue;
      }
      items.add((
        bytes: null,
        filePath: path,
        sizeBytes: file.size,
        fileName: file.name,
        mimeType: _guessMimeType(file.name),
        caption: '',
        poster: null,
      ));
    }
    await _stageMultipleAttachments(contact: contact, items: items);
  }

  Future<void> _sendAttachmentBytes({
    required ContactRecord contact,
    Uint8List? bytes,
    String? filePath,
    int? sizeBytes,
    required String fileName,
    required String mimeType,
  }) {
    return _stageMultipleAttachments(
      contact: contact,
      items: [
        (
          bytes: bytes,
          filePath: filePath,
          sizeBytes: sizeBytes ?? bytes?.length ?? 0,
          fileName: fileName,
          mimeType: mimeType,
          caption: '',
          poster: null,
        ),
      ],
    );
  }

  /// nightly.10: every input pipeline (media picker, drag-drop, paste,
  /// Ctrl+V, file picker) calls THIS to add to the staging tray instead
  /// of immediately sending. The Send button reads the staged bucket via
  /// `controller.sendStagedBundle(contact, caption: composer.text)`.
  ///
  /// Album packing + per-item delays now live on `sendStagedBundle` in
  /// the controller; this function only filters by per-contact cap and
  /// converts the tuple into [StagedAttachment].
  Future<void> _stageMultipleAttachments({
    required ContactRecord contact,
    required List<
      ({
        Uint8List? bytes,
        String? filePath,
        int sizeBytes,
        String fileName,
        String mimeType,
        String caption,
        Uint8List? poster,
      })
    >
    items,
  }) async {
    if (items.isEmpty) return;
    final cap = MessengerController.maxAttachmentsPerSend;
    final clamped = items.take(cap).toList(growable: false);
    if (items.length > cap) {
      widget.controller.setStatus(
        'Only the first $cap files will be staged (got ${items.length}).',
      );
    }
    final perContactCap = widget.controller.effectiveMaxAttachmentSizeFor(
      contact,
    );
    final capMb = perContactCap ~/ (1024 * 1024);
    final staged = <StagedAttachment>[];
    for (final item in clamped) {
      if (item.sizeBytes > perContactCap) {
        widget.controller.setStatus(
          '${item.fileName} skipped: ${(item.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} '
          'MB exceeds the $capMb MB cap.',
        );
        continue;
      }
      staged.add(
        StagedAttachment(
          id: widget.controller.newAlbumId(),
          fileName: item.fileName,
          mimeType: item.mimeType,
          sizeBytes: item.sizeBytes,
          bytes: item.bytes,
          filePath: item.filePath,
          poster: item.poster,
          caption: item.caption,
        ),
      );
    }
    if (staged.isEmpty) return;
    widget.controller.stageAttachments(contact: contact, items: staged);
  }

  static String _guessMimeType(String fileName) {
    final lowered = fileName.toLowerCase();
    if (lowered.endsWith('.png')) return 'image/png';
    if (lowered.endsWith('.jpg') || lowered.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lowered.endsWith('.gif')) return 'image/gif';
    if (lowered.endsWith('.webp')) return 'image/webp';
    if (lowered.endsWith('.bmp')) return 'image/bmp';
    if (lowered.endsWith('.heic') || lowered.endsWith('.heif')) {
      return 'image/heic';
    }
    if (lowered.endsWith('.pdf')) return 'application/pdf';
    if (lowered.endsWith('.txt') || lowered.endsWith('.md')) {
      return 'text/plain';
    }
    if (lowered.endsWith('.json')) return 'application/json';
    if (lowered.endsWith('.mp4') || lowered.endsWith('.m4v')) {
      return 'video/mp4';
    }
    if (lowered.endsWith('.mov')) return 'video/quicktime';
    if (lowered.endsWith('.webm')) return 'video/webm';
    if (lowered.endsWith('.mkv')) return 'video/x-matroska';
    if (lowered.endsWith('.avi')) return 'video/x-msvideo';
    if (lowered.endsWith('.3gp')) return 'video/3gpp';
    if (lowered.endsWith('.mpg') || lowered.endsWith('.mpeg')) {
      return 'video/mpeg';
    }
    if (lowered.endsWith('.mp3')) return 'audio/mpeg';
    if (lowered.endsWith('.m4a')) return 'audio/mp4';
    if (lowered.endsWith('.wav')) return 'audio/wav';
    if (lowered.endsWith('.ogg') || lowered.endsWith('.opus')) {
      return 'audio/ogg';
    }
    if (lowered.endsWith('.flac')) return 'audio/flac';
    return 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final selectedContact = _selectedContact;
    final selectedGroup = _selectedGroup;
    final lanLobbySelected =
        _lanLobbySelected && selectedContact == null && selectedGroup == null;
    final activeCall = widget.controller.voiceCallService?.active;
    if (activeCall == null) {
      _callScreenSessionId = null;
      _callScreenMinimized = false;
      _dismissedCallId = null;
      _terminalCallTimerId = null;
      _terminalCallTimer?.cancel();
      _terminalCallTimer = null;
    } else if (_callScreenSessionId != activeCall.callId &&
        _dismissedCallId != activeCall.callId) {
      _callScreenSessionId = activeCall.callId;
      _callScreenMinimized = false;
    }
    final endedCall = activeCall;
    if (endedCall != null && endedCall.state == VoiceCallState.ended) {
      _callScreenMinimized = false;
      if (_terminalCallTimerId != endedCall.callId) {
        _terminalCallTimerId = endedCall.callId;
        _terminalCallTimer?.cancel();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _terminalCallTimer = Timer(const Duration(seconds: 4), () {
            if (!mounted) return;
            setState(() => _dismissedCallId = endedCall.callId);
          });
        });
      }
    } else if (activeCall != null) {
      _terminalCallTimer?.cancel();
      _terminalCallTimer = null;
      _terminalCallTimerId = null;
    }
    final visibleCall = activeCall != null &&
            _dismissedCallId != activeCall.callId
        ? activeCall
        : null;
    final callContact = visibleCall == null
        ? null
        : widget.controller.contacts
              .where((contact) => contact.deviceId == visibleCall.peerDeviceId)
              .firstOrNull;
    return CallbackShortcuts(
      bindings: widget.themeController.shell != ConestShell.courier
          ? const {}
          : {
              const SingleActivator(
                LogicalKeyboardKey.arrowDown,
                alt: true,
              ): () =>
                  _courierKey.currentState?.navigateChat(1),
              const SingleActivator(
                LogicalKeyboardKey.arrowUp,
                alt: true,
              ): () =>
                  _courierKey.currentState?.navigateChat(-1),
              const SingleActivator(
                LogicalKeyboardKey.keyK,
                control: true,
              ): () =>
                  _courierKey.currentState?._searchFocus.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
                  _courierKey.currentState?._searchFocus.requestFocus(),
              const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
              ): () =>
                  _courierKey.currentState?._newChat(),
              const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
                  _courierKey.currentState?._newChat(),
            },
      child: Scaffold(
        floatingActionButton:
            widget.themeController.shell == ConestShell.courier
            ? null
            : FloatingActionButton.small(
                heroTag: 'global-transfers',
                tooltip: l10nOf(context).uiTransfers812412,
                onPressed: _showTransfers,
                child: Badge(
                  isLabelVisible: widget.controller.transferSnapshots.any(
                    (entry) =>
                        entry.phase.isActive ||
                        entry.phase == TransferPhase.paused,
                  ),
                  label: Text(
                    "${(widget.controller.transferSnapshots.where((entry) => entry.phase.isActive || entry.phase == TransferPhase.paused).length)}",
                  ),
                  child: const Icon(Icons.downloading_outlined),
                ),
              ),
        body: DecoratedBox(
          decoration: BoxDecoration(gradient: palette.appGradient),
          child: Stack(
            children: [
              // Signature ambient overlay — sits behind all panels, hugs the
              // screen corners with reticles + readout. Intensity is the
              // user-controlled Decoration setting.
              Positioned.fill(
                child: SignatureDecoration(
                  palette: palette,
                  intensity: widget.themeController.decorationIntensity,
                ),
              ),
              PopScope(
                canPop: visibleCall == null &&
                    selectedContact == null &&
                    selectedGroup == null &&
                    !lanLobbySelected,
                onPopInvokedWithResult: (didPop, result) {
                  if (didPop) return;
                  if (visibleCall != null) {
                    _minimizeOrDismissCall(visibleCall);
                    return;
                  }
                  if (_selectedContactId != null ||
                      _selectedGroupId != null ||
                      _lanLobbySelected) {
                    setState(() {
                      _selectedContactId = null;
                      _selectedGroupId = null;
                      _lanLobbySelected = false;
                      _replyTarget = null;
                    });
                  }
                },
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 920;
                      final resizableSidebar =
                          isWide &&
                          widget.themeController.shell == ConestShell.courier;
                      final showDetailsPane =
                          isWide &&
                          widget.themeController.shell == ConestShell.courier &&
                          _detailsPaneOpen &&
                          constraints.maxWidth >= 1120;
                      final detailsPaneWidth = showDetailsPane ? 320.0 : 0.0;
                      final sidebarMaximum = math.min(
                        560.0,
                        constraints.maxWidth - 488 - detailsPaneWidth,
                      );
                      final sidebarWidth = _sidebarWidth
                          .clamp(300.0, math.max(300.0, sidebarMaximum))
                          .toDouble();
                      if (!isWide && selectedContact != null) {
                        return _ChatPanel(
                          telegramLayout:
                              widget.themeController.shell ==
                              ConestShell.courier,
                          key: ValueKey('chat-${selectedContact.deviceId}'),
                          controller: widget.controller,
                          palette: palette,
                          contact: selectedContact,
                          composerController: _composerController,
                          replyTarget: _replyTarget,
                          onBack: () => setState(() {
                            _selectedContactId = null;
                            _replyTarget = null;
                          }),
                          onCancelReply: () =>
                              setState(() => _replyTarget = null),
                          onReplyToMessage: (message) =>
                              setState(() => _replyTarget = message),
                          onShowProfile: () =>
                              _showContactProfile(selectedContact),
                          onSend: _sendCurrentMessage,
                          onAttach: _openMediaPicker,
                          onDropFiles: _handleDroppedFiles,
                          onSmartPaste: () => unawaited(_handleSmartPaste()),
                          onContentInserted: (content) =>
                              unawaited(_stageInsertedContent(content)),
                        );
                      }
                      if (!isWide && selectedGroup != null) {
                        return _GroupChatPanel(
                          telegramLayout:
                              widget.themeController.shell ==
                              ConestShell.courier,
                          key: ValueKey('group-${selectedGroup.groupId}'),
                          controller: widget.controller,
                          palette: palette,
                          group: selectedGroup,
                          composerController: _composerController,
                          replyTarget: _replyTarget,
                          onBack: () => setState(() {
                            _selectedGroupId = null;
                            _replyTarget = null;
                          }),
                          onCancelReply: () =>
                              setState(() => _replyTarget = null),
                          onReplyToMessage: (message) =>
                              setState(() => _replyTarget = message),
                          onShowDetails: () => _showGroupDetails(selectedGroup),
                          onSend: _sendCurrentGroupMessage,
                          onDropFiles: _handleDroppedFilesForGroup,
                          onAttach: _openMediaPicker,
                          onScheduleAttachment: _scheduleGroupAttachment,
                          onSmartPaste: () => unawaited(_handleSmartPaste()),
                          onContentInserted: (content) =>
                              unawaited(_stageInsertedContent(content)),
                        );
                      }
                      if (!isWide && lanLobbySelected) {
                        return _LanLobbyPanel(
                          controller: widget.controller,
                          palette: palette,
                          composerController: _composerController,
                          onBack: () =>
                              setState(() => _lanLobbySelected = false),
                          onSend: _sendLanLobbyMessage,
                        );
                      }
                      final home = Row(
                        children: [
                          SizedBox(
                            width: isWide
                                ? (resizableSidebar ? sidebarWidth : 380.0)
                                : constraints.maxWidth,
                            // Shell selector — Garrison (Discord rail) and
                            // Courier (Telegram list) are alternate home
                            // presentations; all reuse the chat panels below.
                            child: switch (widget.themeController.shell) {
                              ConestShell.courier => _CourierHome(
                                key: _courierKey,
                                controller: widget.controller,
                                palette: palette,
                                selectedContactId: _selectedContactId,
                                selectedGroupId: _selectedGroupId,
                                lanLobbySelected: lanLobbySelected,
                                onContactSelected: _selectHomeContact,
                                onGroupSelected: _selectHomeGroup,
                                onLanLobbySelected: _selectHomeLanLobby,
                                onAddContact: _showAddContact,
                                onCreateGroup: _showCreateGroup,
                                onShowTransfers: _showTransfers,
                                onShowDebug:
                                    widget.buildInfo.channel ==
                                        UpdateChannel.debug
                                    ? _showDebugMenu
                                    : null,
                                onShowSettings: _showSettings,
                                onShowInvite: _showInvite,
                                onShowBeam: _showBeam,
                              ),
                              ConestShell.garrison => _GarrisonHome(
                                controller: widget.controller,
                                palette: palette,
                                selectedContactId: _selectedContactId,
                                selectedGroupId: _selectedGroupId,
                                lanLobbySelected: lanLobbySelected,
                                onContactSelected: _selectHomeContact,
                                onGroupSelected: _selectHomeGroup,
                                onGroupDetails: _showGroupDetails,
                                onLanLobbySelected: _selectHomeLanLobby,
                                onAddContact: _showAddContact,
                                onCreateGroup: _showCreateGroup,
                                onShowSettings: _showSettings,
                                onShowInvite: _showInvite,
                                onShowBeam: _showBeam,
                              ),
                              ConestShell.signature => _Sidebar(
                                controller: widget.controller,
                                palette: palette,
                                homeLayout: widget.themeController.homeLayout,
                                selectedContactId: _selectedContactId,
                                selectedGroupId: _selectedGroupId,
                                lanLobbySelected: lanLobbySelected,
                                onAddContact: _showAddContact,
                                onCreateGroup: _showCreateGroup,
                                onLanLobbySelected: _selectHomeLanLobby,
                                onGroupSelected: _selectHomeGroup,
                                onGroupDetails: _showGroupDetails,
                                onContactSelected: _selectHomeContact,
                                onContactProfile: _showContactProfile,
                                // Automatic file battle tests can mutate large
                                // amounts of app-owned storage, so expose them
                                // only in the isolated debug channel.
                                onShowDebug:
                                    widget.buildInfo.channel ==
                                        UpdateChannel.debug
                                    ? _showDebugMenu
                                    : null,
                                onPoll: widget.controller.pollNow,
                                onShowSettings: _showSettings,
                                onShowInvite: _showInvite,
                                onShowBeam: _showBeam,
                              ),
                            },
                          ),
                          if (resizableSidebar)
                            ConversationSidebarDivider(
                              key: const ValueKey(
                                'conversation-sidebar-divider',
                              ),
                              color: palette.border,
                              onResize: (delta) => setState(() {
                                _sidebarWidth = (sidebarWidth + delta).clamp(
                                  300.0,
                                  sidebarMaximum,
                                );
                              }),
                              onResizeEnd: _saveSidebarWidth,
                              onReset: () {
                                setState(() => _sidebarWidth = 380);
                                _saveSidebarWidth();
                              },
                            ),
                          if (isWide)
                            Expanded(
                              child: lanLobbySelected
                                  ? _LanLobbyPanel(
                                      controller: widget.controller,
                                      palette: palette,
                                      composerController: _composerController,
                                      onSend: _sendLanLobbyMessage,
                                    )
                                  : selectedGroup != null
                                  ? _GroupChatPanel(
                                      telegramLayout:
                                          widget.themeController.shell ==
                                          ConestShell.courier,
                                      key: ValueKey(
                                        'group-${selectedGroup.groupId}',
                                      ),
                                      controller: widget.controller,
                                      palette: palette,
                                      group: selectedGroup,
                                      composerController: _composerController,
                                      replyTarget: _replyTarget,
                                      onCancelReply: () =>
                                          setState(() => _replyTarget = null),
                                      onReplyToMessage: (message) => setState(
                                        () => _replyTarget = message,
                                      ),
                                      onShowDetails: () =>
                                          _showGroupDetails(selectedGroup),
                                      onSend: _sendCurrentGroupMessage,
                                      onDropFiles: _handleDroppedFilesForGroup,
                                      onAttach: _openMediaPicker,
                                      onScheduleAttachment:
                                          _scheduleGroupAttachment,
                                      onSmartPaste: () =>
                                          unawaited(_handleSmartPaste()),
                                      onContentInserted: (content) => unawaited(
                                        _stageInsertedContent(content),
                                      ),
                                    )
                                  : selectedContact == null
                                  ? _EmptyChatState(palette: palette)
                                  : _ChatPanel(
                                      telegramLayout:
                                          widget.themeController.shell ==
                                          ConestShell.courier,
                                      key: ValueKey(
                                        'chat-${selectedContact.deviceId}',
                                      ),
                                      controller: widget.controller,
                                      palette: palette,
                                      contact: selectedContact,
                                      composerController: _composerController,
                                      replyTarget: _replyTarget,
                                      onCancelReply: () =>
                                          setState(() => _replyTarget = null),
                                      onReplyToMessage: (message) => setState(
                                        () => _replyTarget = message,
                                      ),
                                      onShowProfile: () =>
                                          _showContactProfile(selectedContact),
                                      onSend: _sendCurrentMessage,
                                      onAttach: _openMediaPicker,
                                      onDropFiles: _handleDroppedFiles,
                                      onSmartPaste: () =>
                                          unawaited(_handleSmartPaste()),
                                      onContentInserted: (content) => unawaited(
                                        _stageInsertedContent(content),
                                      ),
                                    ),
                            ),
                          if (showDetailsPane && selectedContact != null)
                            _ContactDetailsPane(
                              controller: widget.controller,
                              palette: palette,
                              contact: selectedContact,
                              onClose: () =>
                                  setState(() => _detailsPaneOpen = false),
                              onOpenFullProfile: () => _showContactProfile(
                                selectedContact,
                                forceDialog: true,
                              ),
                            ),
                          if (showDetailsPane && selectedGroup != null)
                            _GroupDetailsPane(
                              controller: widget.controller,
                              palette: palette,
                              group: selectedGroup,
                              onClose: () =>
                                  setState(() => _detailsPaneOpen = false),
                              onOpenFullDetails: () => _showGroupDetails(
                                selectedGroup,
                                forceDialog: true,
                              ),
                            ),
                        ],
                      );
                      // Only devices on this network reach this one: say so
                      // above the chats, in every shell.
                      final reachable = Column(
                        children: [
                          InternetReachBanner(
                            controller: widget.controller,
                            onSetUp: () => unawaited(_showSettings()),
                          ),
                          Expanded(child: home),
                        ],
                      );
                      // Standard mode on a phone: chats, calls and settings
                      // as tabs, as the popular messengers have them.
                      if (isWide ||
                          widget.controller.userMode != UserMode.normal) {
                        return reachable;
                      }
                      return _PhoneTabs(
                        tab: _phoneTab,
                        onTab: (tab) {
                          if (tab == 2) {
                            unawaited(_showSettings());
                          } else {
                            setState(() => _phoneTab = tab);
                          }
                        },
                        chats: reachable,
                        calls: CallsList(
                          controller: widget.controller,
                          onOpenContact: (contact) {
                            setState(() => _phoneTab = 0);
                            _selectHomeContact(contact);
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                top: 4,
                left: 12,
                right: 12,
                child: SafeArea(
                  child: GroupCallBanner(controller: widget.controller),
                ),
              ),
              if (visibleCall != null && !_callScreenMinimized)
                Positioned.fill(
                  child: _VoiceCallOverlay(
                    controller: widget.controller,
                    palette: palette,
                    call: visibleCall,
                    contact: callContact,
                    onMinimize: () => _minimizeOrDismissCall(visibleCall),
                    onChooseOutput: _chooseCallOutput,
                  ),
                )
              else if (visibleCall != null)
                Positioned(
                  top: 4,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    child: _CallReturnBar(
                      call: visibleCall,
                      contact: callContact,
                      palette: palette,
                      onReturn: () => setState(() {
                        _callScreenMinimized = false;
                      }),
                      onHangUp: () => unawaited(
                        widget.controller.voiceCallService!.end().catchError(
                          (Object error) =>
                              widget.controller.setStatus('$error'),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VoiceCallOverlay extends StatefulWidget {
  const _VoiceCallOverlay({
    required this.controller,
    required this.palette,
    required this.call,
    required this.contact,
    required this.onMinimize,
    required this.onChooseOutput,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final VoiceCallSession call;
  final ContactRecord? contact;
  final VoidCallback onMinimize;
  final VoidCallback onChooseOutput;

  @override
  State<_VoiceCallOverlay> createState() => _VoiceCallOverlayState();
}

class _VoiceCallOverlayState extends State<_VoiceCallOverlay> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  String get _stateLabel => switch (widget.call.state) {
    VoiceCallState.idle => l10nOf(context).uiPreparingCallE86D6C,
    VoiceCallState.ringing =>
      widget.call.outgoing
          ? l10nOf(context).uiCallingACD4A6
          : l10nOf(context).uiIncomingVoiceCallF68FD3,
    VoiceCallState.connecting => l10nOf(context).uiConnectingFD3E79,
    VoiceCallState.connected => _connectedTime(),
    VoiceCallState.reconnecting => l10nOf(context).uiReconnecting8A8B95,
    VoiceCallState.ended =>
      widget.call.failureReason ?? l10nOf(context).uiCallEnded9933A4,
  };

  String _connectedTime() {
    final elapsed = DateTime.now().difference(widget.call.startedAt);
    final seconds = elapsed.inSeconds.clamp(0, 24 * 60 * 60);
    return l10nOf(context).voiceConnected('${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}');
  }

  void _run(Future<void> Function() operation) {
    unawaited(operation().catchError((Object error) {
      widget.controller.setStatus('Voice call: $error');
    }));
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final incoming = !call.outgoing && call.state == VoiceCallState.ringing;
    final ended = call.state == VoiceCallState.ended;
    final connected = call.state == VoiceCallState.connected ||
        call.state == VoiceCallState.reconnecting;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onMinimize();
      },
      child: Material(
        color: widget.palette.panel.withValues(alpha: 0.98),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Align(
                      alignment: Alignment.topRight,
                      child: IconButton(
                        tooltip: l10nOf(context).uiMinimizeCall6CB0F0,
                        onPressed: widget.onMinimize,
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ),
                    const Spacer(),
                    SealAvatar(
                      seed: call.peerDeviceId,
                      palette: widget.palette,
                      size: 112,
                      animate: true,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      widget.contact?.alias ?? l10nOf(context).unknownContact,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _stateLabel,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: widget.palette.inkSoft,
                      ),
                    ),
                    if (call.failureReason != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        call.failureReason!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: widget.palette.danger),
                      ),
                    ],
                    const Spacer(),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        if (incoming)
                          FilledButton.icon(
                            onPressed: () => _run(
                              widget.controller.acceptVoiceCall,
                            ),
                            icon: const Icon(Icons.call),
                            label: Text(l10nOf(context).uiAcceptBB54DB),
                          ),
                        if (incoming)
                          OutlinedButton.icon(
                            onPressed: () => _run(
                              widget.controller.rejectVoiceCall,
                            ),
                            icon: const Icon(Icons.call_end),
                            label: Text(l10nOf(context).uiReject2B03B5),
                          ),
                        if (connected)
                          OutlinedButton.icon(
                            onPressed: () => _run(
                              widget.controller.voiceCallService!.toggleMute,
                            ),
                            icon: Icon(
                              call.muted ? Icons.mic_off : Icons.mic,
                            ),
                            label: Text(call.muted ? l10nOf(context).uiUnmute7044C3 : l10nOf(context).uiMute0F0973),
                          ),
                        if (connected)
                          FilterChip(
                            label:  Text(l10nOf(context).uiNoiseSuppression71DE3C),
                            selected:
                                widget
                                    .controller
                                    .identity
                                    ?.voiceNoiseSuppressionEnabled ??
                                true,
                            onSelected: (enabled) => _run(
                              () => widget.controller.setVoiceNoiseSuppression(
                                enabled,
                              ),
                            ),
                          ),
                        if (connected && !kIsWeb && Platform.isAndroid)
                          OutlinedButton.icon(
                            onPressed: () => _run(
                              widget.controller.voiceCallService!
                                  .toggleSpeakerphone,
                            ),
                            icon: Icon(
                              call.speakerphoneEnabled
                                  ? Icons.volume_up
                                  : Icons.hearing,
                            ),
                            label: Text(
                              call.speakerphoneEnabled
                                  ? l10nOf(context).uiSpeakerOn93982E
                                  : l10nOf(context).uiSpeakerOff97823A,
                            ),
                          ),
                        if (connected &&
                            (Platform.isLinux || Platform.isWindows))
                          OutlinedButton.icon(
                            onPressed: widget.onChooseOutput,
                            icon: const Icon(Icons.speaker_outlined),
                            label: Text(l10nOf(context).uiAudioOutput2B89CC),
                          ),
                        if (ended)
                          FilledButton.icon(
                            onPressed: widget.onMinimize,
                            icon: const Icon(Icons.check),
                            label: Text(l10nOf(context).uiDoneE9B450),
                          )
                        else if (!incoming)
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: widget.palette.danger,
                              foregroundColor: widget.palette.onPrimary,
                            ),
                            onPressed: () => _run(
                              widget.controller.voiceCallService!.end,
                            ),
                            icon: const Icon(Icons.call_end),
                            label: Text(
                              call.outgoing &&
                                      call.state == VoiceCallState.ringing
                                  ? l10nOf(context).uiCancelCallCE6C16
                                  : l10nOf(context).uiHangUp66BE99,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 36),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CallReturnBar extends StatelessWidget {
  const _CallReturnBar({
    required this.call,
    required this.contact,
    required this.palette,
    required this.onReturn,
    required this.onHangUp,
  });

  final VoiceCallSession call;
  final ContactRecord? contact;
  final ConestPalette palette;
  final VoidCallback onReturn;
  final VoidCallback onHangUp;

  @override
  Widget build(BuildContext context) => Material(
    color: palette.panel2,
    elevation: 6,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onReturn,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.call, color: palette.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10nOf(context).uiValueValueReturnToCall49F82C(
                  (call.state == VoiceCallState.reconnecting
                          ? l10nOf(context).uiReconnecting9D80F9
                          : call.state == VoiceCallState.connected
                          ? l10nOf(context).callActive
                          : l10nOf(context).callGeneric)
                      .toString(),
                  (contact == null ? '' : ' · ${contact!.alias}').toString(),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: l10nOf(context).uiHangUp66BE99,
              onPressed: onHangUp,
              icon: Icon(Icons.call_end, color: palette.danger),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ContactDetailsPane extends StatelessWidget {
  const _ContactDetailsPane({
    required this.controller,
    required this.palette,
    required this.contact,
    required this.onClose,
    required this.onOpenFullProfile,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final ContactRecord contact;
  final VoidCallback onClose;
  final VoidCallback onOpenFullProfile;

  @override
  Widget build(BuildContext context) {
    final reachability = controller.reachabilityStateFor(contact.deviceId);
    return SizedBox(
      width: 320,
      child: Material(
        color: palette.panel,
        elevation: 1,
        child: SafeArea(
          left: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10nOf(context).uiContactDetailsD4EC65,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    tooltip: l10nOf(context).uiCloseDetails433DA6,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: SealAvatar(
                  seed: contact.deviceId,
                  label: contact.alias,
                  palette: palette,
                  size: 88,
                  animate: true,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                contact.alias,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (contact.bio.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  contact.bio,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: palette.inkSoft),
                ),
              ],
              const SizedBox(height: 18),
              _ReachabilityChip(
                state: reachability,
                palette: palette,
                expand: true,
              ),
              const SizedBox(height: 12),
              _DetailsValue(
                label: l10nOf(context).uiRoute499952,
                value: contact.routeSummary,
              ),
              _DetailsValue(
                label: l10nOf(context).uiSafetyNumber5ED2D3,
                value: contact.shortSafetyNumber,
              ),
              _DetailsValue(
                label: l10nOf(context).uiIrohEndpoint72F674,
                value:
                    contact.irohEndpointId ?? l10nOf(context).contactNotPinned,
              ),
              _DetailsValue(
                label: l10nOf(context).uiDeviceA5A74A,
                value: contact.deviceId,
                monospace: true,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onOpenFullProfile,
                icon: const Icon(Icons.open_in_new),
                label: Text(l10nOf(context).uiOpenFullProfile35063C),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupDetailsPane extends StatelessWidget {
  const _GroupDetailsPane({
    required this.controller,
    required this.palette,
    required this.group,
    required this.onClose,
    required this.onOpenFullDetails,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final GroupRecord group;
  final VoidCallback onClose;
  final VoidCallback onOpenFullDetails;

  @override
  Widget build(BuildContext context) {
    final members = group.activeMemberDeviceIds;
    return SizedBox(
      width: 320,
      child: Material(
        color: palette.panel,
        elevation: 1,
        child: SafeArea(
          left: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10nOf(context).uiGroupDetailsDF844A,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    tooltip: l10nOf(context).uiCloseDetails433DA6,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: SealAvatar(
                  seed: group.groupId,
                  label: group.title,
                  palette: palette,
                  size: 88,
                  animate: true,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                group.title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                l10nOf(
                  context,
                ).uiValueActiveMemberValue6700F2((members.length)),
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
              ),
              const SizedBox(height: 18),
              for (final member in members)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: SealAvatar(
                    seed: member,
                    label: controller.groupMemberLabel(member),
                    palette: palette,
                    size: 34,
                  ),
                  title: Text(
                    controller.groupMemberLabel(member),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    member == group.ownerDeviceId
                        ? l10nOf(context).uiOwner89FF31
                        : l10nOf(context).roleMember,
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: onOpenFullDetails,
                icon: const Icon(Icons.settings_outlined),
                label: Text(l10nOf(context).uiOpenGroupSettings0B568E),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailsValue extends StatelessWidget {
  const _DetailsValue({
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            fontFamily: monospace ? ConestPalette.monoFont : null,
          ),
        ),
      ],
    ),
  );
}

/// Intent dispatched by the composer's `Ctrl+V` / `Cmd+V` Shortcuts
/// override. The matching Action fires the active chat panel's
/// `onSmartPaste` callback, which first tries a binary clipboard paste
/// (image / file URI) and falls back to plain-text paste if no binary
/// content is present.
class _PasteMediaIntent extends Intent {
  const _PasteMediaIntent();
}

/// Courier shell — a Telegram-shaped unified conversation list. Contacts,
/// groups and the LAN lobby merge into one list sorted by recent activity,
/// each a clean tailed row (seal · name · preview · time · unread). Reuses
/// the shared chat panels on tap.
class _CourierHome extends StatefulWidget {
  const _CourierHome({
    super.key,
    required this.controller,
    required this.palette,
    required this.selectedContactId,
    required this.selectedGroupId,
    required this.lanLobbySelected,
    required this.onContactSelected,
    required this.onGroupSelected,
    required this.onLanLobbySelected,
    required this.onAddContact,
    required this.onCreateGroup,
    required this.onShowTransfers,
    this.onShowDebug,
    required this.onShowSettings,
    required this.onShowInvite,
    required this.onShowBeam,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final String? selectedContactId;
  final String? selectedGroupId;
  final bool lanLobbySelected;
  final ValueChanged<ContactRecord> onContactSelected;
  final ValueChanged<GroupRecord> onGroupSelected;
  final VoidCallback onLanLobbySelected;
  final VoidCallback onAddContact;
  final VoidCallback onCreateGroup;
  final VoidCallback onShowTransfers;
  final VoidCallback? onShowDebug;
  final Future<void> Function() onShowSettings;
  final Future<void> Function() onShowInvite;
  final Future<void> Function() onShowBeam;

  @override
  State<_CourierHome> createState() => _CourierHomeState();
}

class _CourierHomeState extends State<_CourierHome> {
  bool _showArchived = false;
  String _activeFolderId = 'all';

  /// In Both mode: which chats the list shows.
  /// "all", "conest" or a network's id.
  String _source = 'all';
  List<({String id, bool selected, VoidCallback open})> _navigation = const [];

  void navigateChat(int direction) {
    if (_navigation.isEmpty) return;
    final current = _navigation.indexWhere((entry) => entry.selected);
    final next = current < 0
        ? (direction > 0 ? 0 : _navigation.length - 1)
        : (current + direction).clamp(0, _navigation.length - 1);
    _navigation[next].open();
  }

  void _refreshLocalConversations() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.localConversationRevision.addListener(
      _refreshLocalConversations,
    );
  }

  @override
  void didUpdateWidget(covariant _CourierHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.localConversationRevision.removeListener(
        _refreshLocalConversations,
      );
      widget.controller.localConversationRevision.addListener(
        _refreshLocalConversations,
      );
    }
  }

  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scaffold = GlobalKey<ScaffoldState>();

  Future<void> _showRequests() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _ContactRequestsScreen(
        controller: widget.controller,
        palette: widget.palette,
      ),
    ),
  );

  Future<void> _showScheduledMessages() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => _ScheduledMessagesScreen(
        controller: widget.controller,
        palette: widget.palette,
      ),
    ),
  );

  Future<void> _createFolder() async {
    final name = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiNewFolderA71199),
        content: TextField(
          controller: name,
          autofocus: true,
          maxLength: 48,
          decoration: InputDecoration(
            hintText: l10nOf(context).uiFolderNameB2CE02,
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.text),
            child: Text(l10nOf(context).actionCreate),
          ),
        ],
      ),
    );
    name.dispose();
    if (value == null || value.trim().isEmpty || !mounted) return;
    try {
      final folder = await widget.controller.createChatFolder(value);
      if (mounted) setState(() => _activeFolderId = folder.id);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${(error)}")));
    }
  }

  Future<void> _editFolder(ChatFolder folder) async {
    final name = TextEditingController(text: folder.name);
    final folderIndex = widget.controller.chatFolders.indexWhere(
      (value) => value.id == folder.id,
    );
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          l10nOf(context).uiEditValue75BE00((folder.name).toString()),
        ),
        content: TextField(
          controller: name,
          autofocus: true,
          maxLength: 48,
          decoration: InputDecoration(
            labelText: l10nOf(context).uiFolderNameB2CE02,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10nOf(context).actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'delete'),
            child: Text(l10nOf(context).menuDelete),
          ),
          if (folderIndex > 0)
            TextButton(
              onPressed: () => Navigator.pop(context, 'moveUp'),
              child: Text(l10nOf(context).uiMoveEarlier07DD6F),
            ),
          if (folderIndex >= 0 &&
              folderIndex < widget.controller.chatFolders.length - 1)
            TextButton(
              onPressed: () => Navigator.pop(context, 'moveDown'),
              child: Text(l10nOf(context).uiMoveLaterBB4C84),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: Text(l10nOf(context).uiSaveEFC007),
          ),
        ],
      ),
    );
    final updatedName = name.text.trim();
    name.dispose();
    if (!mounted) return;
    if (action == 'delete') {
      await widget.controller.deleteChatFolder(folder.id);
      if (mounted && _activeFolderId == folder.id) {
        setState(() => _activeFolderId = 'all');
      }
    } else if (action == 'save' && updatedName.isNotEmpty) {
      await widget.controller.updateChatFolder(folder.id, name: updatedName);
    } else if (action == 'moveUp' && folderIndex > 0) {
      await widget.controller.reorderChatFolders(folderIndex, folderIndex - 1);
    } else if (action == 'moveDown' &&
        folderIndex >= 0 &&
        folderIndex < widget.controller.chatFolders.length - 1) {
      await widget.controller.reorderChatFolders(folderIndex, folderIndex + 1);
    }
  }

  Future<void> _newChat() async {
    final action = await Navigator.of(context).push<Object>(
      MaterialPageRoute(
        builder: (_) => _CourierNewChatScreen(
          controller: widget.controller,
          palette: widget.palette,
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case ContactRecord contact:
        widget.onContactSelected(contact);
      case 'group':
        widget.onCreateGroup();
      case 'contact':
        widget.onAddContact();
      case 'beam':
        unawaited(widget.onShowBeam());
    }
  }

  Future<void> _chatActions(
    ConversationKind kind,
    String id, {
    Offset? at,
  }) async {
    final prefs = widget.controller.conversationPreferences(kind, id);
    final actions = <(String, IconData, String)>[
      ('pin', Icons.push_pin_outlined, prefs.pinned ? 'Unpin' : 'Pin'),
      (
        'mute',
        Icons.notifications_off_outlined,
        prefs.muted ? 'Unmute' : 'Mute',
      ),
      (
        'archive',
        Icons.archive_outlined,
        prefs.archived ? 'Unarchive' : 'Archive',
      ),
      ('folder', Icons.create_new_folder_outlined, 'Add to folder'),
    ];
    final String? selected;
    if (at != null) {
      selected = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
        items: [
          for (final action in actions)
            PopupMenuItem(
              value: action.$1,
              child: Row(
                children: [
                  Icon(action.$2),
                  const SizedBox(width: 12),
                  Text(action.$3),
                ],
              ),
            ),
        ],
      );
    } else {
      selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final action in actions)
                ListTile(
                  leading: Icon(action.$2),
                  title: Text(action.$3),
                  onTap: () => Navigator.pop(context, action.$1),
                ),
            ],
          ),
        ),
      );
    }
    if (selected == null || !mounted) return;
    if (selected == 'folder') {
      final folders = widget.controller.chatFolders;
      if (folders.isEmpty) {
        await _createFolder();
        return;
      }
      final currentId =
          kind == ConversationKind.group || kind == ConversationKind.direct
          ? id
          : id;
      final chosen = await showDialog<Set<String>>(
        context: context,
        builder: (context) {
          final values = <String>{
            for (final folder in folders)
              if (folder.conversationIds.contains(currentId)) folder.id,
          };
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text(l10nOf(context).uiAddToFolderBFAD96),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final folder in folders)
                      CheckboxListTile(
                        value: values.contains(folder.id),
                        title: Text(folder.name),
                        onChanged: (checked) => setDialogState(() {
                          if (checked == true) {
                            values.add(folder.id);
                          } else {
                            values.remove(folder.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10nOf(context).actionCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, values),
                  child: Text(l10nOf(context).uiSaveEFC007),
                ),
              ],
            ),
          );
        },
      );
      if (chosen == null) return;
      for (final folder in folders) {
        final ids = [...folder.conversationIds];
        if (chosen.contains(folder.id) && !ids.contains(currentId))
          ids.add(currentId);
        if (!chosen.contains(folder.id)) ids.remove(currentId);
        await widget.controller.updateChatFolder(
          folder.id,
          conversationIds: ids,
        );
      }
      if (mounted) setState(() {});
      return;
    }
    try {
      await widget.controller.updateConversationPreferences(
        kind,
        id,
        pinned: selected == 'pin' ? !prefs.pinned : null,
        muted: selected == 'mute' ? !prefs.muted : null,
        archived: selected == 'archive' ? !prefs.archived : null,
      );
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10nOf(
                context,
              ).uiCouldNotSaveChatSettings2372B2((error).toString()),
            ),
          ),
        );
      }
    }
  }

  /// Starts (or reopens) a Matrix DM with a user id.
  Future<void> _newMatrixChat() async {
    final matrix = widget.controller.matrixClient;
    if (matrix == null) return;
    await startMatrixChat(context, matrix, widget.palette);
  }

  Widget _drawer() {
    final me = widget.controller.identity;
    Widget action(IconData icon, String title, VoidCallback callback) =>
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          onTap: () {
            _scaffold.currentState?.closeDrawer();
            callback();
          },
        );
    return Drawer(
      backgroundColor: widget.palette.panel,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SealAvatar(
                    seed: me?.deviceId ?? 'me',
                    label: me?.displayName ?? l10nOf(context).uiConest26885B,
                    palette: widget.palette,
                    size: 64,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    me?.displayName ?? l10nOf(context).uiConest26885B,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (me?.bio.isNotEmpty == true)
                    Text(me!.bio, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const Divider(height: 1),
            action(Icons.group_add_outlined, 'New group', widget.onCreateGroup),
            action(
              Icons.contacts_outlined,
              'Contacts',
              () => unawaited(_newChat()),
            ),
            action(
              Icons.forum_outlined,
              'LAN lobby',
              widget.onLanLobbySelected,
            ),
            if (widget.controller.matrixClient?.signedIn == true &&
                widget.controller.appMode != AppMode.conest)
              action(
                Icons.alternate_email,
                'New Matrix chat',
                () => unawaited(_newMatrixChat()),
              ),
            action(
              Icons.archive_outlined,
              'Archived chats',
              () => setState(() => _showArchived = true),
            ),
            action(
              Icons.person_add_alt_1_outlined,
              'Contact requests (${widget.controller.pendingContactRequests.length})',
              () => unawaited(_showRequests()),
            ),
            action(Icons.swap_vert, 'Transfers', widget.onShowTransfers),
            action(
              Icons.schedule_send_outlined,
              'Scheduled messages',
              () => unawaited(_showScheduledMessages()),
            ),
            const Divider(),
            action(
              Icons.qr_code_2,
              'My invite',
              () => unawaited(widget.onShowInvite()),
            ),
            action(
              Icons.center_focus_strong,
              'Conest Beam',
              () => unawaited(widget.onShowBeam()),
            ),
            action(
              Icons.settings_outlined,
              'Settings',
              () => unawaited(widget.onShowSettings()),
            ),
            if (widget.onShowDebug != null)
              action(
                Icons.bug_report_outlined,
                'Debug tools',
                widget.onShowDebug!,
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.localConversationRevision.removeListener(
      _refreshLocalConversations,
    );
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    ChatMessage? matchingMessage(List<ChatMessage> messages) {
      for (final message in messages.reversed) {
        if (message.bodyPreview.toLowerCase().contains(query)) return message;
      }
      return null;
    }

    // Unified, recency-sorted conversation entries.
    final folderIds = widget.controller
        .conversationIdsForFolder(_activeFolderId)
        .toSet();
    final entries =
        <
          ({
            String seed,
            String title,
            String preview,
            DateTime? at,
            int unread,
            bool selected,
            bool isGroup,
            String? network,
            bool pinned,
            bool archived,
            bool muted,
            String draft,
            int memberCount,
            ContactReachabilityState? reachability,
            VoidCallback onTap,
          })
        >[];
    final networks = [
      for (final source in networkChatSources(
        widget.controller,
        widget.palette,
      ))
        if (source.active && widget.controller.showsChatNetwork(source.id))
          source,
    ];
    // A network's filter that is gone (hidden, signed out, turned off)
    // shows everything again, not an empty list.
    if (_source != 'all' &&
        _source != 'conest' &&
        !networks.any((network) => network.id == _source)) {
      _source = 'all';
    }
    final showConest = _source == 'all' || _source == 'conest';
    for (final contact
        in showConest ? widget.controller.contacts : const <ContactRecord>[]) {
      if (_activeFolderId != 'all' && !folderIds.contains(contact.deviceId))
        continue;
      final last = widget.controller.lastMessageFor(contact.deviceId);
      final prefs = widget.controller.conversationPreferences(
        ConversationKind.direct,
        contact.deviceId,
      );
      final match = query.isEmpty
          ? null
          : matchingMessage(widget.controller.messagesFor(contact.deviceId));
      if (query.isNotEmpty &&
          !contact.alias.toLowerCase().contains(query) &&
          match == null) {
        continue;
      }
      entries.add((
        seed: contact.deviceId,
        pinned: prefs.pinned,
        archived: prefs.archived,
        muted: prefs.muted,
        draft: prefs.draft,
        title: contact.alias,
        preview: match?.bodyPreview ?? last?.bodyPreview ?? 'No messages yet',
        at: last?.createdAt,
        unread: widget.controller.unreadCountFor(contact.deviceId),
        selected: widget.selectedContactId == contact.deviceId,
        isGroup: false,
        network: null,
        memberCount: 0,
        reachability: widget.controller.reachabilityStateFor(contact.deviceId),
        onTap: () => widget.onContactSelected(contact),
      ));
    }
    for (final group
        in showConest
            ? widget.controller.visibleGroups
            : const <GroupRecord>[]) {
      if (_activeFolderId != 'all' && !folderIds.contains(group.groupId))
        continue;
      final last = widget.controller.lastGroupMessageFor(group.groupId);
      final prefs = widget.controller.conversationPreferences(
        ConversationKind.group,
        group.groupId,
      );
      final match = query.isEmpty
          ? null
          : matchingMessage(widget.controller.messagesForGroup(group.groupId));
      if (query.isNotEmpty &&
          !group.title.toLowerCase().contains(query) &&
          match == null) {
        continue;
      }
      entries.add((
        seed: group.groupId,
        pinned: prefs.pinned,
        archived: prefs.archived,
        muted: prefs.muted,
        draft: prefs.draft,
        title: group.title,
        preview:
            match?.bodyPreview ??
            last?.bodyPreview ??
            '${group.activeMemberDeviceIds.length} member(s)',
        at: last?.createdAt,
        unread: widget.controller.unreadGroupCountFor(group.groupId),
        selected: widget.selectedGroupId == group.groupId,
        isGroup: true,
        network: null,
        memberCount: group.activeMemberDeviceIds.length,
        reachability: null,
        onTap: () => widget.onGroupSelected(group),
      ));
    }
    // Chats on other networks (Matrix, bitchat, …).
    if (_activeFolderId == 'all') {
      for (final source in networks) {
        if (_source != 'all' && _source != source.id) continue;
        for (final chat in source.chats(context)) {
          if (!chat.matches(query)) continue;
          entries.add((
            seed: '${source.id}:${chat.id}',
            pinned: false,
            archived: false,
            muted: false,
            draft: '',
            title: chat.title,
            preview: chat.preview,
            at: chat.at,
            unread: chat.unread,
            selected: false,
            isGroup: chat.isGroup,
            network: source.label,
            memberCount: chat.memberCount,
            reachability: null,
            onTap: () => chat.open(context),
          ));
        }
      }
    }
    final archivedCount = entries.where((entry) => entry.archived).length;
    entries.removeWhere((entry) => entry.archived != _showArchived);
    entries.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      final at = a.at;
      final bt = b.at;
      if (at == null && bt == null) return a.title.compareTo(b.title);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });

    final saved = widget.controller.savedMessagesContact;
    _navigation = [
      if (!_showArchived &&
          showConest &&
          saved != null &&
          'saved messages'.contains(query))
        (
          id: 'saved',
          selected: widget.selectedContactId == saved.deviceId,
          open: () => widget.onContactSelected(saved),
        ),
      if (!_showArchived && showConest && 'lan lobby'.contains(query))
        (
          id: 'lobby',
          selected: widget.lanLobbySelected,
          open: widget.onLanLobbySelected,
        ),
      for (final entry in entries)
        (id: entry.seed, selected: entry.selected, open: entry.onTap),
    ];

    return Scaffold(
      key: _scaffold,
      backgroundColor: widget.palette.panel,
      drawer: _drawer(),
      floatingActionButton: FloatingActionButton(
        heroTag: 'courier-new-chat',
        tooltip: l10nOf(context).uiNewMessage1ED2E7,
        onPressed: _newChat,
        backgroundColor: widget.palette.primary,
        foregroundColor: widget.palette.onPrimary,
        child: const Icon(Icons.edit_outlined),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: _showArchived
                      ? l10nOf(context).uiBackToChats8DE6F6
                      : l10nOf(context).uiNavigationMenu6609F1,
                  onPressed: () {
                    if (_showArchived) {
                      setState(() => _showArchived = false);
                    } else {
                      _scaffold.currentState?.openDrawer();
                    }
                  },
                  icon: Icon(_showArchived ? Icons.arrow_back : Icons.menu),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _showArchived
                        ? l10nOf(context).archivedChats
                        : l10nOf(context).uiConest26885B,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: l10nOf(context).actionSearch,
                  onPressed: _searchFocus.requestFocus,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          // Simple mode: one list of chats, no filters or folders.
          if (!_showArchived &&
              query.isEmpty &&
              widget.controller.userMode != UserMode.minimal)
            SizedBox(
              height: 42,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                children: [
                  if (networks.isNotEmpty)
                    for (final (source, label) in [
                      ('all', 'All chats'),
                      ('conest', 'Conest'),
                      for (final network in networks)
                        (network.id, network.label),
                    ]) ...[
                      if (source != 'all') const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(label),
                        selected: _activeFolderId == 'all' && _source == source,
                        onSelected: (_) => setState(() {
                          _activeFolderId = 'all';
                          _source = source;
                        }),
                      ),
                    ]
                  else
                    ChoiceChip(
                      label: Text(l10nOf(context).uiAllChats398E5B),
                      selected: _activeFolderId == 'all',
                      onSelected: (_) => setState(() {
                        _activeFolderId = 'all';
                        _source = 'all';
                      }),
                    ),
                  for (final folder in widget.controller.chatFolders) ...[
                    const SizedBox(width: 8),
                    GestureDetector(
                      onLongPress: () => _editFolder(folder),
                      child: InputChip(
                        label: Text(folder.name),
                        selected: _activeFolderId == folder.id,
                        // Folders hold Conest chats.
                        onSelected: (_) => setState(() {
                          _activeFolderId = folder.id;
                          _source = 'all';
                        }),
                        onDeleted: () async {
                          await widget.controller.deleteChatFolder(folder.id);
                          if (mounted && _activeFolderId == folder.id) {
                            setState(() => _activeFolderId = 'all');
                          }
                        },
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: Text(l10nOf(context).uiNewFolderA71199),
                    onPressed: _createFolder,
                  ),
                ],
              ),
            ),
          if (_activeFolderId != 'all' && query.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _activeFolderId = 'all'),
                icon: const Icon(Icons.search),
                label: Text(l10nOf(context).uiSearchAllChatsC825C8),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              key: const ValueKey('courier-search'),
              controller: _search,
              focusNode: _searchFocus,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10nOf(context).searchChatsAndMessages,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l10nOf(context).uiClearSearch67300D,
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(_search.clear),
                      ),
                filled: true,
                fillColor: widget.palette.panel2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                if (!_showArchived &&
                    query.isEmpty &&
                    widget.controller.pendingContactRequests.isNotEmpty)
                  ListTile(
                    leading: Icon(
                      Icons.person_add_alt_1_outlined,
                      color: widget.palette.primary,
                    ),
                    title: Text(l10nOf(context).uiContactRequests082691),
                    subtitle: Text(
                      l10nOf(context).uiReviewPeopleWhoWantTo24A8CB,
                    ),
                    trailing: Badge(
                      label: Text(
                        "${(widget.controller.pendingContactRequests.length)}",
                      ),
                    ),
                    onTap: _showRequests,
                  ),
                if (!_showArchived && query.isEmpty && archivedCount > 0)
                  ListTile(
                    leading: const Icon(Icons.archive_outlined),
                    title: Text(l10nOf(context).archivedChats),
                    trailing: Text("${(archivedCount)}"),
                    onTap: () => setState(() => _showArchived = true),
                  ),
                if (!_showArchived &&
                    showConest &&
                    'saved messages'.contains(query))
                  _savedMessagesRow(
                    widget.controller,
                    widget.palette,
                    context: context,
                    selectedContactId: widget.selectedContactId,
                    onSelected: widget.onContactSelected,
                  ),
                if (!_showArchived && showConest && 'lan lobby'.contains(query))
                  _CourierRow(
                    palette: widget.palette,
                    icon: Icons.forum_outlined,
                    title: l10nOf(context).uiLANLobbyC16DC8,
                    preview: l10nOf(context).uiFreeForAllLocalChat5485CC,
                    unread: widget.controller.unreadLanLobbyCount,
                    selected: widget.lanLobbySelected,
                    onTap: widget.onLanLobbySelected,
                  ),
                if (entries.isEmpty &&
                    (query.isEmpty || !'lan lobby'.contains(query)))
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: query.isNotEmpty
                        ? Text(l10nOf(context).uiNoChatsFoundC6BD82)
                        : _showArchived
                        ? Text(l10nOf(context).uiNoArchivedChatsEAE7F0)
                        : !showConest
                        ? Text(l10nOf(context).uiNoMatrixChatsYet23B023)
                        : _EmptyContactsState(palette: widget.palette),
                  ),
                for (final entry in entries)
                  _CourierRow(
                    key: ValueKey('courier-chat-${entry.seed}'),
                    avatar: deltaListAvatar(widget.controller, entry.seed),
                    palette: widget.palette,
                    seed: entry.seed,
                    title: entry.title,
                    preview: query.isEmpty && entry.draft.isNotEmpty
                        ? l10nOf(context).chatDraftPreview(entry.draft)
                        : entry.preview,
                    pinned: entry.pinned,
                    muted: entry.muted,
                    badge: entry.network,
                    onLongPress: entry.network != null
                        ? null
                        : () => unawaited(
                      _chatActions(
                        entry.isGroup
                            ? ConversationKind.group
                            : ConversationKind.direct,
                        entry.seed,
                      ),
                    ),
                    onSecondaryTapDown: entry.network != null
                        ? null
                        : (event) => unawaited(
                      _chatActions(
                        entry.isGroup
                            ? ConversationKind.group
                            : ConversationKind.direct,
                        entry.seed,
                        at: event.globalPosition,
                      ),
                    ),
                    at: entry.at,
                    unread: entry.unread,
                    selected: entry.selected,
                    isGroup: entry.isGroup,
                    memberCount: entry.memberCount,
                    reachability: entry.reachability,
                    onTap: entry.onTap,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Contact picker shared by the drawer and the floating compose action.
class _CourierNewChatScreen extends StatefulWidget {
  const _CourierNewChatScreen({
    required this.controller,
    required this.palette,
  });
  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<_CourierNewChatScreen> createState() => _CourierNewChatScreenState();
}

class _CourierNewChatScreenState extends State<_CourierNewChatScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: widget.palette.panel,
      appBar: AppBar(
        title: Text(l10nOf(context).uiNewMessage1ED2E7),
        backgroundColor: widget.palette.panel,
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final query = _search.text.trim().toLowerCase();
          final contacts =
              widget.controller.contacts
                  .where(
                    (contact) => contact.alias.toLowerCase().contains(query),
                  )
                  .toList()
                ..sort(
                  (a, b) =>
                      a.alias.toLowerCase().compareTo(b.alias.toLowerCase()),
                );
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: l10nOf(context).searchContacts,
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: l10nOf(context).uiClearSearch67300D,
                                icon: const Icon(Icons.close),
                                onPressed: () => setState(_search.clear),
                              ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        if (query.isEmpty) ...[
                          ListTile(
                            leading: const Icon(Icons.group_add_outlined),
                            title: Text(l10nOf(context).uiNewGroupF9850C),
                            onTap: () => Navigator.pop(context, 'group'),
                          ),
                          ListTile(
                            leading: const Icon(Icons.person_add_alt_1),
                            title: Text(l10nOf(context).contactAdd),
                            onTap: () => Navigator.pop(context, 'contact'),
                          ),
                          ListTile(
                            leading: const Icon(Icons.center_focus_strong),
                            title: Text(
                              l10nOf(context).uiAddWithConestBeam19D1E2,
                            ),
                            onTap: () => Navigator.pop(context, 'beam'),
                          ),
                          const Divider(),
                        ],
                        if (contacts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              query.isEmpty
                                  ? l10nOf(context).uiAddAContactToStart165431
                                  : l10nOf(context).uiNoContactsFound816015,
                            ),
                          ),
                        for (final contact in contacts)
                          ListTile(
                            leading: SealAvatar(
                              seed: contact.deviceId,
                              label: contact.alias,
                              palette: widget.palette,
                              size: 48,
                            ),
                            title: Text(contact.alias),
                            subtitle: Text(
                              reachabilityLabel(
                                context,
                                widget.controller.reachabilityStateFor(
                                  contact.deviceId,
                                ),
                              ),
                            ),
                            onTap: () => Navigator.pop(context, contact),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One Telegram-style row in the [_CourierHome] list.

/// The Saved messages entry pinned above every chat list; it opens like a
/// contact (this device itself).
Widget _savedMessagesRow(
  MessengerController controller,
  ConestPalette palette, {
  required BuildContext context,
  required String? selectedContactId,
  required ValueChanged<ContactRecord> onSelected,
}) {
  final saved = controller.savedMessagesContact;
  if (saved == null) return const SizedBox.shrink();
  final last = controller.messagesFor(saved.deviceId).lastOrNull;
  return _CourierRow(
    key: const ValueKey('saved-messages-row'),
    palette: palette,
    icon: Icons.bookmark_outline,
    title: l10nOf(context).uiSavedMessagesC0FA7E,
    preview: last?.bodyPreview ?? l10nOf(context).savedMessagesPreview,
    unread: 0,
    pinned: true,
    selected: selectedContactId == saved.deviceId,
    onTap: () => onSelected(saved),
  );
}

class _CourierRow extends StatelessWidget {
  const _CourierRow({
    super.key,
    required this.palette,
    required this.title,
    required this.preview,
    required this.unread,
    required this.selected,
    required this.onTap,
    this.seed,
    this.avatar,
    this.icon,
    this.at,
    this.isGroup = false,
    this.memberCount = 0,
    this.reachability,
    this.pinned = false,
    this.muted = false,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.badge,
  });

  /// A short source marker after the title, for example "Matrix".
  final String? badge;
  final bool pinned;
  final bool muted;
  final VoidCallback? onLongPress;
  final GestureTapDownCallback? onSecondaryTapDown;
  final ConestPalette palette;
  final String title;
  final String preview;
  final int unread;
  final bool selected;
  final VoidCallback onTap;
  final String? seed;
  final Widget? avatar;
  final IconData? icon;
  final DateTime? at;
  final bool isGroup;
  final int memberCount;
  final ContactReachabilityState? reachability;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Container(
        color: selected ? palette.selection : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            if (seed != null)
              SizedBox(
                width: 44,
                height: 44,
                child: Stack(
                  children: [
                    avatar ??
                        SealAvatar(
                          seed: seed!,
                          palette: palette,
                          size: 44,
                          label: title,
                        ),
                    if (isGroup && memberCount > 0)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: palette.secondary,
                            borderRadius: BorderRadius.circular(
                              ConestPalette.radiusSm,
                            ),
                          ),
                          child: Text(
                            "${(memberCount)}",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              )
            else
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: palette.panel2,
                  shape: BoxShape.circle,
                  border: Border.all(color: palette.border),
                ),
                child: Icon(icon, color: palette.primary, size: 22),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (badge != null)
                        Container(
                          margin: const EdgeInsetsDirectional.only(end: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: palette.secondary.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            badge!,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: palette.secondary,
                            ),
                          ),
                        ),
                      if (muted)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: Icon(
                            Icons.notifications_off,
                            size: 14,
                            color: palette.inkSoft,
                          ),
                        ),
                      if (pinned)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: Icon(
                            Icons.push_pin,
                            size: 14,
                            color: palette.inkSoft,
                          ),
                        ),
                      if (at != null)
                        Text(
                          formatTimestamp(at!),
                          style: TextStyle(
                            fontFamily: ConestPalette.monoFont,
                            fontSize: 10,
                            color: palette.inkSoft,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: palette.inkSoft,
                                fontWeight: unread > 0
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                        ),
                      ),
                      if (reachability != null) ...[
                        const SizedBox(width: 6),
                        _CourierPresenceMark(
                          state: reachability!,
                          palette: palette,
                        ),
                      ],
                      if (unread > 0) ...[
                        const SizedBox(width: 6),
                        _UnreadBadge(
                          count: unread,
                          palette: palette,
                          compact: true,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact dot + label presence marker for [_CourierRow] chat list entries.
class _CourierPresenceMark extends StatelessWidget {
  const _CourierPresenceMark({required this.state, required this.palette});

  final ContactReachabilityState state;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    final accent = switch (state) {
      ContactReachabilityState.online => palette.success,
      ContactReachabilityState.seenRecently => palette.warning,
      ContactReachabilityState.known => palette.inkSoft,
      ContactReachabilityState.unknown => palette.danger,
    };
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            reachabilityLabel(context, state),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: accent,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Garrison shell — a Discord-shaped rail of "cells" (a Home/DMs cell plus
/// one cell per group) and a content column. Home lists the LAN lobby + DM
/// contacts; a group cell shows the group header + members with an open-chat
/// action. Reuses the shared chat panels on tap.
class _GarrisonHome extends StatefulWidget {
  const _GarrisonHome({
    required this.controller,
    required this.palette,
    required this.selectedContactId,
    required this.selectedGroupId,
    required this.lanLobbySelected,
    required this.onContactSelected,
    required this.onGroupSelected,
    required this.onGroupDetails,
    required this.onLanLobbySelected,
    required this.onAddContact,
    required this.onCreateGroup,
    required this.onShowSettings,
    required this.onShowInvite,
    required this.onShowBeam,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final String? selectedContactId;
  final String? selectedGroupId;
  final bool lanLobbySelected;
  final ValueChanged<ContactRecord> onContactSelected;
  final ValueChanged<GroupRecord> onGroupSelected;
  final ValueChanged<GroupRecord> onGroupDetails;
  final VoidCallback onLanLobbySelected;
  final VoidCallback onAddContact;
  final VoidCallback onCreateGroup;
  final Future<void> Function() onShowSettings;
  final Future<void> Function() onShowInvite;
  final Future<void> Function() onShowBeam;

  @override
  State<_GarrisonHome> createState() => _GarrisonHomeState();
}

class _GarrisonHomeState extends State<_GarrisonHome> {
  String? _cellGroupId; // null = the Home / DMs cell.

  MessengerController get controller => widget.controller;
  ConestPalette get palette => widget.palette;

  GroupRecord? _activeCellGroup(List<GroupRecord> groups) {
    final id = _cellGroupId;
    if (id == null) return null;
    for (final group in groups) {
      if (group.groupId == id) return group;
    }
    return null;
  }

  Widget _railCell({
    required bool selected,
    required Widget child,
    required VoidCallback onTap,
    String? tooltip,
    int unread = 0,
  }) {
    final cell = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 3,
            height: selected ? 30 : 0,
            decoration: BoxDecoration(
              color: palette.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 5),
          Stack(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTap,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: selected ? palette.selection : palette.panel2,
                    borderRadius: BorderRadius.circular(selected ? 14 : 22),
                    border: Border.all(
                      color: selected ? palette.primary : palette.border,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: child,
                ),
              ),
              if (unread > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: palette.secondary,
                      shape: BoxShape.circle,
                      border: Border.all(color: palette.panel, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    return tooltip == null ? cell : Tooltip(message: tooltip, child: cell);
  }

  @override
  Widget build(BuildContext context) {
    final groups = controller.visibleGroups;
    final cellGroup = _activeCellGroup(groups);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 60,
          color: palette.panel,
          child: SafeArea(
            right: false,
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _railCell(
                  selected: _cellGroupId == null,
                  tooltip: l10nOf(context).uiDirectMessagesE7596A,
                  onTap: () => setState(() => _cellGroupId = null),
                  child: Icon(
                    Icons.forum_outlined,
                    color: _cellGroupId == null
                        ? palette.primary
                        : palette.inkSoft,
                    size: 22,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
                  child: Divider(height: 1, color: palette.border),
                ),
                for (final group in groups)
                  _railCell(
                    selected: _cellGroupId == group.groupId,
                    tooltip: group.title,
                    unread: controller.unreadGroupCountFor(group.groupId),
                    onTap: () => setState(() => _cellGroupId = group.groupId),
                    child: SealAvatar(
                      seed: group.groupId,
                      palette: palette,
                      size: 32,
                      label: group.title,
                    ),
                  ),
                _railCell(
                  selected: false,
                  tooltip: l10nOf(context).uiNewGroupF9850C,
                  onTap: widget.onCreateGroup,
                  child: Icon(Icons.add, color: palette.primary, size: 22),
                ),
              ],
            ),
          ),
        ),
        VerticalDivider(width: 1, color: palette.border),
        Expanded(
          child: cellGroup == null
              ? _homeContent(context)
              : _groupContent(context, cellGroup),
        ),
      ],
    );
  }

  Widget _homeContent(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(
            children: [
              Text(
                l10nOf(context).uiDirectMessagesE7596A,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                tooltip: l10nOf(context).uiConestBeamE98B77,
                onPressed: () => unawaited(widget.onShowBeam()),
                icon: const Icon(Icons.center_focus_strong),
              ),
              IconButton(
                tooltip: l10nOf(context).uiMyInviteF80A7A,
                onPressed: () => unawaited(widget.onShowInvite()),
                icon: const Icon(Icons.qr_code_2),
              ),
              IconButton(
                tooltip: l10nOf(context).tabSettings,
                onPressed: () => unawaited(widget.onShowSettings()),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              _savedMessagesRow(
                controller,
                palette,
                context: context,
                selectedContactId: widget.selectedContactId,
                onSelected: widget.onContactSelected,
              ),
              _CourierRow(
                palette: palette,
                icon: Icons.forum_outlined,
                title: l10nOf(context).uiLANLobbyC16DC8,
                preview: l10nOf(context).uiFreeForAllLocalChat5485CC,
                unread: controller.unreadLanLobbyCount,
                selected: widget.lanLobbySelected,
                onTap: widget.onLanLobbySelected,
              ),
              for (final request in controller.pendingContactRequests)
                _PendingContactRequestCard(
                  controller: controller,
                  palette: palette,
                  request: request,
                  compact: true,
                ),
              if (controller.contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _EmptyContactsState(palette: palette),
                ),
              for (final contact in controller.contacts)
                _CourierRow(
                  palette: palette,
                  seed: contact.deviceId,
                  title: contact.alias,
                  preview:
                      controller
                          .lastMessageFor(contact.deviceId)
                          ?.bodyPreview ??
                      'No messages yet',
                  at: controller.lastMessageFor(contact.deviceId)?.createdAt,
                  unread: controller.unreadCountFor(contact.deviceId),
                  selected: widget.selectedContactId == contact.deviceId,
                  onTap: () => widget.onContactSelected(contact),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _groupContent(BuildContext context, GroupRecord group) {
    final memberIds = group.activeMemberDeviceIds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(
            children: [
              SealAvatar(
                seed: group.groupId,
                palette: palette,
                size: 34,
                label: group.title,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  group.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: l10nOf(context).uiGroupDetailsDF844A,
                onPressed: () => widget.onGroupDetails(group),
                icon: const Icon(Icons.groups_2_outlined),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => widget.onGroupSelected(group),
              icon: const Icon(Icons.chat_bubble_outline),
              label: Text(
                l10nOf(context).uiOpenValue8DF02B(
                  (group.title.toLowerCase().replaceAll(' ', '-')).toString(),
                ),
              ),
            ),
          ),
        ),
        MonoSectionLabel(
          palette: palette,
          label: l10nOf(
            context,
          ).uiMembersValue541E72((memberIds.length).toString()),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              for (final deviceId in memberIds)
                ListTile(
                  leading: SealAvatar(
                    seed: deviceId,
                    palette: palette,
                    size: 32,
                    label: controller.groupMemberLabel(deviceId),
                  ),
                  title: Text(controller.groupMemberLabel(deviceId)),
                  subtitle: Text(
                    groupRoleLabel(
                      context,
                      group.roleFor(deviceId) ?? GroupMemberRole.member,
                    ),
                    style: TextStyle(
                      fontFamily: ConestPalette.monoFont,
                      fontSize: 11,
                      color: palette.inkSoft,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.palette,
    required this.homeLayout,
    required this.selectedContactId,
    required this.selectedGroupId,
    required this.lanLobbySelected,
    required this.onAddContact,
    required this.onCreateGroup,
    required this.onLanLobbySelected,
    required this.onGroupSelected,
    required this.onGroupDetails,
    required this.onContactSelected,
    required this.onContactProfile,
    required this.onPoll,
    required this.onShowSettings,
    required this.onShowInvite,
    required this.onShowBeam,
    this.onShowDebug,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final ConestHomeLayout homeLayout;
  final String? selectedContactId;
  final String? selectedGroupId;
  final bool lanLobbySelected;
  final VoidCallback onAddContact;
  final VoidCallback onCreateGroup;
  final VoidCallback onLanLobbySelected;
  final ValueChanged<GroupRecord> onGroupSelected;
  final ValueChanged<GroupRecord> onGroupDetails;
  final ValueChanged<ContactRecord> onContactSelected;
  final ValueChanged<ContactRecord> onContactProfile;
  final Future<void> Function() onPoll;
  final Future<void> Function() onShowSettings;
  final Future<void> Function() onShowInvite;
  final Future<void> Function() onShowBeam;
  final Future<void> Function()? onShowDebug;

  /// Classic layout — a compact one-line list row per contact (seal · name ·
  /// last message · time · unread badge).
  List<Widget> _buildClassicRows(BuildContext context) {
    final rows = <Widget>[];
    for (final contact in controller.contacts) {
      final preview = controller.lastMessageFor(contact.deviceId);
      final unread = controller.unreadCountFor(contact.deviceId);
      final selected = selectedContactId == contact.deviceId;
      rows.add(
        InkWell(
          key: ValueKey('classic-${contact.deviceId}'),
          borderRadius: BorderRadius.circular(ConestPalette.radius),
          onTap: () => onContactSelected(contact),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? palette.selection : Colors.transparent,
              borderRadius: BorderRadius.circular(ConestPalette.radius),
            ),
            child: Row(
              children: [
                SealAvatar(
                  seed: contact.deviceId,
                  palette: palette,
                  size: 38,
                  label: contact.alias,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              contact.alias,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          Text(
                            preview == null
                                ? ''
                                : formatTimestamp(preview.createdAt),
                            style: TextStyle(
                              fontFamily: ConestPalette.monoFont,
                              fontSize: 10,
                              color: palette.inkSoft,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              preview?.bodyPreview ??
                                  l10nOf(context).uiNoMessagesYetC04921,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: palette.inkSoft,
                                    fontWeight: unread > 0
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                  ),
                            ),
                          ),
                          if (unread > 0) ...[
                            const SizedBox(width: 6),
                            _UnreadBadge(
                              count: unread,
                              palette: palette,
                              compact: true,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return rows;
  }

  /// Station Feed — an operator packet-log: the latest activity per peer,
  /// newest first, each a typed event row (time gutter · seal · peer · a
  /// SENT/RECV mono tag · snippet).
  List<Widget> _buildStationFeed(BuildContext context) {
    final entries = <({ContactRecord contact, ChatMessage message})>[];
    for (final contact in controller.contacts) {
      final message = controller.lastMessageFor(contact.deviceId);
      if (message != null) {
        entries.add((contact: contact, message: message));
      }
    }
    entries.sort((a, b) => b.message.createdAt.compareTo(a.message.createdAt));
    if (entries.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            l10nOf(context).uiNoActivityYetPairA7F5366,
            style: TextStyle(
              fontFamily: ConestPalette.monoFont,
              fontSize: 11,
              color: palette.inkSoft,
            ),
          ),
        ),
      ];
    }
    final rows = <Widget>[];
    for (final entry in entries) {
      final outbound = entry.message.outbound;
      final tagColor = outbound ? palette.primary : palette.secondary;
      rows.add(
        InkWell(
          key: ValueKey('feed-${entry.contact.deviceId}'),
          onTap: () => onContactSelected(entry.contact),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 46,
                  child: Text(
                    formatTimestamp(entry.message.createdAt),
                    style: TextStyle(
                      fontFamily: ConestPalette.monoFont,
                      fontSize: 10,
                      color: palette.inkSoft,
                    ),
                  ),
                ),
                SealAvatar(
                  seed: entry.contact.deviceId,
                  palette: palette,
                  size: 30,
                  label: entry.contact.alias,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              entry.contact.alias,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: tagColor.withValues(alpha: 0.5),
                              ),
                              borderRadius: BorderRadius.circular(
                                ConestPalette.radiusSm,
                              ),
                            ),
                            child: Text(
                              outbound
                                  ? l10nOf(context).uiSENT5AD0CD
                                  : l10nOf(context).uiRECVBFC296,
                              style: TextStyle(
                                fontFamily: ConestPalette.monoFont,
                                fontSize: 8,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w700,
                                color: tagColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.message.bodyPreview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      rows.add(
        Divider(height: 1, color: palette.border.withValues(alpha: 0.4)),
      );
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final identity = controller.identity!;
    final lanLobbyUnreadCount = controller.unreadLanLobbyCount;
    final localRelayLabel = controller.localRelayRunning
        ? 'LAN node :${identity.localRelayPort}'
        : 'LAN node unavailable';
    final primaryRelayLabel = identity.primaryRelayRoute == null
        ? null
        : controller.relayDisplayLabel(identity.primaryRelayRoute!);
    final internetRelayLabel = identity.hasInternetRelay
        ? identity.configuredRelays.length == 1
              ? 'internet $primaryRelayLabel'
              : 'internet $primaryRelayLabel +${identity.configuredRelays.length - 1}'
        : 'internet relay optional';
    final lanSummary = identity.lanAddresses.isEmpty
        ? 'no LAN address detected'
        : 'LAN ${identity.lanAddresses.take(2).join(', ')}';
    return StableScrollbar(
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          StatusStrip(
            palette: palette,
            title: l10nOf(context).uiNodeOnlineFAC64A,
            detail:
                '$lanSummary · '
                '${identity.hasInternetRelay ? 'relay ✓' : 'relay optional'} · '
                'vault unlocked',
            dotColor: controller.localRelayRunning
                ? palette.success
                : palette.warning,
            margin: const EdgeInsets.only(bottom: 14),
          ),
          Card(
            elevation: 0,
            color: palette.paperStrong,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(color: palette.stroke),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SealAvatar(
                        seed: identity.deviceId,
                        palette: palette,
                        size: 44,
                        animate: true,
                        label: identity.displayName,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              identity.displayName,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            Text(
                              l10nOf(context).uiDeviceValue11AEA9(
                                (identity.deviceIdShort).toString(),
                              ),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: palette.inkSoft),
                            ),
                          ],
                        ),
                      ),
                      if (onShowDebug != null)
                        IconButton(
                          onPressed: onShowDebug,
                          icon: const Icon(Icons.bug_report_outlined),
                          tooltip: l10nOf(context).uiDebugBD604D,
                        ),
                      IconButton(
                        onPressed: onShowSettings,
                        icon: const Icon(Icons.settings_outlined),
                        tooltip: l10nOf(context).tabSettings,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _StatusChip(
                    label: controller.lastRelayStatus,
                    palette: palette,
                    icon: Icons.route,
                    expand: true,
                  ),
                  const SizedBox(height: 8),
                  _StatusChip(
                    label: localRelayLabel,
                    palette: palette,
                    icon: Icons.lan_outlined,
                    expand: true,
                  ),
                  const SizedBox(height: 8),
                  _StatusChip(
                    label: internetRelayLabel,
                    palette: palette,
                    icon: Icons.cloud_outlined,
                    expand: true,
                  ),
                  const SizedBox(height: 8),
                  _StatusChip(
                    label: lanSummary,
                    palette: palette,
                    icon: Icons.wifi_tethering,
                    expand: true,
                  ),
                  const SizedBox(height: 8),
                  _StatusChip(
                    label: l10nOf(context).uiSafetyValueC542B8(
                      (identity.shortSafetyNumber).toString(),
                    ),
                    palette: palette,
                    icon: Icons.verified_user_outlined,
                    expand: true,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onShowInvite,
                          icon: const Icon(Icons.qr_code_2),
                          label: Text(l10nOf(context).uiMyInviteF80A7A),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: onAddContact,
                          icon: const Icon(Icons.person_add_alt_1),
                          label: Text(l10nOf(context).uiAdd61CC55),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onShowBeam,
                      icon: const Icon(Icons.center_focus_strong),
                      label: Text(l10nOf(context).uiConestBeamE98B77),
                    ),
                  ),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: onPoll,
                    icon: const Icon(Icons.sync),
                    label: Text(l10nOf(context).uiPollRoutesNow22318F),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (controller.savedMessagesContact != null) ...[
            _savedMessagesRow(
              controller,
              palette,
              context: context,
              selectedContactId: selectedContactId,
              onSelected: onContactSelected,
            ),
            const SizedBox(height: 8),
          ],
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onLanLobbySelected,
            child: Ink(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: lanLobbySelected
                    ? palette.selection
                    : palette.paperStrong,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: lanLobbySelected ? palette.primary : palette.stroke,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: palette.primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.forum_outlined, color: palette.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10nOf(context).uiLANLobbyC16DC8,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10nOf(context).uiFreeForAllLocalChat5485CC,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  if (lanLobbyUnreadCount > 0) ...[
                    const SizedBox(width: 8),
                    _UnreadBadge(count: lanLobbyUnreadCount, palette: palette),
                  ],
                  Text(
                    "${(controller.lanLobbyMessages.length)}",
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: palette.inkSoft),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                l10nOf(context).uiGroupsAE9629,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                onPressed: controller.contacts.isEmpty ? null : onCreateGroup,
                icon: const Icon(Icons.group_add_outlined),
                tooltip: l10nOf(context).groupCreate,
              ),
              Text(
                "${(controller.visibleGroups.length)}",
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: palette.inkSoft),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (controller.visibleGroups.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                controller.contacts.isEmpty
                    ? l10nOf(context).uiAddTrustedContactsBeforeCreating1084CC
                    : l10nOf(context).uiNoGroupsYet5009C6,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
              ),
            )
          else
            for (
              var index = 0;
              index < controller.visibleGroups.length;
              index++
            ) ...[
              if (index > 0) const SizedBox(height: 8),
              Builder(
                // Stable identity so a reorder/insert can't transiently hand
                // this slot another group's element.
                key: ValueKey(controller.visibleGroups[index].groupId),
                builder: (context) {
                  final group = controller.visibleGroups[index];
                  final preview = controller.lastGroupMessageFor(group.groupId);
                  final unreadCount = controller.unreadGroupCountFor(
                    group.groupId,
                  );
                  final selected = selectedGroupId == group.groupId;
                  final myDeviceId = controller.identity?.deviceId ?? '';
                  final hasLeft =
                      myDeviceId.isNotEmpty &&
                      !group.hasActiveMember(myDeviceId);
                  return InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => onGroupSelected(group),
                    child: Ink(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: selected
                            ? palette.selection
                            : palette.paperStrong,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: selected ? palette.primary : palette.stroke,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  group.title,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              if (hasLeft) ...[
                                const SizedBox(width: 8),
                                _GroupLeftBadge(palette: palette),
                              ],
                              if (unreadCount > 0) ...[
                                const SizedBox(width: 8),
                                _UnreadBadge(
                                  count: unreadCount,
                                  palette: palette,
                                  compact: true,
                                ),
                              ],
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                onPressed: () => onGroupDetails(group),
                                icon: const Icon(Icons.groups_2_outlined),
                                tooltip: l10nOf(context).uiGroupDetailsDF844A,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10nOf(context).uiValueMemberSE75249(
                              (group.activeMemberDeviceIds.length),
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: palette.inkSoft),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            preview == null
                                ? l10nOf(context).uiNoMessagesYetC04921
                                : preview.bodyPreview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontWeight: unreadCount > 0
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          const SizedBox(height: 16),
          for (final request in controller.pendingContactRequests) ...[
            _PendingContactRequestCard(
              controller: controller,
              palette: palette,
              request: request,
            ),
            const SizedBox(height: 10),
          ],
          // The "Contacts · 0" header above an empty-state card is redundant —
          // show the header only when there is something to count.
          if (controller.contacts.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _EmptyContactsState(palette: palette),
            )
          else ...[
            Row(
              children: [
                Text(
                  l10nOf(context).uiContactsB0DD61,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  "${(controller.contacts.length)}",
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(color: palette.inkSoft),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (homeLayout == ConestHomeLayout.classic)
              ..._buildClassicRows(context)
            else if (homeLayout == ConestHomeLayout.stationFeed)
              ..._buildStationFeed(context)
            else
              for (
                var index = 0;
                index < controller.contacts.length;
                index++
              ) ...[
                if (index > 0) const SizedBox(height: 8),
                Builder(
                  key: ValueKey(controller.contacts[index].deviceId),
                  builder: (context) {
                    final contact = controller.contacts[index];
                    final preview = controller.lastMessageFor(contact.deviceId);
                    final unreadCount = controller.unreadCountFor(
                      contact.deviceId,
                    );
                    final reachabilityState = controller.reachabilityStateFor(
                      contact.deviceId,
                    );
                    final selected = selectedContactId == contact.deviceId;
                    return InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => onContactSelected(contact),
                      child: Ink(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: selected
                              ? palette.selection
                              : palette.paperStrong,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: selected ? palette.primary : palette.stroke,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SealAvatar(
                              seed: contact.deviceId,
                              palette: palette,
                              size: 44,
                              label: contact.alias,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          contact.alias,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      TrustChip(
                                        palette: palette,
                                        kind: TrustChipKind.e2ee,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        contact.shortSafetyNumber,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall
                                            ?.copyWith(
                                              fontFamily:
                                                  ConestPalette.monoFont,
                                              color: palette.inkSoft,
                                            ),
                                      ),
                                      if (unreadCount > 0) ...[
                                        const SizedBox(width: 8),
                                        _UnreadBadge(
                                          count: unreadCount,
                                          palette: palette,
                                          compact: true,
                                        ),
                                      ],
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () =>
                                            onContactProfile(contact),
                                        icon: const Icon(Icons.badge_outlined),
                                        tooltip: l10nOf(
                                          context,
                                        ).uiContactProfile1B3A0E,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  _ReachabilityChip(
                                    state: reachabilityState,
                                    palette: palette,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    contact.routeSummary,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: palette.inkSoft),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    preview == null
                                        ? l10nOf(context).uiNoMessagesYetC04921
                                        : preview.bodyPreview,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          fontWeight: unreadCount > 0
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
          ],
          if (controller.statusMessage != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                localizedUiText(context, controller.statusMessage!),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
              ),
            ),
          ],
          const SizedBox(height: 18),
        ],
      ),
    );
  }
}

class CreateGroupDialog extends StatefulWidget {
  const CreateGroupDialog({
    super.key,
    this.fullscreenOnMobile = false,
    required this.controller,
    required this.palette,
  });

  final bool fullscreenOnMobile;
  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<CreateGroupDialog> {
  final _titleController = TextEditingController();
  final Set<String> _selectedDeviceIds = <String>{};
  final Map<String, GroupMemberRole> _selectedRoles =
      <String, GroupMemberRole>{};
  bool _creating = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating) {
      return;
    }
    setState(() => _creating = true);
    try {
      final members = widget.controller.contacts
          .where((contact) => _selectedDeviceIds.contains(contact.deviceId))
          .toList(growable: false);
      final group = await widget.controller.createGroup(
        title: _titleController.text,
        members: members,
        adminDeviceIds: _selectedRoles.entries
            .where((entry) => entry.value == GroupMemberRole.admin)
            .map((entry) => entry.key)
            .toList(growable: false),
        moderatorDeviceIds: _selectedRoles.entries
            .where((entry) => entry.value == GroupMemberRole.moderator)
            .map((entry) => entry.key)
            .toList(growable: false),
      );
      if (mounted) {
        Navigator.of(context).pop(group);
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
      if (mounted) {
        setState(() => _creating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = widget.controller.contacts;
    final canCreate =
        _titleController.text.trim().isNotEmpty &&
        _selectedDeviceIds.isNotEmpty &&
        !_creating;
    return AdaptiveChatDialog(
      fullscreenOnMobile: widget.fullscreenOnMobile,
      title: Text(l10nOf(context).groupCreate),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: l10nOf(context).groupTitle,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final contact in contacts)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Checkbox(
                        value: _selectedDeviceIds.contains(contact.deviceId),
                        onChanged:
                            _selectedDeviceIds.length >= 15 &&
                                !_selectedDeviceIds.contains(contact.deviceId)
                            ? null
                            : (value) {
                                setState(() {
                                  if (value == true) {
                                    _selectedDeviceIds.add(contact.deviceId);
                                    _selectedRoles[contact.deviceId] =
                                        GroupMemberRole.member;
                                  } else {
                                    _selectedDeviceIds.remove(contact.deviceId);
                                    _selectedRoles.remove(contact.deviceId);
                                  }
                                });
                              },
                      ),
                      title: Text(contact.alias),
                      subtitle: Text(contact.shortSafetyNumber),
                      trailing: _selectedDeviceIds.contains(contact.deviceId)
                          ? DropdownButton<GroupMemberRole>(
                              value:
                                  _selectedRoles[contact.deviceId] ??
                                  GroupMemberRole.member,
                              onChanged: (role) {
                                if (role == null) {
                                  return;
                                }
                                setState(() {
                                  _selectedRoles[contact.deviceId] = role;
                                });
                              },
                              items: [
                                DropdownMenuItem(
                                  value: GroupMemberRole.member,
                                  child: Text(l10nOf(context).roleMember),
                                ),
                                DropdownMenuItem(
                                  value: GroupMemberRole.moderator,
                                  child: Text(l10nOf(context).roleModerator),
                                ),
                                DropdownMenuItem(
                                  value: GroupMemberRole.admin,
                                  child: Text(l10nOf(context).roleAdmin),
                                ),
                              ],
                            )
                          : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _creating ? null : () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionCancel),
        ),
        FilledButton(
          onPressed: canCreate ? _create : null,
          child: Text(
            _creating
                ? l10nOf(context).actionCreating
                : l10nOf(context).actionCreate,
          ),
        ),
      ],
    );
  }
}

class GroupDetailsDialog extends StatefulWidget {
  const GroupDetailsDialog({
    super.key,
    this.fullscreenOnMobile = false,
    required this.controller,
    required this.palette,
    required this.group,
  });

  final bool fullscreenOnMobile;
  final MessengerController controller;
  final ConestPalette palette;
  final GroupRecord group;

  @override
  State<GroupDetailsDialog> createState() => _GroupDetailsDialogState();
}

enum _DeleteGroupChoice { cancel, transfer, delete }

class _GroupDetailsDialogState extends State<GroupDetailsDialog> {
  bool _savingHistoryVisibility = false;
  Future<void> _editHistoryVisibility() async {
    setState(() => _savingHistoryVisibility = true);
    try {
      final includeEarlier = await widget.controller
          .groupHistoryIncludesEarlierMessages(group.groupId);
      if (!mounted) return;
      final selected = await showDialog<bool>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(l10nOf(context).uiHistoryForNewMembersF419F2),
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                l10nOf(context).uiAppliesToFutureAdmissionsHistory78E3A0,
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                l10nOf(context).uiValueAllRetainedHistory5E25F4(
                  (includeEarlier ? '✓ ' : '').toString(),
                ),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                l10nOf(context).uiValueSinceAdmissionB2617B(
                  (!includeEarlier ? '✓ ' : '').toString(),
                ),
              ),
            ),
          ],
        ),
      );
      if (selected != null && selected != includeEarlier) {
        await widget.controller.setGroupHistoryIncludesEarlierMessages(
          group.groupId,
          selected,
        );
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    } finally {
      if (mounted) setState(() => _savingHistoryVisibility = false);
    }
  }

  GroupRecord get group {
    for (final candidate in widget.controller.groups) {
      if (candidate.groupId == widget.group.groupId) {
        return candidate;
      }
    }
    return widget.group;
  }

  String? get _currentDeviceId => widget.controller.identity?.deviceId;

  bool get _canAssignRoles =>
      widget.controller.canAssignGroupRoles(group.groupId);

  bool get _canAddMembers =>
      widget.controller.canAddGroupMembers(group.groupId);

  Future<void> _addMember(ContactRecord contact) async {
    try {
      await widget.controller.addGroupMembers(
        groupId: group.groupId,
        members: [contact],
      );
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  Future<void> _removeMember(String deviceId) async {
    try {
      await widget.controller.removeGroupMember(
        groupId: group.groupId,
        memberDeviceId: deviceId,
      );
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  Future<void> _setRole(String deviceId, GroupMemberRole role) async {
    try {
      await widget.controller.setGroupMemberRole(
        groupId: group.groupId,
        memberDeviceId: deviceId,
        role: role,
      );
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  Future<void> _leave() async {
    try {
      await widget.controller.leaveGroup(group.groupId);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  Future<void> _deleteGroup() async {
    final choice = await showDialog<_DeleteGroupChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiDeleteValueF0396B((group.title).toString())),
        content:  Text(
          l10nOf(context).uiChooseHowToWindDownF7399D,
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.cancel),
            child: Text(l10nOf(context).actionCancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.transfer),
            child: Text(l10nOf(context).uiTransferOwnershipA563C9),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.delete),
            child: Text(l10nOf(context).uiDeleteForEveryoneE055A8),
          ),
        ],
      ),
    );
    if (choice == null || choice == _DeleteGroupChoice.cancel) {
      return;
    }
    if (choice == _DeleteGroupChoice.transfer) {
      await _transferOwnership();
      return;
    }
    await _dissolve();
  }

  Future<void> _transferOwnership() async {
    final currentDeviceId = _currentDeviceId;
    if (currentDeviceId == null) {
      return;
    }
    final candidates = group.activeMemberDeviceIds
        .where((deviceId) => deviceId != currentDeviceId)
        .toList(growable: false);
    if (candidates.isEmpty) {
      widget.controller.setStatus(
        'No other active members to transfer ownership to.',
      );
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (context) {
        String? selected = candidates.first;
        return StatefulBuilder(
          builder: (context, setLocalState) => AlertDialog(
            title: Text(l10nOf(context).uiTransferOwnershipA6819E),
            content: SizedBox(
              width: 360,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final deviceId in candidates)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(_roleIcon(group.roleFor(deviceId))),
                      title: Text(widget.controller.groupMemberLabel(deviceId)),
                      subtitle: Text(
                        groupRoleLabel(
                          context,
                          group.roleFor(deviceId) ?? GroupMemberRole.member,
                        ),
                      ),
                      trailing: Icon(
                        selected == deviceId
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      onTap: () => setLocalState(() => selected = deviceId),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10nOf(context).actionCancel),
              ),
              FilledButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.of(context).pop(selected),
                child: Text(l10nOf(context).uiTransferCBB4CC),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null) {
      return;
    }
    try {
      await widget.controller.transferGroupOwnership(
        groupId: group.groupId,
        newOwnerDeviceId: picked,
      );
      widget.controller.setStatus(
        'Ownership transferred to ${widget.controller.groupMemberLabel(picked)}.',
      );
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  Future<void> _dissolve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiDeleteValueForEveryone12E724((group.title).toString())),
        content:  Text(
          l10nOf(context).uiEveryMemberWillBeRemoved75A3FC,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).uiDeleteForEveryoneE055A8),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.controller.dissolveGroup(group.groupId);
      if (mounted) {
        setState(() {});
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  Future<void> _removeFromList() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiRemoveThisGroup38C4E8),
        content: Text(l10nOf(context).uiRemoveThisGroupFromYourDA7898),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).uiRemoveE96390),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.controller.removeGroupFromList(group.groupId);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  IconData _roleIcon(GroupMemberRole? role) {
    return switch (role) {
      GroupMemberRole.owner => Icons.verified_user_outlined,
      GroupMemberRole.admin => Icons.admin_panel_settings_outlined,
      GroupMemberRole.moderator => Icons.shield_outlined,
      GroupMemberRole.member || null => Icons.person_outline,
    };
  }

  /// Asks a member who is not a contact to become one (an ordinary
  /// contact request, sent with the keys and routes the group knows).
  Future<void> _addAsContact(String deviceId) async {
    try {
      await widget.controller.requestContactFromGroup(
        groupId: group.groupId,
        memberDeviceId: deviceId,
      );
      if (mounted) setState(() {});
    } catch (error) {
      widget.controller.setStatus(error.toString());
    }
  }

  Widget? _memberTrailing(String deviceId, GroupMemberRole? role) {
    final canChangeRole =
        _canAssignRoles && role != null && role != GroupMemberRole.owner;
    final canRemove =
        deviceId != _currentDeviceId &&
        widget.controller.canRemoveGroupMember(group.groupId, deviceId);
    final canAdd =
        deviceId != _currentDeviceId &&
        !widget.controller.contacts.any((c) => c.deviceId == deviceId);
    if (!canChangeRole && !canRemove && !canAdd) {
      return null;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canAdd)
          IconButton(
            key: ValueKey('group-add-contact-$deviceId'),
            onPressed: () => _addAsContact(deviceId),
            icon: const Icon(Icons.person_add_alt_1_outlined),
            tooltip: l10nOf(context).contactAdd,
          ),
        if (canChangeRole)
          PopupMenuButton<GroupMemberRole>(
            tooltip: l10nOf(context).uiChangeRole2B9BFD,
            icon: const Icon(Icons.manage_accounts_outlined),
            initialValue: role,
            onSelected: (value) => _setRole(deviceId, value),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: GroupMemberRole.member,
                child: Text(l10nOf(context).roleMember),
              ),
              PopupMenuItem(
                value: GroupMemberRole.moderator,
                child: Text(l10nOf(context).roleModerator),
              ),
              PopupMenuItem(
                value: GroupMemberRole.admin,
                child: Text(l10nOf(context).roleAdmin),
              ),
            ],
          ),
        if (canRemove)
          IconButton(
            onPressed: () => _removeMember(deviceId),
            icon: const Icon(Icons.person_remove_outlined),
            tooltip: l10nOf(context).uiRemoveMember1C31D1,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeIds = group.activeMemberDeviceIds;
    final addable = widget.controller.contacts
        .where((contact) => !activeIds.contains(contact.deviceId))
        .toList(growable: false);
    final myId = widget.controller.identity?.deviceId;
    String mapLabel(String id) {
      final name = widget.controller.groupMemberLabel(id).trim();
      if (name.isEmpty) return '?';
      final parts = name
          .split(RegExp(r'\s+'))
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.length >= 2) {
        return (parts[0][0] + parts[1][0]).toUpperCase();
      }
      return name.substring(0, name.length >= 2 ? 2 : 1).toUpperCase();
    }

    final trustNodes = [
      for (final deviceId in activeIds)
        if (deviceId != myId)
          TrustMapNode(
            label: mapLabel(deviceId),
            trusted: widget.controller.contacts.any(
              (c) => c.deviceId == deviceId && !c.pendingVerification,
            ),
          ),
    ];
    return AdaptiveChatDialog(
      fullscreenOnMobile: widget.fullscreenOnMobile,
      title: Text(group.title),
      content: SizedBox(
        width: 460,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              l10nOf(context).uiValueMemberSOwnerValueE42E13(
                (activeIds.length),
                (widget.controller.groupMemberLabel(
                  group.ownerDeviceId,
                )).toString(),
              ),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: widget.palette.inkSoft),
            ),
            const SizedBox(height: 12),
            for (final deviceId in activeIds)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(_roleIcon(group.roleFor(deviceId))),
                title: Text(widget.controller.groupMemberLabel(deviceId)),
                subtitle: Text(
                  groupRoleLabel(
                    context,
                    group.roleFor(deviceId) ?? GroupMemberRole.member,
                  ),
                ),
                trailing: _memberTrailing(deviceId, group.roleFor(deviceId)),
              ),
            if (myId == group.ownerDeviceId && !group.isDissolved)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history),
                title: Text(l10nOf(context).uiHistoryForNewMembersF419F2),
                subtitle: Text(
                  l10nOf(context).uiChooseWhatFutureMembersCanC38992,
                ),
                onTap: _savingHistoryVisibility ? null : _editHistoryVisibility,
                trailing: _savingHistoryVisibility
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
              ),
            // Trust fanout sits below the member list so the role rows render
            // first (and aren't pushed out of a constrained dialog viewport).
            if (trustNodes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Center(
                child: TrustMap(
                  palette: widget.palette,
                  members: trustNodes,
                  size: 220,
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  l10nOf(context).uiGROUPTRUSTFANOUTMintPaired5DDF6E,
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 10,
                    letterSpacing: 1,
                    color: widget.palette.inkSoft,
                  ),
                ),
              ),
            ],
            if (_canAddMembers && addable.isNotEmpty) ...[
              const Divider(),
              Text(
                l10nOf(context).uiAddTrustedContact126717,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              for (final contact in addable)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(contact.alias),
                  subtitle: Text(contact.shortSafetyNumber),
                  trailing: IconButton(
                    onPressed: activeIds.length >= 16
                        ? null
                        : () => _addMember(contact),
                    icon: const Icon(Icons.person_add_alt_1),
                    tooltip: l10nOf(context).uiAddMember170AD0,
                  ),
                ),
            ],
          ],
        ),
      ),
      actions: [
        if (_currentDeviceId != null &&
            group.roleFor(_currentDeviceId!) == GroupMemberRole.owner &&
            group.hasActiveMember(_currentDeviceId!))
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _deleteGroup,
            icon: const Icon(Icons.delete_forever_outlined),
            label: Text(l10nOf(context).uiDeleteGroup043336),
          )
        else if (_currentDeviceId != null &&
            group.roleFor(_currentDeviceId!) != GroupMemberRole.owner &&
            group.hasActiveMember(_currentDeviceId!))
          TextButton.icon(
            onPressed: _leave,
            icon: const Icon(Icons.logout),
            label: Text(l10nOf(context).uiLeave7E3520),
          )
        else if (_currentDeviceId != null &&
            !group.hasActiveMember(_currentDeviceId!) &&
            group.localRemovedAt == null)
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _removeFromList,
            icon: const Icon(Icons.delete_outline),
            label: Text(l10nOf(context).uiRemoveFromList23A976),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionClose),
        ),
      ],
    );
  }
}

Future<void> _forwardTextMessage(
  BuildContext context,
  MessengerController controller,
  ConestPalette palette,
  ChatMessage message,
) async {
  if (message.hasAttachment || message.body.trim().isEmpty) return;
  await _forwardPlainText(context, controller, palette, message.body);
}

Future<void> _forwardPlainText(
  BuildContext context,
  MessengerController controller,
  ConestPalette palette,
  String text,
) async {
  final destination = await _pickForwardDestination(
    context,
    controller,
    palette,
    title: l10nOf(context).uiForwardMessage482959,
    preview: text,
  );
  if (destination == null) return;
  try {
    await _sendTextTo(controller, destination, text);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10nOf(context).uiForwardedMessageQueuedC82DA4)),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10nOf(context).uiCouldNotForwardValue80193D((error).toString()),
          ),
        ),
      );
    }
  }
}

/// Forwards the selected messages, in chat order, to one chat: texts as
/// texts, files (photos, voice, album items, group files) as files. Files
/// not downloaded yet are left out, and said so.
Future<void> _forwardMessages(
  BuildContext context,
  MessengerController controller,
  ConestPalette palette,
  List<ChatMessage> selected,
) async {
  if (selected.isEmpty) return;
  final strings = l10nOf(context);
  final ordered = [...selected]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final first = ordered.first;
  final destination = await _pickForwardDestination(
    context,
    controller,
    palette,
    title: strings.forwardSelectedTitle(ordered.length),
    preview: first.body.trim().isNotEmpty
        ? first.body
        : first.attachment?.fileName ?? first.groupFile?.fileName ?? '',
  );
  if (destination == null || !context.mounted) return;
  var sent = 0;
  var skipped = 0;
  // Album items forwarded together stay one album at the destination.
  final albums = <String, String>{};
  String? albumFor(ChatMessage message) {
    final id = message.albumId;
    if (id == null || id.isEmpty) return null;
    return albums.putIfAbsent(
      id,
      () => 'forward-album-${DateTime.now().microsecondsSinceEpoch}-$id',
    );
  }

  try {
    for (final message in ordered) {
      if (!context.mounted) return;
      final attachment = message.attachment;
      final groupFile = message.groupFile;
      if (attachment != null) {
        final path = await controller.attachmentCachePathFor(attachment.id);
        if (path == null || !context.mounted) {
          skipped++;
          continue;
        }
        await _sendFileTo(
          context,
          controller,
          destination,
          path: path,
          fileName: attachment.fileName,
          mimeType: attachment.mimeType,
          sizeBytes: attachment.sizeBytes,
          presentation: attachment.presentation,
          voice: attachment.voiceMetadata,
          albumId: albumFor(message),
        );
        sent++;
      } else if (groupFile != null) {
        final path = controller.groupFilePathFor(message.id);
        if (path == null) {
          skipped++;
          continue;
        }
        await _sendFileTo(
          context,
          controller,
          destination,
          path: path,
          fileName: groupFile.fileName,
          mimeType: groupFile.mimeType,
          sizeBytes: groupFile.sizeBytes,
          presentation:
              groupFile.mimeType.startsWith('image/') ||
                  groupFile.mimeType.startsWith('video/')
              ? AttachmentPresentation.media
              : AttachmentPresentation.file,
          voice: groupFile.voiceMetadata,
        );
        sent++;
      } else if (message.body.trim().isNotEmpty) {
        await _sendTextTo(controller, destination, message.body);
        sent++;
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            [
              strings.forwardedSummary(sent),
              if (skipped > 0) strings.forwardSkipped(skipped),
            ].join(' '),
          ),
        ),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.uiCouldNotForwardValue80193D('$error'))),
      );
    }
  }
}

Future<void> _forwardAttachment(
  BuildContext context,
  MessengerController controller,
  ConestPalette palette,
  AttachmentDescriptor descriptor,
) async {
  final path = await controller.attachmentCachePathFor(descriptor.id);
  if (!context.mounted) return;
  if (path == null) {
    controller.setStatus('This attachment is not available locally yet.');
    return;
  }
  await _forwardFile(
    context,
    controller,
    palette,
    path: path,
    fileName: descriptor.fileName,
    mimeType: descriptor.mimeType,
    sizeBytes: descriptor.sizeBytes,
    presentation: descriptor.presentation,
    voice: descriptor.voiceMetadata,
  );
}

/// Forwards a group file this device holds to a chat, a group or Saved
/// messages.
Future<void> _forwardGroupFile(
  BuildContext context,
  MessengerController controller,
  ConestPalette palette,
  ChatMessage message,
) async {
  final manifest = message.groupFile;
  final path = controller.groupFilePathFor(message.id);
  if (manifest == null) return;
  if (path == null) {
    controller.setStatus('Download this file before forwarding it.');
    return;
  }
  await _forwardFile(
    context,
    controller,
    palette,
    path: path,
    fileName: manifest.fileName,
    mimeType: manifest.mimeType,
    sizeBytes: manifest.sizeBytes,
    presentation:
        manifest.mimeType.startsWith('image/') ||
            manifest.mimeType.startsWith('video/')
        ? AttachmentPresentation.media
        : AttachmentPresentation.file,
    voice: manifest.voiceMetadata,
  );
}

/// Where to forward to: a contact, a group, or Saved messages.
Future<Object?> _pickForwardDestination(
  BuildContext context,
  MessengerController controller,
  ConestPalette palette, {
  required String title,
  required String preview,
}) => showDialog<Object>(
  context: context,
  builder: (context) => _ForwardPickerDialog(
    controller: controller,
    palette: palette,
    title: title,
    preview: preview,
  ),
);

class _ForwardPickerDialog extends StatefulWidget {
  const _ForwardPickerDialog({
    required this.controller,
    required this.palette,
    required this.title,
    required this.preview,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final String title;
  final String preview;

  @override
  State<_ForwardPickerDialog> createState() => _ForwardPickerDialogState();
}

class _ForwardPickerDialogState extends State<_ForwardPickerDialog> {
  // Owned here, so it outlives the closing animation.
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final contacts = widget.controller.contacts.where(
      (contact) =>
          contact.canSendOutbound &&
          contact.alias.toLowerCase().contains(query),
    );
    final groups = widget.controller.visibleGroups.where(
      (group) =>
          group.hasActiveMember(widget.controller.identity?.deviceId ?? '') &&
          group.title.toLowerCase().contains(query),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        height: 400,
        child: Column(
          children: [
            Text(widget.preview, maxLines: 3, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),
            TextField(
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: l10nOf(context).searchChats,
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (widget.controller.savedMessagesContact case final saved?
                      when 'saved messages'.contains(query))
                    ListTile(
                      key: const ValueKey('forward-to-saved'),
                      leading: const Icon(Icons.bookmark_outline),
                      title: Text(l10nOf(context).uiSavedMessagesC0FA7E),
                      onTap: () => Navigator.pop(context, saved),
                    ),
                  if (contacts.isEmpty && groups.isEmpty)
                    ListTile(
                      title: Text(l10nOf(context).uiNoAvailableChats1FAA40),
                    ),
                  for (final contact in contacts)
                    ListTile(
                      leading: SealAvatar(
                        seed: contact.deviceId,
                        label: contact.alias,
                        palette: widget.palette,
                        size: 36,
                      ),
                      title: Text(contact.alias),
                      onTap: () => Navigator.pop(context, contact),
                    ),
                  for (final group in groups)
                    ListTile(
                      leading: const Icon(Icons.group_outlined),
                      title: Text(group.title),
                      onTap: () => Navigator.pop(context, group),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10nOf(context).actionCancel),
        ),
      ],
    );
  }
}

/// Sends a file (forwarded) to [destination]. A voice note ([voice]) goes
/// as a voice note, and files sharing an [albumId] arrive as one album.
Future<void> _sendFileTo(
  BuildContext context,
  MessengerController controller,
  Object destination, {
  required String path,
  required String fileName,
  required String mimeType,
  required int sizeBytes,
  required AttachmentPresentation presentation,
  VoiceMessageMetadata? voice,
  String? albumId,
}) async {
  // Voice notes are always Ogg/Opus (their metadata says so), but the
  // stored type loses its "; codecs=opus" and reads as a generic file.
  if (voice != null) mimeType = 'audio/ogg; codecs=opus';
  switch (destination) {
    case ContactRecord contact:
      final source = StagedAttachment(
        id: 'forward-${DateTime.now().microsecondsSinceEpoch}',
        fileName: fileName,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        filePath: path,
        presentation: voice != null
            ? AttachmentPresentation.media
            : presentation,
      );
      if (voice != null) {
        await controller.sendVoiceMessage(
          contact: contact,
          source: source,
          metadata: voice,
        );
      } else {
        await controller.sendAttachmentSource(
          contact: contact,
          source: source,
          albumId: albumId,
        );
      }
    case GroupRecord group:
      if (voice != null) {
        await controller.publishGroupFile(
          groupId: group.groupId,
          path: path,
          fileName: fileName,
          mimeType: mimeType,
          voiceMetadata: voice,
          // Recorded by the app: nothing personal in it.
          keepMetadata: true,
        );
      } else {
        await publishGroupFileAsking(
          context,
          controller,
          groupId: group.groupId,
          path: path,
          fileName: fileName,
          mimeType: mimeType,
        );
      }
  }
}

Future<void> _sendTextTo(
  MessengerController controller,
  Object destination,
  String body,
) async {
  switch (destination) {
    case ContactRecord contact:
      await controller.sendMessage(contact: contact, body: body);
    case GroupRecord group:
      await controller.sendGroupMessage(groupId: group.groupId, body: body);
  }
}

Future<void> _forwardFile(
  BuildContext context,
  MessengerController controller,
  ConestPalette palette, {
  required String path,
  required String fileName,
  required String mimeType,
  required int sizeBytes,
  required AttachmentPresentation presentation,
  VoiceMessageMetadata? voice,
}) async {
  final destination = await _pickForwardDestination(
    context,
    controller,
    palette,
    title: l10nOf(context).menuForwardAttachment,
    preview: fileName,
  );
  if (destination == null || !context.mounted) return;
  try {
    await _sendFileTo(
      context,
      controller,
      destination,
      path: path,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      presentation: presentation,
      voice: voice,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10nOf(context).uiForwardedAttachmentQueued57C88B),
        ),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10nOf(
              context,
            ).uiCouldNotForwardAttachmentValue5165FD((error).toString()),
          ),
        ),
      );
    }
  }
}

class _TelegramChatHeader extends StatelessWidget {
  const _TelegramChatHeader({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.seed,
    required this.onDetails,
    required this.onSearch,
    this.onBack,
    this.onConnectionDetails,
    this.onCall,
  });
  final ConestPalette palette;
  final String title;
  final String subtitle;
  final String seed;
  final VoidCallback onDetails;
  final VoidCallback onSearch;
  final VoidCallback? onBack;
  final VoidCallback? onConnectionDetails;
  final VoidCallback? onCall;

  @override
  Widget build(BuildContext context) => Material(
    color: palette.panel,
    child: SizedBox(
      height: 64,
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              tooltip: l10nOf(context).actionBack,
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onDetails,
              child: Row(
                children: [
                  ClipOval(
                    child: SealAvatar(
                      seed: seed,
                      label: title,
                      palette: palette,
                      size: 42,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: l10nOf(context).uiSearchMessagesABEA65,
            onPressed: onSearch,
            icon: const Icon(Icons.search),
          ),
          if (onCall != null)
            IconButton(
              tooltip: l10nOf(context).uiStartVoiceCallExperimental6DE320,
              onPressed: onCall,
              icon: const Icon(Icons.call_outlined),
            ),
          PopupMenuButton<String>(
            tooltip: l10nOf(context).uiChatOptionsA40D0F,
            icon: const Icon(Icons.more_vert),
            onSelected: (action) =>
                action == 'details' ? onDetails() : onConnectionDetails?.call(),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'details',
                child: Text(l10nOf(context).uiChatDetails15DAEC),
              ),
              if (onConnectionDetails != null)
                PopupMenuItem(
                  value: 'connection',
                  child: Text(l10nOf(context).uiConnectionDetailsAB30A5),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _GroupChatPanel extends StatefulWidget {
  const _GroupChatPanel({
    super.key,
    this.telegramLayout = false,
    required this.controller,
    required this.palette,
    required this.group,
    required this.composerController,
    required this.replyTarget,
    required this.onCancelReply,
    required this.onReplyToMessage,
    required this.onSend,
    required this.onShowDetails,
    required this.onDropFiles,
    this.onAttach,
    this.onScheduleAttachment,
    this.onBack,
    this.onSmartPaste,
    this.onContentInserted,
  });

  final bool telegramLayout;
  final MessengerController controller;
  final ConestPalette palette;
  final GroupRecord group;
  final TextEditingController composerController;
  final ChatMessage? replyTarget;
  final VoidCallback onCancelReply;
  final ValueChanged<ChatMessage> onReplyToMessage;
  final VoidCallback onSend;
  final VoidCallback onShowDetails;
  final ValueChanged<List<XFile>> onDropFiles;
  final VoidCallback? onAttach;
  final VoidCallback? onScheduleAttachment;
  final VoidCallback? onBack;
  final VoidCallback? onSmartPaste;

  /// An image or GIF from the keyboard (Android).
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;

  @override
  State<_GroupChatPanel> createState() => _GroupChatPanelState();
}

/// Plays an unsent recording inside the send/discard dialog with the same
/// position control as sent voice messages, plus playback volume.
class _VoicePreviewPlayer extends StatefulWidget {
  const _VoicePreviewPlayer({
    required this.service,
    required this.recording,
    required this.onError,
  });

  static const itemId = 'voice-preview';

  final VoiceMessageService service;
  final VoiceRecordingResult recording;
  final void Function(Object error) onError;

  @override
  State<_VoicePreviewPlayer> createState() => _VoicePreviewPlayerState();
}

class _VoicePreviewPlayerState extends State<_VoicePreviewPlayer> {
  StreamSubscription<Duration>? _positions;
  Timer? _refresh;
  Duration _position = Duration.zero;

  VoiceMessageService get _service => widget.service;
  bool get _isCurrent => _service.playingItemId == _VoicePreviewPlayer.itemId;

  @override
  void initState() {
    super.initState();
    _positions = _service.playbackPositionStream.listen((position) {
      if (mounted && _isCurrent) setState(() => _position = position);
    });
    // Play/pause and completion do not always emit a position event.
    _refresh = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_positions?.cancel());
    _refresh?.cancel();
    if (_isCurrent) unawaited(_service.stopPlayback());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      widget.onError(error);
    }
    if (mounted) setState(() {});
  }

  Future<void> _seek(double fraction) => _run(() async {
    if (!_isCurrent) await _service.playPreview();
    final target = Duration(
      milliseconds: (fraction * widget.recording.metadata.durationMs).round(),
    );
    setState(() => _position = target);
    await _service.seekPlayback(target);
  });

  static String _clock(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final total = Duration(milliseconds: widget.recording.metadata.durationMs);
    final position = _isCurrent ? _position : Duration.zero;
    final fraction = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final playing = _isCurrent && _service.isPlaying;
    final volume = _service.playbackVolume;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: playing ? l10nOf(context).uiPausePreview805180 : l10nOf(context).uiPlayPreview47BB44,
                onPressed: () => unawaited(_run(_service.playPreview)),
                icon: Icon(
                  playing
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                ),
              ),
              Expanded(
                child: Slider(
                  value: fraction,
                  onChanged: (value) => unawaited(_seek(value)),
                ),
              ),
              Text("${(_clock(position))} / ${(_clock(total))}"),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: volume == 0 ? l10nOf(context).uiUnmutePreview12A31A : l10nOf(context).uiMutePreviewCE44BD,
                onPressed: () => unawaited(
                  _run(() => _service.setPlaybackVolume(volume == 0 ? 1 : 0)),
                ),
                icon: Icon(
                  volume == 0
                      ? Icons.volume_off_outlined
                      : volume < 0.5
                      ? Icons.volume_down_outlined
                      : Icons.volume_up_outlined,
                ),
              ),
              Expanded(
                child: Slider(
                  value: volume,
                  label: l10nOf(context).uiValue3072D4((((volume * 100).round())).toString()),
                  divisions: 20,
                  onChanged: (value) =>
                      unawaited(_run(() => _service.setPlaybackVolume(value))),
                ),
              ),
            ],
          ),
        ],
    );
  }
}

class _GroupVoiceControls extends StatelessWidget {
  const _GroupVoiceControls({
    required this.controller,
    required this.messageId,
    required this.durationMs,
    required this.palette,
  });

  final MessengerController controller;
  final String messageId;
  final int durationMs;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    final service = controller.voiceMessageService;
    final total = Duration(milliseconds: durationMs);
    return StreamBuilder<Duration>(
      stream: service.playbackPositionStream,
      initialData: Duration.zero,
      builder: (context, snapshot) {
        final isCurrent = service.playingItemId == messageId;
        final position = snapshot.data ?? Duration.zero;
        final value = (position.inMilliseconds / durationMs).clamp(0.0, 1.0);
        final label =
            '${total.inMinutes}:${(total.inSeconds % 60).toString().padLeft(2, '0')}';
        final path = controller.groupFilePathFor(messageId);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
            IconButton(
              tooltip: isCurrent && service.isPlaying
                  ? l10nOf(context).uiPauseVoiceMessageECD12D
                  : l10nOf(context).uiPlayVoiceMessageB16684,
              onPressed: path == null
                  ? null
                  : () => unawaited(
                      service
                          .togglePlayback(path, itemId: messageId)
                          .catchError(
                            (Object error) => controller.setStatus('$error'),
                          ),
                    ),
              icon: Icon(
                isCurrent && service.isPlaying
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                color: palette.primary,
              ),
            ),
            Expanded(
              child: isCurrent
                  ? Slider(
                      value: value,
                      onChanged: (next) => unawaited(
                        service.seekPlayback(
                          Duration(milliseconds: (next * durationMs).round()),
                        ),
                      ),
                    )
                  : Text(l10nOf(context).uiVoiceMessageValue2F0300((label).toString())),
            ),
            PopupMenuButton<double>(
              tooltip: l10nOf(context).uiPlaybackSpeed6FF42B,
              icon: const Icon(Icons.speed),
              onSelected: (rate) => unawaited(
                service
                    .setPlaybackRate(rate)
                    .catchError(
                      (Object error) => controller.setStatus('$error'),
                    ),
              ),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 1, child: Text('1×')),
                PopupMenuItem(value: 1.5, child: Text('1.5×')),
                PopupMenuItem(value: 2, child: Text('2×')),
              ],
            ),
              ],
            ),
            if (isCurrent && service.playbackError != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    l10nOf(context).uiPlaybackFailedValue1C0E1A((service.playbackError).toString()),
                    style: TextStyle(color: palette.danger, fontSize: 12),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _VoiceComposerPanel extends StatelessWidget {
  const _VoiceComposerPanel({
    required this.service,
    required this.destinationKey,
    required this.palette,
    required this.locked,
    required this.sending,
    required this.onStop,
    required this.onCancel,
    required this.onSend,
  });

  final VoiceMessageService service;
  final String destinationKey;
  final ConestPalette palette;
  final bool locked;
  final bool sending;
  final VoidCallback onStop;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  String _duration(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => StreamBuilder<VoiceRecordingSnapshot>(
    stream: service.recordingSnapshots,
    initialData: service.recordingSnapshot,
    builder: (context, snapshot) {
      final voice = snapshot.data ?? service.recordingSnapshot;
      if (voice.destinationKey != destinationKey ||
          voice.state == VoiceRecordingState.idle) {
        return const SizedBox.shrink();
      }
      final recording = voice.state == VoiceRecordingState.recording;
      final preview = voice.state == VoiceRecordingState.preview;
      final duration = service.preview?.metadata.durationMs != null
          ? Duration(milliseconds: service.preview!.metadata.durationMs)
          : voice.elapsed;
      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: palette.panel2,
          border: Border.all(color: palette.stroke),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  voice.error == null
                      ? recording
                            ? Icons.fiber_manual_record
                            : Icons.graphic_eq
                      : Icons.error_outline,
                  color: voice.error == null ? palette.primary : palette.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    voice.error ??
                        (voice.state == VoiceRecordingState.starting
                            ? l10nOf(context).uiPreparingMicrophone0BBF4A
                            : voice.state == VoiceRecordingState.stopping
                            ? l10nOf(context).uiPreparingPreview312E7B
                            : preview
                            ? l10nOf(context).uiVoiceMessagePreviewValue8235CB(
                                (_duration(duration)).toString(),
                              )
                            : l10nOf(context).uiRecordingValueValue111FF1(
                                (locked ? ' · locked' : '').toString(),
                                (_duration(voice.elapsed)).toString(),
                              )),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (voice.state == VoiceRecordingState.starting ||
                    voice.state == VoiceRecordingState.stopping)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (recording)
                  IconButton(
                    tooltip: l10nOf(context).uiStopRecordingEE0D9D,
                    onPressed: onStop,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                IconButton(
                  tooltip: l10nOf(context).uiDeleteRecording8B58CE,
                  onPressed: onCancel,
                  icon: const Icon(Icons.delete_outline),
                ),
                if (preview)
                  FilledButton(
                    onPressed: sending ? null : onSend,
                    child: Text(
                      sending
                          ? l10nOf(context).uiSendingCF7655
                          : l10nOf(context).composerSend,
                    ),
                  ),
              ],
            ),
            if (voice.waveform.isNotEmpty) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 30,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (final sample in voice.waveform.take(64))
                      Expanded(
                        child: Container(
                          height: 4 + sample / 255 * 24,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(
                            color: palette.primary.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (preview && service.preview != null) ...[
              _VoicePreviewPlayer(
                service: service,
                recording: service.preview!,
                onError: service.reportRecordingError,
              ),
              if (service.playingItemId == _VoicePreviewPlayer.itemId &&
                  service.playbackError != null)
                Text(
                  l10nOf(context).uiPlaybackFailedValue1C0E1A(
                    (service.playbackError).toString(),
                  ),
                  style: TextStyle(color: palette.danger),
                ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: PopupMenuButton<double>(
                  initialValue: service.playbackRate,
                  tooltip: l10nOf(context).uiPlaybackSpeed6FF42B,
                  onSelected: (rate) => unawaited(
                    service.setPlaybackRate(rate).catchError((Object error) {
                      service.reportRecordingError(error);
                    }),
                  ),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 1, child: Text('1×')),
                    PopupMenuItem(value: 1.5, child: Text('1.5×')),
                    PopupMenuItem(value: 2, child: Text('2×')),
                  ],
                  child: Text("${(service.playbackRate)}×"),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

class _GroupChatPanelState extends State<_GroupChatPanel> {
  String? _historyCursor;
  bool _loadingHistory = false;
  bool _historyExhausted = false;

  ({String id, double top})? _captureScrollAnchor(List<ChatMessage> messages) {
    final viewportContext = _messageListKey.currentContext;
    final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.attached) return null;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    ({String id, double top})? anchor;
    for (final message in messages) {
      final box =
          _messageKeyFor(message.id).currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= viewportTop || top >= viewportBottom) continue;
      if (anchor == null || top < anchor.top) {
        anchor = (id: message.id, top: top);
      }
    }
    return anchor;
  }

  void _restoreScrollAnchor(({String id, double top})? anchor) {
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final box =
          _messageKeyFor(anchor.id).currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.attached) return;
      final currentTop = box.localToGlobal(Offset.zero).dy;
      final delta = currentTop - anchor.top;
      if (delta.abs() < 0.5) return;
      final position = _scrollController.position;
      final target = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _scrollController.jumpTo(target.toDouble());
    });
  }

  Future<void> _loadOlderHistory() async {
    if (_loadingHistory || _historyExhausted) return;
    final requestedGroup = group.groupId;
    final anchor = _captureScrollAnchor(
      controller.messagesForGroup(requestedGroup),
    );
    setState(() => _loadingHistory = true);
    try {
      final next = await controller.loadOlderGroupHistory(
        requestedGroup,
        beforeEventId: _historyCursor,
      );
      if (!mounted || group.groupId != requestedGroup) return;
      setState(() {
        _historyCursor = next;
        _historyExhausted = next == null;
      });
      _restoreScrollAnchor(anchor);
    } catch (error) {
      if (mounted) {
        controller.setStatus('Could not load older group history: $error');
      }
    } finally {
      if (mounted && group.groupId == requestedGroup) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _messageListKey = GlobalKey();
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey<PopupMenuButtonState<String>>> _messageActionKeys = {};
  bool _didInitialPosition = false;
  bool _initialPositionScheduled = false;
  bool _droppingFiles = false;
  final ReadSweepTimer _readSweep = ReadSweepTimer();
  String? _anchoredFirstUnreadId;
  final LinkedHashSet<String> _selectedMessageIds = LinkedHashSet<String>();
  String? _flashingMessageId;
  Timer? _flashTimer;

  static const Duration _replyFlashDuration = Duration(milliseconds: 320);

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  MessengerController get controller => widget.controller;
  ConestPalette get palette => widget.palette;
  GroupRecord get group => widget.group;

  Future<void> _scheduleText() async {
    final body = widget.composerController.text.trim();
    if (body.isEmpty) return;
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null || !mounted) return;
    final due = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    await controller.scheduleTextMessage(
      kind: ConversationKind.group,
      conversationId: group.groupId,
      body: body,
      scheduledAt: due,
    );
    widget.composerController.clear();
    controller.setStatus('Message scheduled for ${due.toLocal()}.');
  }

  bool _voiceRecordingStarting = false;
  bool _voiceRecordingLocked = false;
  bool _voiceRecordingCancelGesture = false;
  bool _voiceSending = false;

  bool get _voiceRecording => controller.voiceMessageService.isRecording;

  Future<void> _beginGroupVoiceRecording() async {
    if (_voiceRecording || _voiceRecordingStarting) return;
    setState(() {
      _voiceRecordingStarting = true;
      _voiceRecordingLocked = false;
      _voiceRecordingCancelGesture = false;
    });
    try {
      await controller.voiceMessageService.start(
        destinationKey: 'group:${group.groupId}',
      );
      if (!mounted) {
        await controller.voiceMessageService.stopForInterruption();
        return;
      }
    } catch (error) {
      if (error is! StateError ||
          (!error.message.toString().contains('startup') &&
              !error.message.toString().contains('before it started'))) {
        controller.setStatus('$error');
      }
    } finally {
      if (mounted) setState(() => _voiceRecordingStarting = false);
    }
  }

  void _moveGroupVoiceRecording(LongPressMoveUpdateDetails details) {
    if ((!_voiceRecording && !_voiceRecordingStarting) ||
        _voiceRecordingLocked) {
      return;
    }
    final cancel = details.offsetFromOrigin.dx <= -96;
    final locked = !cancel && details.offsetFromOrigin.dy <= -96;
    if (cancel == _voiceRecordingCancelGesture &&
        locked == _voiceRecordingLocked) {
      return;
    }
    setState(() {
      _voiceRecordingCancelGesture = cancel;
      _voiceRecordingLocked = locked;
    });
  }

  Future<void> _cancelGroupVoiceRecording() async {
    final service = controller.voiceMessageService;
    await service.cancel();
    if (mounted && !_voiceRecordingStarting) {
      setState(() {
        _voiceRecordingLocked = false;
        _voiceRecordingCancelGesture = false;
      });
    }
  }

  Future<void> _releaseGroupVoiceRecording() async {
    if (_voiceRecordingCancelGesture) {
      await _cancelGroupVoiceRecording();
    } else if (!_voiceRecordingLocked) {
      await _finishGroupVoiceRecording();
    }
  }

  Future<void> _finishGroupVoiceRecording() async {
    final voiceService = controller.voiceMessageService;
    if (_voiceRecordingStarting) {
      await voiceService.stopForInterruption();
      return;
    }
    if (!_voiceRecording) return;
    if (mounted) {
      setState(() {
        _voiceRecordingLocked = false;
        _voiceRecordingCancelGesture = false;
      });
    }
    try {
      await voiceService.stop();
    } catch (error) {
      if (voiceService.isRecording) await voiceService.stopForInterruption();
      voiceService.reportRecordingError(error);
    }
  }

  Future<void> _sendGroupVoicePreview() async {
    if (_voiceSending) return;
    setState(() => _voiceSending = true);
    try {
      await controller.sendRecordedVoiceMessageToGroup(groupId: group.groupId);
    } catch (error) {
      controller.voiceMessageService.reportRecordingError(error);
    } finally {
      if (mounted) setState(() => _voiceSending = false);
    }
  }

  Future<void> _createPoll() async {
    final question = TextEditingController();
    final options = TextEditingController();
    var mode = PollChoiceMode.single;
    final value = await showDialog<(String, List<String>, PollChoiceMode)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10nOf(context).uiNewPoll6D62BD),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: question,
                decoration: InputDecoration(
                  labelText: l10nOf(context).uiQuestion002FF5,
                ),
              ),
              TextField(
                controller: options,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: l10nOf(context).uiOptionsOnePerLine62FF3D,
                ),
              ),
              DropdownButton<PollChoiceMode>(
                value: mode,
                onChanged: (value) =>
                    setDialogState(() => mode = value ?? mode),
                items: [
                  DropdownMenuItem(
                    value: PollChoiceMode.single,
                    child: Text(l10nOf(context).uiSingleChoice68E3E0),
                  ),
                  DropdownMenuItem(
                    value: PollChoiceMode.multiple,
                    child: Text(l10nOf(context).uiMultipleChoiceB88936),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10nOf(context).actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                question.text,
                options.text.split('\n'),
                mode,
              )),
              child: Text(l10nOf(context).actionCreate),
            ),
          ],
        ),
      ),
    );
    question.dispose();
    options.dispose();
    if (value == null) return;
    await controller.createGroupPoll(
      groupId: group.groupId,
      question: value.$1,
      options: value.$2,
      mode: value.$3,
    );
  }

  Future<void> _changeGroupMessage(
    ChatMessage message, {
    required bool delete,
  }) async {
    final groupId = group.groupId;
    final compatibility = controller.groupMessageChangeCompatibility(groupId);
    String? body;
    if (delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10nOf(context).uiDeleteMessageD536CF),
          content: Text(
            l10nOf(context).uiThisRemovesTheMessageFor2247A2(
              (compatibility == null ? '' : '\n\n$compatibility').toString(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10nOf(context).actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10nOf(context).menuDelete),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    } else {
      body = await showDialog<String>(
        context: context,
        builder: (context) => _EditMessageDialog(
          initialBody: message.body,
          explanation: compatibility,
        ),
      );
      if (body == null || body.trim() == message.body) return;
    }
    if (!mounted) return;
    try {
      await controller.changeGroupMessage(
        groupId: groupId,
        messageId: message.id,
        body: body,
        delete: delete,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("${(error)}")));
      }
    }
  }

  int _searchGeneration = 0;

  Future<void> _searchMessages() async {
    final generation = ++_searchGeneration;
    final conversationId = group.groupId;
    final selected = await showModalBottomSheet<ChatMessage>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChatMessageSearch(
        messages: () => controller.messagesForGroup(group.groupId),
        changes: controller,
        loadOlder: _historyExhausted ? null : _loadOlderHistory,
        searchRemote: (query) =>
            controller.searchGroupMessages(group.groupId, query),
      ),
    );
    if (selected == null || !mounted || group.groupId != conversationId) return;
    final messages = controller.messagesForGroup(group.groupId);
    // Album continuations are represented by their first bubble in the list.
    var target = selected.id;
    final index = messages.indexWhere((message) => message.id == target);
    if (index >= 0 && _isAlbumContinuation(messages, index)) {
      var anchor = index;
      while (anchor > 0 && _isAlbumContinuation(messages, anchor)) {
        anchor--;
      }
      target = messages[anchor].id;
    }
    final found = await revealChatMessage(
      scroll: _scrollController,
      keys: _messageKeys,
      messages: messages,
      messageId: target,
      isCurrent: () =>
          mounted &&
          _searchGeneration == generation &&
          group.groupId == conversationId,
    );
    if (!mounted || _searchGeneration != generation) return;
    if (found) {
      _flashMessage(target);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10nOf(context).uiCouldNotLocateThisMessage220E83),
        ),
      );
    }
  }

  void _flashMessage(String messageId) {
    _flashTimer?.cancel();
    setState(() => _flashingMessageId = messageId);
    _flashTimer = Timer(_replyFlashDuration, () {
      if (!mounted) return;
      setState(() => _flashingMessageId = null);
    });
  }

  void _toggleMessageSelection(ChatMessage message) {
    setState(() {
      if (_selectedMessageIds.contains(message.id)) {
        _selectedMessageIds.remove(message.id);
      } else {
        _selectedMessageIds.add(message.id);
      }
    });
  }

  void _clearMessageSelection() {
    if (_selectedMessageIds.isEmpty) return;
    setState(_selectedMessageIds.clear);
  }

  List<ChatMessage> _selectedMessagesInOrder(List<ChatMessage> all) {
    return all.where((m) => _selectedMessageIds.contains(m.id)).toList();
  }

  bool _canSaveSelected(List<ChatMessage> all) {
    final selected = _selectedMessagesInOrder(all);
    return selected.any((m) {
      final att = m.attachment;
      if (att == null) return false;
      return controller.attachmentAvailableLocally(att.id);
    });
  }

  bool _canDeleteSelected(List<ChatMessage> all) {
    final selected = _selectedMessagesInOrder(all);
    return selected.isNotEmpty &&
        selected.every(
          (message) =>
              message.outbound &&
              !message.hasAttachment &&
              message.groupFile == null,
        );
  }

  Future<void> _deleteSelected(List<ChatMessage> all) async {
    final selected = _selectedMessagesInOrder(all);
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiDeleteSelectedMessages190A5F),
        content: Text(
          l10nOf(context).uiDeleteValueMessageValueForABA7AC((selected.length)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10nOf(context).menuDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final message in selected) {
      try {
        await controller.changeGroupMessage(
          groupId: group.groupId,
          messageId: message.id,
          delete: true,
        );
      } catch (error) {
        controller.setStatus('Delete failed for one message: $error');
      }
    }
    _clearMessageSelection();
  }

  Future<void> _copySelectedMessagesText(List<ChatMessage> all) async {
    final selected = _selectedMessagesInOrder(all);
    if (selected.isEmpty) return;
    final text = selected
        .map((m) {
          final att = m.attachment;
          if (att != null && m.body.isEmpty) {
            return '[${att.fileName}]';
          }
          if (att != null) {
            return '${m.body}\n[${att.fileName}]';
          }
          return m.body;
        })
        .where((s) => s.isNotEmpty)
        .join('\n');
    if (text.isEmpty) {
      controller.setStatus('Nothing to copy from the selected messages.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    controller.setStatus('Copied ${selected.length} message(s).');
    _clearMessageSelection();
  }

  Future<void> _bulkSaveSelected(List<ChatMessage> all) async {
    final selected = _selectedMessagesInOrder(
      all,
    ).where((m) => m.attachment != null).toList();
    final ready = selected
        .where((m) => controller.attachmentAvailableLocally(m.attachment!.id))
        .toList();
    if (ready.isEmpty) {
      controller.setStatus(
        'No selected attachment is ready yet — still transferring.',
      );
      return;
    }
    _clearMessageSelection();
    await bulkSaveAttachments(
      controller,
      ready.map((message) => message.attachment!).toList(growable: false),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    controller.requestGroupHistoryCatchUp(group.groupId);
  }

  @override
  void didUpdateWidget(covariant _GroupChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.groupId != widget.group.groupId) {
      _historyCursor = null;
      _loadingHistory = false;
      _historyExhausted = false;
      controller.requestGroupHistoryCatchUp(group.groupId);
      _messageKeys.clear();
      _didInitialPosition = false;
      _initialPositionScheduled = false;
      _anchoredFirstUnreadId = null;
      _readSweep.cancel();
    }
    _scheduleInitialPosition();
    _scheduleReadSweep();
  }

  @override
  void dispose() {
    final voiceService = controller.voiceMessageService;
    if (voiceService.isRecording &&
        voiceService.previewDestinationKey == 'group:${group.groupId}') {
      unawaited(voiceService.stopForInterruption());
    }
    _readSweep.cancel();
    _flashTimer?.cancel();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _messageKeyFor(String messageId) {
    return _messageKeys.putIfAbsent(
      messageId,
      () => GlobalKey(debugLabel: 'group-message-$messageId'),
    );
  }

  GlobalKey<PopupMenuButtonState<String>> _messageActionKey(String messageId) =>
      _messageActionKeys.putIfAbsent(
        messageId,
        () => GlobalKey<PopupMenuButtonState<String>>(),
      );

  void _pruneMessageKeys(List<ChatMessage> messages) {
    final activeIds = messages.map((message) => message.id).toSet();
    _messageKeys.removeWhere((messageId, _) => !activeIds.contains(messageId));
    _messageActionKeys.removeWhere((messageId, _) => !activeIds.contains(messageId));
  }

  void _scheduleInitialPosition() {
    if (_didInitialPosition || _initialPositionScheduled) {
      return;
    }
    _initialPositionScheduled = true;
    // reverse:true ListView opens at offset 0 = latest message. The flag
    // still gates the read-sweep so we keep it; the post-frame callback is
    // a single shot with no scroll work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPositionScheduled = false;
      if (!mounted || _didInitialPosition) {
        return;
      }
      // Anchor the 'N new messages' divider on the first unread message
      // visible at chat-open. Stays put as new messages arrive; clears
      // when the chat is closed and re-opened.
      if (_anchoredFirstUnreadId == null) {
        final groupMessages = controller.messagesForGroup(group.groupId);
        for (final m in groupMessages) {
          if (!m.outbound &&
              controller.isUnreadGroupMessage(group.groupId, m)) {
            _anchoredFirstUnreadId = m.id;
            break;
          }
        }
      }
      _didInitialPosition = true;
      _scheduleReadSweep();
    });
  }

  void _handleScroll() => _scheduleReadSweep(restart: true);

  void _scheduleReadSweep({bool restart = false}) {
    if (!mounted || !_didInitialPosition || !controller.isAppForeground) {
      return;
    }
    _readSweep.schedule(_runReadSweep, restart: restart);
  }

  Future<void> _runReadSweep() async {
    if (!mounted || !controller.isAppForeground) return;
    final latestVisibleUnread = _latestVisibleUnreadMessage();
    if (latestVisibleUnread == null) return;
    await controller.markGroupReadThroughMessage(
      group.groupId,
      latestVisibleUnread,
    );
  }

  ChatMessage? _latestVisibleUnreadMessage() {
    final viewportContext = _messageListKey.currentContext;
    final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.attached) {
      return null;
    }
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    ChatMessage? latestVisibleUnread;
    for (final message in controller.messagesForGroup(group.groupId)) {
      if (message.outbound ||
          !controller.isUnreadGroupMessage(group.groupId, message)) {
        continue;
      }
      final messageContext = _messageKeyFor(message.id).currentContext;
      final messageBox = messageContext?.findRenderObject() as RenderBox?;
      if (messageBox == null || !messageBox.attached) {
        continue;
      }
      final messageTop = messageBox.localToGlobal(Offset.zero).dy;
      final messageBottom = messageTop + messageBox.size.height;
      if (messageBottom > viewportTop + 4 && messageTop < viewportBottom - 4) {
        latestVisibleUnread = message;
      }
    }
    return latestVisibleUnread;
  }

  Future<void> _copyMessage(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.body));
    controller.setStatus('Copied message text.');
  }

  Future<void> _openGroupFile(ChatMessage message) async {
    final manifest = message.groupFile;
    final path = controller.groupFilePathFor(message.id);
    if (manifest == null || path == null) {
      controller.setStatus('The group file is not available locally.');
      return;
    }
    if (manifest.voiceMetadata != null) {
      try {
        await controller.voiceMessageService.togglePlayback(
          path,
          itemId: message.id,
        );
      } catch (error) {
        controller.setStatus('$error');
      }
      return;
    }
    if (!kIsWeb && Platform.isAndroid) {
      final kind = manifest.mimeType.startsWith('image/')
          ? 'image'
          : manifest.mimeType.startsWith('video/')
          ? 'video'
          : 'other';
      try {
        final saved = await controller.platformBridge.saveMediaFileToGallery(
          sourcePath: path,
          fileName: sanitizeAttachmentFileName(manifest.fileName),
          mimeType: manifest.mimeType,
          kind: kind,
        );
        if (saved != null) {
          controller.setStatus('Saved ${manifest.fileName}.');
          return;
        }
      } catch (error) {
        controller.setStatus('Could not save ${manifest.fileName}: $error');
        return;
      }
      controller.setStatus('The Android file saver is unavailable.');
      return;
    }
    try {
      if (Platform.isLinux) {
        await Process.start('xdg-open', [path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path]);
      } else if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', path]);
      } else {
        controller.setStatus('Opening files is unavailable on this platform.');
      }
    } catch (error) {
      controller.setStatus('Could not open ${manifest.fileName}: $error');
    }
  }

  String _messageSenderLabel(ChatMessage message) {
    if (message.outbound) {
      return 'You';
    }
    return controller.groupMemberLabel(message.senderDeviceId);
  }

  String _replyReferenceLabel(ChatMessage message) {
    final me = controller.identity;
    if (me != null && message.replySenderDeviceId == me.deviceId) {
      return 'You';
    }
    final senderId = message.replySenderDeviceId;
    if (senderId == null || senderId.isEmpty) {
      return message.replySenderDisplayName ?? 'Message';
    }
    return message.replySenderDisplayName ??
        controller.groupMemberLabel(senderId);
  }

  Widget _buildAlbumBubble(BuildContext context, List<ChatMessage> members) {
    if (members.isEmpty) return const SizedBox.shrink();
    final allSelected = members.every(
      (m) => _selectedMessageIds.contains(m.id),
    );
    // Keyed by the newest member, so the read sweep sees the album.
    return _AlbumBubble(
      key: _messageKeyFor(members.last.id),
      members: members,
      controller: controller,
      palette: palette,
      outbound: members.first.outbound,
      selectionMode: _selectionMode,
      selected: allSelected,
      onForwardAttachment: (descriptor) =>
          _forwardAttachment(context, controller, palette, descriptor),
      onForwardAlbum: (album) =>
          _forwardMessages(context, controller, palette, album),
      selectedIds: _selectedMessageIds,
      onToggleMember: _toggleMessageSelection,
      onToggleSelection: (album) {
        setState(() {
          final alreadyAll = album.every(
            (m) => _selectedMessageIds.contains(m.id),
          );
          if (alreadyAll) {
            for (final m in album) {
              _selectedMessageIds.remove(m.id);
            }
          } else {
            for (final m in album) {
              _selectedMessageIds.add(m.id);
            }
          }
        });
      },
    );
  }

  Widget _buildMessageBubble(BuildContext context, ChatMessage message) {
    final outbound = message.outbound;
    final unread = controller.isUnreadGroupMessage(group.groupId, message);
    final selected = _selectedMessageIds.contains(message.id);
    final flashing = _flashingMessageId == message.id;
    final baseColor = selected
        ? palette.primary.withValues(alpha: 0.18)
        : (outbound ? palette.outboundBubble : palette.inboundBubble);
    final attachmentDescriptor = message.attachment;
    final attachmentRow = attachmentDescriptor == null
        ? null
        : _AttachmentRow(
            descriptor: attachmentDescriptor,
            outbound: outbound,
            palette: palette,
            controller: controller,
            messageState: message.state,
            onForward: () => _forwardAttachment(
              context,
              controller,
              palette,
              attachmentDescriptor,
            ),
            onDelete: () => _changeGroupMessage(message, delete: true),
          );
    final attachmentInFlight = attachmentDescriptor != null &&
        (controller.attachmentTransferProgress(attachmentDescriptor.id) != null ||
            controller.outboundAttachmentProgress(attachmentDescriptor.id) != null);
    final attachmentAvailable = attachmentDescriptor != null &&
        controller.attachmentAvailableLocally(attachmentDescriptor.id);
    return GestureDetector(
      key: _messageKeyFor(message.id),
      // nightly.10: opaque so long-press registers on the empty row space
      // next to the bubble too, not just on the bubble itself.
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_selectionMode) {
          _toggleMessageSelection(message);
        } else {
          _messageActionKey(message.id).currentState?.showButtonMenu();
        }
      },
      onSecondaryTapDown: (_) =>
          _messageActionKey(message.id).currentState?.showButtonMenu(),
      onLongPress: () => _toggleMessageSelection(message),
      onDoubleTap: _selectionMode
          ? null
          : () {
              _flashMessage(message.id);
              widget.onReplyToMessage(message);
            },
      child: Align(
        alignment: outbound
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: AnimatedContainer(
          duration: _replyFlashDuration,
          curve: Curves.easeOut,
          constraints: const BoxConstraints(maxWidth: 560),
          margin: EdgeInsets.only(bottom: widget.telegramLayout ? 6 : 12),
          padding: widget.telegramLayout
              ? const EdgeInsets.fromLTRB(12, 8, 8, 4)
              : const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: (outbound && !selected && !flashing)
                ? null
                : (flashing
                      ? Color.alphaBlend(
                          palette.primary.withValues(alpha: 0.28),
                          baseColor,
                        )
                      : baseColor),
            gradient: (outbound && !selected && !flashing)
                ? palette.outboundBubbleGradient
                : null,
            borderRadius: BorderRadius.circular(18),
            boxShadow: (outbound && !selected && !flashing) && palette.glow
                ? [
                    BoxShadow(
                      color: palette.primary.withValues(alpha: 0.22),
                      blurRadius: 12,
                    ),
                  ]
                : null,
            border: selected
                ? Border.all(color: palette.primary, width: 2)
                : (outbound
                      ? null
                      : Border.all(
                          color: unread
                              ? palette.unread.withValues(alpha: 0.55)
                              : palette.border,
                        )),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _messageSenderLabel(message),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: outbound ? palette.outboundMeta : palette.inboundMeta,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.hasReplyPreview) ...[
                      _QuotedReference(
                        palette: palette,
                        outbound: outbound,
                        senderLabel: _replyReferenceLabel(message),
                        snippet: message.replySnippet!,
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (message.groupFile case final file?)
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          controller,
                          controller.transferProgressListenable,
                        ]),
                        builder: (context, _) => GroupFileTile(
                          filename: file.fileName,
                          size: file.sizeBytes,
                          verifiedBytes: controller.groupFileVerifiedBytes(
                            message.id,
                          ),
                          state: controller.groupFileDownloadState(message.id),
                          onOpen: () => unawaited(_openGroupFile(message)),
                          previewPath: file.mimeType.startsWith('image/')
                              ? controller.groupFilePathFor(message.id)
                              : null,
                          error: switch (controller.groupFileError(
                            message.id,
                          )) {
                            final Object error => describeActionError(error),
                            null => null,
                          },
                          onDownload: () => unawaited(
                            controller
                                .downloadGroupFile(group.groupId, message.id)
                                .catchError(
                                  (Object error) =>
                                      controller.setStatus('$error'),
                                ),
                          ),
                          onDownloadAnyway: () => unawaited(
                            controller
                                .downloadGroupFile(
                                  group.groupId,
                                  message.id,
                                  ignoreReserve: true,
                                )
                                .catchError(
                                  (Object error) =>
                                      controller.setStatus('$error'),
                                ),
                          ),
                          onPause: () => unawaited(
                            controller
                                .groupFileSession(message.id)
                                ?.setPaused(true)
                                .catchError(
                                  (Object error) =>
                                      controller.setStatus('$error'),
                                ),
                          ),
                          onResume: () => unawaited(
                            controller
                                .groupFileSession(message.id)
                                ?.setPaused(false)
                                .catchError(
                                  (Object error) =>
                                      controller.setStatus('$error'),
                                ),
                          ),
                          onStopSharing: () => unawaited(
                            controller
                                .groupFileSession(message.id)
                                ?.setSharing(false)
                                .catchError(
                                  (Object error) =>
                                      controller.setStatus('$error'),
                                ),
                          ),
                          onEvict: () => unawaited(
                            controller
                                .evictGroupFile(group.groupId, message.id)
                                .catchError(
                                  (Object error) =>
                                      controller.setStatus('$error'),
                                ),
                          ),
                          sharing: controller
                              .groupFilePreference(group.groupId, message.id)
                              .sharing,
                          playbackControls: file.voiceMetadata == null
                              ? null
                              : _GroupVoiceControls(
                                  controller: controller,
                                  messageId: message.id,
                                  durationMs: file.voiceMetadata!.durationMs,
                                  palette: palette,
                                ),
                          accepted: controller
                              .groupFilePreference(group.groupId, message.id)
                              .accepted,
                        ),
                      ),
                    if (message.hasAttachment) ...[
                      attachmentRow!,
                      if (message.body.isNotEmpty) const SizedBox(height: 8),
                    ],
                    if (message.poll case final poll?) ...[
                      _GroupPollCard(
                        groupId: group.groupId,
                        poll: poll,
                        controller: controller,
                        palette: palette,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (message.body.isNotEmpty ||
                        (!message.hasAttachment && message.groupFile == null))
                      Text(
                        message.body,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: outbound
                              ? palette.outboundText
                              : palette.inboundText,
                          height: 1.35,
                        ),
                      ),
                    if (message.reactions.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final entry in message.reactions.entries)
                            ActionChip(
                              label: Text(
                                "${(entry.key)} ${(entry.value.length)}",
                              ),
                              onPressed: () => unawaited(
                                controller
                                    .toggleGroupReaction(
                                      groupId: group.groupId,
                                      messageId: message.id,
                                      emoji: entry.key,
                                    )
                                    .catchError(
                                      (Object error) =>
                                          controller.setStatus('$error'),
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.telegramLayout
                        ? chatMessageTime(context, message.createdAt)
                        : formatTimestamp(message.createdAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontFamily: ConestPalette.monoFont,
                      color: outbound
                          ? palette.outboundMeta
                          : palette.inboundMeta,
                    ),
                  ),
                  if (!outbound && unread) ...[
                    const SizedBox(width: 6),
                    Text(
                      l10nOf(context).uiNewC2A6B0,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontFamily: ConestPalette.monoFont,
                        color: palette.unread,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (message.isEdited) ...[
                    const SizedBox(width: 6),
                    Text(
                      l10nOf(context).uiEditedA22FCA,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: outbound
                            ? palette.outboundMeta
                            : palette.inboundMeta,
                      ),
                    ),
                  ],
                  if (message.effectiveRoute != null &&
                      controller.userMode.showsNetworkDetail) ...[
                    const SizedBox(width: 8),
                    _MessageRouteChip(
                      message: message,
                      compact: widget.telegramLayout,
                    ),
                  ],
                  if (outbound) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: controller.groupDeliverySummary(message),
                      child: Icon(
                        message.state.icon,
                        size: 16,
                        color: palette.outboundMeta,
                      ),
                    ),
                  ],
                  PopupMenuButton<String>(
                    key: _messageActionKey(message.id),
                    tooltip: l10nOf(context).uiMessageActions949184,
                    padding: EdgeInsets.zero,
                    child: const SizedBox.shrink(),
                    onSelected: (value) async {
                      if (value == 'details') {
                        await MessageInfoDialog.show(
                          context,
                          message: message,
                          memberLabel: controller.groupMemberLabel,
                          timestamp: formatTimestamp,
                          showRoutes: controller.userMode.showsNetworkDetail,
                          senderClockOffset: controller.clockOffsetFor(
                            message.senderDeviceId,
                          ),
                          senderOutOfTouchSince: controller
                              .contactDeviceOutOfTouchSince(
                                message.senderDeviceId,
                              ),
                        );
                      } else if (value == 'copy') {
                        await _copyMessage(message);
                      } else if (value == 'forward') {
                        await _forwardTextMessage(
                          context,
                          controller,
                          palette,
                          message,
                        );
                      } else if (value == 'reply') {
                        widget.onReplyToMessage(message);
                      } else if (value == 'react') {
                        await controller
                            .toggleGroupReaction(
                              groupId: group.groupId,
                              messageId: message.id,
                              emoji: '👍',
                            )
                            .catchError(
                              (Object error) => controller.setStatus('$error'),
                            );
                      } else if (value == 'attachment_download' &&
                          attachmentDescriptor != null) {
                        await controller.acceptIncomingAttachment(
                          attachmentDescriptor.id,
                        );
                      } else if (value == 'attachment_save' &&
                          attachmentRow != null) {
                        if (attachmentAvailable) {
                          await attachmentRow._saveLocalFileToDisk();
                        } else {
                          controller.setStatus(
                            'The attachment is still downloading.',
                          );
                        }
                      } else if (value == 'attachment_copy_image' &&
                          attachmentDescriptor != null) {
                        final bytes = controller.attachmentBytesFor(
                          attachmentDescriptor.id,
                        );
                        if (bytes != null) {
                          await attachmentRow!._copyImageBytesFor(
                            bytes,
                            attachmentDescriptor.fileName,
                          );
                        }
                      } else if (value == 'attachment_copy_path' &&
                          attachmentRow != null) {
                        await attachmentRow._copyCachePath();
                      } else if (value == 'attachment_keep_offline' &&
                          attachmentDescriptor != null) {
                        await controller.setAttachmentKeepOffline(
                          attachmentDescriptor.id,
                          !controller.attachmentKeptOffline(
                            attachmentDescriptor.id,
                          ),
                        );
                      } else if (value == 'attachment_evict' &&
                          attachmentDescriptor != null) {
                        await controller.evictAttachment(
                          attachmentDescriptor.id,
                        );
                      } else if (value == 'attachment_cancel' &&
                          attachmentDescriptor != null) {
                        await controller.cancelAttachmentById(
                          attachmentDescriptor.id,
                        );
                      } else if (value == 'attachment_retry' &&
                          attachmentDescriptor != null) {
                        controller.retryAttachment(attachmentDescriptor.id);
                      } else if (value == 'forward_attachment' &&
                          attachmentRow != null) {
                        await attachmentRow.onForward?.call();
                      } else if (value == 'forward_group_file') {
                        await _forwardGroupFile(
                          context,
                          controller,
                          palette,
                          message,
                        );
                      } else if (value == 'edit' || value == 'delete') {
                        await _changeGroupMessage(
                          message,
                          delete: value == 'delete',
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'details',
                        child: Text(l10nOf(context).messageDetails),
                      ),
                      PopupMenuItem(
                        value: 'reply',
                        child: Text(l10nOf(context).menuReply),
                      ),
                      if (!message.hasAttachment &&
                          message.groupFile == null &&
                          message.body.trim().isNotEmpty)
                        PopupMenuItem(
                          value: 'react',
                          child: Text(l10nOf(context).menuReact),
                        ),
                      if (message.outbound &&
                          message.groupFile == null &&
                          !message.hasAttachment &&
                          group.hasActiveMember(
                            controller.identity?.deviceId ?? '',
                          )) ...[
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(l10nOf(context).menuEdit),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(l10nOf(context).menuDelete),
                        ),
                      ],
                      PopupMenuItem(
                        value: 'copy',
                        child: Text(l10nOf(context).menuCopyMessage),
                      ),
                      if (attachmentDescriptor != null && !outbound &&
                          !attachmentAvailable)
                        PopupMenuItem(
                          value: 'attachment_download',
                          child: Text(l10nOf(context).menuDownloadAttachment),
                        ),
                      if (attachmentAvailable)
                        PopupMenuItem(
                          value: 'attachment_save',
                          child: Text(l10nOf(context).menuSaveAttachment),
                        ),
                      if (attachmentDescriptor?.mimeType.startsWith('image/') == true &&
                          controller.attachmentBytesFor(attachmentDescriptor!.id) != null)
                        PopupMenuItem(
                          value: 'attachment_copy_image',
                          child: Text(l10nOf(context).menuCopyImage),
                        ),
                      if (attachmentAvailable) ...[
                        PopupMenuItem(
                          value: 'attachment_copy_path',
                          child: Text(l10nOf(context).uiCopyCachePathC23134),
                        ),
                        PopupMenuItem(
                          value: 'attachment_keep_offline',
                          child: Text(
                            controller.attachmentKeptOffline(attachmentDescriptor.id)
                                ? l10nOf(context).uiStopKeepingOfflineAABFC7
                                : l10nOf(context).uiKeepOffline123286,
                          ),
                        ),
                        if (!controller.attachmentKeptOffline(attachmentDescriptor.id) &&
                            !attachmentInFlight)
                          PopupMenuItem(
                            value: 'attachment_evict',
                            child: Text(l10nOf(context).menuFreeUpSpace),
                          ),
                      ],
                      if (attachmentInFlight)
                        PopupMenuItem(
                          value: 'attachment_cancel',
                          child: Text(l10nOf(context).menuCancelTransfer),
                        ),
                      if (attachmentDescriptor != null && outbound &&
                          message.state == DeliveryState.failed)
                        PopupMenuItem(
                          value: 'attachment_retry',
                          child: Text(l10nOf(context).menuRetryTransfer),
                        ),
                      if (attachmentDescriptor != null)
                        PopupMenuItem(
                          value: 'forward_attachment',
                          child: Text(l10nOf(context).menuForwardAttachment),
                        ),
                      if (message.groupFile != null &&
                          controller.groupFilePathFor(message.id) != null)
                        PopupMenuItem(
                          value: 'forward_group_file',
                          child: Text(l10nOf(context).uiForwardFileC4B5CB),
                        ),
                      if (!message.hasAttachment &&
                          message.groupFile == null &&
                          message.body.trim().isNotEmpty)
                        PopupMenuItem(
                          value: 'forward',
                          child: Text(l10nOf(context).menuForward),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = controller.messagesForGroup(group.groupId);
    final callTimeline = groupCallChatTimeline(
      messages,
      controller.groupCallSummariesFor(group.groupId),
    );
    _pruneMessageKeys(messages);
    _scheduleInitialPosition();
    _scheduleReadSweep();
    final me = controller.identity;
    final canSend = me != null && group.hasActiveMember(me.deviceId);
    final activeReplyTarget =
        widget.replyTarget != null &&
            widget.replyTarget!.conversationId == group.groupId
        ? widget.replyTarget
        : null;
    final body = Padding(
      padding: widget.telegramLayout
          ? EdgeInsets.zero
          : const EdgeInsets.all(18),
      child: Card(
        margin: widget.telegramLayout ? EdgeInsets.zero : null,
        elevation: 0,
        color: palette.paperStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(widget.telegramLayout ? 0 : 28),
          side: widget.telegramLayout
              ? BorderSide.none
              : BorderSide(color: palette.stroke),
        ),
        child: Column(
          children: [
            if (widget.telegramLayout)
              _TelegramChatHeader(
                onSearch: _searchMessages,
                palette: palette,
                title: group.title,
                subtitle: l10nOf(
                  context,
                ).uiValueMembersCEF563((group.activeMemberDeviceIds.length)),
                seed: group.groupId,
                onBack: widget.onBack,
                onDetails: widget.onShowDetails,
                onCall: controller.groupVoiceCallsAvailable
                    ? () => openGroupCallScreen(
                        context,
                        controller,
                        group.groupId,
                      )
                    : null,
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                child: Row(
                  children: [
                    if (widget.onBack != null)
                      IconButton(
                        onPressed: widget.onBack,
                        icon: const Icon(Icons.arrow_back),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.title,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10nOf(context).uiValueMemberSOwnerValueE42E13(
                              (group.activeMemberDeviceIds.length),
                              (controller.groupMemberLabel(
                                group.ownerDeviceId,
                              )).toString(),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: palette.inkSoft),
                          ),
                        ],
                      ),
                    ),
                    _StatusChip(
                      label: l10nOf(context).uiPairwise64A0EF,
                      palette: palette,
                      icon: Icons.lock_outline,
                    ),
                    const SizedBox(width: 8),
                    GroupCallButton(
                      controller: controller,
                      groupId: group.groupId,
                    ),
                    IconButton(
                      onPressed: widget.onShowDetails,
                      icon: const Icon(Icons.groups_2_outlined),
                      tooltip: l10nOf(context).uiGroupDetailsDF844A,
                    ),
                  ],
                ),
              ),
            const Divider(height: 1),
            if (_selectionMode)
              _MessageSelectionBar(
                palette: palette,
                count: _selectedMessageIds.length,
                onCancel: _clearMessageSelection,
                onCopy: () => _copySelectedMessagesText(messages),
                onForward: () {
                  final selected = [
                    for (final message in messages)
                      if (_selectedMessageIds.contains(message.id)) message,
                  ];
                  _clearMessageSelection();
                  unawaited(
                    _forwardMessages(context, controller, palette, selected),
                  );
                },
                onSave: _canSaveSelected(messages)
                    ? () => _bulkSaveSelected(messages)
                    : null,
                onDelete: _canDeleteSelected(messages)
                    ? () => _deleteSelected(messages)
                    : null,
              ),
            Expanded(
              child: Builder(
                builder: (context) {
                  final anchor = _anchoredFirstUnreadId;
                  final unreadCount = anchor == null
                      ? 0
                      : messages.where((m) {
                          return !m.outbound &&
                              controller.isUnreadGroupMessage(group.groupId, m);
                        }).length;
                  return StableScrollbar(
                    controller: _scrollController,
                    child: ListView.builder(
                      key: _messageListKey,
                      reverse: true,
                      controller: _scrollController,
                      padding: const EdgeInsets.all(18),
                      itemCount:
                          callTimeline.length + (_historyExhausted ? 0 : 1),
                      itemBuilder: (context, index) {
                        if (index == callTimeline.length) {
                          return Center(
                            child: TextButton.icon(
                              onPressed: _loadingHistory
                                  ? null
                                  : _loadOlderHistory,
                              icon: const Icon(Icons.history),
                              label: Text(
                                _loadingHistory
                                    ? l10nOf(context).uiLoadingHistory02CB12
                                    : l10nOf(context).uiLoadOlderMessages07471F,
                              ),
                            ),
                          );
                        }
                        final entry =
                            callTimeline[callTimeline.length - 1 - index];
                        if (entry.summary != null) {
                          return GroupCallSummaryTile(
                            summary: entry.summary!,
                            labelFor: controller.groupMemberLabel,
                          );
                        }
                        final chronoIndex = entry.messageIndex!;
                        final message = messages[chronoIndex];
                        if (_isAlbumContinuation(messages, chronoIndex)) {
                          return const SizedBox.shrink();
                        }
                        final messageBubble =
                            _isAlbumAnchor(messages, chronoIndex)
                            ? _buildAlbumBubble(
                                context,
                                _collectAlbumFrom(messages, chronoIndex),
                              )
                            : _buildMessageBubble(context, message);
                        final replyBubble = widget.telegramLayout
                            ? SwipeToReply(
                                key: ValueKey('reply-swipe-${message.id}'),
                                enabled: !_selectionMode,
                                color: palette.primary,
                                onReply: () => widget.onReplyToMessage(message),
                                child: messageBubble,
                              )
                            : messageBubble;
                        final startsDay =
                            chronoIndex == 0 ||
                            !sameChatDay(
                              messages[chronoIndex - 1].createdAt,
                              message.createdAt,
                            );
                        final bubble = widget.telegramLayout && startsDay
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ChatDaySeparator(
                                    timestamp: message.createdAt,
                                    background: palette.panel2,
                                    foreground: palette.inkSoft,
                                  ),
                                  replyBubble,
                                ],
                              )
                            : replyBubble;
                        final showDivider =
                            anchor != null && message.id == anchor;
                        if (!showDivider) {
                          return bubble;
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _NewMessagesDivider(
                              palette: palette,
                              count: unreadCount,
                            ),
                            bubble,
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.stroke)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (activeReplyTarget != null) ...[
                    _ComposerReplyPreview(
                      palette: palette,
                      senderLabel: _messageSenderLabel(activeReplyTarget),
                      snippet: activeReplyTarget.bodyPreview,
                      onCancel: widget.onCancelReply,
                    ),
                    const SizedBox(height: 12),
                  ],
                  _VoiceComposerPanel(
                    service: controller.voiceMessageService,
                    destinationKey: 'group:${group.groupId}',
                    palette: palette,
                    locked: _voiceRecordingLocked,
                    sending: _voiceSending,
                    onStop: () => unawaited(_finishGroupVoiceRecording()),
                    onCancel: () => unawaited(_cancelGroupVoiceRecording()),
                    onSend: () => unawaited(_sendGroupVoicePreview()),
                  ),
                  Row(
                    children: [
                      if (widget.onAttach != null) ...[
                        PopupMenuButton<String>(
                          enabled: canSend,
                          tooltip: l10nOf(
                            context,
                          ).uiShareOrScheduleAGroup2989F0,
                          icon: const Icon(Icons.attach_file_outlined),
                          onSelected: (action) {
                            if (action == 'schedule') {
                              widget.onScheduleAttachment?.call();
                            } else {
                              widget.onAttach?.call();
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'send',
                              child: Text(l10nOf(context).uiShareFileNow96E2A2),
                            ),
                            PopupMenuItem(
                              value: 'schedule',
                              child: Text(l10nOf(context).uiScheduleFile690A92),
                            ),
                          ],
                        ),
                        const SizedBox(width: 4),
                      ],
                      StreamBuilder<VoiceRecordingState>(
                        stream: controller.voiceMessageService.states,
                        initialData: controller.voiceMessageService.state,
                        builder: (context, snapshot) {
                          final state =
                              snapshot.data ?? VoiceRecordingState.idle;
                          final recording =
                              state == VoiceRecordingState.recording;
                          final ownsPreview =
                              controller
                                  .voiceMessageService
                                  .previewDestinationKey ==
                              'group:${group.groupId}';
                          final preview =
                              state == VoiceRecordingState.preview &&
                              ownsPreview;
                          final foreignRecording = recording && !ownsPreview;
                          final foreignPreview =
                              state == VoiceRecordingState.preview &&
                              !ownsPreview;
                          return GestureDetector(
                            onLongPressStart:
                                preview ||
                                    foreignPreview ||
                                    foreignRecording ||
                                    _voiceRecordingStarting
                                ? null
                                : (_) => _beginGroupVoiceRecording(),
                            onLongPressMoveUpdate:
                                preview || foreignPreview || foreignRecording
                                ? null
                                : _moveGroupVoiceRecording,
                            onLongPressEnd:
                                preview || foreignPreview || foreignRecording
                                ? null
                                : (_) =>
                                      unawaited(_releaseGroupVoiceRecording()),
                            child: IconButton(
                              onPressed:
                                  canSend &&
                                      !foreignPreview &&
                                      !foreignRecording
                                  ? (_voiceRecordingStarting
                                        ? _cancelGroupVoiceRecording
                                        : recording || preview
                                        ? _finishGroupVoiceRecording
                                        : _beginGroupVoiceRecording)
                                  : null,
                              tooltip: foreignRecording
                                  ? l10nOf(
                                      context,
                                    ).uiRecordingBelongsToAnotherConversation87E802
                                  : foreignPreview
                                  ? l10nOf(
                                      context,
                                    ).uiFinishTheVoicePreviewIn142571
                                  : preview
                                  ? l10nOf(
                                      context,
                                    ).uiReviewUnsentVoiceMessage24931C
                                  : _voiceRecordingStarting
                                  ? l10nOf(
                                      context,
                                    ).uiCancelMicrophoneStartup9E9F8A
                                  : _voiceRecordingCancelGesture
                                  ? l10nOf(
                                      context,
                                    ).uiReleaseToDiscardRecording4C5C71
                                  : _voiceRecordingLocked
                                  ? l10nOf(
                                      context,
                                    ).uiRecordingLockedTapToFinish40CD88
                                  : recording
                                  ? l10nOf(
                                      context,
                                    ).uiReleaseToStopSlideLeft4686F1
                                  : l10nOf(context).uiHoldToRecordAGroupC11B32,
                              icon: Icon(
                                _voiceRecordingCancelGesture
                                    ? Icons.delete_outline
                                    : _voiceRecordingLocked
                                    ? Icons.lock_clock_outlined
                                    : recording
                                    ? Icons.stop_circle_outlined
                                    : preview
                                    ? Icons.play_circle_outline
                                    : Icons.mic_none_outlined,
                                color: _voiceRecordingCancelGesture || recording
                                    ? palette.danger
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        onPressed: canSend
                            ? () => unawaited(
                                _createPoll().catchError(
                                  (Object error) =>
                                      controller.setStatus('$error'),
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.poll_outlined),
                        tooltip: l10nOf(context).uiCreatePoll8F5663,
                      ),
                      Expanded(
                        child: Shortcuts(
                          shortcuts: <ShortcutActivator, Intent>{
                            const SingleActivator(
                              LogicalKeyboardKey.keyV,
                              control: true,
                            ): const _PasteMediaIntent(),
                            const SingleActivator(
                              LogicalKeyboardKey.keyV,
                              meta: true,
                            ): const _PasteMediaIntent(),
                          },
                          child: Actions(
                            actions: <Type, Action<Intent>>{
                              _PasteMediaIntent:
                                  CallbackAction<_PasteMediaIntent>(
                                    onInvoke: (_) {
                                      widget.onSmartPaste?.call();
                                      return null;
                                    },
                                  ),
                            },
                            child: TextField(
                              controller: widget.composerController,
                              contentInsertionConfiguration:
                                  widget.onContentInserted == null
                                  ? null
                                  : ContentInsertionConfiguration(
                                      onContentInserted:
                                          widget.onContentInserted!,
                                    ),
                              minLines: 1,
                              maxLines: 5,
                              enabled: canSend,
                              decoration: InputDecoration(
                                hintText: canSend
                                    ? activeReplyTarget == null
                                          ? l10nOf(context).uiWriteToGroup5878DB
                                          : l10nOf(context).uiWriteAReply0A58E1
                                    : l10nOf(context).uiYouAreNoLongerIn571DA7,
                              ),
                              onSubmitted: (_) {
                                if (canSend) {
                                  widget.onSend();
                                }
                              },
                              contextMenuBuilder: (context, editableTextState) {
                                final items = List<ContextMenuButtonItem>.from(
                                  editableTextState.contextMenuButtonItems,
                                );
                                if (widget.onSmartPaste != null) {
                                  items.add(
                                    ContextMenuButtonItem(
                                      label: l10nOf(context).uiPasteMedia4831DE,
                                      onPressed: () {
                                        ContextMenuController.removeAny();
                                        widget.onSmartPaste!();
                                      },
                                    ),
                                  );
                                }
                                return AdaptiveTextSelectionToolbar.buttonItems(
                                  anchors: editableTextState.contextMenuAnchors,
                                  buttonItems: items,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        tooltip: l10nOf(context).composerSchedule,
                        onPressed: canSend ? _scheduleText : null,
                        icon: const Icon(Icons.schedule_send_outlined),
                      ),
                      if (MediaQuery.sizeOf(context).width < 500)
                        IconButton.filled(
                          onPressed: canSend ? widget.onSend : null,
                          icon: const Icon(Icons.send),
                          tooltip: l10nOf(context).composerSend,
                        )
                      else
                        FilledButton.icon(
                          onPressed: canSend ? widget.onSend : null,
                          icon: const Icon(Icons.send),
                          label: Text(l10nOf(context).composerSend),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    Widget searchable(Widget child) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _searchMessages,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _searchMessages,
      },
      child: child,
    );
    if (!_isDesktopPlatform) {
      return searchable(body);
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _droppingFiles = true),
      onDragExited: (_) => setState(() => _droppingFiles = false),
      onDragDone: (details) {
        setState(() => _droppingFiles = false);
        widget.onDropFiles(details.files);
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          searchable(body),
          if (_droppingFiles)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: palette.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: palette.primary, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    l10nOf(context).uiDropToShareThisFile0B73E8,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: palette.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupPollCard extends StatelessWidget {
  const _GroupPollCard({
    required this.groupId,
    required this.poll,
    required this.controller,
    required this.palette,
  });

  final String groupId;
  final PollDefinition poll;
  final MessengerController controller;
  final ConestPalette palette;

  Future<void> _chooseMultiple(BuildContext context) async {
    final selected = <int>{};
    final result = await showDialog<List<int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(poll.question),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < poll.options.length; index++)
                CheckboxListTile(
                  value: selected.contains(index),
                  title: Text(poll.options[index]),
                  onChanged: (value) => setDialogState(() {
                    if (value == true) {
                      selected.add(index);
                    } else {
                      selected.remove(index);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10nOf(context).actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected.toList()),
              child: Text(l10nOf(context).uiVote64F872),
            ),
          ],
        ),
      ),
    );
    if (result == null || result.isEmpty) return;
    await controller.voteInGroupPoll(
      groupId: groupId,
      pollId: poll.id,
      optionIndexes: result,
    );
  }

  @override
  Widget build(BuildContext context) {
    final projection = controller.groupPollProjection(groupId, poll.id);
    final canParticipate = projection != null;
    final counts =
        projection?.counts() ?? List<int>.filled(poll.options.length, 0);
    final closed = projection?.definition.isClosed ?? poll.isClosed;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: palette.panel2.withValues(alpha: 0.65),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              poll.question,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (var index = 0; index < poll.options.length; index++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton(
                      onPressed:
                          !canParticipate ||
                              closed ||
                              poll.mode == PollChoiceMode.multiple
                          ? null
                          : () => unawaited(
                              controller
                                  .voteInGroupPoll(
                                    groupId: groupId,
                                    pollId: poll.id,
                                    optionIndexes: [index],
                                  )
                                  .catchError(
                                    (Object error) =>
                                        controller.setStatus('$error'),
                                  ),
                            ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              poll.options[index],
                              textAlign: TextAlign.start,
                            ),
                          ),
                          Text("${(counts[index])}"),
                        ],
                      ),
                    ),
                    if (projection != null && projection.votes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 8,
                          bottom: 4,
                        ),
                        child: Text(
                          projection.votes.entries
                              .where(
                                (entry) => entry.value.optionIndexes.contains(
                                  '$index',
                                ),
                              )
                              .map(
                                (entry) =>
                                    controller.groupMemberLabel(entry.key),
                              )
                              .join(', '),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ),
                  ],
                ),
              ),
            if (canParticipate &&
                !closed &&
                poll.mode == PollChoiceMode.multiple)
              FilledButton.tonal(
                onPressed: () => unawaited(
                  _chooseMultiple(context).catchError(
                    (Object error) => controller.setStatus('$error'),
                  ),
                ),
                child: Text(l10nOf(context).uiChooseOptionsEA120E),
              ),
            if (canParticipate &&
                !closed &&
                projection
                        ?.votes[controller.identity?.deviceId]
                        ?.optionIndexes
                        .isNotEmpty ==
                    true)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => unawaited(
                    controller
                        .voteInGroupPoll(
                          groupId: groupId,
                          pollId: poll.id,
                          optionIndexes: const <int>[],
                        )
                        .catchError(
                          (Object error) => controller.setStatus('$error'),
                        ),
                  ),
                  child: Text(l10nOf(context).uiRetractVoteA5DA11),
                ),
              ),
            Text(
              closed
                  ? l10nOf(context).uiClosed88D86B
                  : l10nOf(context).uiVisibleVotes460E7A,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: palette.inkSoft),
            ),
            if (closed && (projection?.unconfirmedVotes.isNotEmpty ?? false))
              Text(
                l10nOf(context).uiValueVoteSWereNot02CC9A(
                  (projection!.unconfirmedVotes.length),
                ),
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: palette.inkSoft),
              ),
            if (!canParticipate)
              Text(
                l10nOf(context).uiVotingIsUnavailableWithThis9B92E7,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: palette.inkSoft),
              ),
            if (canParticipate &&
                !closed &&
                controller.identity?.deviceId == poll.creatorDeviceId)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: () => unawaited(
                    controller
                        .closeGroupPoll(groupId: groupId, pollId: poll.id)
                        .catchError(
                          (Object error) => controller.setStatus('$error'),
                        ),
                  ),
                  icon: const Icon(Icons.lock_outline, size: 16),
                  label: Text(l10nOf(context).uiClosePollA6A189),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChatPanel extends StatefulWidget {
  const _ChatPanel({
    super.key,
    this.telegramLayout = false,
    required this.controller,
    required this.palette,
    required this.contact,
    required this.composerController,
    required this.replyTarget,
    required this.onCancelReply,
    required this.onReplyToMessage,
    required this.onSend,
    required this.onShowProfile,
    required this.onAttach,
    required this.onDropFiles,
    this.onBack,
    this.onSmartPaste,
    this.onContentInserted,
  });

  final bool telegramLayout;
  final MessengerController controller;
  final ConestPalette palette;
  final ContactRecord contact;
  final TextEditingController composerController;
  final ChatMessage? replyTarget;
  final VoidCallback onCancelReply;
  final ValueChanged<ChatMessage> onReplyToMessage;
  final VoidCallback onSend;
  final VoidCallback onShowProfile;
  final VoidCallback onAttach;
  final ValueChanged<List<XFile>> onDropFiles;
  final VoidCallback? onBack;
  final VoidCallback? onSmartPaste;

  /// An image or GIF from the keyboard (Android).
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _messageListKey = GlobalKey();
  bool _droppingFiles = false;
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  final Map<String, GlobalKey<PopupMenuButtonState<String>>> _messageActionKeys = {};
  bool _didInitialPosition = false;
  bool _initialPositionScheduled = false;
  final ReadSweepTimer _readSweep = ReadSweepTimer();
  String? _anchoredFirstUnreadId;
  final LinkedHashSet<String> _selectedMessageIds = LinkedHashSet<String>();
  String? _flashingMessageId;
  Timer? _flashTimer;
  bool _routeInspectorOpen = false;
  bool _voiceRecordingStarting = false;
  bool _voiceRecordingLocked = false;
  bool _voiceRecordingCancelGesture = false;
  bool _voiceSending = false;

  bool get _voiceRecording => controller.voiceMessageService.isRecording;

  @override
  void initState() {
    super.initState();
    // Scrolling to older unread messages marks them read.
    _scrollController.addListener(_handleScroll);
  }

  static const Duration _replyFlashDuration = Duration(milliseconds: 320);

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  MessengerController get controller => widget.controller;
  ConestPalette get palette => widget.palette;
  ContactRecord get contact => widget.contact;

  Future<void> _scheduleText() async {
    final body = widget.composerController.text.trim();
    final staged = controller.stagedAttachmentsFor(contact.deviceId);
    if (staged.length > 1) {
      controller.setStatus('Schedule one attachment at a time.');
      return;
    }
    if (body.isEmpty && staged.isEmpty) return;
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null || !mounted) return;
    final due = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (staged case [final attachment]) {
      try {
        await controller.scheduleAttachment(
          contact: contact,
          confirmKeepingMetadata: (error) async =>
              mounted &&
              await confirmSendingMetadata(
                context,
                error.fileName,
                partial: error.partial,
              ),
          source: attachment,
          scheduledAt: due,
          caption: body,
        );
      } catch (error) {
        controller.setStatus(
          'Could not schedule ${attachment.fileName}: $error',
        );
        return;
      }
      controller.removeStaged(
        deviceId: contact.deviceId,
        stagedId: attachment.id,
      );
    } else {
      await controller.scheduleTextMessage(
        kind: ConversationKind.direct,
        conversationId: contact.deviceId,
        body: body,
        scheduledAt: due,
      );
    }
    widget.composerController.clear();
    controller.setStatus('Message scheduled for ${due.toLocal()}.');
  }

  Future<void> _beginVoiceRecording() async {
    if (_voiceRecording || _voiceRecordingStarting) return;
    setState(() {
      _voiceRecordingStarting = true;
      _voiceRecordingLocked = false;
      _voiceRecordingCancelGesture = false;
    });
    try {
      await controller.voiceMessageService.start(
        destinationKey: 'direct:${contact.deviceId}',
      );
      if (!mounted) {
        await controller.voiceMessageService.stopForInterruption();
        return;
      }
    } catch (error) {
      if (error is! StateError ||
          (!error.message.toString().contains('startup') &&
              !error.message.toString().contains('before it started'))) {
        controller.setStatus('$error');
      }
    } finally {
      if (mounted) setState(() => _voiceRecordingStarting = false);
    }
  }

  void _moveVoiceRecording(LongPressMoveUpdateDetails details) {
    if ((!_voiceRecording && !_voiceRecordingStarting) ||
        _voiceRecordingLocked) {
      return;
    }
    final cancel = details.offsetFromOrigin.dx <= -96;
    final locked = !cancel && details.offsetFromOrigin.dy <= -96;
    if (cancel == _voiceRecordingCancelGesture &&
        locked == _voiceRecordingLocked) {
      return;
    }
    setState(() {
      _voiceRecordingCancelGesture = cancel;
      _voiceRecordingLocked = locked;
    });
  }

  Future<void> _cancelVoiceRecording() async {
    final service = controller.voiceMessageService;
    await service.cancel();
    if (mounted && !_voiceRecordingStarting) {
      setState(() {
        _voiceRecordingLocked = false;
        _voiceRecordingCancelGesture = false;
      });
    }
  }

  Future<void> _releaseVoiceRecording() async {
    if (_voiceRecordingCancelGesture) {
      await _cancelVoiceRecording();
    } else if (!_voiceRecordingLocked) {
      await _finishVoiceRecording();
    }
  }

  Future<void> _finishVoiceRecording() async {
    final voiceService = controller.voiceMessageService;
    if (_voiceRecordingStarting) {
      await voiceService.stopForInterruption();
      return;
    }
    if (!_voiceRecording) return;
    if (mounted) {
      setState(() {
        _voiceRecordingLocked = false;
        _voiceRecordingCancelGesture = false;
      });
    }
    try {
      await voiceService.stop();
    } catch (error) {
      if (voiceService.isRecording) {
        await voiceService.stopForInterruption();
      }
      voiceService.reportRecordingError(error);
    }
  }

  Future<void> _sendVoicePreview() async {
    if (_voiceSending) return;
    setState(() => _voiceSending = true);
    try {
      await controller.sendRecordedVoiceMessage(contact: contact);
    } catch (error) {
      controller.voiceMessageService.reportRecordingError(error);
    } finally {
      if (mounted) setState(() => _voiceSending = false);
    }
  }

  /// Derives the LAN/relay paths for the [RouteInspector] from the contact's
  /// route hints and the live route-health tracker. The lower-RTT reachable
  /// LAN route is preferred (active); relay is the fallback.
  List<RouteInspectorPath> _routeInspectorPaths() {
    Duration? lanRtt;
    Duration? relayRtt;
    var lanUp = false;
    var relayUp = false;
    for (final route in contact.routeHints) {
      final health = controller.routeHealthFor(route);
      final up = health?.available ?? false;
      final latency = health?.latency;
      if (route.kind == PeerRouteKind.lan ||
          route.kind == PeerRouteKind.directInternet) {
        if (up) {
          lanUp = true;
          if (latency != null && (lanRtt == null || latency < lanRtt)) {
            lanRtt = latency;
          }
        }
      } else if (route.kind == PeerRouteKind.relay) {
        if (up) {
          relayUp = true;
          if (latency != null && (relayRtt == null || latency < relayRtt)) {
            relayRtt = latency;
          }
        }
      }
    }
    String rtt(Duration? d) => d == null ? '? ms' : '${d.inMilliseconds}ms';
    final lanActive = lanUp;
    return [
      RouteInspectorPath(
        label: l10nOf(context).uiLAN2ECD17,
        detail: lanUp ? '${rtt(lanRtt)} · 0 hops' : 'unreachable',
        color: palette.primary,
        active: lanActive,
        available: lanUp,
      ),
      RouteInspectorPath(
        label: l10nOf(context).uiRELAYA1C0CF,
        detail: relayUp ? '${rtt(relayRtt)} · 2 hops' : 'unreachable',
        color: palette.secondary,
        active: !lanActive && relayUp,
        available: relayUp,
      ),
    ];
  }

  int _searchGeneration = 0;

  Future<void> _searchMessages() async {
    final generation = ++_searchGeneration;
    final conversationId = contact.deviceId;
    final selected = await showModalBottomSheet<ChatMessage>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ChatMessageSearch(
        messages: () => controller.messagesFor(contact.deviceId),
        changes: controller,
      ),
    );
    if (selected == null || !mounted || contact.deviceId != conversationId) {
      return;
    }
    final messages = controller.messagesFor(contact.deviceId);
    // Album continuations are represented by their first bubble in the list.
    var target = selected.id;
    final index = messages.indexWhere((message) => message.id == target);
    if (index >= 0 && _isAlbumContinuation(messages, index)) {
      var anchor = index;
      while (anchor > 0 && _isAlbumContinuation(messages, anchor)) {
        anchor--;
      }
      target = messages[anchor].id;
    }
    final found = await revealChatMessage(
      scroll: _scrollController,
      keys: _messageKeys,
      messages: messages,
      messageId: target,
      isCurrent: () =>
          mounted &&
          _searchGeneration == generation &&
          contact.deviceId == conversationId,
    );
    if (!mounted || _searchGeneration != generation) return;
    if (found) {
      _flashMessage(target);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10nOf(context).uiCouldNotLocateThisMessage220E83),
        ),
      );
    }
  }

  void _flashMessage(String messageId) {
    _flashTimer?.cancel();
    setState(() => _flashingMessageId = messageId);
    _flashTimer = Timer(_replyFlashDuration, () {
      if (!mounted) return;
      setState(() => _flashingMessageId = null);
    });
  }

  void _toggleMessageSelection(ChatMessage message) {
    setState(() {
      if (_selectedMessageIds.contains(message.id)) {
        _selectedMessageIds.remove(message.id);
      } else {
        _selectedMessageIds.add(message.id);
      }
    });
  }

  void _clearMessageSelection() {
    if (_selectedMessageIds.isEmpty) return;
    setState(_selectedMessageIds.clear);
  }

  List<ChatMessage> _selectedMessagesInOrder(List<ChatMessage> all) {
    return all.where((m) => _selectedMessageIds.contains(m.id)).toList();
  }

  bool _canDeleteSelected(List<ChatMessage> all) {
    final selected = _selectedMessagesInOrder(all);
    if (selected.isEmpty) return false;
    return selected.every((m) => m.outbound);
  }

  bool _canSaveSelected(List<ChatMessage> all) {
    final selected = _selectedMessagesInOrder(all);
    return selected.any((m) {
      final att = m.attachment;
      if (att == null) return false;
      return controller.attachmentAvailableLocally(att.id);
    });
  }

  Future<void> _copySelectedMessagesText(List<ChatMessage> all) async {
    final selected = _selectedMessagesInOrder(all);
    if (selected.isEmpty) return;
    final text = selected
        .map((m) {
          final att = m.attachment;
          if (att != null && m.body.isEmpty) {
            return '[${att.fileName}]';
          }
          if (att != null) {
            return '${m.body}\n[${att.fileName}]';
          }
          return m.body;
        })
        .where((s) => s.isNotEmpty)
        .join('\n');
    if (text.isEmpty) {
      controller.setStatus('Nothing to copy from the selected messages.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    controller.setStatus('Copied ${selected.length} message(s).');
    _clearMessageSelection();
  }

  Future<void> _deleteSelected(List<ChatMessage> all) async {
    final selected = _selectedMessagesInOrder(all);
    if (selected.isEmpty) return;
    for (final m in selected) {
      try {
        await controller.deleteMessage(contact: contact, messageId: m.id);
      } catch (error) {
        controller.setStatus('Delete failed for one message: $error');
      }
    }
    _clearMessageSelection();
  }

  Future<void> _bulkSaveSelected(List<ChatMessage> all) async {
    final selected = _selectedMessagesInOrder(
      all,
    ).where((m) => m.attachment != null).toList();
    final ready = selected
        .where((m) => controller.attachmentAvailableLocally(m.attachment!.id))
        .toList();
    if (ready.isEmpty) {
      controller.setStatus(
        'No selected attachment is ready yet — still transferring.',
      );
      return;
    }
    _clearMessageSelection();
    await bulkSaveAttachments(
      controller,
      ready.map((message) => message.attachment!).toList(growable: false),
    );
  }

  @override
  void didUpdateWidget(covariant _ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contact.deviceId != widget.contact.deviceId) {
      _messageKeys.clear();
      _didInitialPosition = false;
      _initialPositionScheduled = false;
      _anchoredFirstUnreadId = null;
      _readSweep.cancel();
    }
    _scheduleInitialPosition();
    _scheduleReadSweep();
  }

  @override
  void dispose() {
    final voiceService = controller.voiceMessageService;
    if (voiceService.isRecording &&
        voiceService.previewDestinationKey == 'direct:${contact.deviceId}') {
      unawaited(voiceService.stopForInterruption());
    }
    _readSweep.cancel();
    _flashTimer?.cancel();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _messageKeyFor(String messageId) {
    return _messageKeys.putIfAbsent(
      messageId,
      () => GlobalKey(debugLabel: 'chat-message-$messageId'),
    );
  }

  GlobalKey<PopupMenuButtonState<String>> _messageActionKey(String messageId) =>
      _messageActionKeys.putIfAbsent(
        messageId,
        () => GlobalKey<PopupMenuButtonState<String>>(),
      );

  void _pruneMessageKeys(List<ChatMessage> messages) {
    final activeIds = messages.map((message) => message.id).toSet();
    _messageKeys.removeWhere((messageId, _) => !activeIds.contains(messageId));
    _messageActionKeys.removeWhere((messageId, _) => !activeIds.contains(messageId));
  }

  void _scheduleInitialPosition() {
    if (_didInitialPosition || _initialPositionScheduled) {
      return;
    }
    _initialPositionScheduled = true;
    // With the reverse:true ListView, the default scroll position is offset
    // 0 = latest message — no jumpTo needed. The only post-frame work is to
    // surface the oldest unread message (if any) so the user can scroll up
    // through history starting from there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPositionScheduled = false;
      if (!mounted || _didInitialPosition) {
        return;
      }
      final messages = controller.messagesFor(contact.deviceId);
      ChatMessage? firstUnread;
      for (final message in messages) {
        if (!message.outbound &&
            controller.isUnreadMessage(contact.deviceId, message)) {
          firstUnread = message;
          break;
        }
      }
      if (firstUnread != null) {
        _anchoredFirstUnreadId ??= firstUnread.id;
        final unreadContext = _messageKeyFor(firstUnread.id).currentContext;
        if (unreadContext != null) {
          Scrollable.ensureVisible(
            unreadContext,
            alignment: 0.5,
            duration: Duration.zero,
          );
        }
      }
      _didInitialPosition = true;
      _scheduleReadSweep();
    });
  }

  void _handleScroll() => _scheduleReadSweep(restart: true);

  void _scheduleReadSweep({bool restart = false}) {
    if (!mounted || !_didInitialPosition || !controller.isAppForeground) {
      return;
    }
    // Telegram-style: the mark-read waits 800 ms (see ReadSweepTimer).
    _readSweep.schedule(_runReadSweep, restart: restart);
  }

  Future<void> _runReadSweep() async {
    if (!mounted || !controller.isAppForeground) return;
    final latestVisibleUnread = _latestVisibleUnreadMessage();
    if (latestVisibleUnread == null) return;
    await controller.markConversationReadThroughMessage(
      contact.deviceId,
      latestVisibleUnread,
    );
  }

  ChatMessage? _latestVisibleUnreadMessage() {
    final viewportContext = _messageListKey.currentContext;
    final viewportBox = viewportContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.attached) {
      return null;
    }
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    ChatMessage? latestVisibleUnread;
    for (final message in controller.messagesFor(contact.deviceId)) {
      if (message.outbound ||
          !controller.isUnreadMessage(contact.deviceId, message)) {
        continue;
      }
      final messageContext = _messageKeyFor(message.id).currentContext;
      final messageBox = messageContext?.findRenderObject() as RenderBox?;
      if (messageBox == null || !messageBox.attached) {
        continue;
      }
      final messageTop = messageBox.localToGlobal(Offset.zero).dy;
      final messageBottom = messageTop + messageBox.size.height;
      final visible =
          messageBottom > viewportTop + 4 && messageTop < viewportBottom - 4;
      if (!visible) {
        continue;
      }
      latestVisibleUnread = message;
    }
    return latestVisibleUnread;
  }

  Future<void> _editMessage(BuildContext context, ChatMessage message) async {
    final updated = await showDialog<String>(
      context: context,
      builder: (context) => _EditMessageDialog(initialBody: message.body),
    );
    if (updated == null) {
      return;
    }
    await controller.editMessage(
      contact: contact,
      messageId: message.id,
      body: updated,
    );
  }

  Future<void> _deleteMessage(BuildContext context, ChatMessage message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiDeleteMessageD536CF),
        content: Text(
          message.outbound && message.state != DeliveryState.pending
              ? l10nOf(context).uiThisRemovesTheMessageHere61D27C
              : l10nOf(context).uiThisRemovesTheMessageFrom6A47E2,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).menuDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await controller.deleteMessage(contact: contact, messageId: message.id);
  }

  Future<void> _copyMessage(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.body));
    controller.setStatus('Copied message text.');
  }

  String _messageSenderLabel(ChatMessage message) {
    final me = controller.identity;
    if (me != null && message.senderDeviceId == me.deviceId) {
      return 'You';
    }
    return contact.alias;
  }

  String _replyReferenceLabel(ChatMessage message) {
    final me = controller.identity;
    if (me != null && message.replySenderDeviceId == me.deviceId) {
      return 'You';
    }
    if (message.replySenderDeviceId == contact.deviceId) {
      return contact.alias;
    }
    return message.replySenderDisplayName ?? 'Message';
  }

  Widget _buildAlbumBubble(BuildContext context, List<ChatMessage> members) {
    if (members.isEmpty) return const SizedBox.shrink();
    final allSelected = members.every(
      (m) => _selectedMessageIds.contains(m.id),
    );
    // Keyed by the newest member, so the read sweep sees the album.
    return _AlbumBubble(
      key: _messageKeyFor(members.last.id),
      members: members,
      controller: controller,
      palette: palette,
      outbound: members.first.outbound,
      selectionMode: _selectionMode,
      selected: allSelected,
      onForwardAttachment: (descriptor) =>
          _forwardAttachment(context, controller, palette, descriptor),
      onForwardAlbum: (album) =>
          _forwardMessages(context, controller, palette, album),
      selectedIds: _selectedMessageIds,
      onToggleMember: _toggleMessageSelection,
      onDeleteAttachment: (message) => _deleteMessage(context, message),
      onToggleSelection: (album) {
        setState(() {
          final alreadyAll = album.every(
            (m) => _selectedMessageIds.contains(m.id),
          );
          if (alreadyAll) {
            for (final m in album) {
              _selectedMessageIds.remove(m.id);
            }
          } else {
            for (final m in album) {
              _selectedMessageIds.add(m.id);
            }
          }
        });
      },
    );
  }

  Widget _buildMessageBubble(BuildContext context, ChatMessage message) {
    final outbound = message.outbound;
    final unread = controller.isUnreadMessage(contact.deviceId, message);
    final selected = _selectedMessageIds.contains(message.id);
    final flashing = _flashingMessageId == message.id;
    final baseColor = selected
        ? palette.primary.withValues(alpha: 0.18)
        : (outbound ? palette.outboundBubble : palette.inboundBubble);
    // Signature: the outbound (self) bubble is the mint→teal gradient with a
    // faint bloom when the theme wants glow; inbound stays a flat panel with a
    // hairline border. Selection/flash states fall back to a flat fill.
    final useSelfGradient = outbound && !selected && !flashing;
    final attachmentDescriptor = message.attachment;
    final attachmentRow = attachmentDescriptor == null
        ? null
        : _AttachmentRow(
            descriptor: attachmentDescriptor,
            outbound: outbound,
            palette: palette,
            controller: controller,
            messageState: message.state,
            conversationPeerDeviceId: contact.deviceId,
            onForward: () => _forwardAttachment(
              context,
              controller,
              palette,
              attachmentDescriptor,
            ),
            onDelete: () => _deleteMessage(context, message),
          );
    final attachmentInFlight = attachmentDescriptor != null &&
        (controller.attachmentTransferProgress(attachmentDescriptor.id) != null ||
            controller.outboundAttachmentProgress(attachmentDescriptor.id) != null);
    final attachmentAvailable = attachmentDescriptor != null &&
        controller.attachmentAvailableLocally(attachmentDescriptor.id);
    return GestureDetector(
      key: _messageKeyFor(message.id),
      // nightly.10: opaque so long-press registers in the empty row space
      // next to the bubble, not just on the bubble itself.
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_selectionMode) {
          _toggleMessageSelection(message);
        } else {
          _messageActionKey(message.id).currentState?.showButtonMenu();
        }
      },
      onSecondaryTapDown: (_) =>
          _messageActionKey(message.id).currentState?.showButtonMenu(),
      onLongPress: () => _toggleMessageSelection(message),
      onDoubleTap: _selectionMode
          ? null
          : () async {
              _flashMessage(message.id);
              if (outbound) {
                await _editMessage(context, message);
              } else {
                widget.onReplyToMessage(message);
              }
            },
      child: Align(
        alignment: outbound
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: AnimatedContainer(
          duration: _replyFlashDuration,
          curve: Curves.easeOut,
          constraints: const BoxConstraints(maxWidth: 520),
          margin: EdgeInsets.only(bottom: widget.telegramLayout ? 6 : 12),
          padding: widget.telegramLayout
              ? const EdgeInsets.fromLTRB(12, 8, 8, 4)
              : const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: useSelfGradient
                ? null
                : (flashing
                      ? Color.alphaBlend(
                          palette.primary.withValues(alpha: 0.28),
                          baseColor,
                        )
                      : baseColor),
            gradient: useSelfGradient ? palette.outboundBubbleGradient : null,
            borderRadius: BorderRadius.circular(18),
            boxShadow: useSelfGradient && palette.glow
                ? [
                    BoxShadow(
                      color: palette.primary.withValues(alpha: 0.22),
                      blurRadius: 12,
                    ),
                  ]
                : null,
            border: selected
                ? Border.all(color: palette.primary, width: 2)
                : (outbound
                      ? null
                      : Border.all(
                          color: unread
                              ? palette.unread.withValues(alpha: 0.55)
                              : palette.border,
                        )),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.hasReplyPreview) ...[
                      _QuotedReference(
                        palette: palette,
                        outbound: outbound,
                        senderLabel: _replyReferenceLabel(message),
                        snippet: message.replySnippet!,
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (message.hasAttachment) ...[
                      attachmentRow!,
                      if (message.body.isNotEmpty) const SizedBox(height: 8),
                    ],
                    if (message.body.isNotEmpty || !message.hasAttachment)
                      Text(
                        message.body,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: outbound
                              ? palette.outboundText
                              : palette.inboundText,
                          height: 1.35,
                        ),
                      ),
                    if (message.reactions.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final entry in message.reactions.entries)
                            ActionChip(
                              label: Text("${(entry.key)} ${(entry.value.length)}"),
                              onPressed: () => unawaited(
                                controller
                                    .toggleMessageReaction(
                                      contact: contact,
                                      messageId: message.id,
                                      emoji: entry.key,
                                    )
                                    .catchError(
                                      (Object error) =>
                                          controller.setStatus('$error'),
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.telegramLayout
                        ? chatMessageTime(context, message.createdAt)
                        : formatTimestamp(message.createdAt),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontFamily: ConestPalette.monoFont,
                      color: outbound
                          ? palette.outboundMeta
                          : palette.inboundMeta,
                    ),
                  ),
                  if (!outbound && unread) ...[
                    const SizedBox(width: 6),
                    Text(
                      l10nOf(context).uiNewC2A6B0,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontFamily: ConestPalette.monoFont,
                        color: palette.unread,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  if (message.isEdited) ...[
                    const SizedBox(width: 6),
                    Text(
                      l10nOf(context).uiEditedA22FCA,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: outbound
                            ? palette.outboundMeta
                            : palette.inboundMeta,
                      ),
                    ),
                  ],
                  if (message.effectiveRoute != null &&
                      controller.userMode.showsNetworkDetail) ...[
                    const SizedBox(width: 8),
                    _MessageRouteChip(
                      message: message,
                      compact: widget.telegramLayout,
                    ),
                  ],
                  if (controller.canSendViaPlainMatrix(
                    contact.deviceId,
                    message,
                  ))
                    IconButton(
                      tooltip: l10nOf(context).uiNotDeliveredYetSendViaF056E1,
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      onPressed: () => _sendViaPlainMatrix(
                        context,
                        controller,
                        contact,
                        message,
                      ),
                      icon: const Icon(Icons.alternate_email),
                    ),
                  if (outbound) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: message.route == MessageRoute.plainMatrix
                          ? l10nOf(context).uiSentAsAPlainMatrixAAE694
                          : deliveryStateLabel(context, message.state),
                      child: Icon(
                        message.state.icon,
                        size: 16,
                        color: palette.outboundMeta,
                      ),
                    ),
                  ],
                  PopupMenuButton<String>(
                    key: _messageActionKey(message.id),
                    tooltip: l10nOf(context).uiMessageActions949184,
                    padding: EdgeInsets.zero,
                    child: const SizedBox.shrink(),
                    onSelected: (value) async {
                      try {
                        if (value == 'copy') {
                          await _copyMessage(message);
                        } else if (value == 'details') {
                          await MessageInfoDialog.show(
                            context,
                            message: message,
                            timestamp: formatTimestamp,
                            showRoutes: controller.userMode.showsNetworkDetail,
                            senderClockOffset: controller.clockOffsetFor(
                              message.senderDeviceId,
                            ),
                            senderOutOfTouchSince: controller
                                .contactDeviceOutOfTouchSince(
                                  message.senderDeviceId,
                                ),
                          );
                        } else if (value == 'forward') {
                          await _forwardTextMessage(
                            context,
                            controller,
                            palette,
                            message,
                          );
                        } else if (value == 'reply') {
                          widget.onReplyToMessage(message);
                        } else if (value == 'react') {
                          await controller
                              .toggleMessageReaction(
                                contact: contact,
                                messageId: message.id,
                                emoji: '👍',
                              )
                              .catchError(
                                (Object error) =>
                                    controller.setStatus('$error'),
                              );
                        } else if (value == 'edit') {
                          await _editMessage(context, message);
                        } else if (value == 'cancel') {
                          await controller.cancelPendingMessage(
                            contact: contact,
                            messageId: message.id,
                          );
                        } else if (value == 'plain_matrix') {
                          await _sendViaPlainMatrix(
                            context,
                            controller,
                            contact,
                            message,
                          );
                        } else if (value == 'attachment_download' &&
                            attachmentDescriptor != null) {
                          await controller.acceptIncomingAttachment(
                            attachmentDescriptor.id,
                          );
                        } else if (value == 'attachment_save' &&
                            attachmentRow != null) {
                          if (attachmentAvailable) {
                            await attachmentRow._saveLocalFileToDisk();
                          } else {
                            controller.setStatus(
                              'The attachment is still downloading.',
                            );
                          }
                        } else if (value == 'attachment_copy_image' &&
                            attachmentDescriptor != null) {
                          final bytes = controller.attachmentBytesFor(
                            attachmentDescriptor.id,
                          );
                          if (bytes != null) {
                            await attachmentRow!._copyImageBytesFor(
                              bytes,
                              attachmentDescriptor.fileName,
                            );
                          }
                        } else if (value == 'attachment_copy_path' &&
                            attachmentRow != null) {
                          await attachmentRow._copyCachePath();
                        } else if (value == 'attachment_keep_offline' &&
                            attachmentDescriptor != null) {
                          await controller.setAttachmentKeepOffline(
                            attachmentDescriptor.id,
                            !controller.attachmentKeptOffline(
                              attachmentDescriptor.id,
                            ),
                          );
                        } else if (value == 'attachment_evict' &&
                            attachmentDescriptor != null) {
                          await controller.evictAttachment(
                            attachmentDescriptor.id,
                          );
                        } else if (value == 'attachment_cancel' &&
                            attachmentDescriptor != null) {
                          await controller.cancelAttachmentById(
                            attachmentDescriptor.id,
                          );
                        } else if (value == 'attachment_retry' &&
                            attachmentDescriptor != null) {
                          controller.retryAttachment(attachmentDescriptor.id);
                        } else if (value == 'forward_attachment' &&
                            attachmentRow != null) {
                          await attachmentRow.onForward?.call();
                        } else if (value == 'delete') {
                          await _deleteMessage(context, message);
                        }
                      } catch (error) {
                        controller.setStatus(error.toString());
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'details',
                        child: Text(l10nOf(context).messageDetails),
                      ),
                      PopupMenuItem(
                        value: 'reply',
                        child: Text(l10nOf(context).menuReply),
                      ),
                      if (message.state != DeliveryState.canceled)
                        PopupMenuItem(
                          value: 'react',
                          child: Text(l10nOf(context).menuReact),
                        ),
                      if (!message.hasAttachment &&
                          message.body.trim().isNotEmpty)
                        PopupMenuItem(
                          value: 'forward',
                          child: Text(l10nOf(context).menuForward),
                        ),
                      PopupMenuItem(
                        value: 'copy',
                        child: Text(l10nOf(context).menuCopyMessage),
                      ),
                      if (attachmentDescriptor != null && !outbound &&
                          !attachmentAvailable)
                        PopupMenuItem(
                          value: 'attachment_download',
                          child: Text(l10nOf(context).menuDownloadAttachment),
                        ),
                      if (attachmentAvailable)
                        PopupMenuItem(
                          value: 'attachment_save',
                          child: Text(l10nOf(context).menuSaveAttachment),
                        ),
                      if (attachmentDescriptor?.mimeType.startsWith('image/') == true &&
                          controller.attachmentBytesFor(attachmentDescriptor!.id) != null)
                        PopupMenuItem(
                          value: 'attachment_copy_image',
                          child: Text(l10nOf(context).menuCopyImage),
                        ),
                      if (attachmentAvailable) ...[
                        PopupMenuItem(
                          value: 'attachment_copy_path',
                          child: Text(l10nOf(context).uiCopyCachePathC23134),
                        ),
                        PopupMenuItem(
                          value: 'attachment_keep_offline',
                          child: Text(
                            controller.attachmentKeptOffline(attachmentDescriptor.id)
                                ? l10nOf(context).uiStopKeepingOfflineAABFC7
                                : l10nOf(context).uiKeepOffline123286,
                          ),
                        ),
                        if (!controller.attachmentKeptOffline(attachmentDescriptor.id) &&
                            !attachmentInFlight)
                          PopupMenuItem(
                            value: 'attachment_evict',
                            child: Text(l10nOf(context).menuFreeUpSpace),
                          ),
                      ],
                      if (attachmentInFlight)
                        PopupMenuItem(
                          value: 'attachment_cancel',
                          child: Text(l10nOf(context).menuCancelTransfer),
                        ),
                      if (attachmentDescriptor != null && outbound &&
                          message.state == DeliveryState.failed)
                        PopupMenuItem(
                          value: 'attachment_retry',
                          child: Text(l10nOf(context).menuRetryTransfer),
                        ),
                      if (attachmentDescriptor != null)
                        PopupMenuItem(
                          value: 'forward_attachment',
                          child: Text(l10nOf(context).menuForwardAttachment),
                        ),
                      if (outbound && message.state == DeliveryState.pending)
                        PopupMenuItem(
                          value: 'cancel',
                          child: Text(l10nOf(context).menuCancelSending),
                        ),
                      if (controller.canSendViaPlainMatrix(
                        contact.deviceId,
                        message,
                      ))
                        PopupMenuItem(
                          value: 'plain_matrix',
                          child: Text(l10nOf(context).uiSendViaMatrix3868FE),
                        ),
                      if (outbound)
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(l10nOf(context).menuEditMessage),
                        ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(l10nOf(context).menuDeleteMessage),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = controller.messagesFor(contact.deviceId);
    _pruneMessageKeys(messages);
    if (controller.isAppForeground) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          controller.refreshConversationReachabilityIfStale(contact.deviceId),
        );
      });
    }
    _scheduleInitialPosition();
    _scheduleReadSweep();
    // Saved messages: no routes, calls or profile.
    final saved = controller.isSavedMessages(contact.deviceId);
    final reachabilityState = controller.reachabilityStateFor(contact.deviceId);
    final activeReplyTarget =
        widget.replyTarget != null &&
            (widget.replyTarget!.senderDeviceId == contact.deviceId ||
                widget.replyTarget!.recipientDeviceId == contact.deviceId)
        ? widget.replyTarget
        : null;
    final body = Padding(
      padding: widget.telegramLayout
          ? EdgeInsets.zero
          : const EdgeInsets.all(18),
      child: Card(
        margin: widget.telegramLayout ? EdgeInsets.zero : null,
        elevation: 0,
        color: palette.paperStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(widget.telegramLayout ? 0 : 28),
          side: widget.telegramLayout
              ? BorderSide.none
              : BorderSide(color: palette.stroke),
        ),
        child: Column(
          children: [
            if (widget.telegramLayout)
              _TelegramChatHeader(
                onSearch: _searchMessages,
                palette: palette,
                title: contact.alias,
                subtitle: saved
                    ? l10nOf(context).uiOnlyOnThisDevice7D64C4
                    : reachabilityLabel(context, reachabilityState),
                seed: contact.deviceId,
                onBack: widget.onBack,
                onDetails: saved ? () {} : widget.onShowProfile,
                onConnectionDetails: saved
                    ? null
                    : () => setState(
                        () => _routeInspectorOpen = !_routeInspectorOpen,
                      ),
                // Builds without native call media hide the action rather
                // than offering a button that can only fail.
                onCall:
                    saved ||
                        controller.voiceCallService?.media.available != true
                    ? null
                    : () {
                  if (controller.identity?.experimentalVoiceCallsEnabled !=
                      true) {
                    controller.setStatus(
                      'Voice calls are turned off. Enable them in Settings to call.',
                    );
                    return;
                  }
                  final service = controller.voiceCallService;
                  if (service == null) {
                    controller.setStatus(
                      'Voice-call audio is unavailable in this build.',
                    );
                    return;
                  }
                  unawaited(
                    service
                        .startOutgoing(contact.deviceId)
                        .then<void>((_) {})
                        .catchError(
                          (Object error) => controller.setStatus('$error'),
                        ),
                  );
                },
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compactHeader = constraints.maxWidth < 560;
                    final title = Row(
                      children: [
                        SealAvatar(
                          seed: contact.deviceId,
                          palette: palette,
                          size: 38,
                          animate: true,
                          label: contact.alias,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                contact.alias,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                saved
                                    ? l10nOf(context).uiNotesFilesAndForwardsOnlyB0145F
                                    : l10nOf(context).uiValueSafetyValue82C755((contact.routeSummary).toString(), (contact.shortSafetyNumber).toString()),
                                maxLines: compactHeader ? 3 : 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      fontFamily: ConestPalette.monoFont,
                                      color: palette.inkSoft,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                    final controls = <Widget>[
                      if (!saved) ...[
                      _ReachabilityChip(
                        state: reachabilityState,
                        palette: palette,
                      ),
                      _ConnectivityChip(
                        contact: contact,
                        controller: controller,
                        palette: palette,
                      ),
                      IconButton(
                        onPressed: () => setState(
                          () => _routeInspectorOpen = !_routeInspectorOpen,
                        ),
                        icon: const Icon(Icons.route_outlined),
                        tooltip: l10nOf(context).uiRouteInspector0E65DE,
                        isSelected: _routeInspectorOpen,
                        color: _routeInspectorOpen ? palette.primary : null,
                      ),
                      IconButton(
                        onPressed: widget.onShowProfile,
                        icon: const Icon(Icons.badge_outlined),
                        tooltip: l10nOf(context).uiContactProfile1B3A0E,
                      ),
                      ],
                    ];
                    if (!compactHeader) {
                      return Row(
                        children: [
                          if (widget.onBack != null)
                            IconButton(
                              onPressed: widget.onBack,
                              icon: const Icon(Icons.arrow_back),
                            ),
                          Expanded(child: title),
                          if (controls.isNotEmpty) const SizedBox(width: 12),
                          ...controls.expand(
                            (control) => [control, const SizedBox(width: 8)],
                          ),
                          // Something for removeLast to drop when there
                          // are no controls (Saved messages).
                          if (controls.isEmpty) const SizedBox.shrink(),
                        ]..removeLast(),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (widget.onBack != null)
                              IconButton(
                                onPressed: widget.onBack,
                                icon: const Icon(Icons.arrow_back),
                              ),
                            Expanded(child: title),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: controls,
                        ),
                      ],
                    );
                  },
                ),
              ),
            const Divider(height: 1),
            if (_routeInspectorOpen)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => RouteInspector(
                    palette: palette,
                    paths: _routeInspectorPaths(),
                    note: 'auto-fallback ✓',
                  ),
                ),
              ),
            if (contact.pendingVerification)
              _PendingVerificationBanner(
                controller: controller,
                palette: palette,
                contact: contact,
              ),
            if (_selectionMode)
              _MessageSelectionBar(
                palette: palette,
                count: _selectedMessageIds.length,
                onCancel: _clearMessageSelection,
                onCopy: () => _copySelectedMessagesText(messages),
                onForward: () {
                  final selected = [
                    for (final message in messages)
                      if (_selectedMessageIds.contains(message.id)) message,
                  ];
                  _clearMessageSelection();
                  unawaited(
                    _forwardMessages(context, controller, palette, selected),
                  );
                },
                onSave: _canSaveSelected(messages)
                    ? () => _bulkSaveSelected(messages)
                    : null,
                onDelete: _canDeleteSelected(messages)
                    ? () => _deleteSelected(messages)
                    : null,
              ),
            Expanded(
              child: Builder(
                builder: (context) {
                  final anchor = _anchoredFirstUnreadId;
                  final unreadCount = anchor == null
                      ? 0
                      : messages.where((m) {
                          return !m.outbound &&
                              controller.isUnreadMessage(contact.deviceId, m);
                        }).length;
                  return StableScrollbar(
                    controller: _scrollController,
                    child: ListView.builder(
                      key: _messageListKey,
                      reverse: true,
                      controller: _scrollController,
                      padding: const EdgeInsets.all(18),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final chronoIndex = messages.length - 1 - index;
                        final message = messages[chronoIndex];
                        if (_isAlbumContinuation(messages, chronoIndex)) {
                          return const SizedBox.shrink();
                        }
                        final messageBubble =
                            _isAlbumAnchor(messages, chronoIndex)
                            ? _buildAlbumBubble(
                                context,
                                _collectAlbumFrom(messages, chronoIndex),
                              )
                            : _buildMessageBubble(context, message);
                        final replyBubble = widget.telegramLayout
                            ? SwipeToReply(
                                key: ValueKey('reply-swipe-${message.id}'),
                                enabled: !_selectionMode,
                                color: palette.primary,
                                onReply: () => widget.onReplyToMessage(message),
                                child: messageBubble,
                              )
                            : messageBubble;
                        final startsDay =
                            chronoIndex == 0 ||
                            !sameChatDay(
                              messages[chronoIndex - 1].createdAt,
                              message.createdAt,
                            );
                        final bubble = widget.telegramLayout && startsDay
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  ChatDaySeparator(
                                    timestamp: message.createdAt,
                                    background: palette.panel2,
                                    foreground: palette.inkSoft,
                                  ),
                                  replyBubble,
                                ],
                              )
                            : replyBubble;
                        final showDivider =
                            anchor != null && message.id == anchor;
                        if (!showDivider) {
                          return bubble;
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _NewMessagesDivider(
                              palette: palette,
                              count: unreadCount,
                            ),
                            bubble,
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (contact.pairingState != ContactPairingState.accepted)
              _ContactPairingStatusBanner(
                controller: controller,
                palette: palette,
                contact: contact,
              ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.stroke)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (activeReplyTarget != null) ...[
                    _ComposerReplyPreview(
                      palette: palette,
                      senderLabel: _messageSenderLabel(activeReplyTarget),
                      snippet: activeReplyTarget.bodyPreview,
                      onCancel: widget.onCancelReply,
                    ),
                    const SizedBox(height: 12),
                  ],
                  // nightly.10: staged-attachment tray (preview tiles +
                  // X-to-cancel). Hidden when no items are staged.
                  _StagedAttachmentTray(
                    controller: widget.controller,
                    contact: contact,
                    palette: palette,
                  ),
                  _VoiceComposerPanel(
                    service: controller.voiceMessageService,
                    destinationKey: 'direct:${contact.deviceId}',
                    palette: palette,
                    locked: _voiceRecordingLocked,
                    sending: _voiceSending,
                    onStop: () => unawaited(_finishVoiceRecording()),
                    onCancel: () => unawaited(_cancelVoiceRecording()),
                    onSend: () => unawaited(_sendVoicePreview()),
                  ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: contact.canComposeOutbound
                            ? widget.onAttach
                            : null,
                        icon: const Icon(Icons.attach_file_outlined),
                        tooltip: l10nOf(context).composerAttach,
                      ),
                      Expanded(
                        child: Shortcuts(
                          shortcuts: <ShortcutActivator, Intent>{
                            const SingleActivator(
                              LogicalKeyboardKey.keyV,
                              control: true,
                            ): const _PasteMediaIntent(),
                            const SingleActivator(
                              LogicalKeyboardKey.keyV,
                              meta: true,
                            ): const _PasteMediaIntent(),
                          },
                          child: Actions(
                            actions: <Type, Action<Intent>>{
                              _PasteMediaIntent:
                                  CallbackAction<_PasteMediaIntent>(
                                    onInvoke: (_) {
                                      widget.onSmartPaste?.call();
                                      return null;
                                    },
                                  ),
                            },
                            child: TextField(
                              controller: widget.composerController,
                              contentInsertionConfiguration:
                                  widget.onContentInserted == null
                                  ? null
                                  : ContentInsertionConfiguration(
                                      onContentInserted:
                                          widget.onContentInserted!,
                                    ),
                              minLines: 1,
                              maxLines: 5,
                              enabled: contact.canComposeOutbound,
                              decoration: InputDecoration(
                                hintText: !contact.canComposeOutbound
                                    ? l10nOf(context).uiThisContactRequestIsBlocked944F7D
                                    : !contact.canSendOutbound
                                    ? l10nOf(context).uiMessageSavedHereUntilTheA49A2C
                                    : activeReplyTarget == null
                                    ? (widget.telegramLayout
                                          ? l10nOf(context).uiMessage68F414
                                          : l10nOf(context).uiWriteAnEncryptedMessage9F7705)
                                    : l10nOf(context).uiWriteAReplyOrAddFC0A42,
                              ),
                              onSubmitted: (_) => widget.onSend(),
                              contextMenuBuilder: (context, editableTextState) {
                                final items = List<ContextMenuButtonItem>.from(
                                  editableTextState.contextMenuButtonItems,
                                );
                                if (widget.onSmartPaste != null) {
                                  items.add(
                                    ContextMenuButtonItem(
                                      label: l10nOf(context).uiPasteMedia4831DE,
                                      onPressed: () {
                                        ContextMenuController.removeAny();
                                        widget.onSmartPaste!();
                                      },
                                    ),
                                  );
                                }
                                return AdaptiveTextSelectionToolbar.buttonItems(
                                  anchors: editableTextState.contextMenuAnchors,
                                  buttonItems: items,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      StreamBuilder<VoiceRecordingState>(
                        stream: controller.voiceMessageService.states,
                        initialData: controller.voiceMessageService.state,
                        builder: (context, snapshot) {
                          final state =
                              snapshot.data ?? VoiceRecordingState.idle;
                          final recording =
                              state == VoiceRecordingState.recording;
                          final ownsPreview =
                              controller
                                  .voiceMessageService
                                  .previewDestinationKey ==
                              'direct:${contact.deviceId}';
                          final preview =
                              state == VoiceRecordingState.preview &&
                              ownsPreview;
                          final foreignRecording = recording && !ownsPreview;
                          final foreignPreview =
                              state == VoiceRecordingState.preview &&
                              !ownsPreview;
                          return GestureDetector(
                            onLongPressStart:
                                preview ||
                                    foreignPreview ||
                                    foreignRecording ||
                                    _voiceRecordingStarting
                                ? null
                                : (_) => _beginVoiceRecording(),
                            onLongPressMoveUpdate:
                                preview || foreignPreview || foreignRecording
                                ? null
                                : _moveVoiceRecording,
                            onLongPressEnd:
                                preview || foreignPreview || foreignRecording
                                ? null
                                : (_) => unawaited(_releaseVoiceRecording()),
                            child: IconButton(
                              tooltip: foreignRecording
                                  ? l10nOf(context).uiRecordingBelongsToAnotherConversation87E802
                                  : foreignPreview
                                  ? l10nOf(context).uiFinishTheVoicePreviewIn142571
                                  : preview
                                  ? l10nOf(context).uiReviewUnsentVoiceMessage24931C
                                  : _voiceRecordingStarting
                                  ? l10nOf(context).uiCancelMicrophoneStartup9E9F8A
                                  : _voiceRecordingCancelGesture
                                  ? l10nOf(context).uiReleaseToDiscardRecording4C5C71
                                  : _voiceRecordingLocked
                                  ? l10nOf(context).uiRecordingLockedTapToFinish40CD88
                                  : recording
                                  ? l10nOf(context).uiReleaseToStopSlideLeft4686F1
                                  : l10nOf(context).uiHoldToRecordAVoice06B1B5,
                              onPressed:
                                  contact.canSendOutbound &&
                                      !foreignPreview &&
                                      !foreignRecording
                                  ? (_voiceRecordingStarting
                                        ? _cancelVoiceRecording
                                        : recording || preview
                                        ? _finishVoiceRecording
                                        : _beginVoiceRecording)
                                  : null,
                              icon: Icon(
                                _voiceRecordingCancelGesture
                                    ? Icons.delete_outline
                                    : _voiceRecordingLocked
                                    ? Icons.lock_clock_outlined
                                    : recording
                                    ? Icons.stop_circle_outlined
                                    : preview
                                    ? Icons.play_circle_outline
                                    : Icons.mic_none_outlined,
                                color: _voiceRecordingCancelGesture || recording
                                    ? palette.danger
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: l10nOf(context).composerSchedule,
                        onPressed: contact.canSendOutbound
                            ? _scheduleText
                            : null,
                        icon: const Icon(Icons.schedule_send_outlined),
                      ),
                      if (widget.telegramLayout)
                        IconButton.filled(
                          tooltip: l10nOf(context).composerSend,
                          onPressed: contact.canComposeOutbound
                              ? widget.onSend
                              : null,
                          icon: const Icon(Icons.send_rounded),
                        )
                      else
                        FilledButton.icon(
                        onPressed: contact.canComposeOutbound
                            ? widget.onSend
                              : null,
                          icon: const Icon(Icons.north_east),
                          label: Text(l10nOf(context).composerSend),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    Widget searchable(Widget child) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _searchMessages,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _searchMessages,
      },
      child: child,
    );
    if (!_isDesktopPlatform) {
      return searchable(body);
    }
    return DropTarget(
      onDragEntered: (_) => setState(() => _droppingFiles = true),
      onDragExited: (_) => setState(() => _droppingFiles = false),
      onDragDone: (details) {
        setState(() => _droppingFiles = false);
        widget.onDropFiles(details.files);
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          searchable(body),
          if (_droppingFiles)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: palette.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: palette.primary,
                      width: 2,
                      style: BorderStyle.solid,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    l10nOf(context).uiDropFilesToSendMax106011((MessengerController.maxAttachmentsPerSend).toString()),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: palette.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initialBody, this.explanation});

  final String initialBody;
  final String? explanation;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialBody);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(l10nOf(context).menuEditMessage),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.explanation != null) ...[
            Text(widget.explanation!),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _controller,
            minLines: 1,
            maxLines: 6,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l10nOf(context).uiMessage68F414,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionCancel),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: Text(l10nOf(context).uiSaveEFC007),
        ),
      ],
    );
  }
}

class _LanLobbyPanel extends StatelessWidget {
  const _LanLobbyPanel({
    required this.controller,
    required this.palette,
    required this.composerController,
    required this.onSend,
    this.onBack,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final TextEditingController composerController;
  final VoidCallback onSend;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final messages = controller.lanLobbyMessages;
    final unreadCount = controller.unreadLanLobbyCount;
    if (unreadCount > 0 && controller.isAppForeground) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(controller.markLanLobbyRead());
      });
    }
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Card(
        elevation: 0,
        color: palette.paperStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: palette.stroke),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
              child: Row(
                children: [
                  if (onBack != null)
                    IconButton(
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10nOf(context).uiLANLobbyC16DC8,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10nOf(context).uiFreeForAllLocalChatBC90D2,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  _StatusChip(
                    label: l10nOf(context).uiLANOnly94945D,
                    palette: palette,
                    icon: Icons.lan_outlined,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: messages.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l10nOf(context).uiNoLANLobbyMessagesYetBCDC4B,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(18),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[messages.length - index - 1];
                        final outbound = message.outbound;
                        final unread = controller.isUnreadLanLobbyMessage(
                          message,
                        );
                        final sender =
                            message.senderDisplayName ??
                            (outbound ? 'You' : message.senderDeviceId);
                        return Align(
                          alignment: outbound
                              ? AlignmentDirectional.centerEnd
                              : AlignmentDirectional.centerStart,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 560),
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: outbound
                                  ? palette.outboundBubble
                                  : palette.inboundBubble,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: outbound
                                    ? palette.outboundBubble
                                    : unread
                                    ? palette.unread.withValues(alpha: 0.55)
                                    : palette.stroke,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  outbound
                                      ? l10nOf(context).uiYou905CB3
                                      : l10nOf(context).uiValueUntrusted519A32(
                                          (sender).toString(),
                                        ),
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: outbound
                                            ? palette.outboundMeta
                                            : palette.inboundMeta,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  message.body,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: outbound
                                            ? palette.outboundText
                                            : palette.inboundText,
                                        height: 1.35,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  formatTimestamp(message.createdAt),
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: outbound
                                            ? palette.outboundMeta
                                            : palette.inboundMeta,
                                      ),
                                ),
                                if (!outbound && unread) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    l10nOf(context).uiNewC2A6B0,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: palette.unread,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: palette.stroke)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: composerController,
                      minLines: 1,
                      maxLines: 5,
                      decoration: InputDecoration(
                        hintText: l10nOf(context).uiWriteToNearbyLANUsers291142,
                      ),
                      onSubmitted: (_) => onSend(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: onSend,
                    icon: const Icon(Icons.campaign_outlined),
                    label: Text(l10nOf(context).uiBroadcast77CA3F),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ContactProfileDialog extends StatefulWidget {
  const ContactProfileDialog({
    super.key,
    this.fullscreenOnMobile = false,
    required this.controller,
    required this.palette,
    required this.contact,
  });

  final bool fullscreenOnMobile;
  final MessengerController controller;
  final ConestPalette palette;
  final ContactRecord contact;

  @override
  State<ContactProfileDialog> createState() => _ContactProfileDialogState();
}

class _ContactProfileDialogState extends State<ContactProfileDialog> {
  late final TextEditingController _aliasController;
  late final TextEditingController _bioController;
  List<PeerRouteHealth>? _checks;
  DateTime? _lastCheckStartedAt;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _aliasController = TextEditingController(text: widget.contact.alias);
    _bioController = TextEditingController(text: widget.contact.bio);
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _aliasController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted || _checks == null || !_twoWayConfirmedForLastCheck()) {
      return;
    }
    setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _checkPaths() async {
    await _run(() async {
      final startedAt = DateTime.now().toUtc();
      final checks = await widget.controller.checkContactRoutes(widget.contact);
      if (mounted) {
        setState(() {
          _lastCheckStartedAt = startedAt;
          _checks = checks;
        });
      }
    });
  }

  bool _twoWayConfirmedForLastCheck() {
    final startedAt = _lastCheckStartedAt;
    if (startedAt == null) {
      return false;
    }
    final lastTwoWay = widget.controller
        .reachabilityRecordFor(widget.contact.deviceId)
        ?.lastTwoWaySuccessAt;
    return lastTwoWay != null && !lastTwoWay.isBefore(startedAt);
  }

  Future<void> _copyPathState() async {
    final checks = _checks;
    if (checks == null) {
      return;
    }
    final reachability = widget.controller.reachabilityRecordFor(
      widget.contact.deviceId,
    );
    final reachabilityState = widget.controller.reachabilityStateFor(
      widget.contact.deviceId,
    );
    var alias = widget.contact.alias;
    for (final contact in widget.controller.contacts) {
      if (contact.deviceId == widget.contact.deviceId) {
        alias = contact.alias;
        break;
      }
    }
    final lines = <String>[
      'Conest path state',
      'contactAlias=$alias',
      'contactDevice=${widget.contact.deviceId}',
      'generatedAt=${DateTime.now().toUtc().toIso8601String()}',
      'lastCheckTwoWayConfirmed=${_twoWayConfirmedForLastCheck()}',
      'reachability=${reachabilityState.name}',
      'lastTwoWaySuccessAt=${reachability?.lastTwoWaySuccessAt?.toIso8601String() ?? ''}',
      'lastHeartbeatAttemptAt=${reachability?.lastHeartbeatAttemptAt?.toIso8601String() ?? ''}',
      'lastHeartbeatReplyAt=${reachability?.lastHeartbeatReplyAt?.toIso8601String() ?? ''}',
      'lastAvailablePathAt=${reachability?.lastAvailablePathAt?.toIso8601String() ?? ''}',
      'lastAnySignalAt=${reachability?.lastAnySignalAt?.toIso8601String() ?? ''}',
      'lastFailureAt=${reachability?.lastFailureAt?.toIso8601String() ?? ''}',
      for (final check in checks)
        [
          'route=${check.route.kind.name}:${check.route.label}',
          'available=${check.available}',
          if (check.latency != null)
            'latencyMs=${check.latency!.inMilliseconds}',
          if (check.relayInstanceId != null)
            'relayInstanceId=${check.relayInstanceId}',
          if (check.error != null) 'error=${check.error}',
        ].join(' '),
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
  }

  Future<void> _saveProfile() async {
    await _run(
      () => widget.controller.updateContactProfile(
        deviceId: widget.contact.deviceId,
        alias: _aliasController.text,
        bio: _bioController.text,
      ),
    );
  }

  Future<void> _confirmRemove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiRemoveValueF4FE4B((widget.contact.alias).toString())),
        content:  Text(
          l10nOf(context).uiThisRemovesTheLocalContact0D6D1E,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).uiRemoveE96390),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _run(() => widget.controller.removeContact(widget.contact.deviceId));
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final checks = _checks;
    var currentContact = widget.contact;
    for (final contact in widget.controller.contacts) {
      if (contact.deviceId == widget.contact.deviceId) {
        currentContact = contact;
        break;
      }
    }
    final reachabilityRecord = widget.controller.reachabilityRecordFor(
      currentContact.deviceId,
    );
    final reachabilityState = widget.controller.reachabilityStateFor(
      currentContact.deviceId,
    );
    final checkTwoWayConfirmed = _twoWayConfirmedForLastCheck();
    return AdaptiveChatDialog(
      fullscreenOnMobile: widget.fullscreenOnMobile,
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: Text(l10nOf(context).uiContactProfile1B3A0E),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: _aliasController,
                      decoration: InputDecoration(
                        labelText: l10nOf(context).contactAlias,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 340,
                    child: TextField(
                      controller: _bioController,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: l10nOf(context).uiDescriptionBio505243,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _ReachabilityChip(
                state: reachabilityState,
                palette: widget.palette,
                expand: true,
              ),
              const SizedBox(height: 12),
              SelectableText(
                'last two-way success ${_formatProfileTimestamp(reachabilityRecord?.lastTwoWaySuccessAt)}\nlast heartbeat attempt ${_formatProfileTimestamp(reachabilityRecord?.lastHeartbeatAttemptAt)}\nlast heartbeat reply ${_formatProfileTimestamp(reachabilityRecord?.lastHeartbeatReplyAt)}\nlast available path ${_formatProfileTimestamp(reachabilityRecord?.lastAvailablePathAt)}\nlast signal ${_formatProfileTimestamp(reachabilityRecord?.lastAnySignalAt)}\nlast failure ${_formatProfileTimestamp(reachabilityRecord?.lastFailureAt)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: widget.palette.inkSoft,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                'display ${currentContact.displayName}\naccount ${currentContact.accountId}\ndevice ${currentContact.deviceId}\nsafety ${currentContact.safetyNumber}\ntrusted ${currentContact.trustedAt.toLocal()}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: widget.palette.inkSoft,
                  height: 1.5,
                ),
              ),
              if (widget.controller.userMode.showsNetworkDetail) ...[
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10nOf(context).uiAvailablePaths6EE503,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _checkPaths,
                      icon: const Icon(Icons.network_check),
                      label: Text(l10nOf(context).uiCheckPaths917FF3),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: checks == null || _busy
                          ? null
                          : _copyPathState,
                      icon: const Icon(Icons.copy),
                      label: Text(l10nOf(context).uiCopyState9BFD16),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (checks == null)
                  Text(
                    l10nOf(context).uiRunACheckToMeasure5D76A5,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.palette.inkSoft,
                    ),
                  )
                else if (checks.isEmpty)
                  Text(
                    l10nOf(context).uiNoRouteHintsAreAdvertisedB25540,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.palette.inkSoft,
                    ),
                  )
                else
                  Column(
                    children: [
                      for (final check in checks)
                        _RouteHealthTile(
                          check: check,
                          palette: widget.palette,
                          twoWayConfirmed: checkTwoWayConfirmed,
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                RouteTestPanel(
                  controller: widget.controller,
                  contact: currentContact,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _confirmRemove,
          child: Text(l10nOf(context).uiRemoveContact7F9A8A),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionClose),
        ),
        FilledButton(
          onPressed: _busy ? null : _saveProfile,
          child: Text(l10nOf(context).uiSaveProfile909BF3),
        ),
      ],
    );
  }
}

class AddContactDialog extends StatefulWidget {
  const AddContactDialog({
    super.key,
    this.fullscreenOnMobile = false,
    required this.controller,
    required this.palette,
  });

  final bool fullscreenOnMobile;
  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<AddContactDialog> createState() => _AddContactDialogState();
}

class _AddContactDialogState extends State<AddContactDialog> {
  final _aliasController = TextEditingController();
  final _payloadController = TextEditingController();
  final _codephraseController = TextEditingController();
  bool _submitting = false;
  String? _error;

  ContactInvite? get _previewInvite =>
      ContactInvite.tryDecodePayload(_payloadController.text.trim());
  bool get _hasPayload => _payloadController.text.trim().isNotEmpty;
  bool get _hasCodephrase => _codephraseController.text.trim().isNotEmpty;
  String get _submitLabel {
    if (_hasPayload) {
      return l10nOf(context).contactTrustPayload;
    }
    if (_hasCodephrase) {
      return l10nOf(context).contactFindCodephrase;
    }
    return l10nOf(context).contactAdd;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.activatePairingSession();
  }

  @override
  void dispose() {
    _aliasController.dispose();
    _payloadController.dispose();
    _codephraseController.dispose();
    super.dispose();
  }

  Future<void> _scanPayload() async {
    final payload = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (payload == null || !mounted) {
      return;
    }
    setState(() {
      _payloadController.text = payload.trim();
      final preview = _previewInvite;
      if (preview != null && _aliasController.text.trim().isEmpty) {
        _aliasController.text = preview.displayName;
      }
    });
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await widget.controller.addContactFromInvite(
        alias: _aliasController.text.trim(),
        payload: _payloadController.text.trim(),
        codephrase: _codephraseController.text.trim(),
      );
      var keepContact = true;
      if (!mounted) {
        return;
      }
      if (result.exchangeStatus == ContactExchangeStatus.manualActionRequired) {
        keepContact =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(l10nOf(context).contactExchangeFailed),
                content: Text(
                  l10nOf(
                    context,
                  ).contactExchangeFailedBody(result.contact.alias),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l10nOf(context).actionAbort),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(l10nOf(context).contactKeep),
                  ),
                ],
              ),
            ) ??
            false;
        if (keepContact != true) {
          await widget.controller.removeContact(
            result.contact.deviceId,
            notifyPeer: false,
          );
          keepContact = false;
        }
      }
      if (mounted) {
        Navigator.of(context).pop(keepContact ? result.contact : null);
      }
    } catch (error) {
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _previewInvite;
    return AdaptiveChatDialog(
      fullscreenOnMobile: widget.fullscreenOnMobile,
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: Text(l10nOf(context).contactAdd),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ConnectivityOfflineBanner(
                controller: widget.controller,
                palette: widget.palette,
                message: l10nOf(context).uiConnectivityIsOffTurnOnE42D4A,
              ),
              TextField(
                controller: _aliasController,
                decoration: InputDecoration(
                  labelText: l10nOf(context).contactAlias,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _payloadController,
                minLines: 4,
                maxLines: 7,
                decoration: InputDecoration(
                  labelText: l10nOf(context).contactInvitePayload,
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (widget.controller.supportsScanner) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    onPressed: _scanPayload,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(l10nOf(context).contactScanQr),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _codephraseController,
                decoration: InputDecoration(
                  labelText: l10nOf(context).contactCodephrase,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  l10nOf(context).uiEitherInputIsEnoughOn020B90,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.palette.inkSoft,
                  ),
                ),
              ),
              if (preview != null) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    l10nOf(context).uiInvitePreview6433A0,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    "${(preview.displayName)}${(preview.bio.isEmpty ? '' : ' • ${preview.bio}')} • ${(preview.routeHints.isEmpty ? l10nOf(context).inviteNoRoutes : preview.routeHints.map((route) => '${route.kind.name}:${route.label}').join(' • '))}",
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.palette.inkSoft,
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    _error!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionCancel),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_submitLabel),
        ),
      ],
    );
  }
}

class InviteScreen extends StatefulWidget {
  const InviteScreen({
    super.key,
    required this.controller,
    required this.invite,
    required this.palette,
  });

  final MessengerController controller;
  final ContactInvite invite;
  final ConestPalette palette;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  /// Above this, the extended invite is hard to scan as one QR code: Beam
  /// (an animated QR) is offered first.
  static const int _comfortableQrLength = 1200;

  late ContactInvite _invite = widget.invite;

  /// The ci6 invite for contacts on older versions.
  bool _legacy = false;
  bool _qrDespiteSize = false;
  late bool _showQr = !_isWindowsPlatform;

  String get _payload =>
      _legacy ? _invite.encodeCompatiblePayload() : _invite.encodePayload();

  /// Codephrases come from the compatible invite: that is what nearby
  /// devices and relays announce.
  String get _codePayload => _invite.encodeCompatiblePayload();

  bool get _tooBigForQr =>
      !_legacy && !_qrDespiteSize && _payload.length > _comfortableQrLength;

  Future<void> _showAsBeam() async {
    try {
      final transfer = await widget.controller.prepareInviteBeam(
        legacy: _legacy,
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) =>
              BeamSenderScreen(transfer: transfer, palette: widget.palette),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  bool _rotating = false;
  String? _error;
  String? _lastAdvertisedCodephrase;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _advertiseVisibleCodephrase();
      }
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        _advertiseVisibleCodephrase();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _rotateNow() async {
    setState(() {
      _rotating = true;
      _error = null;
      _showQr = !_isWindowsPlatform;
    });
    try {
      final invite = await widget.controller.rotatePairingCodeNow();
      if (mounted) {
        setState(() {
          _invite = invite;
          _lastAdvertisedCodephrase = null;
        });
        _advertiseVisibleCodephrase();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _rotating = false);
      }
    }
  }

  void _advertiseVisibleCodephrase() {
    final codephrase = currentPairingCodeSnapshotForPayload(
      _codePayload,
    ).codephrase;
    if (codephrase == _lastAdvertisedCodephrase) {
      return;
    }
    _lastAdvertisedCodephrase = codephrase;
    unawaited(widget.controller.refreshPairingAdvertisement());
  }

  Future<void> _openFullscreenQr() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => FullscreenQrScreen(
          payload: _payload,
          codephrase: currentPairingCodeSnapshotForPayload(
            _codePayload,
          ).codephrase,
          palette: widget.palette,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pairingSnapshot = currentPairingCodeSnapshotForPayload(_codePayload);
    final palette = widget.palette;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Card(
                  elevation: 0,
                  color: palette.paperStrong,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                    side: BorderSide(color: palette.stroke),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10nOf(context).uiShareInviteDBCC1E,
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                              tooltip: l10nOf(context).actionClose,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _ConnectivityOfflineBanner(
                          controller: widget.controller,
                          palette: palette,
                          message: l10nOf(
                            context,
                          ).uiConnectivityIsOffTurnOnFA573F,
                        ),
                        if (!widget.controller.invitesReachOverInternet)
                          Padding(
                            key: const ValueKey('invite-lan-only'),
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              l10nOf(context).uiThisInviteWorksOnlyOnB106B0,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (_tooBigForQr)
                          Container(
                            key: const ValueKey('invite-beam-first'),
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: palette.paper,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: palette.stroke),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.animation_outlined,
                                  size: 42,
                                  color: palette.primary,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  l10nOf(
                                    context,
                                  ).uiThisInviteAlsoListsYourEF3A4F,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: _showAsBeam,
                                  icon: const Icon(Icons.animation_outlined),
                                  label: Text(
                                    l10nOf(context).uiShowAsBeam74375F,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _qrDespiteSize = true),
                                  child: Text(
                                    l10nOf(context).uiShowTheQRAnyway0B0CDF,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else if (_showQr)
                          Column(
                            children: [
                              GestureDetector(
                                onTap: _openFullscreenQr,
                                child: Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                  child: _SignatureQrFrame(
                                    palette: palette,
                                    child: QrImageView(
                                      data: _payload,
                                      version: QrVersions.auto,
                                      size: 260,
                                      gapless: false,
                                      errorStateBuilder: (context, error) {
                                        return _QrFallback(
                                          palette: palette,
                                          error: error.toString(),
                                        );
                                      },
                                      eyeStyle: QrEyeStyle(
                                        color: palette.qrInk,
                                      ),
                                      dataModuleStyle: QrDataModuleStyle(
                                        color: palette.qrInk,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.center,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: _openFullscreenQr,
                                    icon: const Icon(Icons.open_in_full),
                                    label: Text(
                                      l10nOf(context).uiOpenFullscreenQRC5418D,
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _showAsBeam,
                                    icon: const Icon(Icons.animation_outlined),
                                    label: Text(
                                      l10nOf(context).uiShowAsBeam74375F,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          )
                        else
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: palette.paper,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: palette.stroke),
                            ),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.qr_code_2_outlined,
                                  size: 42,
                                  color: palette.inkSoft,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  l10nOf(
                                    context,
                                  ).uiQRRenderingIsDeferredOn8A6997,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  l10nOf(
                                    context,
                                  ).uiUseTheCodephraseBelowOrB6A588,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: palette.inkSoft),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      setState(() => _showQr = true),
                                  icon: const Icon(Icons.qr_code_2),
                                  label: Text(l10nOf(context).uiShowQRCFBAC6),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 18),
                        Center(
                          child: CodephraseRing(
                            palette: palette,
                            codephrase: pairingSnapshot.codephrase,
                            secondsRemaining: pairingSnapshot.secondsRemaining,
                            totalSeconds: pairingCodeWindow.inSeconds,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: SelectableText(
                            pairingSnapshot.codephrase,
                            style: TextStyle(
                              fontFamily: ConestPalette.monoFont,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                              color: palette.inkSoft,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10nOf(context).uiScanningTheCompactQRIs9459D9,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          l10nOf(
                            context,
                          ).uiQRPayloadValueCharactersBABEDF((_payload.length)),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                        if (_invite.hasSignedCarrierHints) ...[
                          const SizedBox(height: 6),
                          if (!_legacy)
                            Text(
                              l10nOf(context).uiAlsoListsYourAddressesOnC5D815(
                                (_invite.carrierHints.keys
                                        .map(
                                          (kind) =>
                                              transportKindLabel(context, kind),
                                        )
                                        .join(', '))
                                    .toString(),
                              ),
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: palette.inkSoft),
                            ),
                          SwitchListTile.adaptive(
                            key: const ValueKey('invite-legacy'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(l10nOf(context).uiLegacyInviteC61C5D),
                            subtitle: Text(
                              l10nOf(context).uiForContactsOnConestOr486754,
                            ),
                            value: _legacy,
                            onChanged: (value) =>
                                setState(() => _legacy = value),
                          ),
                        ],
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _rotating ? null : _rotateNow,
                          icon: _rotating
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                          label: Text(
                            l10nOf(context).uiRotateCodephraseNow89B2D5,
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                          ),
                        ],
                        if (_invite.bio.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(
                            _invite.bio,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: palette.inkSoft,
                                  fontStyle: FontStyle.italic,
                                ),
                          ),
                        ],
                        if (_invite.routeHints.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final route in _invite.routeHints)
                                _RoutePill(route: route, palette: palette),
                            ],
                          ),
                        ],
                        const SizedBox(height: 18),
                        SelectableText(
                          _payload,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class BeamHubScreen extends StatefulWidget {
  const BeamHubScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<BeamHubScreen> createState() => _BeamHubScreenState();
}

class _BeamHubScreenState extends State<BeamHubScreen> {
  bool _busy = false;
  String? _error;

  Future<({Uint8List bytes, String name, String mime})?> _pickBeamFile() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final platformFile = picked.files.single;
    if (platformFile.size <= 0 ||
        platformFile.size > conestBeamMaximumPayloadBytes) {
      throw ArgumentError('Conest Beam v1 accepts files up to 64 MiB.');
    }
    final Uint8List bytes;
    if (platformFile.path != null) {
      bytes = await File(platformFile.path!).readAsBytes();
    } else if (platformFile.bytes != null) {
      bytes = platformFile.bytes!;
    } else {
      throw StateError('The file picker did not provide readable file data.');
    }
    if (bytes.length != platformFile.size ||
        bytes.length > conestBeamMaximumPayloadBytes) {
      throw StateError('The selected file changed or exceeded 64 MiB.');
    }
    return (
      bytes: bytes,
      name: platformFile.name,
      mime: _beamMimeType(platformFile.name),
    );
  }

  Future<ContactRecord?> _chooseContact() => showDialog<ContactRecord>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l10nOf(context).uiEncryptForContactE07450),
      children: [
        for (final contact in widget.controller.contacts.where(
          (entry) => entry.canSendOutbound && entry.hasPinnedIrohIdentity,
        ))
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(contact),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: SealAvatar(
                seed: contact.deviceId,
                label: contact.alias,
                palette: widget.palette,
                size: 36,
              ),
              title: Text(contact.alias),
              subtitle: Text(
                l10nOf(
                  context,
                ).uiPinnedValue834309((contact.shortSafetyNumber).toString()),
              ),
            ),
          ),
        if (!widget.controller.contacts.any(
          (entry) => entry.canSendOutbound && entry.hasPinnedIrohIdentity,
        ))
          Padding(
            padding: EdgeInsets.all(20),
            child: Text(l10nOf(context).uiNoVerifiedCiContactsAre3FD190),
          ),
      ],
    ),
  );

  Future<void> _preparePublic() async {
    final allowed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10nOf(context).uiPublicOpticalTransfer58E3F4),
        content: Text(l10nOf(context).uiAnyoneWhoCanSeeTheFAB2D0),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).uiChoosePublicFile6E2739),
          ),
        ],
      ),
    );
    if (allowed != true) return;
    await _runPreparation(() async {
      final file = await _pickBeamFile();
      if (file == null) return null;
      return widget.controller.preparePublicBeam(
        bytes: file.bytes,
        fileName: file.name,
        mimeType: file.mime,
      );
    });
  }

  Future<void> _prepareEncrypted() async {
    final contact = await _chooseContact();
    if (contact == null || !mounted) return;
    await _runPreparation(() async {
      final file = await _pickBeamFile();
      if (file == null) return null;
      return widget.controller.prepareContactBeam(
        contact: contact,
        bytes: file.bytes,
        fileName: file.name,
        mimeType: file.mime,
      );
    });
  }

  Future<void> _prepareInvite() =>
      _runPreparation(() => widget.controller.prepareInviteBeam());

  Future<void> _runPreparation(
    Future<PreparedBeamTransfer?> Function() prepare,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final transfer = await prepare();
      if (transfer == null || !mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) =>
              BeamSenderScreen(transfer: transfer, palette: widget.palette),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receive() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => BeamReceiverScreen(
          controller: widget.controller,
          palette: widget.palette,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    return Scaffold(
      appBar: AppBar(title: Text(l10nOf(context).uiConestBeamE98B77)),
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              l10nOf(context).uiCloseUpTransferE6BA46,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              l10nOf(context).uiALoopingLTFountainStream840218,
              style: TextStyle(color: palette.inkSoft),
            ),
            const SizedBox(height: 20),
            _BeamActionCard(
              palette: palette,
              icon: Icons.download_outlined,
              title: l10nOf(context).uiReceiveBeam2CB58B,
              detail: widget.controller.supportsScanner
                  ? 'Scan animated frames and review before import.'
                  : 'Uses the native desktop camera when bundled, with manual cb1 input as a fallback.',
              onTap: _busy ? null : _receive,
            ),
            _BeamActionCard(
              palette: palette,
              icon: Icons.lock_outline,
              title: l10nOf(context).uiSendEncryptedFile99D424,
              detail: 'Pairwise encrypted for a verified ci6 contact.',
              onTap: _busy ? null : _prepareEncrypted,
            ),
            _BeamActionCard(
              palette: palette,
              icon: Icons.public,
              title: l10nOf(context).uiSendPublicFileF81389,
              detail: 'Not confidential. The receiver must explicitly accept.',
              warning: true,
              onTap: _busy ? null : _preparePublic,
            ),
            _BeamActionCard(
              palette: palette,
              icon: Icons.person_add_alt_1,
              title: l10nOf(context).uiBeamContactInvite2BAB4C,
              detail: 'Signed ci6 invite with a fingerprint comparison.',
              onTap: _busy ? null : _prepareInvite,
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BeamActionCard extends StatelessWidget {
  const _BeamActionCard({
    required this.palette,
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.warning = false,
  });

  final ConestPalette palette;
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback? onTap;
  final bool warning;

  @override
  Widget build(BuildContext context) => Card(
    color: palette.paperStrong,
    child: ListTile(
      onTap: onTap,
      leading: Icon(
        icon,
        color: warning ? Theme.of(context).colorScheme.error : palette.primary,
      ),
      title: Text(title),
      subtitle: Text(detail),
      trailing: const Icon(Icons.chevron_right),
    ),
  );
}

class BeamSenderScreen extends StatefulWidget {
  const BeamSenderScreen({
    super.key,
    required this.transfer,
    required this.palette,
  });

  final PreparedBeamTransfer transfer;
  final ConestPalette palette;

  @override
  State<BeamSenderScreen> createState() => _BeamSenderScreenState();
}

class _BeamSenderScreenState extends State<BeamSenderScreen> {
  late String _frame = widget.transfer.encoder.nextFrame().encodeText();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 125), (_) {
      if (!mounted) return;
      setState(() {
        _frame = widget.transfer.encoder.nextFrame().encodeText();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manifest = widget.transfer.package.manifest;
    final public = manifest.mode == BeamMode.public;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        title: Text(manifest.fileName),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final qrSize = math.max(
            260.0,
            math.min(constraints.maxWidth - 32, constraints.maxHeight - 240),
          );
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                RepaintBoundary(
                  child: QrImageView(
                    data: _frame,
                    version: QrVersions.auto,
                    size: qrSize,
                    gapless: true,
                    eyeStyle: const QrEyeStyle(color: Colors.black),
                    dataModuleStyle: const QrDataModuleStyle(
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  public
                      ? l10nOf(context).uiPUBLICVisibleToAnyoneNearbyA775C2
                      : manifest.mode == BeamMode.contactEncrypted
                      ? l10nOf(context).uiCONTACTENCRYPTED879896
                      : l10nOf(context).uiSIGNEDCONTACTINVITE752317,
                  style: TextStyle(
                    color: public ? Colors.red.shade700 : Colors.black87,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10nOf(context).uiFrameValueValueSourceBlocks9C37CB(
                    (widget.transfer.encoder.frameIndex).toString(),
                    (widget.transfer.encoder.sourceBlockCount),
                    (manifest.senderFingerprint).toString(),
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontFamily: ConestPalette.monoFont,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10nOf(context).uiKeepThisScreenVisibleUntil2261B8,
                  style: TextStyle(color: Colors.black87),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class BeamReceiverScreen extends StatefulWidget {
  const BeamReceiverScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<BeamReceiverScreen> createState() => _BeamReceiverScreenState();
}

class _BeamReceiverScreenState extends State<BeamReceiverScreen> {
  final BeamDecoder _decoder = BeamDecoder();
  final TextEditingController _frameController = TextEditingController();
  final TextEditingController _aliasController = TextEditingController();
  MobileScannerController? _scanner;
  FfiDesktopBeamScanner? _desktopScanner;
  StreamSubscription<String>? _desktopScannerSubscription;
  bool _desktopCameraActive = false;
  BeamDecodeProgress _progress = const BeamDecodeProgress(
    solvedBlocks: 0,
    sourceBlockCount: 0,
    distinctFrames: 0,
    complete: false,
  );
  BeamImportResult? _result;
  bool _finishing = false;
  bool _saving = false;
  bool _fingerprintCompared = false;
  int _invalidFrames = 0;
  String? _error;
  String? _savedPath;

  @override
  void initState() {
    super.initState();
    if (widget.controller.supportsScanner) {
      _scanner = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    } else {
      unawaited(_startDesktopScanner());
    }
  }

  Future<void> _startDesktopScanner() async {
    final scanner = FfiDesktopBeamScanner.tryCreate();
    if (scanner == null) return;
    _desktopScanner = scanner;
    _desktopScannerSubscription = scanner.frames.listen(
      _addFrame,
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted) return;
        setState(() {
          _desktopCameraActive = false;
          _error = 'Desktop camera unavailable: $error';
        });
      },
    );
    try {
      await scanner.start();
      if (mounted) setState(() => _desktopCameraActive = true);
    } catch (error) {
      await _desktopScannerSubscription?.cancel();
      _desktopScannerSubscription = null;
      await scanner.dispose();
      _desktopScanner = null;
      if (mounted) {
        setState(() {
          _desktopCameraActive = false;
          _error = 'Desktop camera unavailable: $error';
        });
      }
    }
  }

  @override
  void dispose() {
    _scanner?.dispose();
    unawaited(_desktopScannerSubscription?.cancel());
    unawaited(_desktopScanner?.dispose());
    _frameController.dispose();
    _aliasController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && value.startsWith('cb1:')) {
        _addFrame(value);
      }
    }
  }

  void _addFrame(String value) {
    if (_finishing || _result != null) return;
    try {
      final progress = _decoder.addFrame(BeamFrame.decodeText(value.trim()));
      setState(() {
        _progress = progress;
        _error = null;
      });
      if (progress.complete) {
        _finishing = true;
        _scanner?.stop();
        unawaited(_desktopScanner?.close());
        unawaited(_inspectComplete());
      }
    } catch (error) {
      setState(() {
        _invalidFrames++;
        _error = 'Ignored frame: $error';
      });
    }
  }

  Future<void> _inspectComplete() async {
    try {
      final result = await widget.controller.inspectBeamPackage(
        _decoder.package!,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _aliasController.text = result.invite?.displayName ?? '';
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Beam rejected: $error');
    }
  }

  Future<void> _saveAccepted() async {
    final result = _result;
    if (result == null) return;
    setState(() => _saving = true);
    try {
      final file = await widget.controller.persistAcceptedBeam(result);
      if (mounted) setState(() => _savedPath = file.path);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _acceptInvite() async {
    final result = _result;
    final invite = result?.invite;
    if (invite == null || !_fingerprintCompared) return;
    setState(() => _saving = true);
    try {
      await widget.controller.addContactFromInvite(
        alias: _aliasController.text.trim(),
        payload: invite.encodePayload(),
        codephrase: '',
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: Text(l10nOf(context).uiReceiveConestBeamB05BCB)),
      body: result == null
          ? Column(
              children: [
                if (_scanner != null)
                  Expanded(
                    child: MobileScanner(
                      controller: _scanner,
                      onDetect: _onDetect,
                    ),
                  )
                else if (_desktopCameraActive)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.videocam_outlined,
                              size: 64,
                              color: widget.palette.primary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              l10nOf(context).uiDesktopCameraActiveDA0F15,
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              l10nOf(context).uiPointThisCameraAtThe2EA3F7,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: widget.palette.inkSoft),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l10nOf(context).uiNativeDesktopCameraCaptureIs4619C8,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: widget.palette.inkSoft),
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      LinearProgressIndicator(value: _progress.fraction),
                      const SizedBox(height: 8),
                      Text(
                        l10nOf(context).uiValueValueBlocksValueFrames66F819(
                          (_progress.solvedBlocks).toString(),
                          (_progress.sourceBlockCount).toString(),
                          (_progress.distinctFrames).toString(),
                          (_invalidFrames).toString(),
                        ),
                      ),
                      if (_scanner == null) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _frameController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: InputDecoration(
                            labelText: l10nOf(context).uiPasteOneCbFrame66EA2B,
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: () {
                            _addFrame(_frameController.text);
                            _frameController.clear();
                          },
                          child: Text(l10nOf(context).uiAddFrame2BBA30),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            )
          : _BeamApprovalView(
              result: result,
              aliasController: _aliasController,
              fingerprintCompared: _fingerprintCompared,
              saving: _saving,
              savedPath: _savedPath,
              error: _error,
              onFingerprintChanged: (value) =>
                  setState(() => _fingerprintCompared = value),
              onAcceptInvite: _acceptInvite,
              onSave: _saveAccepted,
            ),
    );
  }
}

class _BeamApprovalView extends StatelessWidget {
  const _BeamApprovalView({
    required this.result,
    required this.aliasController,
    required this.fingerprintCompared,
    required this.saving,
    required this.savedPath,
    required this.error,
    required this.onFingerprintChanged,
    required this.onAcceptInvite,
    required this.onSave,
  });

  final BeamImportResult result;
  final TextEditingController aliasController;
  final bool fingerprintCompared;
  final bool saving;
  final String? savedPath;
  final String? error;
  final ValueChanged<bool> onFingerprintChanged;
  final VoidCallback onAcceptInvite;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final manifest = result.manifest;
    final invite = result.invite;
    final public = manifest.mode == BeamMode.public;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(
          public ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
          size: 54,
          color: public
              ? Theme.of(context).colorScheme.error
              : Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Text(
          invite != null
              ? l10nOf(context).uiSignedContactInviteA7CC8B
              : manifest.fileName,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          public
              ? l10nOf(context).uiPUBLICUNTRUSTEDTheSignatureProves96FA7F
              : result.contactTrusted
              ? l10nOf(context).uiEncryptedAndAuthenticatedAsA68B7E4
              : l10nOf(context).uiSignatureValidCompareTheFingerprintA8A1FE,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        SelectableText(
          manifest.senderFingerprint ??
              l10nOf(context).beamFingerprintUnavailable,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: ConestPalette.monoFont,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (invite != null) ...[
          const SizedBox(height: 18),
          TextField(
            controller: aliasController,
            decoration: InputDecoration(
              labelText: l10nOf(context).uiContactAliasE07C25,
            ),
          ),
          CheckboxListTile(
            value: fingerprintCompared,
            onChanged: (value) => onFingerprintChanged(value ?? false),
            title: Text(l10nOf(context).uiWeComparedThisFingerprintIn952BEB),
            contentPadding: EdgeInsets.zero,
          ),
          FilledButton.icon(
            onPressed: saving || !fingerprintCompared ? null : onAcceptInvite,
            icon: const Icon(Icons.person_add_alt_1),
            label: Text(l10nOf(context).uiTrustAndAddContact0962A2),
          ),
        ] else ...[
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: saving || savedPath != null ? null : onSave,
            icon: const Icon(Icons.save_alt),
            label: Text(
              public
                  ? l10nOf(context).uiAcceptAndSavePublicFile852517
                  : l10nOf(context).uiSaveFileBEDC84,
            ),
          ),
        ],
        if (savedPath != null) ...[
          const SizedBox(height: 12),
          Text(l10nOf(context).uiSavedInPrivateConestStorage4C1334),
          SelectableText(savedPath!),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }
}

String _beamMimeType(String fileName) {
  final extension = p.extension(fileName).toLowerCase();
  return switch (extension) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    '.pdf' => 'application/pdf',
    '.txt' => 'text/plain',
    '.mp4' => 'video/mp4',
    '.webm' => 'video/webm',
    '.zip' => 'application/zip',
    _ => 'application/octet-stream',
  };
}

class FullscreenQrScreen extends StatelessWidget {
  const FullscreenQrScreen({
    super.key,
    required this.payload,
    required this.codephrase,
    required this.palette,
  });

  final String payload;
  final String codephrase;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = math.max(
              260.0,
              math.min(constraints.maxWidth - 32, constraints.maxHeight - 180),
            );
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: l10nOf(context).actionClose,
                      ),
                    ),
                    QrImageView(
                      data: payload,
                      version: QrVersions.auto,
                      size: size,
                      gapless: false,
                      errorStateBuilder: (context, error) {
                        return _QrFallback(
                          palette: palette,
                          error: error.toString(),
                        );
                      },
                      eyeStyle: QrEyeStyle(color: palette.qrInk),
                      dataModuleStyle: QrDataModuleStyle(color: palette.qrInk),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      l10nOf(context).uiFullscreenCompactInviteQRCF6B8B,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      codephrase,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Colors.black87,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      l10nOf(
                        context,
                      ).uiValueCharactersIncreaseScreenBrightnessA5AF7D(
                        (payload.length),
                      ),
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    this.fullscreenOnMobile = false,
    required this.controller,
    required this.updateService,
    required this.themeController,
    required this.palette,
    this.onResetIdentity,
  });

  final bool fullscreenOnMobile;
  final MessengerController controller;
  final UpdateService updateService;
  final ConestThemeController themeController;
  final ConestPalette palette;
  final Future<void> Function()? onResetIdentity;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  String _settingsCategory = 'Personal / Preferences';

  /// Phones: a category's page is open (otherwise the list of pages).
  bool _settingsPageOpen = false;

  static const _settingsCategories = [
    'Personal / Preferences',
    'Devices',
    'Connectivity',
    'Network / Relay',
    'Storage',
    'Updates',
    'Danger',
  ];

  String _settingsCategoryLabel(BuildContext context, String category) =>
      switch (category) {
        'Personal / Preferences' => l10nOf(context).settingsPersonal,
        'Devices' => l10nOf(context).uiDevicesDF485C,
        'Storage' => l10nOf(context).settingsStorage,
        'Connectivity' => l10nOf(context).settingsConnectivity,
        'Network / Relay' => l10nOf(context).settingsRelays,
        'Updates' => l10nOf(context).settingsUpdates,
        'Danger' => l10nOf(context).settingsAccount,
        _ => category,
      };

  static IconData _settingsCategoryIcon(String category) => switch (category) {
    'Personal / Preferences' => Icons.person_outline,
    'Devices' => Icons.devices_outlined,
    'Connectivity' => Icons.hub_outlined,
    'Network / Relay' => Icons.dns_outlined,
    'Storage' => Icons.sd_storage_outlined,
    'Updates' => Icons.system_update_outlined,
    _ => Icons.warning_amber_outlined,
  };

  /// One page at a time: beside a list of categories on wide windows, or
  /// opened from the list on phones; [page] holds the chosen category's
  /// sections. The simplest mode shows its short page as it is.
  Widget _settingsLayout(
    BuildContext context, {
    required bool categorized,
    required bool wide,
    required Widget page,
  }) {
    if (!categorized) return SingleChildScrollView(child: page);
    Widget tile(String category, {required bool selected}) => ListTile(
      key: ValueKey('settings-category-$category'),
      dense: wide,
      selected: selected,
      leading: Icon(_settingsCategoryIcon(category)),
      title: Text(_settingsCategoryLabel(context, category)),
      trailing: wide ? null : const Icon(Icons.chevron_right),
      onTap: () => setState(() {
        _settingsCategory = category;
        _settingsPageOpen = true;
      }),
    );
    if (wide) {
      final height = MediaQuery.sizeOf(context).height * 0.7;
      return SizedBox(
        width: 900,
        height: height < 420 ? 420 : height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 210,
              child: ListView(
                children: [
                  for (final category in _settingsCategories)
                    tile(category, selected: category == _settingsCategory),
                ],
              ),
            ),
            const VerticalDivider(width: 24),
            Expanded(
              child: SingleChildScrollView(
                key: ValueKey('settings-page-$_settingsCategory'),
                child: page,
              ),
            ),
          ],
        ),
      );
    }
    if (!_settingsPageOpen) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final category in _settingsCategories)
            tile(category, selected: false),
        ],
      );
    }
    return SingleChildScrollView(
      key: ValueKey('settings-page-$_settingsCategory'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('settings-back'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.arrow_back),
            title: Text(_settingsCategoryLabel(context, _settingsCategory)),
            onTap: () => setState(() => _settingsPageOpen = false),
          ),
          page,
        ],
      ),
    );
  }

  /// Simple mode shows only the personal settings until asked for all.
  bool _showAllSettings = false;

  late final TextEditingController _displayNameController;
  late final TextEditingController _bioController;
  final TextEditingController _relayHostController = TextEditingController();
  final TextEditingController _relayPortController = TextEditingController(
    text: "${(defaultRelayPort)}",
  );
  late final TextEditingController _localRelayPortController;
  late final TextEditingController _irohRelayUrlsController;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final identity = widget.controller.identity;
    _displayNameController = TextEditingController(
      text: identity?.displayName ?? '',
    );
    _bioController = TextEditingController(text: identity?.bio ?? '');
    _localRelayPortController = TextEditingController(
      text: "${(identity?.localRelayPort ?? defaultRelayPort)}",
    );
    _irohRelayUrlsController = TextEditingController(
      text: identity?.connectivity.irohRelayUrls.join('\n') ?? '',
    );
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    _relayHostController.dispose();
    _relayPortController.dispose();
    _localRelayPortController.dispose();
    _irohRelayUrlsController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        final identity = widget.controller.identity;
        if (identity != null) {
          _displayNameController.text = identity.displayName;
          _bioController.text = identity.bio;
          _localRelayPortController.text = '${identity.localRelayPort}';
          _irohRelayUrlsController.text = identity.connectivity.irohRelayUrls
              .join('\n');
        }
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _setGlobalTransportPolicy(
    TransportKind kind,
    TransportPolicy policy,
  ) => _run(() async {
    final identity = widget.controller.identity!;
    final policies = Map<TransportKind, TransportPolicy>.from(
      identity.connectivity.transportPolicies,
    )..[kind] = policy;
    await widget.controller.updateGlobalConnectivity(
      identity.connectivity.copyWith(transportPolicies: policies),
    );
  });

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title:  Text(l10nOf(context).uiResetIdentity8B0224),
        content:  Text(
          l10nOf(context).uiThisClearsTheEncryptedVault864B3D,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10nOf(context).uiReset44C57A),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await _run(
      () =>
          widget.controller.resetIdentity(onPostReset: widget.onResetIdentity),
    );
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = widget.controller.identity;
    final report = widget.controller.relayCapabilityReport;
    final configuredRelays = widget.controller.configuredRelays;
    final contactRelays = widget.controller.discoveredContactRelayRoutes;
    final simple =
        widget.controller.userMode == UserMode.minimal && !_showAllSettings;
    // Every category is a page: a sidebar on wide windows, a list of
    // pages on phones. The simplest mode keeps one short page.
    final categorized = !simple;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return AdaptiveChatDialog(
      fullscreenOnMobile: widget.fullscreenOnMobile,
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: Text(l10nOf(context).tabSettings),
      content: SizedBox(
        width: categorized && wide ? 900 : 720,
        child: identity == null
            ? Text(l10nOf(context).uiNoIdentityIsActive6B2EE3)
            : _settingsLayout(
                context,
                categorized: categorized,
                wide: wide,
                page: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!categorized ||
                        _settingsCategory == 'Personal / Preferences')
                      _SettingsSection(
                        title: l10nOf(context).settingsPersonal,
                        palette: widget.palette,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            UserModeSelector(controller: widget.controller),
                            const SizedBox(height: 12),
                            LanguageSelector(
                              controller: widget.controller,
                              languages: appLanguageNames,
                              aiTranslated: aiTranslatedLanguages,
                            ),
                            if (widget.controller.userMode == UserMode.minimal)
                              SwitchListTile(
                                key: const ValueKey('show-all-settings'),
                                contentPadding: EdgeInsets.zero,
                                title: Text(l10nOf(context).settingsShowAll),
                                value: _showAllSettings,
                                onChanged: (value) =>
                                    setState(() => _showAllSettings = value),
                              ),
                            ListTile(
                              key: const ValueKey('settings-user-guide'),
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.menu_book_outlined),
                              title: Text(l10nOf(context).settingsUserGuide),
                              trailing: const Icon(Icons.open_in_new),
                              onTap: () =>
                                  unawaited(openUserGuide(widget.controller)),
                            ),
                            const SizedBox(height: 12),
                            _ThemeModeSelector(
                              controller: widget.themeController,
                              palette: widget.palette,
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 280,
                                  child: TextField(
                                    controller: _displayNameController,
                                    decoration: InputDecoration(
                                      labelText: l10nOf(context).onbDisplayName,
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(
                                          () => widget.controller
                                              .updateDisplayName(
                                                _displayNameController.text,
                                              ),
                                        ),
                                  child: Text(l10nOf(context).uiSaveNameE73831),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 420,
                                  child: TextField(
                                    controller: _bioController,
                                    minLines: 1,
                                    maxLines: 4,
                                    decoration:  InputDecoration(
                                      labelText: l10nOf(context).uiDescriptionBio505243,
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(
                                          () => widget.controller.updateBio(
                                            _bioController.text,
                                          ),
                                        ),
                                  child: Text(l10nOf(context).uiSaveBioBE2711),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile.adaptive(
                              value: identity.notificationsEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateNotificationsEnabled(value),
                                    ),
                              title:  Text(l10nOf(context).uiMessageNotifications595635),
                              subtitle:  Text(
                                l10nOf(context).uiShowASystemNotificationWhen90113B,
                              ),
                            ),
                            if (widget
                                    .controller
                                    .voiceCallService
                                    ?.media
                                    .available ==
                                true)
                            SwitchListTile.adaptive(
                              value: identity.experimentalVoiceCallsEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy ||
                                      widget
                                              .controller
                                              .voiceCallService
                                              ?.media
                                              .available !=
                                          true
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateExperimentalVoiceCallsEnabled(
                                            value,
                                          ),
                                    ),
                              title:  Text(l10nOf(context).uiExperimentalVoiceCalls51098B),
                              subtitle: Text(
                                widget
                                            .controller
                                            .voiceCallService
                                            ?.media
                                            .available ==
                                        true
                                    ? l10nOf(context).uiAllowsOneToOneIroh45EEF1
                                    : l10nOf(context).uiVoiceCallAudioIsUnavailable0B6C43,
                              ),
                            ),
                            if (!kIsWeb && Platform.isAndroid)
                              SwitchListTile.adaptive(
                                value:
                                    experimentalAndroidBackgroundRuntimeAvailable &&
                                    identity.androidBackgroundRuntimeEnabled,
                                contentPadding: EdgeInsets.zero,
                                onChanged:
                                    _busy ||
                                        !experimentalAndroidBackgroundRuntimeAvailable
                                    ? null
                                    : (value) => _run(
                                        () => widget.controller
                                            .updateAndroidBackgroundRuntimeEnabled(
                                              value,
                                            ),
                                      ),
                                title:  Text(
                                  l10nOf(context).uiExperimentalAndroidBackgroundReceive60828A,
                                ),
                                subtitle:  Text(
                                  l10nOf(context).uiDisabledInReleaseBuildsThe45B7DF,
                                ),
                              ),
                            if (!kIsWeb &&
                                Platform.isAndroid &&
                                widget
                                        .controller
                                        .voiceCallService
                                        ?.media
                                        .available ==
                                    true)
                              SwitchListTile.adaptive(
                                value:
                                    experimentalAndroidBackgroundRuntimeAvailable &&
                                    identity.experimentalVoiceCallsEnabled &&
                                    identity.androidBackgroundCallsEnabled,
                                contentPadding: EdgeInsets.zero,
                                onChanged:
                                    _busy ||
                                        !experimentalAndroidBackgroundRuntimeAvailable ||
                                        !identity.experimentalVoiceCallsEnabled ||
                                        widget
                                                .controller
                                                .voiceCallService
                                                ?.media
                                                .available !=
                                            true
                                    ? null
                                    : (value) => _run(
                                        () => widget.controller
                                            .updateAndroidBackgroundCallsEnabled(
                                              value,
                                            ),
                                      ),
                                title:  Text(
                                  l10nOf(context).uiAllowVoiceCallsInBackground73C5C5,
                                ),
                                subtitle:  Text(
                                  l10nOf(context).uiKeepsCallSignalingActiveAndC0A342,
                                ),
                              ),
                            if (kDebugMode)
                              SwitchListTile.adaptive(
                                value: identity.suppressReadReceipts,
                                contentPadding: EdgeInsets.zero,
                                onChanged: _busy
                                    ? null
                                    : (value) => _run(
                                        () => widget.controller
                                            .updateSuppressReadReceipts(value),
                                      ),
                                title:  Text(
                                  l10nOf(context).uiDonTSendReadConfirmations230076,
                                ),
                                subtitle:  Text(
                                  l10nOf(context).uiDebugOnlyDeliveryAcknowledgementsStill7D6A9C,
                                ),
                              ),
                            const SizedBox(height: 12),
                            Text(
                              l10nOf(context).uiPrivacyOfFilesYouSend4E4A5B,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            SwitchListTile.adaptive(
                              key: const ValueKey('strip-file-metadata'),
                              contentPadding: EdgeInsets.zero,
                              value: widget.controller.removesFileMetadata,
                              title:  Text(l10nOf(context).uiRemoveMetadataFromFilesA4860E),
                              subtitle:  Text(
                                l10nOf(context).uiBeforeSendingRemovesLocationCamera4E390D,
                              ),
                              onChanged: (value) => unawaited(
                                widget.controller
                                    .setRemovesFileMetadata(value)
                                    .then((_) {
                                      if (mounted) setState(() {});
                                    }),
                              ),
                            ),
                            SwitchListTile.adaptive(
                              key: const ValueKey('random-file-names'),
                              contentPadding: EdgeInsets.zero,
                              value: widget.controller.randomizesFileNames,
                              title:  Text(
                                l10nOf(context).uiSendFilesUnderRandomNames5F79D4,
                              ),
                              subtitle:  Text(
                                l10nOf(context).uiReplacesFileNamesWithRandom16F099,
                              ),
                              onChanged: (value) => unawaited(
                                widget.controller
                                    .setRandomizesFileNames(value)
                                    .then((_) {
                                      if (mounted) setState(() {});
                                    }),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              'account ${identity.accountId}\ndevice ${identity.deviceId}\nsafety ${identity.safetyNumber}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: widget.palette.inkSoft,
                                    height: 1.5,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (!categorized || _settingsCategory == 'Devices') ...[
                      _SettingsSection(
                        title: l10nOf(context).uiDevicesDF485C,
                        palette: widget.palette,
                        child: DevicesPanel(
                          controller: widget.controller,
                          onScan: widget.controller.supportsScanner
                              ? () => Navigator.of(context).push<String>(
                                  MaterialPageRoute(
                                    builder: (_) => const QrScanScreen(),
                                  ),
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (!simple &&
                        (!categorized || _settingsCategory == 'Storage'))
                      _SettingsSection(
                        title: l10nOf(context).settingsStorage,
                        palette: widget.palette,
                        child: SwitchListTile.adaptive(
                          value: identity.connectivity.storageReserveEnabled,
                          contentPadding: EdgeInsets.zero,
                          onChanged: _busy
                              ? null
                              : (value) => _run(
                                  () => widget.controller
                                      .updateStorageReserveEnabled(value),
                                ),
                          title:  Text(l10nOf(context).uiKeepOfStorageFreeF00434),
                          subtitle:  Text(
                            l10nOf(context).uiReserveFreeSpaceForOther1AC9CF,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (!simple &&
                        (!categorized || _settingsCategory == 'Connectivity'))
                      _SettingsSection(
                        title: l10nOf(context).settingsConnectivity,
                        palette: widget.palette,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.controller.userMode.showsNetworkDetail)
                              ListTile(
                                key: const ValueKey('open-connections'),
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(Icons.hub_outlined),
                                title: Text(l10nOf(context).connectionsTitle),
                                subtitle: Text(
                                  l10nOf(context).connectionsDescription,
                                ),
                                onTap: () => ConnectionsScreen.show(
                                  context,
                                  widget.controller,
                                ),
                              ),
                            SwitchListTile.adaptive(
                              value: identity.connectivity.lanEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateGlobalConnectivity(
                                            identity.connectivity.copyWith(
                                              lanEnabled: value,
                                            ),
                                          ),
                                    ),
                              title:  Text(l10nOf(context).uiLAN2ECD17),
                              subtitle:  Text(
                                l10nOf(context).uiSameNetworkListenerPairingBeacons5CF0A2,
                              ),
                            ),
                            SwitchListTile.adaptive(
                              value: identity.connectivity.onlineEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateGlobalConnectivity(
                                            identity.connectivity.copyWith(
                                              onlineEnabled: value,
                                            ),
                                          ),
                                    ),
                              title:  Text(l10nOf(context).uiOnlineC3E839),
                              subtitle:  Text(
                                l10nOf(context).uiIrohMessagingAndFileTransfersC4D635,
                              ),
                            ),
                            SwitchListTile.adaptive(
                              value: identity.connectivity.irohRelayEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged:
                                  _busy || !identity.connectivity.onlineEnabled
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateGlobalConnectivity(
                                            identity.connectivity.copyWith(
                                              irohRelayEnabled: value,
                                            ),
                                          ),
                                    ),
                              title:  Text(l10nOf(context).uiIrohRelayFallbackE954F7),
                              subtitle:  Text(
                                l10nOf(context).uiUseIrohSBuiltIn631E03,
                              ),
                            ),
                            SwitchListTile.adaptive(
                              value: identity
                                  .connectivity
                                  .irohTransferLimitEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateIrohTransferLimitEnabled(
                                            value,
                                          ),
                                    ),
                              title: Text(
                                l10nOf(context).uiLimitIrohFilesToMiBB58353,
                              ),
                              subtitle:  Text(
                                l10nOf(context).uiAppliesToDirectOnlineAnd28F6F1,
                              ),
                            ),
                            SwitchListTile.adaptive(
                              key: const ValueKey('share-identifying-carriers'),
                              value: identity
                                  .connectivity
                                  .shareIdentifyingCarriersWithGroups,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateShareIdentifyingCarriersWithGroups(
                                            value,
                                          ),
                                    ),
                              title:  Text(
                                l10nOf(context).uiShareEmailAndMatrixAddressesD762EE,
                              ),
                              subtitle: Text(
                                l10nOf(context).uiLetsMembersOfYourGroups9912A5,
                              ),
                            ),
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              title:  Text(l10nOf(context).uiAutomaticDownloads5E777B),
                              subtitle:  Text(
                                l10nOf(context).uiVerifiedContactsOnlyLimitsAdapt8A1876,
                              ),
                              trailing: DropdownButton<AutoDownloadPreset>(
                                value:
                                    identity.connectivity.autoDownloadPreset ==
                                        AutoDownloadPreset.custom
                                    ? AutoDownloadPreset.medium
                                    : identity.connectivity.autoDownloadPreset,
                                onChanged: _busy
                                    ? null
                                    : (value) {
                                        if (value == null) return;
                                        unawaited(
                                          _run(
                                            () => widget.controller
                                                .updateGlobalConnectivity(
                                                  identity.connectivity
                                                      .copyWith(
                                                        autoDownloadPreset:
                                                            value,
                                                      ),
                                                ),
                                          ),
                                        );
                                      },
                                items: [
                                  DropdownMenuItem(
                                    value: AutoDownloadPreset.low,
                                    child: Text(l10nOf(context).uiLowA12494),
                                  ),
                                  DropdownMenuItem(
                                    value: AutoDownloadPreset.medium,
                                    child: Text(l10nOf(context).uiMediumD40496),
                                  ),
                                  DropdownMenuItem(
                                    value: AutoDownloadPreset.high,
                                    child: Text(l10nOf(context).uiHighB1A595),
                                  ),
                                ],
                              ),
                            ),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.end,
                              children: [
                                SizedBox(
                                  width: 440,
                                  child: TextField(
                                    controller: _irohRelayUrlsController,
                                    enabled:
                                        !_busy &&
                                        identity.connectivity.irohRelayEnabled,
                                    minLines: 1,
                                    maxLines: 4,
                                    decoration:  InputDecoration(
                                      labelText: l10nOf(context).uiCustomIrohRelayURLsDBF979,
                                      helperText:
                                          l10nOf(context).uiOneHTTPSURLPerLineDA8E70,
                                    ),
                                  ),
                                ),
                                FilledButton.tonal(
                                  onPressed:
                                      _busy ||
                                          !identity
                                              .connectivity
                                              .irohRelayEnabled
                                      ? null
                                      : () => _run(() async {
                                          final current =
                                              widget.controller.identity!;
                                          final values =
                                              _irohRelayUrlsController.text
                                                  .split(RegExp(r'[\s,]+'))
                                                  .where(
                                                    (value) => value.isNotEmpty,
                                                  );
                                          await widget.controller
                                              .updateGlobalConnectivity(
                                                current.connectivity.copyWith(
                                                  irohRelayUrls: values
                                                      .toList(),
                                                  irohCustomRelaysBulkCapable:
                                                      values.isEmpty
                                                      ? false
                                                      : null,
                                                ),
                                              );
                                        }),
                                  child:  Text(l10nOf(context).uiSaveIrohRelaysC144AD),
                                ),
                              ],
                            ),
                            if (widget.controller.matrixAvailable) ...[
                              const SizedBox(height: 16),
                              AppModeSelector(controller: widget.controller),
                            ],
                            if (Platform.isWindows) const _WindowsFirewallTile(),
                            NetworkChatsSettings(
                              controller: widget.controller,
                              palette: widget.palette,
                            ),
                            // Network detail: Advanced mode only.
                            if (widget.controller.userMode.showsNetworkDetail)
                              const _MessageRouteLegend(),
                            if (widget.controller.matrixCarrierAvailable)
                              MatrixAccountPanel(controller: widget.controller),
                            const SizedBox(height: 12),
                            NostrCarrierPanel(controller: widget.controller),
                            const SizedBox(height: 12),
                            NostrDirectPanel(controller: widget.controller),
                            const SizedBox(height: 12),
                            EmailCarrierPanel(controller: widget.controller),
                            const SizedBox(height: 12),
                            DeltaChatPanel(controller: widget.controller),
                            const SizedBox(height: 12),
                            ReticulumCarrierPanel(
                              controller: widget.controller,
                            ),
                            const SizedBox(height: 12),
                            MeshtasticCarrierPanel(
                              controller: widget.controller,
                            ),
                            const SizedBox(height: 12),
                            MeshCoreCarrierPanel(controller: widget.controller),
                            const SizedBox(height: 12),
                            BitchatCarrierPanel(controller: widget.controller),
                            const SizedBox(height: 12),
                            TorCarrierPanel(controller: widget.controller),
                            if (widget
                                .controller
                                .userMode
                                .showsNetworkDetail) ...[
                              const SizedBox(height: 12),
                              Text(
                                l10nOf(context).uiTransportPolicy088D79,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 6),
                              for (final kind
                                  in widget.controller.configurableTransports)
                                _TransportPolicySelector(
                                  kind: kind,
                                  value: identity.connectivity.policyFor(kind),
                                  enabled: !_busy,
                                  onChanged: (value) =>
                                      _setGlobalTransportPolicy(kind, value),
                                ),
                            ],
                            const SizedBox(height: 8),
                            Text(
                              identity.connectivity.anyEnabled
                                  ? l10nOf(context).uiPerContactRoutingIsIntersected88E292
                                  : l10nOf(context).uiConnectivityIsFullyOffTheB12483,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: identity.connectivity.anyEnabled
                                        ? widget.palette.inkSoft
                                        : widget.palette.danger,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (!simple &&
                        (!categorized ||
                            _settingsCategory == 'Network / Relay'))
                      _SettingsSection(
                        title: l10nOf(context).settingsRelays,
                        palette: widget.palette,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (report != null)
                              _InsetPanel(
                                palette: widget.palette,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      report.summary,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                    const SizedBox(height: 10),
                                    for (final note in report.notes)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 6,
                                        ),
                                        child: Text(
                                          note,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: widget.palette.inkSoft,
                                              ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                      widget.controller.checkRelayAvailability,
                                    ),
                              icon: const Icon(Icons.network_check),
                              label:  Text(l10nOf(context).uiCheckAvailabilityFCC1A6),
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile.adaptive(
                              value: identity.relayModeEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateRelayModeEnabled(value),
                                    ),
                              title:  Text(l10nOf(context).uiRunThisDeviceAsA9DEA14),
                              subtitle:  Text(
                                l10nOf(context).uiAllowTrustedContactsToUse001771,
                              ),
                            ),
                            SwitchListTile.adaptive(
                              value: identity.autoUseContactRelays,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateAutoUseContactRelays(value),
                                    ),
                              title:  Text(l10nOf(context).uiAutoUseContactsAsRelaysC62C06),
                              subtitle: Text(
                                l10nOf(context).uiValueCandidateRouteSAre175673((contactRelays.length)),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                SizedBox(
                                  width: 220,
                                  child: TextField(
                                    controller: _localRelayPortController,
                                    keyboardType: TextInputType.number,
                                    decoration:  InputDecoration(
                                      labelText: l10nOf(context).uiLocalRelayPort28A73C,
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(() async {
                                          final port = int.tryParse(
                                            _localRelayPortController.text
                                                .trim(),
                                          );
                                          if (port == null) {
                                            throw ArgumentError(
                                              'Enter a valid local relay port.',
                                            );
                                          }
                                          await widget.controller
                                              .updateLocalRelayPort(port);
                                        }),
                                  child: Text(l10nOf(context).uiSavePort1876F6),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _RelayIdentityMismatchBanner(
                              controller: widget.controller,
                              palette: widget.palette,
                            ),
                            _DefaultRelaysControlsCard(
                              controller: widget.controller,
                              palette: widget.palette,
                            ),
                            const SizedBox(height: 12),
                            _RelayHealthDashboard(
                              controller: widget.controller,
                              palette: widget.palette,
                            ),
                            Text(
                              l10nOf(context).uiConfiguredRelays3CA0DE,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 8),
                            if (configuredRelays.isEmpty)
                              Text(
                                l10nOf(context).uiNoRelaysAddedYetF791E7,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: widget.palette.inkSoft),
                              )
                            else
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final relay in configuredRelays)
                                    InputChip(
                                      label: Text(
                                        widget.controller.relayDisplayLabel(
                                          relay,
                                        ),
                                      ),
                                      onDeleted: _busy
                                          ? null
                                          : () => _run(
                                              () => widget.controller
                                                  .removeRelay(relay),
                                            ),
                                    ),
                                ],
                              ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 220,
                                  child: TextField(
                                    controller: _relayHostController,
                                    decoration: InputDecoration(
                                      labelText: l10nOf(
                                        context,
                                      ).relayHostOrLinkLabel,
                                      hintText: l10nOf(context).relayLinkHint,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 140,
                                  child: TextField(
                                    controller: _relayPortController,
                                    keyboardType: TextInputType.number,
                                    decoration:  InputDecoration(
                                      labelText: l10nOf(context).uiRelayPortEA05DA,
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(() async {
                                          // A link from the relay installer
                                          // carries the relay's key too.
                                          final input = _relayHostController
                                              .text
                                              .trim();
                                          if (input.startsWith(
                                            '${RelayLink.scheme}://',
                                          )) {
                                            await widget.controller
                                                .addRelayFromLink(input);
                                            _relayHostController.clear();
                                            return;
                                          }
                                          final port = int.tryParse(
                                            _relayPortController.text.trim(),
                                          );
                                          if (port == null) {
                                            throw ArgumentError(
                                              'Enter a valid relay port.',
                                            );
                                          }
                                          await widget.controller.addRelay(
                                            host: _relayHostController.text
                                                .trim(),
                                            port: port,
                                          );
                                          _relayHostController.clear();
                                          _relayPortController.text =
                                              '$defaultRelayPort';
                                        }),
                                  child:  Text(l10nOf(context).uiDetectAddRelayE825AD),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (!simple &&
                        (!categorized || _settingsCategory == 'Updates'))
                      _SettingsSection(
                        title: l10nOf(context).settingsUpdates,
                        palette: widget.palette,
                        child: ListenableBuilder(
                          listenable: widget.updateService,
                          builder: (context, _) {
                            final updateService = widget.updateService;
                            final buildInfo = updateService.buildInfo;
                            final available = updateService.availableUpdate;
                            final actionLabel =
                                updateService.targetPlatform ==
                                    UpdateTargetPlatform.android
                                ? 'Download & Install'
                                : 'Download & Restart';
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10nOf(context).uiCurrentBuildValueValue9A675D((buildInfo.displayVersion).toString(), (buildInfo.channelLabel).toString()),
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                if (buildInfo.commit != null &&
                                    buildInfo.commit!.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    l10nOf(context).uiCommitValue2E080C((buildInfo.commit).toString()),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: widget.palette.inkSoft,
                                        ),
                                  ),
                                ],
                                if (widget.controller.errorHistoryEnabled)
                                  ListTile(
                                    key: const ValueKey('open-error-history'),
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(
                                      Icons.bug_report_outlined,
                                    ),
                                    title:  Text(l10nOf(context).uiErrorHistory25AFF8),
                                    subtitle:  Text(
                                      l10nOf(context).uiWhatWentWrongKeptAcross27FC1F,
                                    ),
                                    onTap: () => ErrorHistoryScreen.show(
                                      context,
                                      widget.controller,
                                    ),
                                  ),
                                if (updateService.supportsUpdates)
                                  SwitchListTile.adaptive(
                                    key: const ValueKey(
                                      'receive-unstable-updates',
                                    ),
                                    contentPadding: EdgeInsets.zero,
                                    value: updateService.receiveUnstableUpdates,
                                    onChanged:
                                        updateService.isChecking ||
                                            updateService.isDownloading
                                        ? null
                                        : (value) => unawaited(
                                            updateService
                                                .setReceiveUnstableUpdates(
                                                  value,
                                                ),
                                          ),
                                    title:  Text(
                                      l10nOf(context).uiReceiveUnstableUpdatesBF7122,
                                    ),
                                    subtitle:  Text(
                                      l10nOf(context).uiAlsoOfferNightlyBuildsNewerA7FAB0,
                                    ),
                                  ),
                                if (available != null) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    l10nOf(context).uiAvailableValue4B15F7((available.release.tagName).toString()),
                                  ),
                                ],
                                if (updateService.isDownloading) ...[
                                  const SizedBox(height: 12),
                                  LinearProgressIndicator(
                                    value: updateService.downloadProgress,
                                  ),
                                ],
                                if (updateService.statusMessage != null) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    updateService.statusMessage!,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: widget.palette.inkSoft,
                                        ),
                                  ),
                                ],
                                if (updateService.lastError != null) ...[
                                  const SizedBox(height: 10),
                                  Text(
                                    updateService.lastError!,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                        ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed:
                                          _busy ||
                                              updateService.isChecking ||
                                              updateService.isDownloading
                                          ? null
                                          : () => updateService.checkForUpdate(
                                              userInitiated: true,
                                            ),
                                      icon: const Icon(Icons.system_update_alt),
                                      label: Text(
                                        updateService.isChecking
                                            ? l10nOf(context).uiChecking494D0F
                                            : l10nOf(context).uiCheckForUpdates8604FF,
                                      ),
                                    ),
                                    if (available != null)
                                      FilledButton.icon(
                                        onPressed:
                                            _busy || updateService.isDownloading
                                            ? null
                                            : updateService
                                                  .downloadAndApplyAvailableUpdate,
                                        icon: const Icon(Icons.download),
                                        label: Text(actionLabel),
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (!simple &&
                        (!categorized || _settingsCategory == 'Danger'))
                      _SettingsSection(
                        title: l10nOf(context).settingsAccount,
                        palette: widget.palette,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _confirmReset,
                          icon: const Icon(Icons.restart_alt),
                          label: Text(l10nOf(context).uiResetAppIdentity2E0F86),
                        ),
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionClose),
        ),
      ],
    );
  }
}

class _RelayIdentityMismatchBanner extends StatelessWidget {
  const _RelayIdentityMismatchBanner({
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  String _shortFingerprint(String base64Key) {
    final trimmed = base64Key.trim();
    if (trimmed.length <= 12) {
      return trimmed;
    }
    return '${trimmed.substring(0, 12)}…';
  }

  Future<void> _confirmTrust(
    BuildContext context, {
    required String relayId,
    required String announcedKey,
  }) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          l10nOf(
            context,
          ).uiTrustNewIdentityForValue8B0612((relayId).toString()),
        ),
        content: Text(
          l10nOf(context).uiTheRelayIsNowSigningFF71FD(
            (_shortFingerprint(announcedKey)).toString(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(
                dialogContext,
              ).colorScheme.errorContainer,
              foregroundColor: Theme.of(
                dialogContext,
              ).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10nOf(context).uiTrustNewKeyA181BE),
          ),
        ],
      ),
    );
    if (accepted != true) {
      return;
    }
    try {
      await controller.rotateRelayIdentityKey(
        relayId: relayId,
        newKeyBase64: announcedKey,
      );
    } catch (error) {
      controller.setStatus(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final announced = controller.announcedRelayIdentityKeys;
        if (announced.isEmpty) {
          return const SizedBox.shrink();
        }
        final entries = announced.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10nOf(context).uiRelayIdentityChanged097638,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10nOf(context).uiAConfiguredRelayIsSigning60EED0,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          "${(entry.key)} → ${(_shortFingerprint(entry.value))}",
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontFamily: 'monospace',
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _confirmTrust(
                          context,
                          relayId: entry.key,
                          announcedKey: entry.value,
                        ),
                        child: Text(l10nOf(context).uiTrustNewKeyA181BE),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ContactRequestsScreen extends StatelessWidget {
  const _ContactRequestsScreen({
    required this.controller,
    required this.palette,
  });
  final MessengerController controller;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: palette.panel,
    appBar: AppBar(title: Text(l10nOf(context).uiContactRequests082691)),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final requests = controller.pendingContactRequests;
              if (requests.isEmpty) {
                return Center(
                  child: Text(l10nOf(context).uiNoPendingContactRequests697615),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: requests.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (_, index) => _PendingContactRequestCard(
                  controller: controller,
                  palette: palette,
                  request: requests[index],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _PendingContactRequestCard extends StatelessWidget {
  const _PendingContactRequestCard({
    required this.controller,
    required this.palette,
    required this.request,
    this.compact = false,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final PendingContactRequest request;
  final bool compact;

  ContactInvite? get _invite =>
      ContactInvite.tryDecodePayload(request.invitePayload);

  Future<void> _approve(BuildContext context) async {
    final invite = _invite;
    if (invite == null) return;
    String safetyNumber;
    try {
      safetyNumber = await controller.pendingContactSafetyNumber(request.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10nOf(
                context,
              ).uiCouldNotReviewRequestValue82B3D5((error).toString()),
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          l10nOf(context).uiAddValueF034EE((invite.displayName).toString()),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10nOf(context).uiVerifyThePersonAndCompare738F28),
            const SizedBox(height: 16),
            SelectableText(
              safetyNumber,
              style: const TextStyle(fontFamily: ConestPalette.monoFont),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10nOf(context).contactAdd),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await controller.approvePendingContactRequest(request.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10nOf(context).uiCouldNotAddContactValue7F6C38((error).toString()),
          ),
        ),
      );
    }
  }

  Future<void> _reject(BuildContext context) async {
    try {
      await controller.rejectPendingContactRequest(request.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10nOf(
                context,
              ).uiCouldNotRejectRequestValue2EFD58((error).toString()),
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10nOf(context).uiContactRequestRejected447EE8)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final invite = _invite;
    final name = invite?.displayName.trim().isNotEmpty == true
        ? invite!.displayName.trim()
        : 'Unknown device';
    return Container(
      margin: compact ? const EdgeInsets.fromLTRB(8, 6, 8, 0) : EdgeInsets.zero,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_add_alt_1_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10nOf(
                    context,
                  ).uiContactRequestFromValue50B6AC((name).toString()),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10nOf(context).uiUnverifiedValueC1937C(
              (request.senderDeviceId.length > 12
                      ? request.senderDeviceId.substring(0, 12)
                      : request.senderDeviceId)
                  .toString(),
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: invite == null ? null : () => _approve(context),
                child: Text(l10nOf(context).uiReviewE29A79),
              ),
              TextButton(
                onPressed: () => _reject(context),
                child: Text(l10nOf(context).uiReject2B03B5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ContactPairingStatusBanner extends StatelessWidget {
  const _ContactPairingStatusBanner({
    required this.controller,
    required this.palette,
    required this.contact,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final ContactRecord contact;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l10nOf(
                context,
              ).uiContactRequestFailedValue28DD81((error).toString()),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final blocked = contact.pairingState == ContactPairingState.declined ||
        contact.pairingState == ContactPairingState.cancelled;
    final message = switch (contact.pairingState) {
      ContactPairingState.queued => 'Contact request queued. Messages and files stay here until approved.',
      ContactPairingState.sending => 'Sending contact request. Messages and files stay here until approved.',
      ContactPairingState.awaitingAcceptance => 'Waiting for approval. Messages and files stay here until approved.',
      ContactPairingState.declined => 'Request declined. Queued messages and files are blocked.',
      ContactPairingState.cancelled => 'Request cancelled. Queued messages and files are blocked.',
      ContactPairingState.accepted => '',
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: blocked ? Theme.of(context).colorScheme.errorContainer : palette.panel2,
        border: Border.all(color: palette.stroke),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(blocked ? Icons.block_outlined : Icons.schedule_outlined),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          TextButton(
            onPressed: () => _run(
              context,
              () => controller.retryContactPairingNow(contact.deviceId),
            ),
            child: Text(
              blocked
                  ? l10nOf(context).uiRequestAgain7B0434
                  : l10nOf(context).uiRetry9F5CD8,
            ),
          ),
          if (!blocked)
            TextButton(
              onPressed: () => _run(
                context,
                () => controller.cancelContactPairing(contact.deviceId),
              ),
              child: Text(l10nOf(context).actionCancel),
            ),
          if (blocked)
            TextButton(
              onPressed: () => _run(
                context,
                () => controller.removeContact(
                  contact.deviceId,
                  notifyPeer: false,
                ),
              ),
              child: Text(l10nOf(context).uiDiscardChat319267),
            ),
        ],
      ),
    );
  }
}

class _PendingVerificationBanner extends StatelessWidget {
  const _PendingVerificationBanner({
    required this.controller,
    required this.palette,
    required this.contact,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final ContactRecord contact;

  Future<void> _confirm(BuildContext context) async {
    final predecessor = contact.replacesDeviceId != null
        ? controller.contactByDeviceId(contact.replacesDeviceId!)
        : null;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10nOf(context).uiConfirmIdentityReplacement0219C5),
        content: Text(
          predecessor == null
              ? l10nOf(context).uiTrustValueAsAFresh7BF87F(
                  (contact.alias).toString(),
                  (contact.displayName).toString(),
                )
              : l10nOf(
                  context,
                ).uiTrustThisAsAReinstallCBA4CC((predecessor.alias).toString()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10nOf(context).uiItSThem394960),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await controller.confirmContactReplacement(contact.deviceId);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10nOf(context).uiConfirmFailedValueBDE200((error).toString()),
          ),
        ),
      );
    }
  }

  Future<void> _reject(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10nOf(context).uiRejectThisIdentityCB604F),
        content: Text(l10nOf(context).uiThisDeletesTheNewContactBB4444),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(
                dialogContext,
              ).colorScheme.errorContainer,
              foregroundColor: Theme.of(
                dialogContext,
              ).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10nOf(context).uiReject2B03B5),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await controller.rejectContactReplacement(contact.deviceId);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10nOf(context).uiRejectFailedValue5F5917((error).toString()),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final predecessor = contact.replacesDeviceId != null
        ? controller.contactByDeviceId(contact.replacesDeviceId!)
        : null;
    final predecessorAlias = predecessor?.alias ?? contact.displayName;
    return Container(
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_outlined,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10nOf(
                context,
              ).uiThisContactMayBeAD1405D((predecessorAlias).toString()),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _confirm(context),
            child: Text(l10nOf(context).uiItSThem394960),
          ),
          TextButton(
            onPressed: () => _reject(context),
            child: Text(l10nOf(context).uiNotThem685593),
          ),
        ],
      ),
    );
  }
}

class _DefaultRelaysControlsCard extends StatefulWidget {
  const _DefaultRelaysControlsCard({
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<_DefaultRelaysControlsCard> createState() =>
      _DefaultRelaysControlsCardState();
}

class _DefaultRelaysControlsCardState
    extends State<_DefaultRelaysControlsCard> {
  bool _importing = false;

  Future<void> _runImport() async {
    final result = await showDialog<_ImportRelaysDialogResult>(
      context: context,
      builder: (dialogContext) => const _ImportRelaysDialog(),
    );
    if (result == null) return;
    setState(() => _importing = true);
    try {
      await widget.controller.importRelaysFromUrl(
        url: result.url,
        publicKeyBase64: result.publicKeyBase64,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10nOf(
              context,
            ).uiImportedRelaysFromValue37C175((result.url).toString()),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
          content: Text(
            l10nOf(context).uiImportFailedValueBAFB4A((error).toString()),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _removeSource(CustomRelaySource source) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10nOf(context).uiRemoveImportedList36FC81),
        content: Text(
          l10nOf(context).uiThisWillRemoveValueRelay330EEB(
            (source.routeKeys.length),
            (source.url).toString(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10nOf(context).actionCancel),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10nOf(context).uiRemoveE96390),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await widget.controller.removeCustomRelaySource(source.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10nOf(context).uiRemoveFailedValue58F348((error).toString()),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final sources = widget.controller.customRelaySources;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10nOf(context).uiNoBundledConestRelaysOnline46529B),
              const Divider(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    l10nOf(context).uiImportedRelayListsB0BD8B,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: _importing ? null : _runImport,
                    child: _importing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10nOf(context).uiImportFromURL3F7B77),
                  ),
                ],
              ),
              if (sources.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    l10nOf(context).uiNoImportedLists6CBC34,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.palette.inkSoft,
                    ),
                  ),
                )
              else
                for (final source in sources)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10nOf(context).uiValueValueValueRouteS40FB98(
                              (source.url).toString(),
                              (source.isSigned
                                      ? l10nOf(context).relaySourceSigned
                                      : l10nOf(context).relaySourceUnsigned)
                                  .toString(),
                              (source.routeKeys.length),
                            ),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => _removeSource(source),
                          child: Text(l10nOf(context).uiRemoveE96390),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _ImportRelaysDialogResult {
  const _ImportRelaysDialogResult({required this.url, this.publicKeyBase64});

  final String url;
  final String? publicKeyBase64;
}

class _ImportRelaysDialog extends StatefulWidget {
  const _ImportRelaysDialog();

  @override
  State<_ImportRelaysDialog> createState() => _ImportRelaysDialogState();
}

class _ImportRelaysDialogState extends State<_ImportRelaysDialog> {
  final _urlController = TextEditingController();
  final _publicKeyController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    _publicKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(l10nOf(context).uiImportRelayListFromURL86E363),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10nOf(context).uiJSONURL6918BA,
              hintText: 'https://example.com/relays.json',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _publicKeyController,
            decoration: InputDecoration(
              labelText: l10nOf(context).uiOperatorSPublicKeyOptionalA80E7A,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10nOf(context).uiLeaveBlankToImportUnsigned0D354E,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionCancel),
        ),
        FilledButton(
          onPressed: () {
            final url = _urlController.text.trim();
            if (url.isEmpty) return;
            final key = _publicKeyController.text.trim();
            Navigator.of(context).pop(
              _ImportRelaysDialogResult(
                url: url,
                publicKeyBase64: key.isEmpty ? null : key,
              ),
            );
          },
          child: Text(l10nOf(context).uiImportD6FBC9),
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.palette,
    required this.child,
  });

  final String title;
  final ConestPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surfaceElevated.withValues(
          alpha: palette.isDark ? 0.72 : 0.88,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: palette.stroke),
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Signature settings header — mono `// SECTION` in place of the
          // old titleLarge, matching the design's SectionLabel vocabulary.
          Text(
            "// ${(title.toUpperCase())}",
            style: TextStyle(
              fontFamily: ConestPalette.monoFont,
              fontSize: 11,
              letterSpacing: 2,
              color: palette.textMuted,
            ),
          ),
          const SizedBox(height: 14),
          Material(type: MaterialType.transparency, child: child),
        ],
      ),
    );
  }
}

/// Live relay health dashboard — an aggregate OK/WARN/DOWN/AVG-RTT strip plus
/// a per-relay [RelayHealthRow] with a latency sparkline, driven by the
/// controller's `relayHealthScores`. Self-updating via [ListenableBuilder].
class _RelayHealthDashboard extends StatelessWidget {
  const _RelayHealthDashboard({
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  Color _statusColor(RelayHealthScore? score) {
    if (score == null || score.recentAttempts == 0) return palette.textMuted;
    final rate = score.successRate;
    if (rate >= 0.7) return palette.success;
    if (rate > 0) return palette.warning;
    return palette.danger;
  }

  String _detail(RelayHealthScore? score) {
    if (score == null || score.recentAttempts == 0) return 'no probes yet';
    final med = score.recentMedianLatency;
    final rtt = med == null ? '—' : '${med.inMilliseconds}ms';
    return '${(score.successRate * 100).round()}% ok · $rtt · '
        '${score.recentAttempts} probe(s)';
  }

  List<double> _spark(RelayHealthScore? score) {
    if (score == null) return const <double>[];
    return [
      for (final s in score.recentSamples)
        s.succeeded ? (s.latency?.inMilliseconds.toDouble() ?? 1.0) : 0.0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final relays = controller.configuredRelays;
        if (relays.isEmpty) {
          return const SizedBox.shrink();
        }
        var ok = 0, warn = 0, down = 0;
        final rtts = <int>[];
        for (final relay in relays) {
          final score =
              controller.relayHealthScores[relayHealthEndpointKey(relay)];
          if (score == null || score.recentAttempts == 0) continue;
          final rate = score.successRate;
          if (rate >= 0.7) {
            ok++;
          } else if (rate > 0) {
            warn++;
          } else {
            down++;
          }
          final med = score.recentMedianLatency;
          if (med != null) rtts.add(med.inMilliseconds);
        }
        final avgRtt = rtts.isEmpty
            ? '—'
            : '${(rtts.reduce((a, b) => a + b) / rtts.length).round()}ms';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: palette.panel2,
                border: Border.all(color: palette.border),
                borderRadius: BorderRadius.circular(ConestPalette.radius),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: RelayStat(
                      palette: palette,
                      label: l10nOf(context).uiOK9CE3BD,
                      value: '$ok',
                      color: palette.success,
                    ),
                  ),
                  Expanded(
                    child: RelayStat(
                      palette: palette,
                      label: l10nOf(context).uiWARNC2FD77,
                      value: '$warn',
                      color: palette.warning,
                    ),
                  ),
                  Expanded(
                    child: RelayStat(
                      palette: palette,
                      label: l10nOf(context).uiDOWN30E504,
                      value: '$down',
                      color: palette.danger,
                    ),
                  ),
                  Expanded(
                    child: RelayStat(
                      palette: palette,
                      label: l10nOf(context).uiAVGRTTE96B26,
                      value: avgRtt,
                      color: palette.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(ConestPalette.radius),
              child: Column(
                children: [
                  for (final relay in relays)
                    Builder(
                      builder: (context) {
                        final score = controller
                            .relayHealthScores[relayHealthEndpointKey(relay)];
                        return RelayHealthRow(
                          palette: palette,
                          host: controller.relayDisplayLabel(relay),
                          detail: _detail(score),
                          statusColor: _statusColor(score),
                          spark: _spark(score),
                        );
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
        );
      },
    );
  }
}

class _InsetPanel extends StatelessWidget {
  const _InsetPanel({required this.palette, required this.child});

  final ConestPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.stroke),
      ),
      child: child,
    );
  }
}

class _ThemeModeSelector extends StatelessWidget {
  const _ThemeModeSelector({required this.controller, required this.palette});

  final ConestThemeController controller;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10nOf(context).uiThemeA797E3,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<ConestThemeMode>(
                segments: [
                  for (final mode in ConestThemeMode.values)
                    ButtonSegment(
                      value: mode,
                      label: Text(themeModeLabel(context, mode)),
                      icon: Icon(_themeModeIcon(mode)),
                    ),
                ],
                selected: {controller.mode},
                onSelectionChanged: (selected) {
                  final mode = selected.single;
                  unawaited(controller.setMode(mode));
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              controller.mode == ConestThemeMode.adaptive &&
                      palette.usingDynamicColor
                  ? l10nOf(context).uiAdaptiveIsUsingSystemDynamicBAA149
                  : l10nOf(context).uiMintAndPinkRemainTheC846F3,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10nOf(context).uiDecoration2DB87A,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  _decorationLabel(controller.decorationIntensity, context),
                  style: TextStyle(
                    fontFamily: ConestPalette.monoFont,
                    fontSize: 11,
                    letterSpacing: 1,
                    color: palette.inkSoft,
                  ),
                ),
              ],
            ),
            Slider(
              value: controller.decorationIntensity.clamp(0.0, 1.5),
              min: 0,
              max: 1.5,
              divisions: 6,
              label: _decorationLabel(controller.decorationIntensity, context),
              onChanged: (value) =>
                  unawaited(controller.setDecorationIntensity(value)),
            ),
            Text(
              l10nOf(context).uiAmbientGridScanlinesCornerReticles45D5C5,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
            const SizedBox(height: 16),
            Text(
              l10nOf(context).uiShellBDC1FD,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<ConestShell>(
                segments: [
                  for (final shell in ConestShell.values)
                    ButtonSegment(value: shell, label: Text(shell.label)),
                ],
                selected: {controller.shell},
                onSelectionChanged: (selected) =>
                    unawaited(controller.setShell(selected.single)),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              shellDescription(context, controller.shell),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
            // The inner Home layout only applies to the Signature shell.
            if (controller.shell == ConestShell.signature) ...[
              const SizedBox(height: 16),
              Text(
                l10nOf(context).uiHomeLayoutE19685,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<ConestHomeLayout>(
                  segments: [
                    for (final layout in ConestHomeLayout.values)
                      ButtonSegment(
                        value: layout,
                        label: Text(homeLayoutLabel(context, layout)),
                      ),
                  ],
                  selected: {controller.homeLayout},
                  onSelectionChanged: (selected) =>
                      unawaited(controller.setHomeLayout(selected.single)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                homeLayoutDescription(context, controller.homeLayout),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
              ),
            ],
          ],
        );
      },
    );
  }

  String _decorationLabel(double intensity, BuildContext context) {
    if (intensity <= 0.05) return l10nOf(context).uiCLEAN2F3D27;
    if (intensity < 0.8) return l10nOf(context).uiSUBTLEBB048B;
    if (intensity <= 1.05) return l10nOf(context).uiDEFAULTC18920;
    return l10nOf(context).uiFULLCC0A74;
  }

  IconData _themeModeIcon(ConestThemeMode mode) {
    return switch (mode) {
      ConestThemeMode.system => Icons.brightness_auto_outlined,
      ConestThemeMode.light => Icons.light_mode_outlined,
      ConestThemeMode.dark => Icons.dark_mode_outlined,
      ConestThemeMode.black => Icons.contrast_outlined,
      ConestThemeMode.adaptive => Icons.palette_outlined,
    };
  }
}

class DebugMenuDialog extends StatefulWidget {
  const DebugMenuDialog({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<DebugMenuDialog> createState() => _DebugMenuDialogState();
}

class _DebugMenuDialogState extends State<DebugMenuDialog> {
  DebugRunReport? _report;
  bool _busy = false;
  bool _fileTestBusy = false;
  String? _selectedDebugContactId;
  int _selectedDebugSizeMiB = 5;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _selectedDebugContactId = widget.controller.contacts
        .where((contact) => contact.canSendOutbound)
        .firstOrNull
        ?.deviceId;
    widget.controller.addListener(_handleControllerUpdate);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerUpdate);
    super.dispose();
  }

  void _handleControllerUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _runTests() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final report = await widget.controller.runDebugSelfTest();
      if (mounted) {
        setState(() => _report = report);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _copyDebugInfo() async {
    final text = widget.controller.buildDebugAnalysisText(report: _report);
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      setState(() => _notice = 'Debug analysis copied to clipboard.');
    }
  }

  Future<void> _runLanFileTest({bool matrix = false}) async {
    final deviceId = _selectedDebugContactId;
    final contact = deviceId == null
        ? null
        : widget.controller.contactByDeviceId(deviceId);
    if (contact == null) {
      setState(() => _error = 'Select a verified contact first.');
      return;
    }
    setState(() {
      _fileTestBusy = true;
      _error = null;
      _notice = null;
    });
    try {
      final results = matrix
          ? await widget.controller.runDebugFileBattleTestMatrix(
              contact: contact,
            )
          : <DebugFileTestResult>[
              await widget.controller.runDebugFileBattleTest(
                contact: contact,
                sizeMiB: _selectedDebugSizeMiB,
              ),
            ];
      if (mounted) {
        final passed = results.where((result) => result.success).length;
        setState(() {
          _notice = matrix
              ? 'Automatic matrix finished: $passed/${results.length} passed.'
              : results.single.success
              ? '${results.single.sizeMiB} MiB passed automatically.'
              : '${results.single.sizeMiB} MiB failed: '
                    '${results.single.detail ?? "unknown error"}';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _fileTestBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = widget.controller.identity;
    final contacts = widget.controller.contacts;
    final relays = widget.controller.configuredRelays;
    final selectableContacts = contacts
        .where((contact) => contact.canSendOutbound)
        .toList(growable: false);
    if (_selectedDebugContactId != null &&
        !selectableContacts.any(
          (contact) => contact.deviceId == _selectedDebugContactId,
        )) {
      _selectedDebugContactId = selectableContacts.firstOrNull?.deviceId;
    }
    final diagnosticTransfers = widget.controller.transferSnapshots
        .where(
          (snapshot) =>
              widget.controller
                  .attachmentDescriptorFor(snapshot.id)
                  ?.mimeType ==
              'application/x-conest-transfer-test',
        )
        .take(8)
        .toList(growable: false);
    final debugFileTestsReady = widget.controller.debugFileBattleTestEnabled;
    final platform = kIsWeb ? 'web' : Platform.operatingSystem;
    final report = _report;
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: const Text('Debug menu'),
      content: SizedBox(
        width: 760,
        child: identity == null
            ? const Text('No identity is active.')
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DebugInfoBlock(
                      title: 'Build',
                      lines: [
                        'mode: ${kDebugMode ? 'debug' : 'release'}',
                        'debug protocol: ${widget.controller.debugBuildId ?? '(disabled)'}',
                        'platform: $platform',
                        'scanner: ${widget.controller.supportsScanner ? 'yes' : 'no'}',
                      ],
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 12),
                    _DebugInfoBlock(
                      title: 'Identity',
                      lines: [
                        'account: ${identity.accountId}',
                        'device: ${identity.deviceId}',
                        'display: ${identity.displayName}',
                        'bio: ${identity.bio.isEmpty ? '(empty)' : identity.bio}',
                        'safety: ${identity.safetyNumber}',
                      ],
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 12),
                    _DebugInfoBlock(
                      title: 'Network',
                      lines: [
                        'local relay: ${widget.controller.localRelayRunning ? 'running :${identity.localRelayPort}' : 'not running'}',
                        'pairing beacon: ${widget.controller.pairingBeaconRunning ? 'running :$defaultRelayPort' : 'not running'}',
                        'beacon routes: ${widget.controller.recentPairingBeaconRoutes.isEmpty ? '(none)' : widget.controller.recentPairingBeaconRoutes.map((route) => route.label).join(', ')}',
                        'relay mode: ${identity.relayModeEnabled ? 'on' : 'off'}',
                        'auto contact relays: ${identity.autoUseContactRelays ? 'on' : 'off'}',
                        'lan: ${identity.lanAddresses.isEmpty ? '(none)' : identity.lanAddresses.join(', ')}',
                        'configured relays: ${relays.isEmpty ? '(none)' : relays.map((route) => route.label).join(', ')}',
                        'last relay status: ${widget.controller.lastRelayStatus}',
                      ],
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 12),
                    _DebugInfoBlock(
                      title: 'Runtime',
                      lines: [
                        'mode: ${widget.controller.runtimeModeLabel}',
                        'next poll: ${widget.controller.nextScheduledPollAt?.toIso8601String() ?? '(none)'}',
                        'pairing session: ${widget.controller.pairingSessionActive ? 'active until ${widget.controller.pairingSessionActiveUntil?.toIso8601String() ?? '(unknown)'}' : 'inactive'}',
                        'last pairing beacon send: ${widget.controller.lastPairingBeaconSentAt?.toIso8601String() ?? '(none)'}',
                        'fetch/store/health: ${widget.controller.fetchCallCount}/${widget.controller.storeCallCount}/${widget.controller.healthCallCount}',
                        'vault saves: ${widget.controller.vaultSaveCount} (${widget.controller.lastVaultSaveAt?.toIso8601String() ?? 'never'})',
                      ],
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 12),
                    _DebugInfoBlock(
                      title: 'Storage and queues',
                      lines: [
                        'contacts: ${contacts.length}',
                        'lan lobby messages: ${widget.controller.lanLobbyMessages.length}',
                        'messages: ${widget.controller.totalMessageCount}',
                        'pending outbound: ${widget.controller.pendingOutboundCount}',
                        'awaiting recipient ack: ${widget.controller.awaitingRecipientAckCount}',
                        'seen envelopes: ${widget.controller.seenEnvelopeCount}',
                        'status: ${widget.controller.statusMessage ?? '(none)'}',
                      ],
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 12),
                    _DebugInfoBlock(
                      title: '3-device workflow',
                      lines: const [
                        '1. Open this debug menu on Windows, Linux, and Android debug builds.',
                        '2. Tap Run Debug Tests on each device after all three are online.',
                        '3. Tap Copy Debug + Analysis on each device and compare the peer matrix lines.',
                        '4. If a peer stays warn/fail, compare available paths, probe ack, two-way reply, and relay probe fields across all three reports.',
                      ],
                      palette: widget.palette,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'File transfer diagnostics',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      debugFileTestsReady
                          ? 'The selected peer must run the exact same debug build. It auto-accepts the encrypted test, verifies every block and the final SHA-256, reports timing, and removes test artifacts on both devices. No visual confirmation is required. Tests check LAN reachability first, then use Iroh. Iroh relay fallback follows your settings; online tests need no custom Conest relay.'
                          : 'Automatic file tests are disabled because this local build has no exact artifact tag and commit. Use a Debug workflow artifact or build both peers with identical CONEST_BUILD_TAG and CONEST_BUILD_COMMIT values.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: debugFileTestsReady
                            ? widget.palette.inkSoft
                            : widget.palette.warning,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.controller.nativeAttachmentCryptoAvailable
                          ? 'Block crypto: native Rust acceleration'
                          : 'Block crypto: compatible Dart fallback (slower)',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: widget.controller.nativeAttachmentCryptoAvailable
                            ? widget.palette.success
                            : widget.palette.warning,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedDebugContactId,
                      decoration: const InputDecoration(
                        labelText: 'Test contact',
                      ),
                      items: [
                        for (final contact in selectableContacts)
                          DropdownMenuItem(
                            value: contact.deviceId,
                            child: Text(contact.alias),
                          ),
                      ],
                      onChanged: _fileTestBusy
                          ? null
                          : (value) =>
                                setState(() => _selectedDebugContactId = value),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      initialValue: _selectedDebugSizeMiB,
                      decoration: const InputDecoration(labelText: 'File size'),
                      items: [
                        for (final size
                            in MessengerController.debugLanTestSizesMiB)
                          DropdownMenuItem(
                            value: size,
                            child: Text('$size MiB'),
                          ),
                      ],
                      onChanged: _fileTestBusy
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _selectedDebugSizeMiB = value);
                              }
                            },
                    ),
                    if (_selectedDebugSizeMiB > 100 &&
                        identity.connectivity.irohTransferLimitEnabled ==
                            true) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Iroh tests stop at the recommended 100 MiB limit. Disable the limit in Settings on both devices for larger online tests. LAN tests can use every size.',
                      ),
                    ],
                    if (_selectedDebugSizeMiB >= 1000) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Large diagnostics need roughly twice the selected size temporarily and can take several minutes.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.palette.warning,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed:
                          _fileTestBusy ||
                              !debugFileTestsReady ||
                              _selectedDebugContactId == null
                          ? null
                          : () => _runLanFileTest(),
                      icon: _fileTestBusy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lan_outlined),
                      label: Text(
                        _fileTestBusy
                            ? 'Running automatic test…'
                            : 'Battle-test selected size',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed:
                          _fileTestBusy ||
                              !debugFileTestsReady ||
                              _selectedDebugContactId == null
                          ? null
                          : () => _runLanFileTest(matrix: true),
                      icon: const Icon(
                        Icons.playlist_add_check_circle_outlined,
                      ),
                      label: const Text('Run full 5–2000 MiB matrix'),
                    ),
                    if (widget.controller.debugFileTestStatus
                        case final status?) ...[
                      const SizedBox(height: 8),
                      Text(
                        status,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (diagnosticTransfers.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      for (final snapshot in diagnosticTransfers)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _DebugInfoBlock(
                            title:
                                widget.controller
                                    .attachmentDescriptorFor(snapshot.id)
                                    ?.fileName ??
                                snapshot.id,
                            lines: [
                              '${snapshot.direction.name} · ${snapshot.phase.name} · ${(snapshot.progress * 100).toStringAsFixed(1)}%',
                              '${snapshot.bytesTransferred} / ${snapshot.totalBytes} bytes${snapshot.routeLabel == null ? '' : ' · ${snapshot.routeLabel}'}',
                              if (snapshot.error != null)
                                'error: ${snapshot.error}',
                            ],
                            palette: widget.palette,
                          ),
                        ),
                    ],
                    if (widget.controller.debugFileTestResults.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      for (final result
                          in widget.controller.debugFileTestResults.take(8))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _DebugInfoBlock(
                            title:
                                '${result.sizeMiB} MiB · ${result.success ? "PASS" : "FAIL"}',
                            lines: [
                              '${result.bytesVerified} verified bytes in ${result.elapsed.inSeconds}s',
                              if (result.mebibytesPerSecond != null)
                                '${result.mebibytesPerSecond!.toStringAsFixed(1)} MiB/s',
                              if (result.detail != null) result.detail!,
                            ],
                            palette: widget.palette,
                          ),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      'Contact route cache',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (contacts.isEmpty)
                      Text(
                        'No contacts to inspect.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.palette.inkSoft,
                        ),
                      )
                    else
                      for (final contact in contacts)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _DebugInfoBlock(
                            title: contact.alias,
                            lines: [
                              'device: ${contact.deviceId}',
                              'routes: ${contact.routeSummary}',
                              'cached health: ${contact.prioritizedRouteHints.map((route) => widget.controller.routeHealthFor(route)?.summary ?? '${route.kind.name}:${route.label} not checked').join(' | ')}',
                            ],
                            palette: widget.palette,
                          ),
                        ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _busy ? null : _runTests,
                      icon: _busy
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fact_check_outlined),
                      label: const Text('Run Debug Tests'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _copyDebugInfo,
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('Copy Debug + Analysis'),
                    ),
                    if (_notice != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _notice!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.palette.inkSoft,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    if (report != null) ...[
                      const SizedBox(height: 18),
                      Text(
                        'Last run: ${report.passed} passed, ${report.warned} warnings, ${report.failed} failed, ${report.skipped} skipped',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      _DebugInfoBlock(
                        title: 'Run summary',
                        lines: [
                          'devices in scope: ${report.deviceCount}',
                          'peer reports: ${report.peerReports.length}',
                          'peers with available paths: ${report.peersWithAvailablePaths}/${report.peerReports.length}',
                          'peers with heartbeat replies: ${report.peerReports.where((peer) => peer.heartbeatReplyReceived).length}/${report.peerReports.length}',
                          'peers with probe ack: ${report.peersWithProbeAck}/${report.peerReports.length}',
                          'peers with two-way reply: ${report.peersWithTwoWayReply}/${report.peerReports.length}',
                          'peers with relay probe: ${report.peersWithRelayProbe}/${report.peerReports.length}',
                        ],
                        palette: widget.palette,
                      ),
                      if (report.peerReports.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          'Peer test matrix',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        for (final peer in report.peerReports)
                          _DebugPeerTile(peer: peer, palette: widget.palette),
                      ],
                      if (report.notes.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _DebugInfoBlock(
                          title: 'Coverage notes',
                          lines: report.notes,
                          palette: widget.palette,
                        ),
                      ],
                      const SizedBox(height: 8),
                      for (final result in report.results)
                        _DebugResultTile(
                          result: result,
                          palette: widget.palette,
                        ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DebugInfoBlock extends StatelessWidget {
  const _DebugInfoBlock({
    required this.title,
    required this.lines,
    required this.palette,
  });

  final String title;
  final List<String> lines;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.chipBackground,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final line in lines)
            SelectableText(
              line,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
        ],
      ),
    );
  }
}

class _DebugResultTile extends StatelessWidget {
  const _DebugResultTile({required this.result, required this.palette});

  final DebugCheckResult result;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.stroke),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(result.status.icon, color: _debugStatusColor(result.status)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.name,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  result.detail,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
                ),
              ],
            ),
          ),
          Text(
            result.status.name,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: palette.inkSoft),
          ),
        ],
      ),
    );
  }

  Color _debugStatusColor(DebugCheckStatus status) {
    switch (status) {
      case DebugCheckStatus.pass:
        return Colors.green.shade700;
      case DebugCheckStatus.warn:
        return Colors.orange.shade800;
      case DebugCheckStatus.fail:
        return Colors.red.shade700;
      case DebugCheckStatus.skip:
        return palette.inkSoft;
    }
  }
}

class _DebugPeerTile extends StatelessWidget {
  const _DebugPeerTile({required this.peer, required this.palette});

  final DebugPeerReport peer;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    final okColor = Colors.green.shade700;
    final warnColor = Colors.orange.shade800;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${peer.alias} • ${peer.reachability.label}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                peer.deviceId,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: palette.inkSoft),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _DebugFlagChip(
                label:
                    'paths ${peer.availablePathCount}/${peer.totalPathCount}',
                ok: peer.availablePathCount > 0,
                okColor: okColor,
                warnColor: warnColor,
              ),
              _DebugFlagChip(
                label:
                    'heartbeat ${peer.heartbeatReplyReceived ? 'yes' : 'no'}',
                ok: !peer.heartbeatAttempted || peer.heartbeatReplyReceived,
                okColor: okColor,
                warnColor: warnColor,
              ),
              _DebugFlagChip(
                label: 'probe ack ${peer.probeAcknowledged ? 'yes' : 'no'}',
                ok: !peer.probeAccepted || peer.probeAcknowledged,
                okColor: okColor,
                warnColor: warnColor,
              ),
              _DebugFlagChip(
                label: 'two-way ${peer.twoWayReplyReceived ? 'yes' : 'no'}',
                ok: !peer.twoWayAccepted || peer.twoWayReplyReceived,
                okColor: okColor,
                warnColor: warnColor,
              ),
              _DebugFlagChip(
                label: 'relay probe ${peer.relayProbeAccepted ? 'yes' : 'no'}',
                ok: peer.relayProbeAccepted,
                okColor: okColor,
                warnColor: warnColor,
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            'best path: ${peer.bestPathSummary}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
          ),
          const SizedBox(height: 4),
          SelectableText(
            'expected sender state on best path: ${peer.expectedBestDeliveryState}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
          ),
          const SizedBox(height: 4),
          SelectableText(
            'routes: ${peer.routeSummary}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
          ),
          const SizedBox(height: 4),
          SelectableText(
            'last two-way success: ${_formatProfileTimestamp(peer.lastTwoWaySuccessAt)} • last heartbeat reply: ${_formatProfileTimestamp(peer.lastHeartbeatReplyAt)} • last available path: ${_formatProfileTimestamp(peer.lastAvailablePathAt)}',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
          ),
        ],
      ),
    );
  }
}

class _DebugFlagChip extends StatelessWidget {
  const _DebugFlagChip({
    required this.label,
    required this.ok,
    required this.okColor,
    required this.warnColor,
  });

  final String label;
  final bool ok;
  final Color okColor;
  final Color warnColor;

  @override
  Widget build(BuildContext context) {
    final color = ok ? okColor : warnColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _RoutePill extends StatelessWidget {
  const _RoutePill({required this.route, required this.palette});

  final PeerEndpoint route;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.chipBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.stroke),
      ),
      child: Text(
        "${(route.kind.name)}:${(route.label)}",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Signature ci5 frame around a QR: thin corner brackets + a rotated mono
/// "CONEST · ci5 · YEAR" stamp. Drawn in dark ink because it overlays the
/// white QR field where mint would wash out.
class _SignatureQrFrame extends StatelessWidget {
  const _SignatureQrFrame({required this.palette, required this.child});

  final ConestPalette palette;
  final Widget child;

  static const _ink = Color(0xFF111111);

  Widget _bracket({required bool top, required bool left}) {
    return SizedBox(
      width: 14,
      height: 14,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: top
                ? const BorderSide(color: _ink, width: 1.5)
                : BorderSide.none,
            bottom: top
                ? BorderSide.none
                : const BorderSide(color: _ink, width: 1.5),
            left: left
                ? const BorderSide(color: _ink, width: 1.5)
                : BorderSide.none,
            right: left
                ? BorderSide.none
                : const BorderSide(color: _ink, width: 1.5),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(left: 0, top: 0, child: _bracket(top: true, left: true)),
        Positioned(right: 0, top: 0, child: _bracket(top: true, left: false)),
        Positioned(left: 0, bottom: 0, child: _bracket(top: false, left: true)),
        Positioned(
          right: 0,
          bottom: 0,
          child: _bracket(top: false, left: false),
        ),
        Positioned(
          right: -2,
          top: -10,
          child: Transform.rotate(
            angle: -0.035,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.85),
                border: Border.all(color: _ink),
              ),
              child: Text(
                l10nOf(
                  context,
                ).uiCONESTCiValue7964DC((DateTime.now().year).toString()),
                style: const TextStyle(
                  fontFamily: ConestPalette.monoFont,
                  fontSize: 8,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _QrFallback extends StatelessWidget {
  const _QrFallback({required this.palette, required this.error});

  final ConestPalette palette;
  final String error;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 220,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.paper,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.stroke),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.qr_code_2_outlined, color: palette.inkSoft, size: 36),
              const SizedBox(height: 10),
              Text(
                l10nOf(context).uiQRUnavailable12869A,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                l10nOf(context).uiUseTheCodephraseOrPayload187111,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
              ),
              const SizedBox(height: 8),
              Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: palette.inkSoft),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RouteHealthTile extends StatelessWidget {
  const _RouteHealthTile({
    required this.check,
    required this.palette,
    required this.twoWayConfirmed,
  });

  final PeerRouteHealth check;
  final ConestPalette palette;
  final bool twoWayConfirmed;

  @override
  Widget build(BuildContext context) {
    final available = check.available;
    final usable = available && twoWayConfirmed;
    final latency = check.latency;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.stroke),
      ),
      child: Row(
        children: [
          Icon(
            usable
                ? Icons.check_circle_outline
                : available
                ? Icons.sync_problem_outlined
                : Icons.error_outline,
            color: usable ? Colors.green.shade700 : Colors.orange.shade800,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "${(check.route.kind.name.toUpperCase())} ${(check.route.label)}",
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  usable
                      ? l10nOf(context).uiTwoWayConfirmedValueE5A1A1(
                          (latency == null
                                  ? ''
                                  : ' • ${latency.inMilliseconds}ms')
                              .toString(),
                        )
                      : available
                      ? l10nOf(context).uiPathAcceptsSendWaitingFor10B4B0(
                          (latency == null
                                  ? ''
                                  : ' • ${latency.inMilliseconds}ms')
                              .toString(),
                        )
                      : check.error ?? l10nOf(context).uiUnavailable1D5EE3,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
                ),
              ],
            ),
          ),
          Text(
            usable
                ? l10nOf(context).uiUsable829A7C
                : available
                ? l10nOf(context).uiOneWay5EF4D0
                : l10nOf(context).uiSkipC7E168,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: palette.inkSoft),
          ),
        ],
      ),
    );
  }
}

class _EmptyContactsState extends StatelessWidget {
  const _EmptyContactsState({required this.palette});

  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.paperStrong,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.stroke),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10nOf(context).uiShareYourInviteThenEither5FEF78,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: palette.inkSoft,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyChatState extends StatelessWidget {
  const _EmptyChatState({required this.palette});

  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Card(
        elevation: 0,
        color: palette.paperStrong,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: palette.stroke),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 52, color: palette.inkSoft),
                  const SizedBox(height: 16),
                  Text(
                    l10nOf(context).uiStartWithOneTrustedContact650B80,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10nOf(context).uiThisReleasePairsThroughA883AA2,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: palette.inkSoft,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureStrip extends StatelessWidget {
  const _FeatureStrip({required this.palette, required this.items});

  final ConestPalette palette;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: palette.paperStrong,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.stroke),
            ),
            child: Text(item),
          ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.palette,
    required this.icon,
    this.expand = false,
  });

  final String label;
  final ConestPalette palette;
  final IconData icon;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(
      label,
      maxLines: expand ? 2 : 1,
      overflow: TextOverflow.ellipsis,
    );
    return Container(
      width: expand ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.stroke),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: palette.primary),
          const SizedBox(width: 8),
          if (expand) Expanded(child: labelWidget) else labelWidget,
        ],
      ),
    );
  }
}

/// Banner shown on invite-exchange surfaces when global connectivity is fully
/// off — the user wouldn't get acks or pairing responses until they re-enable
/// at least one transport. Renders nothing when LAN or Online is on. Listens
/// to the controller so toggling Settings while the surface is open clears the
/// banner without a manual refresh.
class _ConnectivityOfflineBanner extends StatelessWidget {
  const _ConnectivityOfflineBanner({
    required this.controller,
    required this.palette,
    required this.message,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final String message;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final global =
            controller.identity?.connectivity ??
            const GlobalConnectivityPreferences();
        if (global.anyEnabled) {
          return const SizedBox.shrink();
        }
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: palette.danger.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.danger),
          ),
          child: Row(
            children: [
              Icon(Icons.cloud_off, color: palette.danger, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectivityChip extends StatelessWidget {
  const _ConnectivityChip({
    required this.contact,
    required this.controller,
    required this.palette,
  });

  final ContactRecord contact;
  final MessengerController controller;
  final ConestPalette palette;

  ({String label, IconData icon, Color color}) _labelFor(
    EffectiveRoutingMode mode,
    BuildContext context,
  ) {
    switch (mode) {
      case EffectiveRoutingMode.lanFirst:
        return (
          label: l10nOf(context).uiLANFirstB360D1,
          icon: Icons.swap_horiz,
          color: palette.primary,
        );
      case EffectiveRoutingMode.lanOnly:
        return (
          label: l10nOf(context).uiLANOnly94945D,
          icon: Icons.wifi_tethering,
          color: palette.primary,
        );
      case EffectiveRoutingMode.onlineFirst:
        return (
          label: l10nOf(context).uiOnlineFirst346B6D,
          icon: Icons.public,
          color: palette.primary,
        );
      case EffectiveRoutingMode.onlineOnly:
        return (
          label: l10nOf(context).uiOnlineOnlyF79CB9,
          icon: Icons.cloud_outlined,
          color: palette.primary,
        );
      case EffectiveRoutingMode.offline:
        return (
          label: l10nOf(context).uiOfflineE01FA7,
          icon: Icons.cloud_off,
          color: palette.danger,
        );
    }
  }

  Future<void> _open(BuildContext context) async {
    final global =
        controller.identity?.connectivity ??
        const GlobalConnectivityPreferences();
    if (!global.anyEnabled) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(l10nOf(context).uiConnectivityIsOffEnableLAN39990E),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _ConnectivityDialog(
        title: l10nOf(context).uiRoutingValueFC4557((contact.alias).toString()),
        initial: contact.routing,
        global: global,
        kinds: controller.configurableTransports,
        onSave: (next) {
          unawaited(
            controller.updateContactRoutingPreferences(contact.deviceId, next),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final global =
        controller.identity?.connectivity ??
        const GlobalConnectivityPreferences();
    final mode = contact.routing.effectiveMode(global);
    final info = _labelFor(mode, context);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _open(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: palette.paper,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(info.icon, size: 16, color: info.color),
            const SizedBox(width: 8),
            Text(info.label),
          ],
        ),
      ),
    );
  }
}

class _ConnectivityDialog extends StatefulWidget {
  const _ConnectivityDialog({
    required this.title,
    required this.initial,
    required this.global,
    required this.kinds,
    required this.onSave,
  });

  final String title;
  final ContactRoutingPreferences initial;
  final GlobalConnectivityPreferences global;

  /// Transports with a policy to choose.
  final List<TransportKind> kinds;
  final void Function(ContactRoutingPreferences) onSave;

  @override
  State<_ConnectivityDialog> createState() => _ConnectivityDialogState();
}

class _ConnectivityDialogState extends State<_ConnectivityDialog> {
  late bool _lan = widget.initial.lanEnabled;
  late bool _online = widget.initial.onlineEnabled;
  late bool _irohRelay = widget.initial.irohRelayEnabled;
  late bool _carry = widget.initial.carryForContact;
  late RoutingPreference _preferred = widget.initial.preferred;
  late final Map<TransportKind, TransportPolicy> _policies =
      Map<TransportKind, TransportPolicy>.from(
        widget.initial.transportPolicies,
      );

  String _resolvedLabel() {
    final effective = ContactRoutingPreferences(
      lanEnabled: _lan,
      onlineEnabled: _online,
      preferred: _preferred,
      irohRelayEnabled: _irohRelay,
      transportPolicies: _policies,
    ).effectiveMode(widget.global);
    switch (effective) {
      case EffectiveRoutingMode.lanFirst:
        return l10nOf(context).uiUsesLANWhenAvailableFallsA810EF;
      case EffectiveRoutingMode.lanOnly:
        return l10nOf(context).uiUsesLANOnlyNoRelay589D55;
      case EffectiveRoutingMode.onlineFirst:
        return l10nOf(context).uiUsesOnlineWhenAvailableFallsCE2CAF;
      case EffectiveRoutingMode.onlineOnly:
        return l10nOf(context).uiUsesOnlineOnlyNoLAN193810;
      case EffectiveRoutingMode.offline:
        return widget.global.anyEnabled
            ? l10nOf(context).uiNoTransportSelectedThisContact7969EB
            : l10nOf(context).uiGlobalConnectivityIsOffAdjustA7C644;
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _lan || _online;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            value: _lan,
            onChanged: widget.global.lanEnabled
                ? (v) => setState(() => _lan = v ?? false)
                : null,
            title: Text(l10nOf(context).uiLAN2ECD17),
            subtitle: widget.global.lanEnabled
                ? Text(l10nOf(context).uiSameNetworkDelivery94E793)
                : Text(l10nOf(context).uiDisabledByGlobalSetting2CB06C),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile.adaptive(
            value: _irohRelay,
            onChanged: _online && widget.global.irohRelayEnabled
                ? (value) => setState(() => _irohRelay = value)
                : null,
            title: Text(l10nOf(context).uiAllowIrohRelayFallback35227B),
            subtitle: widget.global.irohRelayEnabled
                ? Text(l10nOf(context).uiVisibleAndOnlineOnlyDirectEA8902)
                : Text(l10nOf(context).uiDisabledByGlobalSetting2CB06C),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          for (final kind in widget.kinds)
            _TransportPolicySelector(
              kind: kind,
              value: _policies[kind] ?? TransportPolicy.disabled,
              enabled:
                  widget.global.policyFor(kind) != TransportPolicy.disabled,
              onChanged: (value) => setState(() => _policies[kind] = value),
            ),
          CheckboxListTile(
            value: _online,
            onChanged: widget.global.onlineEnabled
                ? (v) => setState(() => _online = v ?? false)
                : null,
            title: Text(l10nOf(context).uiOnlineC3E839),
            subtitle: widget.global.onlineEnabled
                ? Text(l10nOf(context).uiRelayInternetDeliveryD64AB6)
                : Text(l10nOf(context).uiDisabledByGlobalSetting2CB06C),
            contentPadding: EdgeInsets.zero,
          ),
          if (_lan && _online) ...[
            const SizedBox(height: 8),
            Text(l10nOf(context).uiPrefer13F662),
            const SizedBox(height: 4),
            SegmentedButton<RoutingPreference>(
              segments: [
                ButtonSegment(
                  value: RoutingPreference.lan,
                  label: Text(l10nOf(context).uiLAN2ECD17),
                ),
                ButtonSegment(
                  value: RoutingPreference.online,
                  label: Text(l10nOf(context).uiOnlineC3E839),
                ),
              ],
              selected: {_preferred},
              onSelectionChanged: (sel) =>
                  setState(() => _preferred = sel.first),
            ),
          ],
          SwitchListTile.adaptive(
            key: const ValueKey('carry-for-contact'),
            value: _carry,
            onChanged: (value) => setState(() => _carry = value),
            title: Text(l10nOf(context).uiCarryTheirMessages22FD33),
            subtitle: Text(l10nOf(context).uiWhenThisContactCannotReach5C3FF8),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 12),
          Text(_resolvedLabel(), style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionCancel),
        ),
        FilledButton(
          onPressed: canSave
              ? () {
                  widget.onSave(
                    ContactRoutingPreferences(
                      lanEnabled: _lan,
                      onlineEnabled: _online,
                      preferred: _preferred,
                      irohRelayEnabled: _irohRelay,
                      carryForContact: _carry,
                      transportPolicies: Map.unmodifiable(_policies),
                    ),
                  );
                  Navigator.of(context).pop();
                }
              : null,
          child: Text(l10nOf(context).uiSaveEFC007),
        ),
      ],
    );
  }
}

class _TransportPolicySelector extends StatelessWidget {
  const _TransportPolicySelector({
    required this.kind,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final TransportKind kind;
  final TransportPolicy value;
  final bool enabled;
  final ValueChanged<TransportPolicy> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(child: Text(transportKindLabel(context, kind))),
        DropdownButton<TransportPolicy>(
          value: value,
          onChanged: enabled
              ? (next) {
                  if (next != null) onChanged(next);
                }
              : null,
          items: [
            for (final policy in TransportPolicy.values)
              DropdownMenuItem(
                value: policy,
                child: Text(switch (policy) {
                  TransportPolicy.automatic => l10nOf(
                    context,
                  ).uiAutomaticAC9041,
                  TransportPolicy.preferred => l10nOf(
                    context,
                  ).uiPreferred0A3E0D,
                  TransportPolicy.disabled => l10nOf(context).uiDisabledF4F447,
                  TransportPolicy.askBeforeUse => l10nOf(
                    context,
                  ).uiAskFirst1AEB84,
                }),
              ),
          ],
        ),
      ],
    ),
  );
}

/// Returns true when `messages[chronoIndex]` is the second-or-later member
/// of an album (same sender + non-null albumId as the previous chronological
/// message). The chat list builder skips these — the chronological-first
/// album member renders one combined `_AlbumBubble`.
bool _isAlbumContinuation(List<ChatMessage> messages, int chronoIndex) {
  if (chronoIndex <= 0) return false;
  final cur = messages[chronoIndex];
  if (cur.albumId == null) return false;
  final prev = messages[chronoIndex - 1];
  return prev.albumId == cur.albumId &&
      prev.senderDeviceId == cur.senderDeviceId;
}

/// Returns true when `messages[chronoIndex]` is the chronologically-first
/// member of an album with at least two consecutive same-sender same-id
/// members.
bool _isAlbumAnchor(List<ChatMessage> messages, int chronoIndex) {
  final cur = messages[chronoIndex];
  if (cur.albumId == null) return false;
  if (_isAlbumContinuation(messages, chronoIndex)) return false;
  // Need at least one continuation for it to be a real album.
  if (chronoIndex + 1 >= messages.length) return false;
  final next = messages[chronoIndex + 1];
  return next.albumId == cur.albumId &&
      next.senderDeviceId == cur.senderDeviceId;
}

/// Collects the contiguous album members starting at the given anchor.
List<ChatMessage> _collectAlbumFrom(
  List<ChatMessage> messages,
  int chronoIndex,
) {
  final anchor = messages[chronoIndex];
  final group = <ChatMessage>[anchor];
  for (var j = chronoIndex + 1; j < messages.length; j++) {
    final next = messages[j];
    if (next.albumId == anchor.albumId &&
        next.senderDeviceId == anchor.senderDeviceId) {
      group.add(next);
    } else {
      break;
    }
  }
  return group;
}

/// Sniffs the first few bytes for a known image magic number. Returns the
/// MIME type string for matched formats, or null if no match. Used by the
/// clipboard-copy path to avoid wrapping JPEG bytes in Formats.png when the
/// AttachmentDescriptor's mimeType lies (e.g. application/octet-stream).
String? sniffImageMimeType(Uint8List bytes) {
  if (bytes.length < 4) return null;
  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  // GIF: 47 49 46 38 (GIF8)
  if (bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'image/gif';
  }
  // WebP: RIFF....WEBP — needs 12 bytes to confirm.
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}

/// Resolves `~/Downloads/conest/` (or `%USERPROFILE%\Downloads\conest` on
/// Windows) and ensures the directory exists. Returns null on web or when
/// HOME is undefined.
Future<Directory?> _resolveConestDownloadsDir() async {
  if (kIsWeb) return null;
  final env = Platform.environment;
  final base = Platform.isWindows
      ? env['USERPROFILE'] ?? env['HOMEPATH']
      : env['HOME'];
  if (base == null || base.isEmpty) return null;
  final dir = Directory(
    '$base${Platform.pathSeparator}Downloads'
    '${Platform.pathSeparator}conest',
  );
  try {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  } catch (_) {
    return null;
  }
  return dir;
}

String _saveKindForMime(String mimeType) {
  if (mimeType.startsWith('image/')) return 'image';
  if (mimeType.startsWith('video/')) return 'video';
  return 'other';
}

/// Bulk-save a batch of (descriptor, bytes) pairs.
///
/// Android: each file routes through `PlatformBridge.saveMediaToGallery` per
/// its mime kind so images land in `Pictures/conest`, videos in
/// `Movies/conest`, and everything else in `Download/conest`. One summary
/// toast at the end.
///
/// Desktop: prompts the user for a target directory (default
/// `~/Downloads/conest`) and writes each file into it with its original
/// filename. The caller's selection should already have filtered to entries
/// where `attachmentBytesFor != null`.
Future<File> _collisionSafeSaveTarget(
  Directory directory,
  String requestedName,
) async {
  final safeName = sanitizeAttachmentFileName(requestedName);
  final extension = p.extension(safeName);
  final stem = p.basenameWithoutExtension(safeName).isEmpty
      ? 'attachment'
      : p.basenameWithoutExtension(safeName);
  for (var suffix = 0; suffix < 10000; suffix++) {
    final candidateName = suffix == 0 ? safeName : '$stem ($suffix)$extension';
    final candidate = File(p.join(directory.path, candidateName));
    if (!isContainedPath(directory.path, candidate.path)) {
      throw const FileSystemException('Unsafe attachment save path.');
    }
    if (!await candidate.exists() && !await Link(candidate.path).exists()) {
      return candidate;
    }
  }
  throw const FileSystemException('Could not allocate a unique save name.');
}

Future<void> _streamCopyFile(File source, File target) async {
  final output = await target.open(mode: FileMode.write);
  try {
    await for (final chunk in source.openRead()) {
      await output.writeFrom(chunk);
    }
    await output.flush();
  } finally {
    await output.close();
  }
}

Future<void> bulkSaveAttachments(
  MessengerController controller,
  List<AttachmentDescriptor> items,
) async {
  if (items.isEmpty) return;
  if (!kIsWeb && Platform.isAndroid) {
    var saved = 0;
    final errors = <String>[];
    for (final descriptor in items) {
      final kind = _saveKindForMime(descriptor.mimeType);
      try {
        final bytes = controller.attachmentBytesFor(descriptor.id);
        final sourcePath = bytes == null
            ? await controller.attachmentCachePathFor(descriptor.id)
            : null;
        final uri = bytes != null
            ? await controller.platformBridge.saveMediaToGallery(
                bytes: bytes,
                fileName: sanitizeAttachmentFileName(descriptor.fileName),
                mimeType: descriptor.mimeType,
                kind: kind,
              )
            : sourcePath == null
            ? null
            : await controller.platformBridge.saveMediaFileToGallery(
                sourcePath: sourcePath,
                fileName: sanitizeAttachmentFileName(descriptor.fileName),
                mimeType: descriptor.mimeType,
                kind: kind,
              );
        if (uri != null) {
          saved++;
          await controller.markAttachmentExplicitlySaved(descriptor.id);
        } else {
          errors.add('${descriptor.fileName}: file is no longer available');
        }
      } catch (error) {
        errors.add('${descriptor.fileName}: $error');
      }
    }
    final summary = errors.isEmpty
        ? 'Saved $saved file(s) to gallery.'
        : 'Saved $saved/${items.length} file(s); '
              '${errors.length} failed.';
    controller.setStatus(summary);
    unawaited(controller.platformBridge.showToast(summary, long: true));
    if (errors.isNotEmpty) {
      controller.appendDebugLog('Bulk save errors:\n${errors.join('\n')}');
    }
    return;
  }
  // Desktop / web fallback: ask for a directory.
  final defaultDir = await _resolveConestDownloadsDir();
  final picked = await FilePicker.getDirectoryPath(
    dialogTitle: 'Save ${items.length} file(s) to…',
    initialDirectory: defaultDir?.path,
  );
  if (picked == null) {
    controller.setStatus('Save canceled.');
    return;
  }
  var saved = 0;
  final errors = <String>[];
  final destination = Directory(picked);
  for (final descriptor in items) {
    File? target;
    try {
      target = await _collisionSafeSaveTarget(destination, descriptor.fileName);
      final bytes = controller.attachmentBytesFor(descriptor.id);
      if (bytes != null) {
        await target.writeAsBytes(bytes, flush: true);
      } else {
        final sourcePath = await controller.attachmentCachePathFor(
          descriptor.id,
        );
        if (sourcePath == null) {
          throw const FileSystemException(
            'The attachment file is no longer available.',
          );
        }
        await _streamCopyFile(File(sourcePath), target);
      }
      saved++;
      await controller.markAttachmentExplicitlySaved(descriptor.id);
    } catch (error) {
      if (target != null) {
        try {
          if (await target.exists()) await target.delete();
        } catch (_) {}
      }
      errors.add('${descriptor.fileName}: $error');
    }
  }
  final summary = errors.isEmpty
      ? 'Saved $saved file(s) to $picked.'
      : 'Saved $saved/${items.length} file(s) to $picked; '
            '${errors.length} failed.';
  controller.setStatus(summary);
  if (errors.isNotEmpty) {
    controller.appendDebugLog('Bulk save errors:\n${errors.join('\n')}');
  }
}

/// Telegram-style album bubble: shows N attachment tiles in a 2- or 3-column
/// grid, sharing one outer container + the shared caption (carried on the
/// first member). Each tile reuses `_AttachmentRow` so the existing Pause /
/// Save / Copy actions stay one-tile-deep.
class _AlbumBubble extends StatelessWidget {
  const _AlbumBubble({
    super.key,
    required this.members,
    required this.controller,
    required this.palette,
    required this.outbound,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelection,
    this.onForwardAttachment,
    this.onDeleteAttachment,
    this.onForwardAlbum,
    this.selectedIds = const <String>{},
    this.onToggleMember,
  });

  final List<ChatMessage> members;
  final MessengerController controller;
  final ConestPalette palette;
  final bool outbound;
  final bool selectionMode;
  final bool selected;
  // nightly.10: when non-null, long-press + tap-in-selection-mode invoke
  // this to select the album as a unit (all members toggle together).
  final void Function(List<ChatMessage> members)? onToggleSelection;
  final Future<void> Function(AttachmentDescriptor descriptor)?
  onForwardAttachment;
  final Future<void> Function(ChatMessage message)? onDeleteAttachment;
  final Future<void> Function(List<ChatMessage> members)? onForwardAlbum;

  /// Selected messages: a file of the album can be selected on its own.
  final Set<String> selectedIds;
  final void Function(ChatMessage member)? onToggleMember;

  RelativeRect _menuAt(BuildContext context, Offset at) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return RelativeRect.fromRect(
      at & const Size(1, 1),
      Offset.zero & overlay.size,
    );
  }

  /// One file's menu (right-click): forward, save, select or delete it.
  Future<void> _showMemberMenu(
    BuildContext context,
    Offset at,
    ChatMessage member,
    _AttachmentRow row,
  ) async {
    final strings = l10nOf(context);
    final attachment = member.attachment!;
    final value = await showMenu<String>(
      context: context,
      position: _menuAt(context, at),
      items: [
        if (onForwardAttachment != null)
          PopupMenuItem(
            value: 'forward',
            child: Text(strings.menuForwardAttachment),
          ),
        if (controller.attachmentAvailableLocally(attachment.id))
          PopupMenuItem(value: 'save', child: Text(strings.menuSaveAttachment)),
        if (onToggleMember != null)
          PopupMenuItem(value: 'select', child: Text(strings.menuSelect)),
        if (onDeleteAttachment != null)
          PopupMenuItem(value: 'delete', child: Text(strings.menuDelete)),
      ],
    );
    switch (value) {
      case 'forward':
        await onForwardAttachment?.call(attachment);
      case 'save':
        await row._saveLocalFileToDisk();
      case 'select':
        onToggleMember?.call(member);
      case 'delete':
        await onDeleteAttachment?.call(member);
    }
  }

  /// The album's menu, from its button or a right-click on the album.
  List<PopupMenuEntry<String>> _albumMenuItems(
    BuildContext context,
    bool anyInFlight,
  ) {
    final strings = l10nOf(context);
    return [
      if (onToggleSelection != null)
        PopupMenuItem(value: 'select', child: Text(strings.menuSelectAlbum)),
      if (onForwardAlbum != null)
        PopupMenuItem(value: 'forward', child: Text(strings.menuForwardAlbum)),
      if (anyInFlight)
        PopupMenuItem(
          value: 'cancel',
          child: Text(strings.uiCancelAlbumDB0A07),
        ),
      PopupMenuItem(value: 'delete', child: Text(strings.uiDeleteAlbum52E30F)),
    ];
  }

  Future<void> _onAlbumMenu(String? value) async {
    final albumId = members.isNotEmpty ? members.first.albumId : null;
    switch (value) {
      case 'select':
        onToggleSelection?.call(members);
      case 'forward':
        await onForwardAlbum?.call(members);
      case 'cancel':
        if (albumId != null) await controller.cancelAlbum(albumId);
      case 'delete':
        if (albumId != null) await controller.deleteAlbum(albumId);
    }
  }

  /// One file of the album: selectable on its own (long-press, or a tap
  /// while selecting) with its own right-click menu.
  Widget _albumItem(BuildContext context, ChatMessage m) {
    final row = _AttachmentRow(
      descriptor: m.attachment!,
      outbound: outbound,
      controller: controller,
      palette: palette,
      messageState: m.state,
      onForward: onForwardAttachment == null
          ? null
          : () => onForwardAttachment!(m.attachment!),
      onDelete: onDeleteAttachment == null
          ? null
          : () => onDeleteAttachment!(m),
    );
    final toggle = onToggleMember;
    final Widget item = selectionMode && toggle != null
        ? GestureDetector(
            key: ValueKey('album-item-${m.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => toggle(m),
            // While selecting, a tap selects instead of opening the file.
            child: AbsorbPointer(child: row),
          )
        : GestureDetector(
            key: ValueKey('album-item-${m.id}'),
            onLongPress: toggle == null ? null : () => toggle(m),
            onSecondaryTapUp: (details) =>
                _showMemberMenu(context, details.globalPosition, m, row),
            child: row,
          );
    if (!selectedIds.contains(m.id)) return item;
    return Stack(
      children: [
        Positioned.fill(child: item),
        PositionedDirectional(
          top: 4,
          end: 4,
          child: Icon(Icons.check_circle, color: palette.primary, size: 22),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = members.isNotEmpty ? members.first.body : '';
    final cols = members.length <= 2 ? 2 : (members.length <= 4 ? 2 : 3);
    final albumId = members.isNotEmpty ? members.first.albumId : null;
    final bool anyInFlight = members.any(
      (m) =>
          m.outbound &&
          (m.state == DeliveryState.pending ||
              m.state == DeliveryState.local ||
              m.state == DeliveryState.relayed),
    );
    final bool anyFailed = members.any(
      (m) => m.outbound && m.state == DeliveryState.failed,
    );
    final bubbleColor = selected
        ? palette.primary.withValues(alpha: 0.18)
        : (outbound ? palette.outboundBubble : palette.inboundBubble);
    final useSelfGradient = outbound && !selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: selectionMode && onToggleSelection != null
          ? () => onToggleSelection!(members)
          : null,
      onLongPress: onToggleSelection != null
          ? () => onToggleSelection!(members)
          : null,
      onSecondaryTapUp: albumId == null || albumId.isEmpty
          ? null
          : (details) async => _onAlbumMenu(
              await showMenu<String>(
                context: context,
                position: _menuAt(context, details.globalPosition),
                items: _albumMenuItems(context, anyInFlight),
              ),
            ),
      child: Align(
        alignment: outbound
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: useSelfGradient ? null : bubbleColor,
            gradient: useSelfGradient ? palette.outboundBubbleGradient : null,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: cols,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    childAspectRatio: 1.0,
                    children: [
                      for (final m in members)
                        if (m.attachment != null) _albumItem(context, m),
                    ],
                  ),
                  if (caption.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      caption,
                      style: TextStyle(
                        color: outbound
                            ? palette.outboundText
                            : palette.inboundText,
                      ),
                    ),
                  ],
                  if (anyFailed) ...[
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: () {
                        for (final m in members) {
                          if (m.outbound &&
                              m.state == DeliveryState.failed &&
                              m.attachment != null) {
                            controller.retryAttachment(m.attachment!.id);
                          }
                        }
                      },
                      child: Text(
                        l10nOf(context).uiRetryFailed7B6CA4,
                        style: TextStyle(
                          color: outbound
                              ? palette.outboundText
                              : palette.inboundText,
                          decoration: TextDecoration.underline,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (albumId != null && albumId.isNotEmpty)
                Positioned(
                  right: -8,
                  top: -8,
                  child: PopupMenuButton<String>(
                    tooltip: l10nOf(context).uiAlbumActions7B6D70,
                    icon: Icon(
                      Icons.more_horiz,
                      size: 18,
                      color: outbound
                          ? palette.outboundMeta
                          : palette.inboundMeta,
                    ),
                    onSelected: _onAlbumMenu,
                    itemBuilder: (_) => _albumMenuItems(context, anyInFlight),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewMessagesDivider extends StatelessWidget {
  const _NewMessagesDivider({required this.palette, required this.count});

  final ConestPalette palette;
  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 0
        ? '$count new message${count == 1 ? "" : "s"}'
        : 'New messages';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Divider(color: palette.unread.withValues(alpha: 0.55)),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: palette.unread,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Divider(color: palette.unread.withValues(alpha: 0.55)),
          ),
        ],
      ),
    );
  }
}

class _MessageSelectionBar extends StatelessWidget {
  const _MessageSelectionBar({
    required this.palette,
    required this.count,
    required this.onCancel,
    required this.onCopy,
    required this.onForward,
    required this.onSave,
    required this.onDelete,
  });

  final ConestPalette palette;
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onCopy;
  final VoidCallback onForward;
  final VoidCallback? onSave;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: palette.primary.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: palette.stroke)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close),
            tooltip: l10nOf(context).uiCancelSelectionF7F56C,
          ),
          const SizedBox(width: 4),
          Text(
            l10nOf(context).uiValueSelectedB1DFAF((count)),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          IconButton(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_outlined),
            tooltip: l10nOf(context).uiCopyAF74F7,
          ),
          IconButton(
            key: const ValueKey('selection-forward'),
            onPressed: onForward,
            icon: const Icon(Icons.forward_outlined),
            tooltip: l10nOf(context).menuForward,
          ),
          IconButton(
            onPressed: onSave,
            icon: const Icon(Icons.download_outlined),
            tooltip: l10nOf(context).uiSaveAttachments5A74EA,
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            tooltip: l10nOf(context).menuDelete,
            color: onDelete != null
                ? Theme.of(context).colorScheme.error
                : null,
          ),
        ],
      ),
    );
  }
}

class _TransfersScreen extends StatelessWidget {
  const _TransfersScreen({required this.controller, required this.palette});

  final MessengerController controller;
  final ConestPalette palette;

  String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _eta(Duration value) {
    if (value.inHours > 0) {
      return '${value.inHours}h ${value.inMinutes.remainder(60)}m';
    }
    if (value.inMinutes > 0) {
      return '${value.inMinutes}m ${value.inSeconds.remainder(60)}s';
    }
    return '${value.inSeconds}s';
  }

  Future<void> _cancelAndClearAll(
    BuildContext context, {
    required int activeCount,
  }) async {
    if (activeCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10nOf(context).uiCancelAndClearAllTransfers01B81D),
          content: Text(
            l10nOf(context).uiThisWillCancelValueActiveB3425E((activeCount)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10nOf(context).uiKeepTransfersDB8CC7),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10nOf(context).uiCancelAndClearCCF59C),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await controller.cancelAndClearAllTransfers();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        controller.transferProgressListenable,
      ]),
      builder: (context, _) {
        final snapshots = controller.transferSnapshots;
        final active = snapshots
            .where(
              (entry) =>
                  entry.phase.isActive ||
                  entry.phase == TransferPhase.paused ||
                  entry.phase == TransferPhase.awaitingApproval,
            )
            .toList(growable: false);
        final recent = snapshots
            .where((entry) => !active.contains(entry))
            .toList(growable: false);
        return Scaffold(
          appBar: AppBar(
            title: Text(l10nOf(context).uiTransfers812412),
            actions: [
              IconButton(
                tooltip: l10nOf(context).uiPauseAll6F6099,
                onPressed:
                    active.any(
                      (entry) => entry.phase.isActive && !entry.pausedByPeer,
                    )
                    ? () => unawaited(controller.pauseAllTransfers())
                    : null,
                icon: const Icon(Icons.pause_circle_outline),
              ),
              IconButton(
                tooltip: l10nOf(context).uiResumeAll039916,
                onPressed: active.any((entry) => entry.pausedByMe)
                    ? () => unawaited(controller.resumeAllTransfers())
                    : null,
                icon: const Icon(Icons.play_circle_outline),
              ),
              IconButton(
                tooltip: l10nOf(context).uiCancelAndClearAllTransfersACEBB3,
                onPressed: snapshots.isEmpty
                    ? null
                    : () => unawaited(
                        _cancelAndClearAll(
                          context,
                          activeCount: active.length,
                        ),
                      ),
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
              IconButton(
                tooltip: l10nOf(context).uiClearCompletedE63FC1,
                onPressed: recent.isEmpty
                    ? null
                    : controller.clearCompletedTransfers,
                icon: const Icon(Icons.cleaning_services_outlined),
              ),
            ],
          ),
          body: snapshots.isEmpty
              ? Center(child: Text(l10nOf(context).uiNoTransfersYetB8E5C1))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                  children: [
                    if (active.isNotEmpty) ...[
                      _TransferSectionLabel(
                        label: l10nOf(
                          context,
                        ).uiActiveValueC78B63((active.length).toString()),
                      ),
                      for (final snapshot in active)
                        _TransferManagerTile(
                          snapshot: snapshot,
                          controller: controller,
                          palette: palette,
                          bytesLabel: _bytes,
                          phaseLabel: (phase) =>
                              transferPhaseLabel(context, phase),
                          etaLabel: _eta,
                        ),
                    ],
                    if (recent.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _TransferSectionLabel(
                        label: l10nOf(
                          context,
                        ).uiRecentValueB82237((recent.length).toString()),
                      ),
                      for (final snapshot in recent)
                        _TransferManagerTile(
                          snapshot: snapshot,
                          controller: controller,
                          palette: palette,
                          bytesLabel: _bytes,
                          phaseLabel: (phase) =>
                              transferPhaseLabel(context, phase),
                          etaLabel: _eta,
                        ),
                    ],
                  ],
                ),
        );
      },
    );
  }
}

class _TransferSectionLabel extends StatelessWidget {
  const _TransferSectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
    child: Text(label, style: Theme.of(context).textTheme.titleSmall),
  );
}

class _TransferManagerTile extends StatelessWidget {
  const _TransferManagerTile({
    required this.snapshot,
    required this.controller,
    required this.palette,
    required this.bytesLabel,
    required this.phaseLabel,
    required this.etaLabel,
  });

  final TransferSnapshot snapshot;
  final MessengerController controller;
  final ConestPalette palette;
  final String Function(int) bytesLabel;
  final String Function(TransferPhase) phaseLabel;
  final String Function(Duration) etaLabel;

  @override
  Widget build(BuildContext context) {
    final descriptor = controller.attachmentDescriptorFor(snapshot.id);
    if (descriptor == null) return const SizedBox.shrink();
    final route = snapshot.routeLabel?.trim();
    final speed = snapshot.bytesPerSecond;
    final details = <String>[
      '${bytesLabel(snapshot.bytesTransferred)} / ${bytesLabel(snapshot.totalBytes)}',
      if (speed != null && speed > 0) '${bytesLabel(speed.round())}/s',
      if (snapshot.eta != null)
        l10nOf(context).transferTimeLeft(etaLabel(snapshot.eta!)),
      if (route != null && route.isNotEmpty) route,
      if (snapshot.queuePriority > 0)
        l10nOf(
          context,
        ).transferQueuePosition(snapshot.queuePriority.toString()),
    ];
    final canCancel =
        snapshot.phase.isActive ||
        snapshot.phase == TransferPhase.paused ||
        snapshot.phase == TransferPhase.awaitingApproval;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          final peer = controller.peerDeviceIdForAttachment(snapshot.id);
          if (peer != null) Navigator.of(context).pop(peer);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    snapshot.direction == TransferDirection.outbound
                        ? Icons.upload_file_outlined
                        : Icons.download_for_offline_outlined,
                    color: palette.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          descriptor.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          "${(controller.transferConversationLabel(snapshot.id))} · ${(phaseLabel(snapshot.phase))}",
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (snapshot.queuePriority > 1)
                    IconButton(
                      tooltip: l10nOf(context).uiMoveToTop44AFA6,
                      onPressed: () =>
                          controller.prioritizeTransfer(snapshot.id),
                      icon: const Icon(Icons.vertical_align_top),
                    ),
                  if (snapshot.phase == TransferPhase.awaitingApproval &&
                      snapshot.direction == TransferDirection.inbound)
                    IconButton(
                      tooltip:
                          controller.attachmentAcceptanceInProgress(snapshot.id)
                          ? l10nOf(context).uiPreparingDownloadF9B13B
                          : l10nOf(context).uiDownloadA479C9,
                      onPressed:
                          controller.attachmentAcceptanceInProgress(snapshot.id)
                          ? null
                          : () => unawaited(
                              controller.acceptIncomingAttachment(snapshot.id),
                            ),
                      icon:
                          controller.attachmentAcceptanceInProgress(snapshot.id)
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                    )
                  else if (snapshot.pausedByMe)
                    IconButton(
                      tooltip: l10nOf(context).uiResumeB3BD0B,
                      onPressed: () =>
                          unawaited(controller.resumeAttachment(snapshot.id)),
                      icon: const Icon(Icons.play_circle_outline),
                    )
                  else if (snapshot.phase.isActive)
                    IconButton(
                      tooltip: l10nOf(context).uiPause781961,
                      onPressed: snapshot.pausedByPeer
                          ? null
                          : () => unawaited(
                              controller.pauseAttachment(snapshot.id),
                            ),
                      icon: const Icon(Icons.pause_circle_outline),
                    ),
                  if (snapshot.phase == TransferPhase.failed ||
                      snapshot.phase == TransferPhase.unavailable)
                    IconButton(
                      tooltip: l10nOf(context).uiRetry9F5CD8,
                      onPressed: () => controller.retryAttachment(snapshot.id),
                      icon: const Icon(Icons.refresh),
                    ),
                  if (canCancel)
                    IconButton(
                      tooltip: l10nOf(context).actionCancel,
                      onPressed: () =>
                          unawaited(controller.cancelTransfer(snapshot.id)),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value:
                    snapshot.phase == TransferPhase.reconnecting ||
                        snapshot.phase == TransferPhase.waitingForPeer
                    ? null
                    : snapshot.progress,
                minHeight: 5,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 6),
              Text(
                details.join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if ((snapshot.error ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  snapshot.error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
              if (controller.canDownloadIgnoringStorageReserve(snapshot.id))
                _StorageReserveOverrideButton(
                  controller: controller,
                  attachmentId: snapshot.id,
                ),
              if (controller.canContinueLargeTransferOverIrohRelay(
                snapshot.id,
              )) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    onPressed: () => unawaited(
                      controller.continueLargeTransferOverIrohRelay(
                        snapshot.id,
                      ),
                    ),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: Text(l10nOf(context).uiContinueOverIrohRelay949702),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StorageReserveOverrideButton extends StatelessWidget {
  const _StorageReserveOverrideButton({
    required this.controller,
    required this.attachmentId,
  });

  final MessengerController controller;
  final String attachmentId;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: controller.attachmentAcceptanceInProgress(attachmentId)
        ? null
        : () => unawaited(
            controller.acceptIncomingAttachment(
              attachmentId,
              ignoreStorageReserve: true,
            ),
          ),
    child: Text(l10nOf(context).uiDownloadAnyway42859F),
  );
}

/// Delta uses the same file viewer, save/forward menu and voice player.
Widget buildDeltaAttachment(
  BuildContext context,
  MessengerController controller,
  AttachmentDescriptor descriptor,
  bool outgoing,
) {
  final palette = ConestPalette(brightness: Theme.of(context).brightness);
  final row = _AttachmentRow(
    descriptor: descriptor,
    outbound: outgoing,
    palette: palette,
    controller: controller,
    messageState: DeliveryState.delivered,
    localContent: true,
    onForward: () =>
        _forwardAttachment(context, controller, palette, descriptor),
  );
  return DeltaAttachmentCard(
    controller: controller,
    descriptor: descriptor,
    save: row._saveLocalFileToDisk,
    forward: () => _forwardAttachment(context, controller, palette, descriptor),
    open: () async {
      if (descriptor.voiceMetadata != null) {
        final path = await controller.attachmentCachePathFor(descriptor.id);
        if (path != null) {
          await controller.voiceMessageService.togglePlayback(
            path,
            itemId: descriptor.id,
          );
        }
      } else if (row._isImage) {
        await row._openPathImage(context);
      } else if (row._isVideo) {
        await row._openVideoPlayer(context);
      } else {
        await openDeltaCachedFile(controller, descriptor);
      }
    },
    child: row,
  );
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.descriptor,
    required this.outbound,
    required this.palette,
    required this.controller,
    required this.messageState,
    this.conversationPeerDeviceId,
    this.onForward,
    this.onDelete,
    this.localContent = false,
  });

  final AttachmentDescriptor descriptor;
  final bool outbound;
  final ConestPalette palette;
  final MessengerController controller;
  final DeliveryState messageState;
  final bool localContent;

  /// Set on 1:1 chat bubbles so the full-screen viewer can list every
  /// other image in the same conversation for swipe navigation. Null
  /// for group bubbles (group-wide swipe is a future enhancement).
  final String? conversationPeerDeviceId;
  final Future<void> Function()? onForward;
  final Future<void> Function()? onDelete;

  String _formatBytes(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatEta(Duration value) {
    if (value.inHours > 0) {
      return '${value.inHours}h ${value.inMinutes.remainder(60)}m';
    }
    if (value.inMinutes > 0) {
      return '${value.inMinutes}m ${value.inSeconds.remainder(60)}s';
    }
    return '${value.inSeconds}s';
  }

  bool get _isImage => descriptor.mimeType.startsWith('image/');
  bool get _isVideo =>
      descriptor.voiceMetadata == null &&
      (descriptor.mimeType.startsWith('video/') ||
          const {
            '.3gp',
            '.avi',
            '.m4v',
            '.mkv',
            '.mov',
            '.mp4',
            '.mpeg',
            '.mpg',
            '.webm',
            '.wmv',
          }.contains(p.extension(descriptor.fileName).toLowerCase()));

  /// Wraps an image/video thumbnail so it never overflows its parent. In a
  /// tight (bounded-height) context — e.g. the album grid's square cells —
  /// the tile fills the cell exactly; as a standalone bubble (unbounded
  /// height) it caps at 320 inside a min-sized Column like before.
  Widget _thumbnailContainer(Widget tile) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight.isFinite) {
          return tile;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
              child: tile,
            ),
          ],
        );
      },
    );
  }

  String _saveKindFor(String mimeType) {
    if (mimeType.startsWith('image/')) return 'image';
    if (mimeType.startsWith('video/')) return 'video';
    return 'other';
  }

  /// Resolves `~/Downloads/conest/` (or `%USERPROFILE%\Downloads\conest` on
  /// Windows) and ensures the directory exists. Returns null on web or when
  /// HOME is undefined.
  Future<Directory?> _conestDownloadsDir() async {
    if (kIsWeb) return null;
    final env = Platform.environment;
    final base = Platform.isWindows
        ? env['USERPROFILE'] ?? env['HOMEPATH']
        : env['HOME'];
    if (base == null || base.isEmpty) return null;
    final dir = Directory(
      '$base${Platform.pathSeparator}Downloads'
      '${Platform.pathSeparator}conest',
    );
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } catch (_) {
      return null;
    }
    return dir;
  }

  /// Save variant that takes explicit file metadata — used by the
  /// full-screen viewer's PageView so each swiped page can save with its
  /// OWN filename / mime even though we don't have a per-page
  /// `_AttachmentRow` for each sibling.
  Future<void> _saveToDiskFor(
    BuildContext context,
    Uint8List bytes,
    String fileName,
    String mimeType,
    String descriptorId,
  ) async {
    final strings = l10nOf(context);
    final safeFileName = sanitizeAttachmentFileName(fileName);
    final kind = _saveKindFor(mimeType);
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final saved = await controller.platformBridge.saveMediaToGallery(
          bytes: bytes,
          fileName: safeFileName,
          mimeType: mimeType,
          kind: kind,
        );
        if (saved != null) {
          final relPath = switch (kind) {
            'image' => 'Pictures/conest',
            'video' => 'Movies/conest',
            _ => 'Download/conest',
          };
          controller.setStatus('Saved $safeFileName to $relPath.');
          unawaited(
            controller.platformBridge.showToast(
              'Saved $safeFileName → $relPath',
              long: true,
            ),
          );
          await controller.markAttachmentExplicitlySaved(descriptorId);
          return;
        }
      } catch (error) {
        controller.setStatus(
          'Gallery save failed ($error); falling back to file dialog.',
        );
      }
    }
    try {
      final defaultDir = await _conestDownloadsDir();
      final path = await FilePicker.saveFile(
        dialogTitle: strings.uiSaveValue5769AA((safeFileName).toString()),
        fileName: safeFileName,
        bytes: bytes,
        initialDirectory: defaultDir?.path,
      );
      if (path == null) return;
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        await File(path).writeAsBytes(bytes);
      }
      controller.setStatus('Saved $safeFileName to $path.');
      await controller.markAttachmentExplicitlySaved(descriptorId);
      unawaited(
        controller.platformBridge.showToast('Saved $safeFileName', long: true),
      );
    } catch (error) {
      controller.setStatus('Save failed: $error');
    }
  }

  Future<void> _saveToDisk(BuildContext context, Uint8List bytes) =>
      _saveToDiskFor(
        context,
        bytes,
        descriptor.fileName,
        descriptor.mimeType,
        descriptor.id,
      );

  Future<void> _saveLocalFileToDisk() async {
    final sourcePath = await controller.attachmentCachePathFor(descriptor.id);
    if (sourcePath == null) {
      controller.setStatus('The attachment file is not available locally.');
      return;
    }
    final safeFileName = sanitizeAttachmentFileName(descriptor.fileName);
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final saved = await controller.platformBridge.saveMediaFileToGallery(
          sourcePath: sourcePath,
          fileName: safeFileName,
          mimeType: descriptor.mimeType,
          kind: _saveKindFor(descriptor.mimeType),
        );
        if (saved != null) {
          controller.setStatus('Saved $safeFileName.');
          await controller.markAttachmentExplicitlySaved(descriptor.id);
          return;
        }
      }
      final targetPath = await FilePicker.saveFile(
        dialogTitle: 'Save $safeFileName',
        fileName: safeFileName,
        initialDirectory: (await _conestDownloadsDir())?.path,
      );
      if (targetPath == null) return;
      final source = File(sourcePath);
      final target = File(targetPath);
      if (source.absolute.path != target.absolute.path) {
        await _streamCopyFile(source, target);
      }
      controller.setStatus('Saved $safeFileName to $targetPath.');
      await controller.markAttachmentExplicitlySaved(descriptor.id);
    } catch (error) {
      controller.setStatus('Save failed: $error');
    }
  }

  Future<void> _copyImageBytesFor(Uint8List bytes, String filename) async {
    // Always put the filename on the OS text clipboard first as the
    // guaranteed-working fallback. Paste targets that can't accept image
    // data (text inputs, terminals) get something useful; if the binary
    // clipboard succeeds afterwards, the image data overlays the text
    // for image-accepting targets.
    try {
      await Clipboard.setData(ClipboardData(text: filename));
    } catch (error) {
      controller.appendDebugLog('Text clipboard fallback failed: $error');
    }

    // Android: super_clipboard's binary surface doesn't surface to apps
    // like Telegram or Signal that read images via ContentResolver. Stage
    // the bytes via FileProvider + ClipData.newUri so paste targets can
    // openInputStream the content URI. We try this first; on success we
    // skip the super_clipboard fallback.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final mime = sniffImageMimeType(bytes) ?? descriptor.mimeType;
        final uri = await controller.platformBridge.copyImageToClipboard(
          bytes: bytes,
          fileName: filename,
          mimeType: mime,
        );
        if (uri != null) {
          controller.appendDebugLog(
            'Android ClipData.newUri OK: $filename -> $uri ($mime, '
            '${bytes.length} bytes).',
          );
          controller.setStatus('Copied $filename to clipboard.');
          unawaited(controller.platformBridge.showToast('Copied $filename'));
          return;
        }
      } catch (error) {
        controller.appendDebugLog(
          'Android ClipData.newUri threw: $error — falling back to '
          'super_clipboard.',
        );
      }
    }

    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      controller.appendDebugLog(
        'super_clipboard unavailable; wrote filename "$filename" '
        'to the text clipboard.',
      );
      controller.setStatus(
        'Copied "$filename" (text only — system clipboard binary surface '
        'unavailable).',
      );
      return;
    }

    Uri? cachedFileUri;
    try {
      cachedFileUri = await _writeClipboardCacheFile(bytes);
    } catch (error) {
      controller.appendDebugLog('Could not write clipboard cache file: $error');
    }

    try {
      final item = DataWriterItem(suggestedName: filename);
      // Sniff the byte header first — the descriptor's mimeType can lie
      // (e.g. a JPEG that arrived as application/octet-stream). Wrapping
      // a JPEG in Formats.png(bytes) silently corrupts paste targets.
      final sniffed =
          sniffImageMimeType(bytes) ?? descriptor.mimeType.toLowerCase();
      switch (sniffed) {
        case 'image/png':
          item.add(Formats.png(bytes));
        case 'image/jpeg':
        case 'image/jpg':
          item.add(Formats.jpeg(bytes));
        case 'image/gif':
          item.add(Formats.gif(bytes));
        case 'image/webp':
          item.add(Formats.webp(bytes));
        default:
          // Fall back to PNG: most paste targets understand it.
          item.add(Formats.png(bytes));
      }
      // Telegram-style: always include the filename so text-only paste
      // targets are useful too.
      item.add(Formats.plainText(filename));
      // File URI lets file managers (Nautilus, Finder, Explorer) paste
      // the image as a file.
      if (cachedFileUri != null) {
        item.add(Formats.fileUri(cachedFileUri));
      }
      await clipboard.write([item]);
      controller.appendDebugLog(
        'Clipboard write OK: $filename ($sniffed, '
        '${bytes.length} bytes, fileUri=${cachedFileUri?.toString() ?? "n/a"}).',
      );
      controller.setStatus('Copied $filename to clipboard.');
    } catch (error, stack) {
      debugPrint('Conest clipboard copy failed: $error\n$stack');
      controller.appendDebugLog('super_clipboard.write threw: $error\n$stack');
      controller.setStatus(
        'Copy failed: $error. Filename copied as text fallback.',
      );
    }
  }

  /// Writes the bytes to a stable on-disk cache so the file-URI format
  /// remains valid until the OS releases the clipboard reference.
  Future<Uri?> _writeClipboardCacheFile(Uint8List bytes) async {
    try {
      final supportDir = await controller.attachmentRoot();
      final sep = Platform.pathSeparator;
      final cacheDir = Directory('${supportDir.path}${sep}clipboard-cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final rawExtension = _extensionFor(descriptor.fileName) ?? 'bin';
      final ext = RegExp(r'^[a-z0-9]{1,16}$').hasMatch(rawExtension)
          ? rawExtension
          : 'bin';
      final target = File(
        '${cacheDir.path}$sep${attachmentStorageKey(descriptor.id)}.$ext',
      );
      await target.writeAsBytes(bytes, flush: true);
      await restrictFileToOwner(target);
      return target.uri;
    } catch (_) {
      return null;
    }
  }

  String? _extensionFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0 || dot == fileName.length - 1) return null;
    return fileName.substring(dot + 1).toLowerCase();
  }

  Future<void> _copyCachePath() async {
    final path = await controller.attachmentCachePathFor(descriptor.id);
    if (path == null) {
      controller.setStatus('Cache path is not ready yet — still transferring.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: path));
    controller.setStatus('Cache path copied: $path');
  }

  /// nightly.11: long-press / right-click context menu. Replaces the
  /// inline Copy / Save / Copy path / Delete buttons on every bubble
  /// (cluttered the UI; user requested a single menu affordance).
  Widget _wrapContextMenu({
    required BuildContext context,
    required Widget child,
  }) {
    // Message bubbles own the shared action menu and long-press selection.
    // A nested attachment recognizer would steal long presses from selection.
    return child;
  }

  Future<void> _openVideoPlayer(BuildContext context) async {
    final navigator = Navigator.of(context);
    final path = await controller.attachmentCachePathFor(descriptor.id);
    if (path == null) {
      controller.setStatus(
        'Video isn\'t cached locally yet — wait for the transfer to finish.',
      );
      return;
    }
    if (Platform.isLinux) {
      // Keep Linux playback outside Flutter's native video plugins. The
      // transient player route had no playback controls on Linux: it only
      // launched xdg-open and closed itself after handing the file off.
      try {
        await Process.start('xdg-open', [
          path,
        ], mode: ProcessStartMode.detached);
      } catch (error) {
        controller.setStatus(
          'Could not open video in the system player: $error',
        );
      }
      return;
    }
    final bytes = controller.attachmentBytesFor(descriptor.id);
    navigator.push(
      MaterialPageRoute<void>(
        builder: (context) => _VideoPlayerScreen(
          cachePath: path,
          title: descriptor.fileName,
          palette: palette,
          onSave: () => bytes == null
              ? _saveLocalFileToDisk()
              : _saveToDisk(context, bytes),
        ),
      ),
    );
  }

  void _openFullScreenImage(BuildContext context, Uint8List bytes) {
    // Gather every other image in this 1:1 conversation so the viewer's
    // PageView can swipe forward/backward across album boundaries. Falls
    // back to the single-page case for group bubbles (peer id not set).
    final peer = conversationPeerDeviceId;
    final siblings = <_ViewerPage>[];
    var initialIndex = 0;
    if (peer != null) {
      final messages = controller.imageAttachmentsFor(peer);
      for (final m in messages) {
        final att = m.attachment!;
        final pageBytes = controller.attachmentBytesFor(att.id);
        if (pageBytes == null) continue;
        if (att.id == descriptor.id) initialIndex = siblings.length;
        siblings.add(
          _ViewerPage(
            bytes: pageBytes,
            fileName: att.fileName,
            descriptorId: att.id,
            mimeType: att.mimeType,
          ),
        );
      }
    }
    if (siblings.isEmpty) {
      siblings.add(
        _ViewerPage(
          bytes: bytes,
          fileName: descriptor.fileName,
          descriptorId: descriptor.id,
          mimeType: descriptor.mimeType,
        ),
      );
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _ImageViewerScreen(
          pages: siblings,
          initialIndex: initialIndex,
          palette: palette,
          onCopy: (page) => _copyImageBytesFor(page.bytes, page.fileName),
          onSave: (page) => _saveToDiskFor(
            context,
            page.bytes,
            page.fileName,
            page.mimeType,
            page.descriptorId,
          ),
        ),
      ),
    );
  }

  Future<void> _openPathImage(BuildContext context) async {
    final navigator = Navigator.of(context);
    final path = await controller.attachmentCachePathFor(descriptor.id);
    if (path == null) {
      controller.setStatus('Image is not available locally.');
      return;
    }
    navigator.push(
      MaterialPageRoute<void>(
        builder: (context) => _PathImageViewerScreen(
          path: path,
          title: descriptor.fileName,
          onSave: _saveLocalFileToDisk,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      controller,
      controller.transferProgressListenable,
    ]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    // Defensive guard: a malformed descriptor used to surface as a blank
    // attachment bubble. Reject early so the user sees an explicit error
    // rather than an empty card.
    if (descriptor.fileName.isEmpty ||
        descriptor.fileHashBase64.isEmpty ||
        (localContent
            ? !controller.deltaAttachmentAvailableLocally(descriptor)
            : descriptor.effectiveChunkCount <= 0 ||
                  descriptor.encryptionKeyBase64.isEmpty)) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: palette.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.danger),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 18, color: palette.danger),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Attachment metadata unavailable',
                style: TextStyle(color: palette.danger),
              ),
            ),
          ],
        ),
      );
    }
    final bytes = controller.attachmentBytesFor(descriptor.id);
    final inboundProgress = controller.attachmentTransferProgress(
      descriptor.id,
    );
    final outboundProgress = outbound
        ? controller.outboundAttachmentProgress(descriptor.id)
        : null;
    final snapshot = controller.transferSnapshotFor(descriptor.id);
    final queuePosition = outbound
        ? controller.outboundQueuePositionFor(descriptor.id)
        : 0;
    final progress =
        snapshot != null &&
            snapshot.phase != TransferPhase.completed &&
            snapshot.phase != TransferPhase.canceled
        ? snapshot.progress
        : outboundProgress ?? inboundProgress;
    final pauseState = controller.pauseStateFor(descriptor.id);
    final textColor = outbound ? palette.outboundText : palette.inboundText;
    final metaColor = outbound ? palette.outboundMeta : palette.inboundMeta;
    final hasBytes = bytes != null;
    final hasLocalFile = controller.attachmentAvailableLocally(descriptor.id);
    final showImage = _isImage && (hasBytes || hasLocalFile);
    // A delivered or read message is done, whatever a lingering transfer
    // record still says (a lost completion once left albums at 100%).
    // A later message read marks earlier ones read too, uploads still
    // running included; those keep their controls until every byte is in.
    final settled =
        (!outbound && hasLocalFile) ||
        ((messageState == DeliveryState.delivered ||
                messageState == DeliveryState.read) &&
            (snapshot == null || snapshot.progress >= 1));
    final transferInFlight =
        !settled &&
        (snapshot?.phase.isActive == true ||
            snapshot?.phase == TransferPhase.paused);

    if (!outbound && controller.attachmentAwaitingAcceptance(descriptor.id)) {
      final sizeMb = descriptor.sizeBytes / (1024 * 1024);
      final accepting = controller.attachmentAcceptanceInProgress(
        descriptor.id,
      );
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.paperStrong,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              descriptor.fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              accepting
                  ? l10nOf(context).uiValueMBPreparingDownload799D4A(
                      (sizeMb.toStringAsFixed(1)).toString(),
                    )
                  : descriptor.sizeBytes >
                        MessengerController.maxAttachmentSizeBytes
                  ? l10nOf(context).uiValueMBDirectRouteRequired6379F0(
                      (sizeMb.toStringAsFixed(1)).toString(),
                    )
                  : l10nOf(context).uiValueMBTapToDownload432280(
                      (sizeMb.toStringAsFixed(1)).toString(),
                    ),
              style: TextStyle(color: metaColor),
            ),
            if (snapshot?.error case final error?) ...[
              const SizedBox(height: 6),
              Text(error, style: TextStyle(color: palette.danger)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: accepting
                      ? null
                      : () => unawaited(
                          controller.acceptIncomingAttachment(descriptor.id),
                        ),
                  child: accepting
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text(l10nOf(context).uiPreparingDownload8CB769),
                          ],
                        )
                      : Text(l10nOf(context).uiDownloadA479C9),
                ),
                if (controller.canDownloadIgnoringStorageReserve(descriptor.id))
                  _StorageReserveOverrideButton(
                    controller: controller,
                    attachmentId: descriptor.id,
                  ),
                TextButton(
                  onPressed: accepting
                      ? null
                      : () => unawaited(
                          controller.rejectIncomingAttachment(descriptor.id),
                        ),
                  child: Text(l10nOf(context).uiReject2B03B5),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (showImage) {
      // nightly.10: Copy / Save moved into the full-screen viewer's AppBar to
      // declutter the bubble. Tap the image to open the viewer.
      final tile = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => bytes != null
              ? _openFullScreenImage(context, bytes)
              : unawaited(_openPathImage(context)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (bytes != null)
                  Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 640,
                  )
                else
                  FutureBuilder<String?>(
                    future: controller.attachmentCachePathFor(descriptor.id),
                    builder: (context, snapshot) {
                      final path = snapshot.data;
                      if (path == null) {
                        return const SizedBox(
                          width: 240,
                          height: 180,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: 640,
                      );
                    },
                  ),
                // nightly.10: Telegram-style dim+spinner overlay while the
                // transfer is in flight so the preview doesn't give a false
                // "sent" feel. Hidden once the bubble is delivered/read.
                if (transferInFlight)
                  _TransferOverlay(
                    progress: progress,
                    // Routes are network detail (Advanced mode only).
                    route: outbound && controller.userMode.showsNetworkDetail
                        ? controller.lastDeliveryRouteFor(descriptor.id)
                        : OutboundDeliveryRoute.unknown,
                    pauseState: pauseState,
                    onPauseToggle: () {
                      if (pauseState?.pausedByMe ?? false) {
                        controller.resumeAttachment(descriptor.id);
                      } else {
                        controller.pauseAttachment(descriptor.id);
                      }
                    },
                  ),
                if (queuePosition > 0)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _QueueBadge(position: queuePosition),
                  ),
              ],
            ),
          ),
        ),
      );
      return _wrapContextMenu(
        context: context,
        child: _thumbnailContainer(tile),
      );
    }

    // Video bubble: render the poster (shipped in the offer envelope) as
    // a thumbnail with a play-circle overlay. Tap → open the full-screen
    // player if the bytes are cached; otherwise show a brief "still
    // transferring" status. Falls through to the generic file row when
    // no poster is present.
    final poster = _isVideo ? controller.videoPosterFor(descriptor.id) : null;
    if (_isVideo && poster != null) {
      final tile = Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: hasLocalFile
              ? () => unawaited(_openVideoPlayer(context))
              : () => controller.setStatus(
                  'Video still transferring (${(progress ?? 0) * 100 ~/ 1}%).',
                ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Image.memory(
                  poster,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: 640,
                ),
                // nightly.10: dim+spinner overlay while in flight so the
                // receiver doesn't think the video is ready before its
                // bytes arrive.
                if (transferInFlight)
                  _TransferOverlay(
                    progress: progress,
                    // Routes are network detail (Advanced mode only).
                    route: outbound && controller.userMode.showsNetworkDetail
                        ? controller.lastDeliveryRouteFor(descriptor.id)
                        : OutboundDeliveryRoute.unknown,
                    pauseState: pauseState,
                    onPauseToggle: () {
                      if (pauseState?.pausedByMe ?? false) {
                        controller.resumeAttachment(descriptor.id);
                      } else {
                        controller.pauseAttachment(descriptor.id);
                      }
                    },
                  )
                else if (queuePosition > 0)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _QueueBadge(position: queuePosition),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(10),
                    child: const Icon(
                      Icons.play_arrow,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      return _wrapContextMenu(
        context: context,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Album grid cells are tight squares — let the poster fill the
            // cell and drop the meta line that would overflow it.
            if (constraints.maxHeight.isFinite) {
              return tile;
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 320,
                    maxHeight: 320,
                  ),
                  child: tile,
                ),
                if (!hasLocalFile) ...[
                  const SizedBox(height: 6),
                  Text(
                    progress != null
                        ? l10nOf(context).uiTransferringValueValue10EEBE(
                            ((progress * 100).toStringAsFixed(0)).toString(),
                            (_formatBytes(descriptor.sizeBytes)).toString(),
                          )
                        : l10nOf(context).uiTransferringValue9D7F13(
                            (_formatBytes(descriptor.sizeBytes)).toString(),
                          ),
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: metaColor),
                  ),
                ],
              ],
            );
          },
        ),
      );
    }

    // nightly.11: video without a poster — render a black placeholder
    // tile with a play-circle so it LOOKS like a video, not a generic
    // document. Without this fallthrough, posterless videos hit the
    // generic file row and rendered as documents.
    if (_isVideo) {
      return _wrapContextMenu(
        context: context,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: hasLocalFile
                  ? () => unawaited(_openVideoPlayer(context))
                  : () => controller.setStatus(
                      'Video still transferring '
                      '(${((progress ?? 0) * 100).toStringAsFixed(0)}%).',
                    ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.center,
                    children: [
                      Container(color: Colors.black),
                      const Icon(
                        Icons.play_circle_outline,
                        color: Colors.white70,
                        size: 64,
                      ),
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 8,
                        child: Text(
                          "${(descriptor.fileName)} · ${(_formatBytes(descriptor.sizeBytes))}",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      if (transferInFlight)
                        _TransferOverlay(
                          progress: progress,
                          route:
                              outbound && controller.userMode.showsNetworkDetail
                              ? controller.lastDeliveryRouteFor(descriptor.id)
                              : OutboundDeliveryRoute.unknown,
                          pauseState: pauseState,
                          onPauseToggle: () {
                            if (pauseState?.pausedByMe ?? false) {
                              controller.resumeAttachment(descriptor.id);
                            } else {
                              controller.pauseAttachment(descriptor.id);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (descriptor.voiceMetadata case final voice?) {
      final duration = Duration(milliseconds: voice.durationMs);
      final durationLabel =
          '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
      return _wrapContextMenu(
        context: context,
        child: InkWell(
          onTap: hasLocalFile
              ? () async {
                  try {
                    final path = await controller.attachmentCachePathFor(
                      descriptor.id,
                    );
                    if (path == null) {
                      controller.setStatus(
                        'Voice message bytes are not ready.',
                      );
                      return;
                    }
                    await controller.voiceMessageService.togglePlayback(
                      path,
                      itemId: descriptor.id,
                    );
                  } catch (error) {
                    controller.setStatus('$error');
                  }
                }
              : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: outbound
                  ? palette.outboundBubble.withValues(alpha: 0.72)
                  : palette.inboundBubble,
              borderRadius: BorderRadius.circular(14),
            ),
            child: StreamBuilder<Duration>(
              stream: controller.voiceMessageService.playbackPositionStream,
              initialData: Duration.zero,
              builder: (context, snapshot) {
                final service = controller.voiceMessageService;
                final isCurrent = service.playingItemId == descriptor.id;
                final fraction = voice.durationMs <= 0
                    ? 0.0
                    : ((snapshot.data?.inMilliseconds ?? 0) / voice.durationMs)
                          .clamp(0.0, 1.0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          hasLocalFile
                              ? (isCurrent && service.isPlaying
                                    ? Icons.pause_circle_outline
                                    : Icons.play_circle_outline)
                              : Icons.mic_none,
                          color: textColor,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10nOf(context).uiVoiceMessage999DEB,
                                style: TextStyle(color: textColor),
                              ),
                              Text(
                                "${(durationLabel)} · ${(_formatBytes(descriptor.sizeBytes))}",
                                style: TextStyle(color: metaColor),
                              ),
                            ],
                          ),
                        ),
                        if (hasLocalFile)
                          PopupMenuButton<double>(
                            tooltip: l10nOf(context).uiPlaybackSpeed6FF42B,
                            icon: Icon(Icons.speed, color: textColor, size: 20),
                            onSelected: (rate) => unawaited(
                              service
                                  .setPlaybackRate(rate)
                                  .catchError(
                                    (Object error) =>
                                        controller.setStatus('$error'),
                                  ),
                            ),
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 1, child: Text('1×')),
                              PopupMenuItem(value: 1.5, child: Text('1.5×')),
                              PopupMenuItem(value: 2, child: Text('2×')),
                            ],
                          ),
                        if (transferInFlight)
                          SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 2,
                            ),
                          ),
                      ],
                    ),
                    if (hasLocalFile && isCurrent)
                      Slider(
                        value: fraction,
                        onChanged: (value) => unawaited(
                          service.seekPlayback(
                            Duration(
                              milliseconds: (value * voice.durationMs).round(),
                            ),
                          ),
                        ),
                      ),
                    if (isCurrent && service.playbackError != null)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          l10nOf(context).uiPlaybackFailedValue1C0E1A(
                            (service.playbackError).toString(),
                          ),
                          style: TextStyle(color: palette.danger, fontSize: 12),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    }

    final icon = _isVideo
        ? Icons.play_circle_outline
        : (_isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined);
    final String pauseSuffix;
    if (pauseState != null && pauseState.pausedByMe) {
      pauseSuffix = ' · ${l10nOf(context).uiPausedC7DFB6}';
    } else if (pauseState != null && pauseState.pausedByPeer) {
      pauseSuffix = ' · ${l10nOf(context).uiPausedByPeer63BD05}';
    } else {
      pauseSuffix = '';
    }
    final String statusLine;
    // A Failed message must never show "Transferring …" — the retry cap
    // or the sender's 60 s stall flipped the state and the bubble should
    // surface that instead of the indefinite spinner that battle tests
    // surfaced in nightly.6.
    if (snapshot != null && snapshot.phase != TransferPhase.completed) {
      final details = <String>[
        snapshot.phase == TransferPhase.awaitingApproval
            ? l10nOf(context).uiDownloadA479C9
            : transferPhaseLabel(context, snapshot.phase),
        '${(snapshot.progress * 100).toStringAsFixed(0)}%',
        '${_formatBytes(snapshot.bytesTransferred)} / ${_formatBytes(snapshot.totalBytes)}',
        if (snapshot.bytesPerSecond != null && snapshot.bytesPerSecond! > 0)
          '${_formatBytes(snapshot.bytesPerSecond!.round())}/s',
        if (snapshot.eta != null)
          l10nOf(context).transferTimeLeft(_formatEta(snapshot.eta!)),
        if ((snapshot.routeLabel ?? '').isNotEmpty) snapshot.routeLabel!,
      ];
      statusLine = details.join(' · ');
    } else if (messageState == DeliveryState.failed) {
      statusLine =
          '${l10nOf(context).callFailed} · ${_formatBytes(descriptor.sizeBytes)}'
          '${outbound ? " · ${l10nOf(context).transferTapRetry}" : ""}';
    } else if (hasLocalFile && !outbound) {
      statusLine = _formatBytes(descriptor.sizeBytes);
    } else if (outbound && outboundProgress != null) {
      final reroutePrefix = controller.isOutboundReroutingFor(descriptor.id)
          ? '${l10nOf(context).transferRerouting} · '
          : '';
      statusLine =
          '$reroutePrefix${l10nOf(context).uiTransferring73F753} · ${(outboundProgress * 100).toStringAsFixed(0)}% · '
          '${_formatBytes(descriptor.sizeBytes)}$pauseSuffix';
    } else if (outbound && queuePosition > 0) {
      statusLine =
          '${l10nOf(context).uiQueued6A5998} · #$queuePosition · ${_formatBytes(descriptor.sizeBytes)}';
    } else if (hasLocalFile) {
      statusLine = _formatBytes(descriptor.sizeBytes);
    } else if (progress != null) {
      statusLine =
          '${l10nOf(context).uiTransferring73F753} · ${(progress * 100).toStringAsFixed(0)}% · '
          '${_formatBytes(descriptor.sizeBytes)}$pauseSuffix';
    } else {
      statusLine =
          '${l10nOf(context).uiTransferring73F753} · ${_formatBytes(descriptor.sizeBytes)}';
    }
    return _wrapContextMenu(
      context: context,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: outbound
              ? palette.primary.withValues(alpha: 0.10)
              : palette.selection,
          borderRadius: BorderRadius.circular(12),
        ),
        // mainAxisSize default (max) so Flexible inside gets real width.
        // The earlier MainAxisSize.min collapsed Flexible to 0 → bubble
        // looked empty for non-image attachments on the receiver.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: textColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        descriptor.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (messageState == DeliveryState.failed && outbound)
                        InkWell(
                          onTap: () {
                            controller.retryAttachment(descriptor.id);
                          },
                          child: Text(
                            statusLine,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: metaColor,
                                  decoration: TextDecoration.underline,
                                ),
                          ),
                        )
                      else
                        Text(
                          statusLine,
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: metaColor),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (progress != null && progress < 1.0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: metaColor.withValues(alpha: 0.18),
                  color: palette.primary,
                ),
              ),
            ],
            // nightly.12: generic file rows (no preview) get an inline
            // route chip + Pause + Cancel row so the user can see whether
            // LAN-direct or relay is in use and abort or pause mid-transfer.
            // Image/video bubbles get the same affordances via _TransferOverlay.
            if (transferInFlight && !_isImage && !_isVideo) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (outbound && controller.userMode.showsNetworkDetail)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: _RouteChip(
                        route: controller.lastDeliveryRouteFor(descriptor.id),
                      ),
                    ),
                  if (pauseState != null)
                    IconButton(
                      icon: Icon(
                        pauseState.pausedByMe
                            ? Icons.play_circle_outline
                            : Icons.pause_circle_outline,
                        size: 22,
                        color: metaColor,
                      ),
                      tooltip: pauseState.pausedByMe
                          ? l10nOf(context).uiResumeB3BD0B
                          : l10nOf(context).uiPause781961,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: pauseState.pausedByPeer
                          ? null
                          : () {
                              if (pauseState.pausedByMe) {
                                controller.resumeAttachment(descriptor.id);
                              } else {
                                controller.pauseAttachment(descriptor.id);
                              }
                            },
                    ),
                  if (outbound)
                    IconButton(
                      icon: Icon(
                        Icons.cancel_outlined,
                        size: 22,
                        color: metaColor,
                      ),
                      tooltip: l10nOf(context).actionCancel,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: () =>
                          controller.cancelAttachmentById(descriptor.id),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// nightly.12: _AttachmentAction / _AttachmentActions / _pauseActionsFor
// removed — every bubble now uses raw IconButtons for pause/cancel in
// the inline row (generic files) or _TransferOverlay (image/video).
// Long-press / right-click handles Copy / Save / Delete via the menu.

class _ViewerPage {
  const _ViewerPage({
    required this.bytes,
    required this.fileName,
    required this.descriptorId,
    this.mimeType = 'image/jpeg',
  });
  final Uint8List bytes;
  final String fileName;
  final String descriptorId;
  final String mimeType;
}

/// nightly.10: horizontal tray of staged attachment previews above the
/// composer. Each tile shows the file's thumbnail (image, video poster,
/// or generic file icon) + X button to drop it. Hidden when no items
/// are staged. Listens directly to the controller so adds from any
/// pipeline (picker, drag-drop, paste, Ctrl+V) appear immediately.
class _StagedAttachmentTray extends StatelessWidget {
  const _StagedAttachmentTray({
    required this.controller,
    required this.contact,
    required this.palette,
  });

  final MessengerController controller;
  final ContactRecord contact;
  final ConestPalette palette;

  String _formatBytes(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final staged = controller.stagedAttachmentsFor(contact.deviceId);
        if (staged.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            height: 88,
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: staged.length,
              // Flutter 3.41.9 (the pinned release toolchain) requires this
              // callback; 3.44 deprecates it in favor of onReorderItem.
              // ignore: deprecated_member_use
              onReorder: (oldIndex, newIndex) => controller.reorderStaged(
                deviceId: contact.deviceId,
                oldIndex: oldIndex,
                newIndex: newIndex,
              ),
              itemBuilder: (context, i) {
                final item = staged[i];
                final isImage = item.mimeType.startsWith('image/');
                final isVideo = item.mimeType.startsWith('video/');
                final preview = item.previewBytesIfCheap;
                Widget previewChild;
                if (isImage && preview != null) {
                  previewChild = Image.memory(
                    preview,
                    fit: BoxFit.cover,
                    cacheWidth: 176,
                  );
                } else if (isVideo && item.poster != null) {
                  previewChild = Stack(
                    fit: StackFit.expand,
                    alignment: Alignment.center,
                    children: [
                      Image.memory(
                        item.poster!,
                        fit: BoxFit.cover,
                        cacheWidth: 176,
                      ),
                      const Icon(
                        Icons.play_circle_outline,
                        color: Colors.white,
                        size: 28,
                      ),
                    ],
                  );
                } else {
                  previewChild = Container(
                    color: palette.selection,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isVideo
                              ? Icons.play_circle_outline
                              : Icons.insert_drive_file_outlined,
                          size: 22,
                          color: palette.inboundMeta,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatBytes(item.sizeBytes),
                          style: TextStyle(
                            fontSize: 10,
                            color: palette.inboundMeta,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  );
                }
                return Padding(
                  key: ValueKey(item.id),
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: 88,
                          height: 88,
                          child: previewChild,
                        ),
                      ),
                      Positioned(
                        left: 4,
                        top: 4,
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: palette.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            "${(i + 1)}",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 2,
                        bottom: 2,
                        child: PopupMenuButton<AttachmentPresentation>(
                          tooltip: l10nOf(context).uiSendMode265A2D,
                          initialValue: item.presentation,
                          onSelected: (presentation) =>
                              controller.setStagedPresentation(
                                deviceId: contact.deviceId,
                                stagedId: item.id,
                                presentation: presentation,
                              ),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: AttachmentPresentation.media,
                              child: Text(l10nOf(context).uiSendAsMedia061D87),
                            ),
                            PopupMenuItem(
                              value: AttachmentPresentation.file,
                              child: Text(l10nOf(context).uiSendAsFileB50EAF),
                            ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              item.presentation == AttachmentPresentation.media
                                  ? l10nOf(context).uiMEDIAB85FA2
                                  : l10nOf(context).uiFILEB4915D,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: -6,
                        top: -6,
                        child: InkWell(
                          onTap: () => controller.removeStaged(
                            deviceId: contact.deviceId,
                            stagedId: item.id,
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// nightly.10: Telegram-style overlay for in-flight image/video previews.
/// A black-tinted scrim with a centered progress indicator + percentage
/// text. Makes "this file hasn't actually been sent yet" unmissable —
/// users were reading the preview alone as "delivered" before this.
class _TransferOverlay extends StatelessWidget {
  const _TransferOverlay({
    this.progress,
    this.route = OutboundDeliveryRoute.unknown,
    this.pauseState,
    this.onPauseToggle,
  });

  /// 0.0 to 1.0, or null for an indeterminate spinner.
  final double? progress;

  /// nightly.11: render a tiny "LAN" / "relay" chip in the corner so the
  /// user can verify the LAN-direct fast-path is actually firing.
  /// `unknown` hides the chip (inbound transfers, just-started outbound
  /// before the first chunk lands).
  final OutboundDeliveryRoute route;

  /// nightly.11: current pause state. When `pausedByMe` is true the
  /// overlay swaps the spinner for a static "Paused" label + Play icon.
  /// `pausedByPeer` true shows "Paused by peer" (no toggle).
  final ({bool pausedByMe, bool pausedByPeer})? pauseState;

  /// nightly.11: tapped on the Pause/Resume icon. Null = no toggle (e.g.
  /// inbound transfers don't expose a pause from this overlay).
  final VoidCallback? onPauseToggle;

  @override
  Widget build(BuildContext context) {
    final pausedByMe = pauseState?.pausedByMe ?? false;
    final pausedByPeer = pauseState?.pausedByPeer ?? false;
    final pct = progress != null ? (progress! * 100).round() : null;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.45),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (pausedByMe || pausedByPeer)
                      const Icon(
                        Icons.pause_circle_outline,
                        color: Colors.white,
                        size: 44,
                      )
                    else
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 3,
                          color: Colors.white,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      pausedByMe
                          ? l10nOf(context).uiPausedC7DFB6
                          : pausedByPeer
                          ? l10nOf(context).uiPausedByPeer63BD05
                          : (pct != null ? "${(pct)}%" : ''),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    if (onPauseToggle != null && !pausedByPeer) ...[
                      const SizedBox(height: 4),
                      InkWell(
                        onTap: onPauseToggle,
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            pausedByMe
                                ? Icons.play_circle_outline
                                : Icons.pause_circle_outline,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (route != OutboundDeliveryRoute.unknown)
            Positioned(right: 6, bottom: 6, child: _RouteChip(route: route)),
        ],
      ),
    );
  }
}

class _PathImageViewerScreen extends StatelessWidget {
  const _PathImageViewerScreen({
    required this.path,
    required this.title,
    required this.onSave,
  });

  final String path;
  final String title;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
        actions: [
          IconButton(
            tooltip: l10nOf(context).uiSaveEFC007,
            onPressed: () => unawaited(onSave()),
            icon: const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0);
          final cacheWidth = (constraints.maxWidth * dpr).round();
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(path),
                cacheWidth: cacheWidth,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => Center(
                  child: Text(
                    l10nOf(context).uiCouldNotDecodeThisImage3EAA16,
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ImageViewerScreen extends StatefulWidget {
  const _ImageViewerScreen({
    required this.pages,
    required this.initialIndex,
    required this.palette,
    this.onCopy,
    this.onSave,
  }) : assert(pages.length > 0);

  final List<_ViewerPage> pages;
  final int initialIndex;
  final ConestPalette palette;
  final Future<void> Function(_ViewerPage page)? onCopy;
  final Future<void> Function(_ViewerPage page)? onSave;

  @override
  State<_ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<_ImageViewerScreen> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.pages.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _previousPage() {
    if (_index > 0) {
      _controller.previousPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  void _nextPage() {
    if (_index < widget.pages.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final activePage = widget.pages[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.pages.length > 1
              ? "${(activePage.fileName)}  ·  ${(_index + 1)}/${(widget.pages.length)}"
              : activePage.fileName,
        ),
        actions: [
          if (widget.onCopy != null)
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: l10nOf(context).uiCopyAF74F7,
              onPressed: () => widget.onCopy!(activePage),
            ),
          if (widget.onSave != null)
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: l10nOf(context).uiSaveEFC007,
              onPressed: () => widget.onSave!(activePage),
            ),
        ],
      ),
      body: Focus(
        autofocus: true,
        // nightly.10: desktop users navigate album pages with arrow keys
        // (the PageView's built-in gesture handling is touch-only).
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _previousPage();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _nextPage();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0);
            // Cap decoded width at the viewport's physical width — enough
            // for pixel-perfect rendering, far less than the source image
            // (a 30 MB photo could be 8 K × 6 K and OOM the platform
            // image codec without this).
            final cacheW = (constraints.maxWidth * dpr).round();
            return PageView.builder(
              controller: _controller,
              itemCount: widget.pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final page = widget.pages[i];
                return Center(
                  child: _ZoomablePage(bytes: page.bytes, cacheWidth: cacheW),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

/// nightly.11: Telegram-style queue position badge — a small dark
/// circle with `#N` in the corner of preview tiles. Replaces the
/// verbose "Queued · #N · X MB" status line so multi-item album
/// transfers feel visually ordered rather than text-cluttered.
/// nightly.12: shared LAN / relay route chip. Used by `_TransferOverlay`
/// for preview tiles AND by the generic file bubble's inline control bar.
/// Single source of truth so both surfaces look identical and the user
/// learns the chip = "this is the active route".
class _RouteChip extends StatelessWidget {
  const _RouteChip({required this.route});

  final OutboundDeliveryRoute route;

  @override
  Widget build(BuildContext context) {
    final info = switch (route) {
      OutboundDeliveryRoute.lanDirect => (
        label: l10nOf(context).uiLAN2ECD17,
        color: const Color(0xFF4ADE80),
      ),
      OutboundDeliveryRoute.irohDirect => (
        label: l10nOf(context).uiDirect24A173,
        color: const Color(0xFF22D3EE),
      ),
      OutboundDeliveryRoute.irohRelay => (
        label: l10nOf(context).uiIrohRelayB128EA,
        color: const Color(0xFFC084FC),
      ),
      OutboundDeliveryRoute.conestRelay => (
        label: l10nOf(context).uiRelayBD28B2,
        color: const Color(0xFFFBBF24),
      ),
      OutboundDeliveryRoute.unknown => (
        label: l10nOf(context).uiRoutingECF60A,
        color: const Color(0xFF94A3B8),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: info.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            info.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// Colour and short name for each [MessageRoute], shared by the message
/// chips and the legend in Settings.
extension MessageRouteStyle on MessageRoute {
  Color get color => switch (this) {
    MessageRoute.lanDirect => const Color(0xFF2E7D32),
    MessageRoute.lanRelay => const Color(0xFF00897B),
    MessageRoute.lanLobby => const Color(0xFF8D6E63),
    MessageRoute.internetDirect => const Color(0xFF3949AB),
    MessageRoute.irohDirect => const Color(0xFF1E88E5),
    MessageRoute.irohRelay => const Color(0xFF8E24AA),
    MessageRoute.conestRelay => const Color(0xFFF57C00),
    MessageRoute.matrixCarrier => const Color(0xFF0DBD8B),
    MessageRoute.plainMatrix => const Color(0xFFE53935),
    MessageRoute.nostrCarrier => const Color(0xFF6A1B9A),
    MessageRoute.emailCarrier => const Color(0xFF546E7A),
    MessageRoute.reticulum => const Color(0xFF00ACC1),
    MessageRoute.meshtastic => const Color(0xFF7CB342),
    MessageRoute.meshCore => const Color(0xFFC0CA33),
    MessageRoute.bitchat => const Color(0xFF1565C0),
    MessageRoute.torOnion => const Color(0xFF7E57C2),
    MessageRoute.viaContact => const Color(0xFFEF6C00),
  };

  String shortLabel(BuildContext context) => switch (this) {
    MessageRoute.lanDirect => 'LAN',
    MessageRoute.lanRelay => l10nOf(context).uiLANRelayA05D48,
    MessageRoute.lanLobby => l10nOf(context).routeShortLobby,
    MessageRoute.internetDirect => l10nOf(context).routeShortDirect,
    MessageRoute.irohDirect => 'Iroh',
    MessageRoute.irohRelay => l10nOf(context).uiIrohRelayB128EA,
    MessageRoute.conestRelay => l10nOf(context).routeShortRelay,
    MessageRoute.matrixCarrier => 'Matrix',
    MessageRoute.plainMatrix => l10nOf(context).uiPlainMatrixBA9DE1,
    MessageRoute.nostrCarrier => 'Nostr',
    MessageRoute.emailCarrier => l10nOf(context).uiEmail84ADD5,
    MessageRoute.reticulum => 'Reticulum',
    MessageRoute.meshtastic => 'Meshtastic',
    MessageRoute.meshCore => 'MeshCore',
    MessageRoute.bitchat => 'Bluetooth',
    MessageRoute.torOnion => 'Tor',
    MessageRoute.viaContact => l10nOf(context).routeShortContact,
  };
}

/// Asks, every time, before sending a pending message as a plain Matrix
/// message to the contact's linked Matrix account.
Future<void> _sendViaPlainMatrix(
  BuildContext context,
  MessengerController controller,
  ContactRecord contact,
  ChatMessage message,
) async {
  final userId = controller.matrixUserIdFor(contact.deviceId);
  if (userId == null) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10nOf(context).uiSendViaMatrix062A08),
      content: Text(
        l10nOf(context).uiValueCannotBeReachedOver14E8C2(
          (contact.alias).toString(),
          (userId).toString(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10nOf(context).uiKeepWaiting9BE1AB),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10nOf(context).uiSendViaMatrix638038),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await controller.sendViaPlainMatrix(
      contact: contact,
      messageId: message.id,
    );
  } catch (error) {
    controller.setStatus('Not sent via Matrix: $error');
  }
}

/// Explains the route marks on messages.
class _MessageRouteLegend extends StatelessWidget {
  const _MessageRouteLegend();

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(l10nOf(context).uiMessageRoutesFBF32C),
      subtitle: Text(l10nOf(context).uiWhatTheColouredMarksOnA10C8E),
      children: [
        for (final route in MessageRoute.values)
          if (route.carrierKind?.userVisible ?? true)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(radius: 6, backgroundColor: route.color),
              title: Text(messageRouteLabel(context, route)),
              subtitle: Text(messageRouteDescription(context, route)),
            ),
      ],
    );
  }
}

/// The route a message took, sent or received: a coloured chip, or a dot
/// and short name in compact layouts.
class _MessageRouteChip extends StatelessWidget {
  const _MessageRouteChip({required this.message, this.compact = false});

  final ChatMessage message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final route = message.effectiveRoute;
    if (route == null) return const SizedBox.shrink();
    final detail = message.transportDetail;
    // Every route it took (all members together, in a group), with the
    // furthest each got: a filled dot arrived, a hollow one is on its way.
    final reached = <MessageRoute, MessageRouteMark>{};
    for (final trace in message.routeTrace) {
      final mark = reached[trace.route];
      if (mark == null || trace.mark.index > mark.index) {
        reached[trace.route] = trace.mark;
      }
    }
    final dots = reached.length > 1
        ? reached.entries.toList()
        : [MapEntry(route, MessageRouteMark.confirmed)];
    final tooltip = reached.length > 1
        ? [
            for (final entry in reached.entries)
              '${messageRouteLabel(context, entry.key)}: ${MessageInfoDialog.markLabel(entry.value, outbound: message.outbound, context: context)}',
          ].join('\n')
        : '${messageRouteLabel(context, route)}: ${messageRouteDescription(context, route)}'
              '${detail == null || detail.isEmpty ? '' : '\n$detail'}';
    return Tooltip(
      message: tooltip,
      child: compact
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in dots.take(4)) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color:
                          entry.value.index >=
                              MessageRouteMark.reachedDevice.index
                          ? entry.key.color
                          : null,
                      border: Border.all(color: entry.key.color, width: 1.2),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                if (dots.length > 4)
                  Text(
                    "+${(dots.length - 4)}",
                    style: TextStyle(fontSize: 9, color: route.color),
                  ),
                const SizedBox(width: 1),
                Text(
                  route.shortLabel(context),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: route.color,
                  ),
                ),
              ],
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: route.color.withValues(alpha: 0.16),
                border: Border.all(color: route.color.withValues(alpha: 0.7)),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                messageRouteLabel(context, route),
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: route.color,
                ),
              ),
            ),
    );
  }
}

class _QueueBadge extends StatelessWidget {
  const _QueueBadge({required this.position});

  final int position;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        "${(position)}",
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// nightly.11: a PageView page that hosts an `InteractiveViewer` for
/// pinch-zoom. The catch: InteractiveViewer's panEnabled defaults to
/// true, which means it claims horizontal swipes too — and those are
/// what `PageView` needs for page-to-page navigation. The fix is to
/// disable pan when not zoomed; the gesture goes straight to PageView.
/// Once the user pinches in, pan re-enables so they can drag the
/// zoomed image around inside the page.
class _ZoomablePage extends StatefulWidget {
  const _ZoomablePage({required this.bytes, required this.cacheWidth});

  final Uint8List bytes;
  final int cacheWidth;

  @override
  State<_ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<_ZoomablePage> {
  final TransformationController _tc = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _tc.addListener(_onTransform);
  }

  @override
  void dispose() {
    _tc.removeListener(_onTransform);
    _tc.dispose();
    super.dispose();
  }

  void _onTransform() {
    final scale = _tc.value.getMaxScaleOnAxis();
    final z = scale > 1.05;
    if (z != _zoomed) setState(() => _zoomed = z);
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _tc,
      minScale: 1.0,
      maxScale: 6,
      panEnabled: _zoomed,
      scaleEnabled: true,
      child: Image.memory(
        widget.bytes,
        fit: BoxFit.contain,
        cacheWidth: widget.cacheWidth,
      ),
    );
  }
}

class _VideoPlayerScreen extends StatefulWidget {
  const _VideoPlayerScreen({
    required this.cachePath,
    required this.title,
    required this.palette,
    this.onSave,
  });

  final String cachePath;
  final String title;
  final ConestPalette palette;
  final Future<void> Function()? onSave;

  @override
  State<_VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<_VideoPlayerScreen> {
  VideoPlayerController? _controller;
  Object? _initError;

  @override
  void initState() {
    super.initState();
    // Linux always uses xdg-open: libmpv can crash the process natively,
    // outside Dart's initialize().catchError recovery path.
    if (Platform.isLinux || (!_mediaKitAvailable && Platform.isWindows)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openInSystemPlayer();
      });
      return;
    }
    final controller = VideoPlayerController.file(File(widget.cachePath));
    _controller = controller;
    controller
        .initialize()
        .then((_) {
          if (!mounted) return;
          setState(() {});
          controller.play();
        })
        .catchError((Object error) {
          // nightly.11: on init failure, instantly hand off to the OS
          // default player rather than showing an error screen. The user
          // sees their video open in mpv/VLC/Windows Media Player
          // immediately and the Conest viewer closes itself.
          if (!mounted) return;
          if (Platform.isLinux || Platform.isWindows) {
            _openInSystemPlayer();
          } else {
            setState(() => _initError = error);
          }
        });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// nightly.10: when video_player can't decode (libmpv missing codec,
  /// unsupported container, or the platform impl just refuses) hand the
  /// file off to the OS default player. xdg-open / start / open per OS.
  Future<void> _openInSystemPlayer() async {
    try {
      if (Platform.isLinux) {
        await Process.start('xdg-open', [
          widget.cachePath,
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [
          widget.cachePath,
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isWindows) {
        await Process.start('cmd', [
          '/c',
          'start',
          '',
          widget.cachePath,
        ], mode: ProcessStartMode.detached);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _initError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          if (widget.onSave != null)
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: l10nOf(context).uiSaveEFC007,
              onPressed: () => widget.onSave!(),
            ),
        ],
      ),
      body: Focus(
        autofocus: true,
        // nightly.10: desktop Esc closes the player; space toggles play/pause.
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.of(context).pop();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.space &&
              c != null &&
              c.value.isInitialized) {
            setState(() {
              c.value.isPlaying ? c.pause() : c.play();
            });
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Center(
          child: _initError != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10nOf(context).uiCouldNotPlayThisVideoF7D318(
                          (_initError).toString(),
                        ),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _openInSystemPlayer,
                        icon: const Icon(Icons.open_in_new),
                        label: Text(
                          l10nOf(context).uiOpenInDefaultPlayerE64C20,
                        ),
                      ),
                    ],
                  ),
                )
              : (c != null && c.value.isInitialized)
              ? AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      VideoPlayer(c),
                      VideoProgressIndicator(c, allowScrubbing: true),
                    ],
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      ),
      floatingActionButton: (c != null && c.value.isInitialized)
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  c.value.isPlaying ? c.pause() : c.play();
                });
              },
              child: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
            )
          : null,
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({
    required this.count,
    required this.palette,
    this.compact = false,
  });

  final int count;
  final ConestPalette palette;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      key: Key('unread-badge-$label'),
      constraints: BoxConstraints(minWidth: compact ? 20 : 24),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: palette.unread,
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _GroupLeftBadge extends StatelessWidget {
  const _GroupLeftBadge({required this.palette});

  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('group-left-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.stroke,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        l10nOf(context).uiYouLeft9F2CDB,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: palette.inkSoft,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ReachabilityChip extends StatelessWidget {
  const _ReachabilityChip({
    required this.state,
    required this.palette,
    this.expand = false,
  });

  final ContactReachabilityState state;
  final ConestPalette palette;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final accent = switch (state) {
      ContactReachabilityState.online => palette.success,
      ContactReachabilityState.seenRecently => palette.warning,
      ContactReachabilityState.known => palette.inkSoft,
      ContactReachabilityState.unknown => palette.danger,
    };
    final labelWidget = Text(
      reachabilityLabel(context, state),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Container(
      width: expand ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(state.icon, size: 16, color: accent),
          const SizedBox(width: 8),
          if (expand) Expanded(child: labelWidget) else labelWidget,
        ],
      ),
    );
  }
}

class _QuotedReference extends StatelessWidget {
  const _QuotedReference({
    required this.palette,
    required this.outbound,
    required this.senderLabel,
    required this.snippet,
  });

  final ConestPalette palette;
  final bool outbound;
  final String senderLabel;
  final String snippet;

  @override
  Widget build(BuildContext context) {
    final baseColor = outbound ? palette.outboundText : palette.inboundText;
    final borderColor = outbound
        ? palette.primary.withValues(alpha: 0.45)
        : palette.secondary.withValues(alpha: 0.42);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: outbound
            ? palette.primary.withValues(alpha: 0.10)
            : palette.selection,
        borderRadius: BorderRadius.circular(12),
        border: BorderDirectional(start: BorderSide(color: borderColor, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            senderLabel,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: baseColor.withValues(alpha: outbound ? 0.9 : 0.7),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: baseColor.withValues(alpha: outbound ? 0.78 : 0.8),
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerReplyPreview extends StatelessWidget {
  const _ComposerReplyPreview({
    required this.palette,
    required this.senderLabel,
    required this.snippet,
    required this.onCancel,
  });

  final ConestPalette palette;
  final String senderLabel;
  final String snippet;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.stroke),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10nOf(
                    context,
                  ).uiReplyingToValue645786((senderLabel).toString()),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: palette.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  snippet,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.inkSoft,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: l10nOf(context).uiCancelReplyBD62D2,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

String formatTimestamp(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatProfileTimestamp(DateTime? value) {
  if (value == null) {
    return 'never';
  }
  return value.toLocal().toString();
}

bool get _isDesktopPlatform =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

bool get _isWindowsPlatform => !kIsWeb && Platform.isWindows;

Brightness get _platformBrightness =>
    WidgetsBinding.instance.platformDispatcher.platformBrightness;

class _ScheduledMessagesScreen extends StatelessWidget {
  const _ScheduledMessagesScreen({
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(l10nOf(context).uiScheduledMessages98CEF4)),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final entries = controller.scheduledMessages
              .where(
                (entry) =>
                    entry.state != ScheduledMessageState.sent &&
                    entry.state != ScheduledMessageState.canceled,
              )
              .toList(growable: false);
          if (entries.isEmpty) {
            return Center(
              child: Text(l10nOf(context).uiNoScheduledMessages1DDB60),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: entries.length,
            separatorBuilder: (_, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return ListTile(
                leading: Icon(
                  entry.state == ScheduledMessageState.blocked
                      ? Icons.error_outline
                      : Icons.schedule_send_outlined,
                  color: entry.state == ScheduledMessageState.blocked
                      ? palette.danger
                      : palette.primary,
                ),
                title: Text(
                  entry.body.isEmpty
                      ? (entry.attachmentFileName ??
                            l10nOf(context).uiScheduledAttachment08DB0E)
                      : entry.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  "${(entry.conversationKind)} • ${(entry.scheduledAtUtc.toLocal())}\n${(entry.failureReason ?? entry.state.name)}",
                ),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'edit') {
                      final editor = TextEditingController(text: entry.body);
                      final body = await showDialog<String>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text(
                            l10nOf(context).uiEditScheduledMessage62AF88,
                          ),
                          content: TextField(
                            controller: editor,
                            autofocus: true,
                            minLines: 1,
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: entry.attachmentPath == null
                                  ? l10nOf(context).uiMessage68F414
                                  : l10nOf(context).uiCaption3428D9,
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialogContext),
                              child: Text(l10nOf(context).actionCancel),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, editor.text),
                              child: Text(l10nOf(context).uiSaveEFC007),
                            ),
                          ],
                        ),
                      );
                      editor.dispose();
                      if (body != null) {
                        try {
                          await controller.editScheduledMessage(entry.id, body);
                        } catch (error) {
                          controller.setStatus('$error');
                        }
                      }
                    } else if (value == 'send') {
                      await controller.sendScheduledMessageNow(entry.id);
                    } else if (value == 'reschedule') {
                      final local = entry.scheduledAtUtc.toLocal();
                      final date = await showDatePicker(
                        context: context,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(
                          const Duration(days: 3650),
                        ),
                        initialDate: local.isBefore(DateTime.now())
                            ? DateTime.now()
                            : local,
                      );
                      if (date == null || !context.mounted) return;
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(local),
                      );
                      if (time == null) return;
                      await controller.rescheduleMessage(
                        entry.id,
                        DateTime(
                          date.year,
                          date.month,
                          date.day,
                          time.hour,
                          time.minute,
                        ),
                      );
                    } else if (value == 'cancel') {
                      await controller.cancelScheduledMessage(entry.id);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(l10nOf(context).menuEdit),
                    ),
                    PopupMenuItem(
                      value: 'send',
                      child: Text(l10nOf(context).uiSendNowDAE330),
                    ),
                    PopupMenuItem(
                      value: 'reschedule',
                      child: Text(l10nOf(context).uiReschedule34B2DC),
                    ),
                    PopupMenuItem(
                      value: 'cancel',
                      child: Text(l10nOf(context).actionCancel),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Shares a file with a group; when its metadata (location, camera,
/// author) cannot be removed, asks before sending it with it. False when
/// the user would rather not.
Future<bool> publishGroupFileAsking(
  BuildContext context,
  MessengerController controller, {
  required String groupId,
  required String path,
  required String fileName,
  required String mimeType,
  String caption = '',
}) async {
  try {
    await controller.publishGroupFile(
      groupId: groupId,
      path: path,
      fileName: fileName,
      mimeType: mimeType,
      caption: caption,
    );
    return true;
  } on FileMetadataException catch (error) {
    if (!context.mounted ||
        !await confirmSendingMetadata(
          context,
          fileName,
          partial: error.partial,
        )) {
      return false;
    }
    await controller.publishGroupFile(
      groupId: groupId,
      path: path,
      fileName: fileName,
      mimeType: mimeType,
      caption: caption,
      // Partly cleaned: what could be removed stays removed.
      keepMetadata: !error.partial,
      acceptPartialMetadata: error.partial,
    );
    return true;
  }
}

/// Asks whether to send [fileName] with the metadata that could not be
/// removed.
Future<bool> confirmSendingMetadata(
  BuildContext context,
  String fileName, {
  bool partial = false,
}) => showFileMetadataConsent(context, fileName, partial: partial);

/// Picks the chat to put something shared from another app into.
class _ShareTargetDialog extends StatelessWidget {
  const _ShareTargetDialog({required this.controller, required this.shared});

  final MessengerController controller;
  final SharedContent shared;

  @override
  Widget build(BuildContext context) {
    final me = controller.identity?.deviceId;
    final contacts = [
      for (final contact in controller.contacts)
        if (contact.canSendOutbound && contact.deviceId != me) contact,
    ]..sort((a, b) => a.alias.compareTo(b.alias));
    final groups = [
      for (final group in controller.groups)
        if (me != null && group.hasActiveMember(me)) group,
    ]..sort((a, b) => a.title.compareTo(b.title));
    final count = shared.files.length;
    return AlertDialog(
      title: Text(
        count == 0
            ? l10nOf(context).uiShareTextTo7B5086
            : count == 1
            ? l10nOf(
                context,
              ).uiShareValueTo6E3BDD((shared.files.single.name).toString())
            : l10nOf(context).uiShareValueFilesToA46E17((count)),
      ),
      content: SizedBox(
        width: 380,
        child: contacts.isEmpty && groups.isEmpty
            ? Text(l10nOf(context).uiNoChatsToShareIntoB50F2F)
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final contact in contacts)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(contact.alias),
                      onTap: () => Navigator.of(context).pop(contact),
                    ),
                  for (final group in groups)
                    ListTile(
                      leading: const Icon(Icons.group_outlined),
                      title: Text(group.title),
                      onTap: () => Navigator.of(context).pop(group),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10nOf(context).actionCancel),
        ),
      ],
    );
  }
}

/// A scrollbar whose thumb keeps its size while scrolling: lists of
/// messages have estimated heights, so the default thumb kept resizing as
/// items were laid out. The thumb is never shorter than [minThumbLength],
/// which on any long list is its size.
class StableScrollbar extends StatelessWidget {
  const StableScrollbar({
    super.key,
    this.controller,
    this.thumbVisibility,
    required this.child,
  });

  final ScrollController? controller;

  /// Always shown (true), or only while scrolling (null: the default).
  final bool? thumbVisibility;
  final Widget child;

  static const double minThumbLength = 64;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: RawScrollbar(
        controller: controller,
        thumbVisibility: thumbVisibility,
        thickness: 6,
        radius: const Radius.circular(3),
        minThumbLength: minThumbLength,
        interactive: controller != null,
        thumbColor: Theme.of(
          context,
        ).colorScheme.onSurface.withValues(alpha: 0.35),
        child: child,
      ),
    );
  }
}

/// Pointer or key activity on the window proves the app is in front, whatever the
/// platform last reported: some Linux desktops report a window in use as
/// hidden, and then chats stopped marking what was on screen read.
class UserActivityForeground extends StatelessWidget {
  const UserActivityForeground({
    super.key,
    required this.isForeground,
    required this.onForeground,
    required this.child,
  });

  final bool Function() isForeground;
  final VoidCallback onForeground;
  final Widget child;

  void _seen(PointerEvent _) {
    if (!isForeground()) onForeground();
  }

  KeyEventResult _typed(FocusNode _, KeyEvent _) {
    if (!isForeground()) onForeground();
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    // Typing counts too (it only listens; keys go on as before).
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _typed,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _seen,
      onPointerSignal: _seen,
      child: child,
    ),
  );
}

/// Windows: lets devices on the same network reach this PC (the firewall
/// blocks them on public networks such as a phone's hotspot).
class _WindowsFirewallTile extends StatefulWidget {
  const _WindowsFirewallTile();

  @override
  State<_WindowsFirewallTile> createState() => _WindowsFirewallTileState();
}

class _WindowsFirewallTileState extends State<_WindowsFirewallTile> {
  bool _busy = false;
  String? _result;

  Future<void> _allow() async {
    setState(() => _busy = true);
    final allowed = await WindowsFirewall.allowIncoming();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = allowed
          ? 'Done: devices on this network can reach this PC.'
          : 'Not changed (Windows did not confirm).';
    });
  }

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('windows-firewall'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.shield_outlined),
    title: Text(l10nOf(context).uiLetDevicesOnThisNetwork42E2F0),
    subtitle: Text(_result ?? l10nOf(context).uiIfMessagesAndFilesFrom3DED27),
    trailing: _busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : TextButton(
            onPressed: _allow,
            child: Text(l10nOf(context).uiAllow3AD0E3),
          ),
  );
}

/// Chats, calls and settings as tabs (Standard mode on a phone).
class _PhoneTabs extends StatelessWidget {
  const _PhoneTabs({
    required this.tab,
    required this.onTab,
    required this.chats,
    required this.calls,
  });

  final int tab;
  final ValueChanged<int> onTab;
  final Widget chats;
  final Widget calls;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: tab == 1 ? calls : chats),
        NavigationBar(
          key: const ValueKey('phone-tabs'),
          selectedIndex: tab,
          onDestinationSelected: onTab,
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.chat_bubble_outline),
              selectedIcon: const Icon(Icons.chat_bubble),
              label: l10nOf(context).tabChats,
            ),
            NavigationDestination(
              icon: const Icon(Icons.call_outlined),
              selectedIcon: const Icon(Icons.call),
              label: l10nOf(context).tabCalls,
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              label: l10nOf(context).tabSettings,
            ),
          ],
        ),
      ],
    );
  }
}
