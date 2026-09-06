import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:path/path.dart' as p;

import 'src/app_storage.dart';
import 'src/attachment_safety.dart';
import 'src/build_info.dart';
import 'src/conest_theme.dart';
import 'src/desktop_beam_scanner.dart';
import 'src/lan_direct.dart';
import 'src/iroh_ffi_bridge.dart';
import 'src/iroh_transport.dart';
import 'src/media_picker_sheet.dart';
import 'src/messenger_controller.dart';
import 'src/models.dart';
import 'src/platform_bridge.dart';
import 'src/qr_scan_screen.dart';
import 'src/relay_client.dart';
import 'src/storage.dart';
import 'src/transport.dart';
import 'src/ui/seal_avatar.dart';
import 'src/ui/signature_decoration.dart';
import 'src/ui/signature_panels.dart';
import 'src/ui/signature_widgets.dart';
import 'src/update_service.dart';

export 'src/conest_theme.dart'
    show
        ConestPalette,
        ConestThemeController,
        ConestThemeMode,
        ThemePreferenceStore;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storageResolver = AppStorageResolver();
  final storageResolution = await storageResolver.resolve();
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
  // nightly.10: register the libmpv-backed VideoPlayer platform impl on
  // Linux + Windows. Without this, video_player throws
  // `UnimplementedError: init() has not been implemented` on those
  // platforms (the federated plugin only ships Android/iOS/macOS/web by
  // default). Cheap no-op on the other platforms.
  //
  // nightly.11: wrap in try/catch — when libmpv isn't installed on the
  // host (common on a fresh Linux box) the dlopen crashes the process.
  // Failure flips _mediaKitAvailable to false and `_VideoPlayerScreen`
  // instantly routes to xdg-open / start instead of attempting inline
  // playback. README mentions libmpv as an optional Linux runtime dep.
  if (Platform.isLinux || Platform.isWindows) {
    try {
      VideoPlayerMediaKit.ensureInitialized(linux: true, windows: true);
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
  );
  await controller.initialize();
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
              title: 'Conest',
              theme: palette.themeData(),
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
                                'Conest is already running',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Close the existing Conest window first. A second instance would race the local relay port and encrypted vault.',
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
              title: 'Conest',
              theme: palette.themeData(),
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
                          'Choose where Conest stores data',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Ghost mode is best-effort privacy: OS launch history, crash logs, network metadata, shell history, recent files, and platform caches are outside app control.',
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
                              const RadioListTile<AppStorageMode>(
                                value: AppStorageMode.device,
                                title: Text('Default on this device'),
                                subtitle: Text(
                                  'Use the normal app data folder and this device keychain when auto-unlock is selected.',
                                ),
                              ),
                              if (widget.portableSupported)
                                const RadioListTile<AppStorageMode>(
                                  value: AppStorageMode.portable,
                                  title: Text('Ghost/portable beside the app'),
                                  subtitle: Text(
                                    'Store Conest-controlled files in a conest_data folder next to the app.',
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const Divider(height: 28),
                        Text(
                          'Vault unlock',
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
                                const RadioListTile<VaultUnlockMode>(
                                  value: VaultUnlockMode.keyFile,
                                  title: Text('Key file auto-unlock'),
                                  subtitle: Text(
                                    'Keeps the key beside the vault. Anyone with the folder can open it.',
                                  ),
                                )
                              else
                                const RadioListTile<VaultUnlockMode>(
                                  value: VaultUnlockMode.secureStorage,
                                  title: Text('Auto-unlock with this device'),
                                  subtitle: Text(
                                    'Stores the vault key in the platform secure store.',
                                  ),
                                ),
                              const RadioListTile<VaultUnlockMode>(
                                value: VaultUnlockMode.passphrase,
                                title: Text('Passphrase unlock'),
                                subtitle: Text(
                                  'Ask for a passphrase on each launch. Forgotten passphrases cannot be recovered.',
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
                            decoration: const InputDecoration(
                              labelText: 'Passphrase',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            key: firstLaunchConfirmPassphraseFieldKey,
                            controller: _confirmPassphraseController,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Confirm passphrase',
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
                              : const Text('Continue'),
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
                          'Unlock Conest',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Enter the passphrase for this vault.',
                          style: TextStyle(color: palette.inkSoft),
                        ),
                        const SizedBox(height: 18),
                        TextField(
                          key: unlockPassphraseFieldKey,
                          controller: _passphraseController,
                          obscureText: true,
                          onSubmitted: (_) => _unlock(),
                          decoration: const InputDecoration(
                            labelText: 'Passphrase',
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
                              : const Text('Unlock'),
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
  String? _activeUpdatePromptTag;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.setAppForegroundState(true);
    widget.updateService.addListener(_handleUpdateServiceChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(widget.updateService.ensureStartupCheck());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final inForeground =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    widget.controller.setAppForegroundState(inForeground);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.updateService.removeListener(_handleUpdateServiceChanged);
    widget.updateService.dispose();
    widget.controller.dispose();
    widget.themeController.dispose();
    unawaited(widget.instanceLock.release());
    super.dispose();
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
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        return AnimatedBuilder(
          animation: Listenable.merge([
            widget.controller,
            widget.themeController,
          ]),
          builder: (context, _) {
            final palette = widget.themeController.resolve(
              platformBrightness: _platformBrightness,
              lightDynamic: lightDynamic,
              darkDynamic: darkDynamic,
            );
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              title: 'Conest',
              navigatorKey: _navigatorKey,
              theme: palette.themeData(),
              home: widget.controller.isReady
                  ? widget.controller.hasIdentity
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
            title: const Text('Updates'),
            content: Text(
              updateService.statusMessage ??
                  'No update is available right now.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        }
        final actionLabel =
            updateService.targetPlatform == UpdateTargetPlatform.android
            ? 'Download & Install'
            : 'Download & Restart';
        return AlertDialog(
          title: const Text('Update Available'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${available.release.tagName} is available on the ${updateService.buildInfo.channelLabel} channel.',
                ),
                const SizedBox(height: 10),
                Text(
                  'Current build: ${updateService.buildInfo.displayVersion}',
                ),
                if ((available.releaseNotes ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    "What's new",
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
              child: const Text('Later'),
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
      widget.controller.setStatus(
        'Enter a display name and a valid local relay port.',
      );
      return;
    }
    if (internetRelayHost.isNotEmpty && internetRelayPort == null) {
      widget.controller.setStatus(
        'If you set an internet relay host, the relay port must be valid too.',
      );
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
        ? 'Desktop nodes relay by default and advertise nearby LAN routes automatically.'
        : !kIsWeb && Platform.isAndroid
        ? 'Android starts with relay mode off. Enable it in Settings only when you want this device to relay.'
        : 'Relay mode can be enabled in Settings when this device should help carry traffic.';
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
                                'Conest',
                                style: Theme.of(context).textTheme.displaySmall
                                    ?.copyWith(
                                      color: palette.textPrimary,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '◢ SECURE TEXT EXCHANGE',
                                style: TextStyle(
                                  fontFamily: ConestPalette.monoFont,
                                  fontSize: 11,
                                  letterSpacing: 2,
                                  color: palette.primary,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Pair by scanning a QR invite or by sharing only the current codephrase, deliver over LAN first, and continue over the internet through relay routes when LAN disappears.',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: palette.inkSoft,
                                      height: 1.4,
                                    ),
                              ),
                              const SizedBox(height: 24),
                              _FeatureStrip(
                                palette: palette,
                                items: const [
                                  'QR scan alone',
                                  'Codephrase-only add',
                                  'LAN-first delivery',
                                  'Internet relay fallback',
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
                                    'Create your first device',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'The local relay port is used for nearby LAN delivery, codephrase pairing, and desktop relay mode. The internet relay is optional but needed once peers leave the LAN.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: palette.inkSoft),
                                  ),
                                  const SizedBox(height: 18),
                                  TextField(
                                    controller: _displayNameController,
                                    decoration: const InputDecoration(
                                      labelText: 'Display name',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _localRelayPortController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Local relay / LAN port',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _internetRelayHostController,
                                    decoration: const InputDecoration(
                                      labelText:
                                          'Internet relay host / URL (optional)',
                                      hintText:
                                          'host auto-detects TCP/UDP; udp://host:port forces UDP',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _internetRelayPortController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Internet relay port',
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
                                    label: const Text(
                                      'Create encrypted device',
                                    ),
                                  ),
                                  if (widget.controller.statusMessage !=
                                      null) ...[
                                    const SizedBox(height: 14),
                                    Text(
                                      widget.controller.statusMessage!,
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
  String? _selectedContactId;
  String? _selectedGroupId;
  bool _lanLobbySelected = false;
  final _composerController = TextEditingController();
  ChatMessage? _replyTarget;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _composerController.dispose();
    super.dispose();
  }

  ContactRecord? get _selectedContact {
    final current = _selectedContactId;
    if (current == null) {
      return null;
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
  void _selectHomeContact(ContactRecord contact) {
    setState(() {
      _lanLobbySelected = false;
      _selectedGroupId = null;
      _selectedContactId = contact.deviceId;
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
    await showDialog<void>(
      context: context,
      builder: (context) => AddContactDialog(
        controller: widget.controller,
        palette: widget.palette,
      ),
    );
  }

  Future<void> _showCreateGroup() async {
    final created = await showDialog<GroupRecord>(
      context: context,
      builder: (context) => CreateGroupDialog(
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

  Future<void> _showGroupDetails(GroupRecord group) async {
    await showDialog<void>(
      context: context,
      builder: (context) => GroupDetailsDialog(
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

  Future<void> _showContactProfile(ContactRecord contact) async {
    await showDialog<void>(
      context: context,
      builder: (context) => ContactProfileDialog(
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

  Future<void> _sendCurrentMessage() async {
    final contact = _selectedContact;
    if (contact == null) return;
    final body = _composerController.text.trim();
    // nightly.10: when files are staged, Send commits the bundle (with
    // the typed text as caption on the first item). When no files are
    // staged, fall through to the text-only send path.
    final staged = widget.controller.stagedAttachmentsFor(contact.deviceId);
    if (staged.isNotEmpty) {
      _composerController.clear();
      setState(() => _replyTarget = null);
      await widget.controller.sendStagedBundle(
        contact: contact,
        caption: body,
        confirmOriginalSourceFallback: _confirmOriginalSourceFallback,
      );
      return;
    }
    if (body.isEmpty) return;
    final replyTarget = _replyTarget;
    _composerController.clear();
    setState(() => _replyTarget = null);
    await widget.controller.sendMessage(
      contact: contact,
      body: body,
      replyTo: replyTarget,
    );
  }

  Future<bool> _confirmOriginalSourceFallback(
    StagedAttachment attachment,
    AttachmentSpoolException error,
  ) async {
    if (!mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Send without resumable copy?'),
            content: Text(
              '${attachment.fileName} could not be copied into private '
              'transfer storage.\n\n$error\n\nThe app can read the original '
              'file directly, but the transfer cannot resume after restart '
              'if that file moves or its permission expires.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Send from original'),
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
    _composerController.clear();
    setState(() => _replyTarget = null);
    await widget.controller.sendGroupMessage(
      groupId: group.groupId,
      body: body,
      replyTo: replyTarget,
    );
  }

  Future<void> _sendLanLobbyMessage() async {
    final body = _composerController.text.trim();
    if (body.isEmpty) {
      return;
    }
    _composerController.clear();
    await widget.controller.sendLanLobbyMessage(body);
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
        text: '$before$text$after',
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
    if (contact == null) return false;
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
        await _sendAttachmentBytes(
          contact: contact,
          bytes: bytes,
          fileName: 'pasted-${DateTime.now().millisecondsSinceEpoch}.$ext',
          mimeType: mime,
        );
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
          return true;
        } catch (error) {
          widget.controller.appendDebugLog('Paste file read failed: $error');
        }
      }
    }
    return false;
  }

  void _handleDroppedFilesForGroup(List<XFile> files) {
    if (files.isEmpty) {
      return;
    }
    widget.controller.setStatus(
      'Group file send arrives in v0.3.3+. Use a 1:1 chat for now.',
    );
  }

  Future<void> _openMediaPicker() async {
    final contact = _selectedContact;
    if (contact == null) {
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
    return 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final selectedContact = _selectedContact;
    final selectedGroup = _selectedGroup;
    final lanLobbySelected =
        _lanLobbySelected && selectedContact == null && selectedGroup == null;
    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'global-transfers',
        tooltip: 'Transfers',
        onPressed: _showTransfers,
        child: Badge(
          isLabelVisible: widget.controller.transferSnapshots.any(
            (entry) =>
                entry.phase.isActive || entry.phase == TransferPhase.paused,
          ),
          label: Text(
            '${widget.controller.transferSnapshots.where((entry) => entry.phase.isActive || entry.phase == TransferPhase.paused).length}',
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
              canPop:
                  selectedContact == null &&
                  selectedGroup == null &&
                  !lanLobbySelected,
              onPopInvokedWithResult: (didPop, result) {
                if (!didPop &&
                    (_selectedContactId != null ||
                        _selectedGroupId != null ||
                        _lanLobbySelected)) {
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
                    if (!isWide && selectedContact != null) {
                      return _ChatPanel(
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
                      );
                    }
                    if (!isWide && selectedGroup != null) {
                      return _GroupChatPanel(
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
                        onSmartPaste: () => unawaited(_handleSmartPaste()),
                      );
                    }
                    if (!isWide && lanLobbySelected) {
                      return _LanLobbyPanel(
                        controller: widget.controller,
                        palette: palette,
                        composerController: _composerController,
                        onBack: () => setState(() => _lanLobbySelected = false),
                        onSend: _sendLanLobbyMessage,
                      );
                    }
                    return Row(
                      children: [
                        SizedBox(
                          width: isWide ? 380 : constraints.maxWidth,
                          // Shell selector — Garrison (Discord rail) and
                          // Courier (Telegram list) are alternate home
                          // presentations; all reuse the chat panels below.
                          child: switch (widget.themeController.shell) {
                            ConestShell.courier => _CourierHome(
                              controller: widget.controller,
                              palette: palette,
                              selectedContactId: _selectedContactId,
                              selectedGroupId: _selectedGroupId,
                              lanLobbySelected: lanLobbySelected,
                              onContactSelected: _selectHomeContact,
                              onGroupSelected: _selectHomeGroup,
                              onLanLobbySelected: _selectHomeLanLobby,
                              onAddContact: _showAddContact,
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
                                    onReplyToMessage: (message) =>
                                        setState(() => _replyTarget = message),
                                    onShowDetails: () =>
                                        _showGroupDetails(selectedGroup),
                                    onSend: _sendCurrentGroupMessage,
                                    onDropFiles: _handleDroppedFilesForGroup,
                                    onSmartPaste: () =>
                                        unawaited(_handleSmartPaste()),
                                  )
                                : selectedContact == null
                                ? _EmptyChatState(palette: palette)
                                : _ChatPanel(
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
                                    onReplyToMessage: (message) =>
                                        setState(() => _replyTarget = message),
                                    onShowProfile: () =>
                                        _showContactProfile(selectedContact),
                                    onSend: _sendCurrentMessage,
                                    onAttach: _openMediaPicker,
                                    onDropFiles: _handleDroppedFiles,
                                    onSmartPaste: () =>
                                        unawaited(_handleSmartPaste()),
                                  ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
class _CourierHome extends StatelessWidget {
  const _CourierHome({
    required this.controller,
    required this.palette,
    required this.selectedContactId,
    required this.selectedGroupId,
    required this.lanLobbySelected,
    required this.onContactSelected,
    required this.onGroupSelected,
    required this.onLanLobbySelected,
    required this.onAddContact,
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
  final Future<void> Function() onShowSettings;
  final Future<void> Function() onShowInvite;
  final Future<void> Function() onShowBeam;

  @override
  Widget build(BuildContext context) {
    // Unified, recency-sorted conversation entries.
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
            int memberCount,
            VoidCallback onTap,
          })
        >[];
    for (final contact in controller.contacts) {
      final last = controller.lastMessageFor(contact.deviceId);
      entries.add((
        seed: contact.deviceId,
        title: contact.alias,
        preview: last?.bodyPreview ?? 'No messages yet',
        at: last?.createdAt,
        unread: controller.unreadCountFor(contact.deviceId),
        selected: selectedContactId == contact.deviceId,
        isGroup: false,
        memberCount: 0,
        onTap: () => onContactSelected(contact),
      ));
    }
    for (final group in controller.visibleGroups) {
      final last = controller.lastGroupMessageFor(group.groupId);
      entries.add((
        seed: group.groupId,
        title: group.title,
        preview:
            last?.bodyPreview ??
            '${group.activeMemberDeviceIds.length} member(s)',
        at: last?.createdAt,
        unread: controller.unreadGroupCountFor(group.groupId),
        selected: selectedGroupId == group.groupId,
        isGroup: true,
        memberCount: group.activeMemberDeviceIds.length,
        onTap: () => onGroupSelected(group),
      ));
    }
    entries.sort((a, b) {
      final at = a.at;
      final bt = b.at;
      if (at == null && bt == null) return a.title.compareTo(b.title);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          child: Row(
            children: [
              Text(
                'Conest',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Conest Beam',
                onPressed: () => unawaited(onShowBeam()),
                icon: const Icon(Icons.center_focus_strong),
              ),
              IconButton(
                tooltip: 'My invite',
                onPressed: () => unawaited(onShowInvite()),
                icon: const Icon(Icons.qr_code_2),
              ),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => unawaited(onShowSettings()),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.panel2,
              borderRadius: BorderRadius.circular(ConestPalette.radius),
              border: Border.all(color: palette.border),
            ),
            child: Row(
              children: [
                Icon(Icons.search, size: 18, color: palette.inkSoft),
                const SizedBox(width: 8),
                Text(
                  'Search contacts, codephrase, key…',
                  style: TextStyle(fontSize: 13, color: palette.inkSoft),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              _CourierRow(
                palette: palette,
                icon: Icons.forum_outlined,
                title: 'LAN lobby',
                preview: 'Free-for-all local chat · untrusted',
                unread: controller.unreadLanLobbyCount,
                selected: lanLobbySelected,
                onTap: onLanLobbySelected,
              ),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: _EmptyContactsState(palette: palette),
                ),
              for (final entry in entries)
                _CourierRow(
                  palette: palette,
                  seed: entry.seed,
                  title: entry.title,
                  preview: entry.preview,
                  at: entry.at,
                  unread: entry.unread,
                  selected: entry.selected,
                  isGroup: entry.isGroup,
                  memberCount: entry.memberCount,
                  onTap: entry.onTap,
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Align(
              alignment: Alignment.centerRight,
              child: FloatingActionButton.extended(
                heroTag: 'courier-add',
                onPressed: onAddContact,
                backgroundColor: palette.primary,
                foregroundColor: palette.onPrimary,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Add'),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One Telegram-style row in the [_CourierHome] list.
class _CourierRow extends StatelessWidget {
  const _CourierRow({
    required this.palette,
    required this.title,
    required this.preview,
    required this.unread,
    required this.selected,
    required this.onTap,
    this.seed,
    this.icon,
    this.at,
    this.isGroup = false,
    this.memberCount = 0,
  });

  final ConestPalette palette;
  final String title;
  final String preview;
  final int unread;
  final bool selected;
  final VoidCallback onTap;
  final String? seed;
  final IconData? icon;
  final DateTime? at;
  final bool isGroup;
  final int memberCount;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
                    SealAvatar(
                      seed: seed!,
                      palette: palette,
                      size: 44,
                      label: title,
                    ),
                    if (isGroup)
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
                            '$memberCount',
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
                  tooltip: 'Direct messages',
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
                  tooltip: 'New group',
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
                'Direct messages',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Conest Beam',
                onPressed: () => unawaited(widget.onShowBeam()),
                icon: const Icon(Icons.center_focus_strong),
              ),
              IconButton(
                tooltip: 'My invite',
                onPressed: () => unawaited(widget.onShowInvite()),
                icon: const Icon(Icons.qr_code_2),
              ),
              IconButton(
                tooltip: 'Settings',
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
              _CourierRow(
                palette: palette,
                icon: Icons.forum_outlined,
                title: 'LAN lobby',
                preview: 'Free-for-all local chat · untrusted',
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
                tooltip: 'Group details',
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
                'Open #${group.title.toLowerCase().replaceAll(' ', '-')}',
              ),
            ),
          ),
        ),
        MonoSectionLabel(
          palette: palette,
          label: 'Members · ${memberIds.length}',
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
                    group.roleFor(deviceId)?.label ?? 'Member',
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
                              preview?.bodyPreview ?? 'No messages yet',
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
            'No activity yet — pair a contact to start the log.',
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
                              outbound ? 'SENT' : 'RECV',
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
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        StatusStrip(
          palette: palette,
          title: 'Node · online',
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
                            'device ${identity.deviceIdShort}',
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
                        tooltip: 'Debug',
                      ),
                    IconButton(
                      onPressed: onShowSettings,
                      icon: const Icon(Icons.settings_outlined),
                      tooltip: 'Settings',
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
                  label: 'safety ${identity.shortSafetyNumber}',
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
                        label: const Text('My invite'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onAddContact,
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Add'),
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
                    label: const Text('Conest Beam'),
                  ),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: onPoll,
                  icon: const Icon(Icons.sync),
                  label: const Text('Poll routes now'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onLanLobbySelected,
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: lanLobbySelected ? palette.selection : palette.paperStrong,
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
                        'LAN lobby',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Free-for-all local chat • untrusted',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
                      ),
                    ],
                  ),
                ),
                if (lanLobbyUnreadCount > 0) ...[
                  const SizedBox(width: 8),
                  _UnreadBadge(count: lanLobbyUnreadCount, palette: palette),
                ],
                Text(
                  '${controller.lanLobbyMessages.length}',
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
              'Groups',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              onPressed: controller.contacts.isEmpty ? null : onCreateGroup,
              icon: const Icon(Icons.group_add_outlined),
              tooltip: 'Create group',
            ),
            Text(
              '${controller.visibleGroups.length}',
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
                  ? 'Add trusted contacts before creating a group.'
                  : 'No groups yet.',
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
                    myDeviceId.isNotEmpty && !group.hasActiveMember(myDeviceId);
                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => onGroupSelected(group),
                  child: Ink(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: selected ? palette.selection : palette.paperStrong,
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
                              tooltip: 'Group details',
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${group.activeMemberDeviceIds.length} member(s)',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          preview == null
                              ? 'No messages yet'
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
                'Contacts',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '${controller.contacts.length}',
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
                                            fontFamily: ConestPalette.monoFont,
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
                                      tooltip: 'Contact profile',
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
                                      ? 'No messages yet'
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
            alignment: Alignment.centerLeft,
            child: Text(
              controller.statusMessage!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
          ),
        ],
        const SizedBox(height: 18),
      ],
    );
  }
}

class CreateGroupDialog extends StatefulWidget {
  const CreateGroupDialog({
    super.key,
    required this.controller,
    required this.palette,
  });

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
    return AlertDialog(
      title: const Text('Create group'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Group title'),
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
                              items: const [
                                DropdownMenuItem(
                                  value: GroupMemberRole.member,
                                  child: Text('Member'),
                                ),
                                DropdownMenuItem(
                                  value: GroupMemberRole.moderator,
                                  child: Text('Moderator'),
                                ),
                                DropdownMenuItem(
                                  value: GroupMemberRole.admin,
                                  child: Text('Admin'),
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canCreate ? _create : null,
          child: Text(_creating ? 'Creating' : 'Create'),
        ),
      ],
    );
  }
}

class GroupDetailsDialog extends StatefulWidget {
  const GroupDetailsDialog({
    super.key,
    required this.controller,
    required this.palette,
    required this.group,
  });

  final MessengerController controller;
  final ConestPalette palette;
  final GroupRecord group;

  @override
  State<GroupDetailsDialog> createState() => _GroupDetailsDialogState();
}

enum _DeleteGroupChoice { cancel, transfer, delete }

class _GroupDetailsDialogState extends State<GroupDetailsDialog> {
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
        title: Text('Delete "${group.title}"'),
        content: const Text(
          'Choose how to wind down this group. Transferring ownership '
          'keeps the group alive under a new owner and demotes you to '
          'admin. Deleting for everyone removes the group from every '
          "member's list and cannot be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.transfer),
            child: const Text('Transfer ownership…'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            onPressed: () =>
                Navigator.of(context).pop(_DeleteGroupChoice.delete),
            child: const Text('Delete for everyone'),
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
            title: const Text('Transfer ownership'),
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
                        group.roleFor(deviceId)?.label ?? 'Member',
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
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: selected == null
                    ? null
                    : () => Navigator.of(context).pop(selected),
                child: const Text('Transfer'),
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
        title: Text('Delete "${group.title}" for everyone?'),
        content: const Text(
          'Every member will be removed from the group and the group '
          "will be marked left in each member's list. Local message "
          'history is not deleted automatically — each member can clear '
          'it via Remove from list. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete for everyone'),
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
        title: const Text('Remove this group?'),
        content: const Text(
          'Remove this group from your list? This deletes the local '
          'message history. Other members will not be notified — they '
          'already see you as having left.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
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

  Widget? _memberTrailing(String deviceId, GroupMemberRole? role) {
    final canChangeRole =
        _canAssignRoles && role != null && role != GroupMemberRole.owner;
    final canRemove =
        deviceId != _currentDeviceId &&
        widget.controller.canRemoveGroupMember(group.groupId, deviceId);
    if (!canChangeRole && !canRemove) {
      return null;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canChangeRole)
          PopupMenuButton<GroupMemberRole>(
            tooltip: 'Change role',
            icon: const Icon(Icons.manage_accounts_outlined),
            initialValue: role,
            onSelected: (value) => _setRole(deviceId, value),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: GroupMemberRole.member,
                child: Text('Member'),
              ),
              PopupMenuItem(
                value: GroupMemberRole.moderator,
                child: Text('Moderator'),
              ),
              PopupMenuItem(value: GroupMemberRole.admin, child: Text('Admin')),
            ],
          ),
        if (canRemove)
          IconButton(
            onPressed: () => _removeMember(deviceId),
            icon: const Icon(Icons.person_remove_outlined),
            tooltip: 'Remove member',
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
    return AlertDialog(
      title: Text(group.title),
      content: SizedBox(
        width: 460,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              '${activeIds.length} member(s) • owner ${widget.controller.groupMemberLabel(group.ownerDeviceId)}',
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
                subtitle: Text(group.roleFor(deviceId)?.label ?? 'Member'),
                trailing: _memberTrailing(deviceId, group.roleFor(deviceId)),
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
                  '// GROUP TRUST FANOUT · mint = paired',
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
                'Add trusted contact',
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
                    tooltip: 'Add member',
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
            label: const Text('Delete group…'),
          )
        else if (_currentDeviceId != null &&
            group.roleFor(_currentDeviceId!) != GroupMemberRole.owner &&
            group.hasActiveMember(_currentDeviceId!))
          TextButton.icon(
            onPressed: _leave,
            icon: const Icon(Icons.logout),
            label: const Text('Leave'),
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
            label: const Text('Remove from list'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _GroupChatPanel extends StatefulWidget {
  const _GroupChatPanel({
    super.key,
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
    this.onBack,
    this.onSmartPaste,
  });

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
  final VoidCallback? onBack;
  final VoidCallback? onSmartPaste;

  @override
  State<_GroupChatPanel> createState() => _GroupChatPanelState();
}

class _GroupChatPanelState extends State<_GroupChatPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _messageListKey = GlobalKey();
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  bool _didInitialPosition = false;
  bool _initialPositionScheduled = false;
  bool _droppingFiles = false;
  Timer? _readSweepDebounce;
  String? _anchoredFirstUnreadId;
  final LinkedHashSet<String> _selectedMessageIds = LinkedHashSet<String>();
  String? _flashingMessageId;
  Timer? _flashTimer;

  static const Duration _readSweepDelay = Duration(milliseconds: 800);
  static const Duration _replyFlashDuration = Duration(milliseconds: 320);

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  MessengerController get controller => widget.controller;
  ConestPalette get palette => widget.palette;
  GroupRecord get group => widget.group;

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
    _scrollController.addListener(_scheduleReadSweep);
  }

  @override
  void didUpdateWidget(covariant _GroupChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.group.groupId != widget.group.groupId) {
      _messageKeys.clear();
      _didInitialPosition = false;
      _initialPositionScheduled = false;
      _anchoredFirstUnreadId = null;
      _readSweepDebounce?.cancel();
    }
    _scheduleInitialPosition();
    _scheduleReadSweep();
  }

  @override
  void dispose() {
    _readSweepDebounce?.cancel();
    _flashTimer?.cancel();
    _scrollController.removeListener(_scheduleReadSweep);
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _messageKeyFor(String messageId) {
    return _messageKeys.putIfAbsent(
      messageId,
      () => GlobalKey(debugLabel: 'group-message-$messageId'),
    );
  }

  void _pruneMessageKeys(List<ChatMessage> messages) {
    final activeIds = messages.map((message) => message.id).toSet();
    _messageKeys.removeWhere((messageId, _) => !activeIds.contains(messageId));
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

  void _scheduleReadSweep() {
    if (!mounted || !_didInitialPosition || !controller.isAppForeground) {
      return;
    }
    _readSweepDebounce?.cancel();
    _readSweepDebounce = Timer(_readSweepDelay, _runReadSweep);
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
    return _AlbumBubble(
      members: members,
      controller: controller,
      palette: palette,
      outbound: members.first.outbound,
      selectionMode: _selectionMode,
      selected: allSelected,
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
    return GestureDetector(
      key: _messageKeyFor(message.id),
      // nightly.10: opaque so long-press registers on the empty row space
      // next to the bubble too, not just on the bubble itself.
      behavior: HitTestBehavior.opaque,
      onTap: _selectionMode ? () => _toggleMessageSelection(message) : null,
      onLongPress: () => _toggleMessageSelection(message),
      onDoubleTap: _selectionMode
          ? null
          : () {
              _flashMessage(message.id);
              widget.onReplyToMessage(message);
            },
      child: Align(
        alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
        child: AnimatedContainer(
          duration: _replyFlashDuration,
          curve: Curves.easeOut,
          constraints: const BoxConstraints(maxWidth: 560),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
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
                    if (message.hasAttachment) ...[
                      _AttachmentRow(
                        descriptor: message.attachment!,
                        outbound: outbound,
                        palette: palette,
                        controller: controller,
                        messageState: message.state,
                      ),
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
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatTimestamp(message.createdAt),
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
                      'new',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontFamily: ConestPalette.monoFont,
                        color: palette.unread,
                        fontWeight: FontWeight.w700,
                      ),
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
                    tooltip: 'Message actions',
                    icon: Icon(
                      Icons.more_horiz,
                      size: 18,
                      color: outbound
                          ? palette.outboundMeta
                          : palette.inboundMeta,
                    ),
                    onSelected: (value) async {
                      if (value == 'copy') {
                        await _copyMessage(message);
                      } else if (value == 'reply') {
                        widget.onReplyToMessage(message);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'reply', child: Text('Reply')),
                      PopupMenuItem(value: 'copy', child: Text('Copy message')),
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
                          '${group.activeMemberDeviceIds.length} member(s) • owner ${controller.groupMemberLabel(group.ownerDeviceId)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  _StatusChip(
                    label: 'pairwise',
                    palette: palette,
                    icon: Icons.lock_outline,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: widget.onShowDetails,
                    icon: const Icon(Icons.groups_2_outlined),
                    tooltip: 'Group details',
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
                onSave: _canSaveSelected(messages)
                    ? () => _bulkSaveSelected(messages)
                    : null,
                // Group-message deletion is not wired in the controller yet;
                // hide the affordance rather than render a dead button.
                onDelete: null,
                showDelete: false,
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
                  return ListView.builder(
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
                      final bubble = _isAlbumAnchor(messages, chronoIndex)
                          ? _buildAlbumBubble(
                              context,
                              _collectAlbumFrom(messages, chronoIndex),
                            )
                          : _buildMessageBubble(context, message);
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
                  Row(
                    children: [
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
                              minLines: 1,
                              maxLines: 5,
                              enabled: canSend,
                              decoration: InputDecoration(
                                hintText: canSend
                                    ? activeReplyTarget == null
                                          ? 'Write to group'
                                          : 'Write a reply'
                                    : 'You are no longer in this group',
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
                                      label: 'Paste media',
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
                      FilledButton.icon(
                        onPressed: canSend ? widget.onSend : null,
                        icon: const Icon(Icons.north_east),
                        label: const Text('Send'),
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
    if (!_isDesktopPlatform) {
      return body;
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
          body,
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
                    'Group file send arrives in v0.3.3+',
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

class _ChatPanel extends StatefulWidget {
  const _ChatPanel({
    super.key,
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
  });

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

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _messageListKey = GlobalKey();
  bool _droppingFiles = false;
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  bool _didInitialPosition = false;
  bool _initialPositionScheduled = false;
  Timer? _readSweepDebounce;
  String? _anchoredFirstUnreadId;
  final LinkedHashSet<String> _selectedMessageIds = LinkedHashSet<String>();
  String? _flashingMessageId;
  Timer? _flashTimer;
  bool _routeInspectorOpen = false;

  static const Duration _readSweepDelay = Duration(milliseconds: 800);
  static const Duration _replyFlashDuration = Duration(milliseconds: 320);

  bool get _selectionMode => _selectedMessageIds.isNotEmpty;

  MessengerController get controller => widget.controller;
  ConestPalette get palette => widget.palette;
  ContactRecord get contact => widget.contact;

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
        label: 'LAN',
        detail: lanUp ? '${rtt(lanRtt)} · 0 hops' : 'unreachable',
        color: palette.primary,
        active: lanActive,
        available: lanUp,
      ),
      RouteInspectorPath(
        label: 'RELAY',
        detail: relayUp ? '${rtt(relayRtt)} · 2 hops' : 'unreachable',
        color: palette.secondary,
        active: !lanActive && relayUp,
        available: relayUp,
      ),
    ];
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
      _readSweepDebounce?.cancel();
    }
    _scheduleInitialPosition();
    _scheduleReadSweep();
  }

  @override
  void dispose() {
    _readSweepDebounce?.cancel();
    _flashTimer?.cancel();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    _scheduleReadSweep();
  }

  GlobalKey _messageKeyFor(String messageId) {
    return _messageKeys.putIfAbsent(
      messageId,
      () => GlobalKey(debugLabel: 'chat-message-$messageId'),
    );
  }

  void _pruneMessageKeys(List<ChatMessage> messages) {
    final activeIds = messages.map((message) => message.id).toSet();
    _messageKeys.removeWhere((messageId, _) => !activeIds.contains(messageId));
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

  void _scheduleReadSweep() {
    if (!mounted || !_didInitialPosition || !controller.isAppForeground) {
      return;
    }
    // Telegram-style: debounce the mark-read by 800 ms so the unread badge
    // on the contact list has time to appear and a burst of inbound
    // messages doesn't clear it instantly. The timer is reset on every
    // call so successive scroll events keep pushing the sweep out.
    _readSweepDebounce?.cancel();
    _readSweepDebounce = Timer(_readSweepDelay, _runReadSweep);
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
        title: const Text('Delete message?'),
        content: Text(
          message.outbound && message.state != DeliveryState.pending
              ? 'This removes the message here and asks the contact to remove their copy if reachable.'
              : 'This removes the message from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
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
    return _AlbumBubble(
      members: members,
      controller: controller,
      palette: palette,
      outbound: members.first.outbound,
      selectionMode: _selectionMode,
      selected: allSelected,
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
    return GestureDetector(
      key: _messageKeyFor(message.id),
      // nightly.10: opaque so long-press registers in the empty row space
      // next to the bubble, not just on the bubble itself.
      behavior: HitTestBehavior.opaque,
      onTap: _selectionMode ? () => _toggleMessageSelection(message) : null,
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
        alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
        child: AnimatedContainer(
          duration: _replyFlashDuration,
          curve: Curves.easeOut,
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
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
                      _AttachmentRow(
                        descriptor: message.attachment!,
                        outbound: outbound,
                        palette: palette,
                        controller: controller,
                        messageState: message.state,
                        conversationPeerDeviceId: contact.deviceId,
                      ),
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
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatTimestamp(message.createdAt),
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
                      'new',
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
                      'edited',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: outbound
                            ? palette.outboundMeta
                            : palette.inboundMeta,
                      ),
                    ),
                  ],
                  if (outbound && message.transportKind != null) ...[
                    const SizedBox(width: 8),
                    _MessageRouteChip(message: message),
                  ],
                  if (outbound) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: message.state.label,
                      child: Icon(
                        message.state.icon,
                        size: 16,
                        color: palette.outboundMeta,
                      ),
                    ),
                  ],
                  PopupMenuButton<String>(
                    tooltip: 'Message actions',
                    icon: Icon(
                      Icons.more_horiz,
                      size: 18,
                      color: outbound
                          ? palette.outboundMeta
                          : palette.inboundMeta,
                    ),
                    onSelected: (value) async {
                      try {
                        if (value == 'copy') {
                          await _copyMessage(message);
                        } else if (value == 'edit') {
                          await _editMessage(context, message);
                        } else if (value == 'cancel') {
                          await controller.cancelPendingMessage(
                            contact: contact,
                            messageId: message.id,
                          );
                        } else if (value == 'delete') {
                          await _deleteMessage(context, message);
                        }
                      } catch (error) {
                        controller.setStatus(error.toString());
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('Copy message'),
                      ),
                      if (outbound && message.state == DeliveryState.pending)
                        const PopupMenuItem(
                          value: 'cancel',
                          child: Text('Cancel sending'),
                        ),
                      if (outbound)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('Edit message'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete message'),
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
    final reachabilityState = controller.reachabilityStateFor(contact.deviceId);
    final activeReplyTarget =
        widget.replyTarget != null &&
            (widget.replyTarget!.senderDeviceId == contact.deviceId ||
                widget.replyTarget!.recipientDeviceId == contact.deviceId)
        ? widget.replyTarget
        : null;
    final body = Padding(
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
                              '${contact.routeSummary} • safety ${contact.shortSafetyNumber}',
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
                      tooltip: 'Route inspector',
                      isSelected: _routeInspectorOpen,
                      color: _routeInspectorOpen ? palette.primary : null,
                    ),
                    IconButton(
                      onPressed: widget.onShowProfile,
                      icon: const Icon(Icons.badge_outlined),
                      tooltip: 'Contact profile',
                    ),
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
                        const SizedBox(width: 12),
                        ...controls.expand(
                          (control) => [control, const SizedBox(width: 8)],
                        ),
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
                  return ListView.builder(
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
                      final bubble = _isAlbumAnchor(messages, chronoIndex)
                          ? _buildAlbumBubble(
                              context,
                              _collectAlbumFrom(messages, chronoIndex),
                            )
                          : _buildMessageBubble(context, message);
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
                  // nightly.10: staged-attachment tray (preview tiles +
                  // X-to-cancel). Hidden when no items are staged.
                  _StagedAttachmentTray(
                    controller: widget.controller,
                    contact: contact,
                    palette: palette,
                  ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: contact.canSendOutbound
                            ? widget.onAttach
                            : null,
                        icon: const Icon(Icons.attach_file_outlined),
                        tooltip: 'Attach a file or image',
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
                              minLines: 1,
                              maxLines: 5,
                              enabled: contact.canSendOutbound,
                              decoration: InputDecoration(
                                hintText: !contact.canSendOutbound
                                    ? 'Verify the contact\'s identity to send.'
                                    : activeReplyTarget == null
                                    ? 'Write an encrypted message'
                                    : 'Write a reply'
                                          ' or add a caption',
                              ),
                              onSubmitted: (_) => widget.onSend(),
                              contextMenuBuilder: (context, editableTextState) {
                                final items = List<ContextMenuButtonItem>.from(
                                  editableTextState.contextMenuButtonItems,
                                );
                                if (widget.onSmartPaste != null) {
                                  items.add(
                                    ContextMenuButtonItem(
                                      label: 'Paste media',
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
                      FilledButton.icon(
                        onPressed: contact.canSendOutbound
                            ? widget.onSend
                            : null,
                        icon: const Icon(Icons.north_east),
                        label: const Text('Send'),
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
    if (!_isDesktopPlatform) {
      return body;
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
          body,
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
                    'Drop files to send (max ${MessengerController.maxAttachmentsPerSend})',
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
  const _EditMessageDialog({required this.initialBody});

  final String initialBody;

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
      title: const Text('Edit message'),
      content: TextField(
        controller: _controller,
        minLines: 1,
        maxLines: 6,
        autofocus: true,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: 'Message'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
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
                          'LAN lobby',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Free-for-all local chat. Messages are session-signed but people here are not trusted contacts.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                      ],
                    ),
                  ),
                  _StatusChip(
                    label: 'LAN only',
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
                          'No LAN lobby messages yet. Nearby Conest peers will receive messages while they are on this LAN.',
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
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
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
                                  outbound ? 'You' : '$sender • untrusted',
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
                                    'new',
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
                      decoration: const InputDecoration(
                        hintText: 'Write to nearby LAN users',
                      ),
                      onSubmitted: (_) => onSend(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: onSend,
                    icon: const Icon(Icons.campaign_outlined),
                    label: const Text('Broadcast'),
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
    required this.controller,
    required this.palette,
    required this.contact,
  });

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
        title: Text('Remove ${widget.contact.alias}?'),
        content: const Text(
          'This removes the local contact and message history. The app will also try to send a removal notice so this contact disappears on the other side.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
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
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: const Text('Contact profile'),
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
                      decoration: const InputDecoration(labelText: 'Alias'),
                    ),
                  ),
                  SizedBox(
                    width: 340,
                    child: TextField(
                      controller: _bioController,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Description / bio',
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
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Available paths',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _checkPaths,
                    icon: const Icon(Icons.network_check),
                    label: const Text('Check Paths'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: checks == null || _busy ? null : _copyPathState,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy State'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (checks == null)
                Text(
                  'Run a check to measure latency, availability, and reachability freshness. Paths are sorted by best direct/LAN route first, then relay fallback.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.palette.inkSoft,
                  ),
                )
              else if (checks.isEmpty)
                Text(
                  'No route hints are advertised for this contact.',
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
          child: const Text('Remove Contact'),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _busy ? null : _saveProfile,
          child: const Text('Save Profile'),
        ),
      ],
    );
  }
}

class AddContactDialog extends StatefulWidget {
  const AddContactDialog({
    super.key,
    required this.controller,
    required this.palette,
  });

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
      return 'Trust QR / payload';
    }
    if (_hasCodephrase) {
      return 'Find by codephrase';
    }
    return 'Add contact';
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
      if (!mounted) {
        return;
      }
      if (result.exchangeStatus == ContactExchangeStatus.manualActionRequired) {
        final keepContact = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Automatic exchange failed'),
            content: Text(
              'You added ${result.contact.alias}, but your invite could not be sent back automatically. Ask the other user to scan or enter your invite from their side, or abort and remove this one-sided contact now.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Abort'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Keep Contact'),
              ),
            ],
          ),
        );
        if (keepContact != true) {
          await widget.controller.removeContact(
            result.contact.deviceId,
            notifyPeer: false,
          );
        }
      }
      if (mounted) {
        Navigator.of(context).pop();
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
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: const Text('Add contact'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ConnectivityOfflineBanner(
                controller: widget.controller,
                palette: widget.palette,
                message:
                    'Connectivity is off. Turn on LAN or Online to exchange this invite.',
              ),
              TextField(
                controller: _aliasController,
                decoration: const InputDecoration(labelText: 'Alias'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _payloadController,
                minLines: 4,
                maxLines: 7,
                decoration: const InputDecoration(
                  labelText: 'Invite payload or scanned QR',
                  alignLabelWithHint: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (widget.controller.supportsScanner) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _scanPayload,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan QR'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _codephraseController,
                decoration: const InputDecoration(labelText: 'Codephrase only'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Either input is enough on its own. Scan or paste a QR invite to trust it directly, or enter only the current codephrase to discover the sender over nearby LAN routes or the configured relay. If automatic exchange fails, the app will suggest asking the other side to add you back or aborting.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.palette.inkSoft,
                  ),
                ),
              ),
              if (preview != null) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Invite preview',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${preview.displayName}${preview.bio.isEmpty ? '' : ' • ${preview.bio}'} • ${preview.routeHints.isEmpty ? 'no routes advertised' : preview.routeHints.map((route) => '${route.kind.name}:${route.label}').join(' • ')}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.palette.inkSoft,
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
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
          child: const Text('Cancel'),
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
  late ContactInvite _invite = widget.invite;
  late String _payload = _invite.encodePayload();
  late bool _showQr = !_isWindowsPlatform;
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
          _payload = invite.encodePayload();
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
      _payload,
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
          codephrase: currentPairingCodeSnapshotForPayload(_payload).codephrase,
          palette: widget.palette,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pairingSnapshot = currentPairingCodeSnapshotForPayload(_payload);
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
                                'Share invite',
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(Icons.close),
                              tooltip: 'Close',
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _ConnectivityOfflineBanner(
                          controller: widget.controller,
                          palette: palette,
                          message:
                              'Connectivity is off. Turn on LAN or Online before sharing this invite.',
                        ),
                        if (_showQr)
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
                              OutlinedButton.icon(
                                onPressed: _openFullscreenQr,
                                icon: const Icon(Icons.open_in_full),
                                label: const Text('Open Fullscreen QR'),
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
                                  'QR rendering is deferred on Windows.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Use the codephrase below, or render the QR after this page is open.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: palette.inkSoft),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      setState(() => _showQr = true),
                                  icon: const Icon(Icons.qr_code_2),
                                  label: const Text('Show QR'),
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
                          'Scanning the compact QR is enough on its own. If the camera still struggles, open it full screen or use only the current codephrase.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'QR payload: ${_payload.length} characters',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: palette.inkSoft),
                        ),
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
                          label: const Text('Rotate Codephrase Now'),
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
      title: const Text('Encrypt for contact'),
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
              subtitle: Text('Pinned · ${contact.shortSafetyNumber}'),
            ),
          ),
        if (!widget.controller.contacts.any(
          (entry) => entry.canSendOutbound && entry.hasPinnedIrohIdentity,
        ))
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('No verified ci6 contacts are available yet.'),
          ),
      ],
    ),
  );

  Future<void> _preparePublic() async {
    final allowed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Public optical transfer'),
        content: const Text(
          'Anyone who can see the display may reconstruct this file. It is '
          'signed for integrity but it is not confidential.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Choose public file'),
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
      _runPreparation(widget.controller.prepareInviteBeam);

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
      appBar: AppBar(title: const Text('Conest Beam')),
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Close-up transfer',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'A looping LT fountain stream survives missed, duplicate, and '
              'out-of-order QR frames. The final file is hash-checked before '
              'you can accept it.',
              style: TextStyle(color: palette.inkSoft),
            ),
            const SizedBox(height: 20),
            _BeamActionCard(
              palette: palette,
              icon: Icons.download_outlined,
              title: 'Receive Beam',
              detail: widget.controller.supportsScanner
                  ? 'Scan animated frames and review before import.'
                  : 'Uses the native desktop camera when bundled, with manual cb1 input as a fallback.',
              onTap: _busy ? null : _receive,
            ),
            _BeamActionCard(
              palette: palette,
              icon: Icons.lock_outline,
              title: 'Send encrypted file',
              detail: 'Pairwise encrypted for a verified ci6 contact.',
              onTap: _busy ? null : _prepareEncrypted,
            ),
            _BeamActionCard(
              palette: palette,
              icon: Icons.public,
              title: 'Send public file',
              detail: 'Not confidential. The receiver must explicitly accept.',
              warning: true,
              onTap: _busy ? null : _preparePublic,
            ),
            _BeamActionCard(
              palette: palette,
              icon: Icons.person_add_alt_1,
              title: 'Beam contact invite',
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
                      ? 'PUBLIC · visible to anyone nearby'
                      : manifest.mode == BeamMode.contactEncrypted
                      ? 'CONTACT ENCRYPTED'
                      : 'SIGNED CONTACT INVITE',
                  style: TextStyle(
                    color: public ? Colors.red.shade700 : Colors.black87,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Frame ${widget.transfer.encoder.frameIndex} · '
                  '${widget.transfer.encoder.sourceBlockCount} source blocks · '
                  '${manifest.senderFingerprint}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontFamily: ConestPalette.monoFont,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Keep this screen visible until the receiver reports 100%.',
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
      appBar: AppBar(title: const Text('Receive Conest Beam')),
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
                            const Text(
                              'Desktop camera active',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Point this camera at the animated Beam QR. '
                              'Only decoded cb1 frames leave the native scanner.',
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
                          'Native desktop camera capture is unavailable. Paste '
                          'cb1 frames below; the protocol decoder and '
                          'verification path are identical.',
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
                        '${_progress.solvedBlocks}/${_progress.sourceBlockCount} '
                        'blocks · ${_progress.distinctFrames} frames · '
                        '$_invalidFrames invalid',
                      ),
                      if (_scanner == null) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: _frameController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Paste one cb1 frame',
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: () {
                            _addFrame(_frameController.text);
                            _frameController.clear();
                          },
                          child: const Text('Add frame'),
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
          invite != null ? 'Signed contact invite' : manifest.fileName,
          textAlign: TextAlign.center,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          public
              ? 'PUBLIC / UNTRUSTED. The signature proves that all frames '
                    'came from one key; it does not prove who owns that key.'
              : result.contactTrusted
              ? 'Encrypted and authenticated as a pinned Conest contact.'
              : 'Signature valid. Compare the fingerprint in person.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        SelectableText(
          manifest.senderFingerprint ?? 'fingerprint unavailable',
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
            decoration: const InputDecoration(labelText: 'Contact alias'),
          ),
          CheckboxListTile(
            value: fingerprintCompared,
            onChanged: (value) => onFingerprintChanged(value ?? false),
            title: const Text('We compared this fingerprint in person'),
            contentPadding: EdgeInsets.zero,
          ),
          FilledButton.icon(
            onPressed: saving || !fingerprintCompared ? null : onAcceptInvite,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('Trust and add contact'),
          ),
        ] else ...[
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: saving || savedPath != null ? null : onSave,
            icon: const Icon(Icons.save_alt),
            label: Text(public ? 'Accept and save public file' : 'Save file'),
          ),
        ],
        if (savedPath != null) ...[
          const SizedBox(height: 12),
          const Text('Saved in private Conest storage:'),
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
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                        tooltip: 'Close',
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
                      'Fullscreen compact invite QR',
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
                      '${payload.length} characters. Increase screen brightness if scanning is unreliable.',
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
    required this.controller,
    required this.updateService,
    required this.themeController,
    required this.palette,
    this.onResetIdentity,
  });

  final MessengerController controller;
  final UpdateService updateService;
  final ConestThemeController themeController;
  final ConestPalette palette;
  final Future<void> Function()? onResetIdentity;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _bioController;
  final TextEditingController _relayHostController = TextEditingController();
  final TextEditingController _relayPortController = TextEditingController(
    text: '$defaultRelayPort',
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
      text: '${identity?.localRelayPort ?? defaultRelayPort}',
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
        title: const Text('Reset identity'),
        content: const Text(
          'This clears the encrypted vault, removes contacts and messages, and returns the app to the first-launch state.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
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
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: const Text('Settings'),
      content: SizedBox(
        width: 720,
        child: identity == null
            ? const Text('No identity is active.')
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SettingsSection(
                      title: 'Personal / Preferences',
                      palette: widget.palette,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                                  decoration: const InputDecoration(
                                    labelText: 'Display name',
                                  ),
                                ),
                              ),
                              FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(
                                        () =>
                                            widget.controller.updateDisplayName(
                                              _displayNameController.text,
                                            ),
                                      ),
                                child: const Text('Save Name'),
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
                                  decoration: const InputDecoration(
                                    labelText: 'Description / bio',
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
                                child: const Text('Save Bio'),
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
                            title: const Text('Message notifications'),
                            subtitle: const Text(
                              'Show a system notification when a direct message arrives.',
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
                              title: const Text(
                                'Experimental Android background receive',
                              ),
                              subtitle: const Text(
                                'Disabled in release builds: the foreground service does not yet host a headless Flutter receiver.',
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
                              title: const Text(
                                "Don't send read confirmations",
                              ),
                              subtitle: const Text(
                                'Debug-only. Delivery acknowledgements still send; incoming read confirmations are still processed.',
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
                    _SettingsSection(
                      title: 'Storage',
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
                        title: const Text('Keep 10% of storage free'),
                        subtitle: const Text(
                          'Reserve free space for other apps. When off, transfers can use this space but must still fit on disk.',
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SettingsSection(
                      title: 'Connectivity',
                      palette: widget.palette,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                            title: const Text('LAN'),
                            subtitle: const Text(
                              'Same-network listener, pairing beacons, LAN delivery.',
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
                            title: const Text('Online'),
                            subtitle: const Text(
                              'Relay polling, internet/relay delivery, auto-imported contact relays.',
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
                            title: const Text('Iroh relay fallback'),
                            subtitle: const Text(
                              'Visible relay path used only while both peers are online.',
                            ),
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Automatic downloads'),
                            subtitle: const Text(
                              'Verified contacts only. Limits adapt to Wi-Fi/Ethernet, cellular, and roaming.',
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
                                                identity.connectivity.copyWith(
                                                  autoDownloadPreset: value,
                                                ),
                                              ),
                                        ),
                                      );
                                    },
                              items: const [
                                DropdownMenuItem(
                                  value: AutoDownloadPreset.low,
                                  child: Text('Low'),
                                ),
                                DropdownMenuItem(
                                  value: AutoDownloadPreset.medium,
                                  child: Text('Medium'),
                                ),
                                DropdownMenuItem(
                                  value: AutoDownloadPreset.high,
                                  child: Text('High'),
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
                                  decoration: const InputDecoration(
                                    labelText: 'Custom Iroh relay URLs',
                                    helperText:
                                        'One HTTPS URL per line; blank uses the standard N0 relay set.',
                                  ),
                                ),
                              ),
                              FilledButton.tonal(
                                onPressed:
                                    _busy ||
                                        !identity.connectivity.irohRelayEnabled
                                    ? null
                                    : () => _run(() async {
                                        final current =
                                            widget.controller.identity!;
                                        final values = _irohRelayUrlsController
                                            .text
                                            .split(RegExp(r'[\s,]+'))
                                            .where((value) => value.isNotEmpty);
                                        await widget.controller
                                            .updateGlobalConnectivity(
                                              current.connectivity.copyWith(
                                                irohRelayUrls: values.toList(),
                                                irohCustomRelaysBulkCapable:
                                                    values.isEmpty
                                                    ? false
                                                    : null,
                                              ),
                                            );
                                      }),
                                child: const Text('Save Iroh relays'),
                              ),
                            ],
                          ),
                          SwitchListTile.adaptive(
                            value: identity
                                .connectivity
                                .irohCustomRelaysBulkCapable,
                            contentPadding: EdgeInsets.zero,
                            onChanged:
                                _busy ||
                                    !identity.connectivity.irohRelayEnabled ||
                                    identity.connectivity.irohRelayUrls.isEmpty
                                ? null
                                : (value) => _run(
                                    () => widget.controller
                                        .updateGlobalConnectivity(
                                          identity.connectivity.copyWith(
                                            irohCustomRelaysBulkCapable: value,
                                          ),
                                        ),
                                  ),
                            title: const Text(
                              'Custom relays allow bulk transfers',
                            ),
                            subtitle: const Text(
                              'Trust these self-managed relays to carry files above 30 MiB automatically.',
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Transport policy',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          for (final kind in const [
                            TransportKind.lan,
                            TransportKind.iroh,
                            TransportKind.conestRelay,
                            TransportKind.optical,
                            TransportKind.deltaChat,
                            TransportKind.reticulum,
                            TransportKind.localSend,
                          ])
                            _TransportPolicySelector(
                              kind: kind,
                              value: identity.connectivity.policyFor(kind),
                              enabled: !_busy,
                              onChanged: (value) =>
                                  _setGlobalTransportPolicy(kind, value),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            identity.connectivity.anyEnabled
                                ? 'Per-contact routing is intersected with these flags. Turning off either restricts traffic; turning off both makes the app idle.'
                                : 'Connectivity is fully off — the app will not send or receive.',
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
                    _SettingsSection(
                      title: 'Network / Relay',
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
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 10),
                                  for (final note in report.notes)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
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
                            label: const Text('Check Availability'),
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
                            title: const Text('Run this device as a relay'),
                            subtitle: const Text(
                              'Allow trusted contacts to use this device as a relay.',
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
                            title: const Text('Auto-use contacts as relays'),
                            subtitle: Text(
                              '${contactRelays.length} candidate route(s) are available right now.',
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
                                  decoration: const InputDecoration(
                                    labelText: 'Local relay port',
                                  ),
                                ),
                              ),
                              FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(() async {
                                        final port = int.tryParse(
                                          _localRelayPortController.text.trim(),
                                        );
                                        if (port == null) {
                                          throw ArgumentError(
                                            'Enter a valid local relay port.',
                                          );
                                        }
                                        await widget.controller
                                            .updateLocalRelayPort(port);
                                      }),
                                child: const Text('Save Port'),
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
                            'Configured relays',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          if (configuredRelays.isEmpty)
                            Text(
                              'No relays added yet.',
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
                                            () => widget.controller.removeRelay(
                                              relay,
                                            ),
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
                                  decoration: const InputDecoration(
                                    labelText: 'Relay host / URL',
                                    hintText: 'udp://host:port forces UDP',
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 140,
                                child: TextField(
                                  controller: _relayPortController,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Relay port',
                                  ),
                                ),
                              ),
                              FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(() async {
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
                                child: const Text('Detect & Add Relay'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SettingsSection(
                      title: 'Updates',
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
                                'Current build: ${buildInfo.displayVersion} • ${buildInfo.channelLabel}',
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              if (buildInfo.commit != null &&
                                  buildInfo.commit!.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'commit ${buildInfo.commit}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: widget.palette.inkSoft),
                                ),
                              ],
                              if (available != null) ...[
                                const SizedBox(height: 10),
                                Text('Available: ${available.release.tagName}'),
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
                                      ?.copyWith(color: widget.palette.inkSoft),
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
                                          ? 'Checking...'
                                          : 'Check for Updates',
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
                    _SettingsSection(
                      title: 'Danger',
                      palette: widget.palette,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _confirmReset,
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Reset App Identity'),
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
          child: const Text('Close'),
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
        title: Text('Trust new identity for $relayId?'),
        content: Text(
          'The relay is now signing with a different Ed25519 public key '
          '(${_shortFingerprint(announcedKey)}). Only continue if the '
          'operator has confirmed they rotated the key — otherwise this '
          'could be a man-in-the-middle.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
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
            child: const Text('Trust new key'),
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
                'Relay identity changed',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'A configured relay is signing with a new key. Verify with the '
                'operator before trusting it.',
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
                          '${entry.key} → ${_shortFingerprint(entry.value)}',
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
                        child: const Text('Trust new key'),
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
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Add ${invite.displayName}?'),
        content: const Text(
          'This request is not authenticated by an existing contact. Verify '
          'the person and compare the safety number through another channel '
          'before accepting.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Add contact'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await controller.approvePendingContactRequest(request.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not add contact: $error')));
    }
  }

  Future<void> _reject(BuildContext context) async {
    await controller.rejectPendingContactRequest(request.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Contact request rejected.')));
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
                  'Contact request from $name',
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
            'Unverified · ${request.senderDeviceId.length > 12 ? request.senderDeviceId.substring(0, 12) : request.senderDeviceId}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: invite == null ? null : () => _approve(context),
                child: const Text('Review'),
              ),
              TextButton(
                onPressed: () => _reject(context),
                child: const Text('Reject'),
              ),
            ],
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
        title: const Text('Confirm identity replacement?'),
        content: Text(
          predecessor == null
              ? 'Trust ${contact.alias} as a fresh contact? Verify the safety '
                    'number out of band first — accepting now archives any '
                    'previous "${contact.displayName}" entries as read-only.'
              : 'Trust this as a reinstall of "${predecessor.alias}"? '
                    'The previous contact will be archived (history kept '
                    'read-only); the new contact takes over. This cannot be '
                    'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text("It's them"),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await controller.confirmContactReplacement(contact.deviceId);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Confirm failed: $error')));
    }
  }

  Future<void> _reject(BuildContext context) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reject this identity?'),
        content: const Text(
          'This deletes the new contact and any held inbound messages. '
          'Use this if you believe this is impersonation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
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
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await controller.rejectContactReplacement(contact.deviceId);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reject failed: $error')));
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
              'This contact may be a reset of "$predecessorAlias". Verify '
              'their safety number out of band before exchanging messages.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _confirm(context),
            child: const Text("It's them"),
          ),
          TextButton(
            onPressed: () => _reject(context),
            child: const Text('Not them'),
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
  bool _refreshing = false;
  bool _importing = false;

  Future<void> _runRefresh() async {
    setState(() => _refreshing = true);
    try {
      final result = await widget.controller.refreshDefaultRelays();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      switch (result.status) {
        case DefaultRelaysRefreshStatus.upToDate:
          messenger.showSnackBar(
            const SnackBar(content: Text('Default relays are up to date.')),
          );
          break;
        case DefaultRelaysRefreshStatus.updated:
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Updated to version ${result.version}: ${result.addedRoutes.length} route(s).',
              ),
            ),
          );
          break;
        case DefaultRelaysRefreshStatus.error:
          messenger.showSnackBar(
            SnackBar(
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              content: Text(
                'Update failed: ${result.errorMessage ?? "unknown error"}',
              ),
            ),
          );
          break;
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

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
        SnackBar(content: Text('Imported relays from ${result.url}.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
          content: Text('Import failed: $error'),
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
        title: const Text('Remove imported list?'),
        content: Text(
          'This will remove ${source.routeKeys.length} relay route(s) imported from ${source.url}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await widget.controller.removeCustomRelaySource(source.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Remove failed: $error')));
    }
  }

  String _relativeFetchedAt(DateTime? value) {
    if (value == null) return 'from bundle';
    final delta = DateTime.now().toUtc().difference(value);
    if (delta.inMinutes < 1) return 'just now';
    if (delta.inHours < 1) return '${delta.inMinutes} min ago';
    if (delta.inDays < 1) return '${delta.inHours} h ago';
    return '${delta.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final version = widget.controller.defaultRelaysVersion;
        final fetched = widget.controller.defaultRelaysLastFetchedAt;
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
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Default relays · v$version · ${_relativeFetchedAt(fetched)}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: _refreshing ? null : _runRefresh,
                    child: _refreshing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Update'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Pulled from the project repository when you tap Update.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: widget.palette.inkSoft),
              ),
              const Divider(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Imported relay lists',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
                        : const Text('Import from URL…'),
                  ),
                ],
              ),
              if (sources.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'No imported lists.',
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
                            '${source.url} · ${source.isSigned ? "signed" : "unsigned"} · ${source.routeKeys.length} route(s)',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => _removeSource(source),
                          child: const Text('Remove'),
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
      title: const Text('Import relay list from URL'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'JSON URL',
              hintText: 'https://example.com/relays.json',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _publicKeyController,
            decoration: const InputDecoration(
              labelText: "Operator's public key (optional, base64)",
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Leave blank to import unsigned (untrusted; pre-flight probes still gate use). Provide the operator\'s key for cryptographically trusted imports — the signature is fetched from <URL>.ed25519.sig.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
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
          child: const Text('Import'),
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
            '// ${title.toUpperCase()}',
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
                      label: 'OK',
                      value: '$ok',
                      color: palette.success,
                    ),
                  ),
                  Expanded(
                    child: RelayStat(
                      palette: palette,
                      label: 'WARN',
                      value: '$warn',
                      color: palette.warning,
                    ),
                  ),
                  Expanded(
                    child: RelayStat(
                      palette: palette,
                      label: 'DOWN',
                      value: '$down',
                      color: palette.danger,
                    ),
                  ),
                  Expanded(
                    child: RelayStat(
                      palette: palette,
                      label: 'AVG RTT',
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
              'Theme',
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
                      label: Text(mode.label),
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
                  ? 'Adaptive is using system dynamic colors.'
                  : 'Mint and pink remain the Conest fallback accents.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Decoration',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  _decorationLabel(controller.decorationIntensity),
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
              label: _decorationLabel(controller.decorationIntensity),
              onChanged: (value) =>
                  unawaited(controller.setDecorationIntensity(value)),
            ),
            Text(
              'Ambient grid, scanlines, corner reticles and the status '
              'readout. Clean ↔ full atmosphere.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
            const SizedBox(height: 16),
            Text(
              'Shell',
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
              controller.shell.blurb,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
            ),
            // The inner Home layout only applies to the Signature shell.
            if (controller.shell == ConestShell.signature) ...[
              const SizedBox(height: 16),
              Text(
                'Home layout',
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
                      ButtonSegment(value: layout, label: Text(layout.label)),
                  ],
                  selected: {controller.homeLayout},
                  onSelectionChanged: (selected) =>
                      unawaited(controller.setHomeLayout(selected.single)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                controller.homeLayout.blurb,
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

  String _decorationLabel(double intensity) {
    if (intensity <= 0.05) return 'CLEAN';
    if (intensity < 0.8) return 'SUBTLE';
    if (intensity <= 1.05) return 'DEFAULT';
    return 'FULL';
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
                          ? 'The selected peer must run the exact same debug build. It auto-accepts the encrypted test, verifies every block and the final SHA-256, reports timing, and removes test artifacts on both devices. No visual confirmation is required. Tests use LAN when enabled for the contact, otherwise direct Iroh. Payload blocks cannot use relays.'
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
        '${route.kind.name}:${route.label}',
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
                'CONEST · ci5 · ${DateTime.now().year}',
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
                'QR unavailable',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Use the codephrase or payload below.',
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
                  '${check.route.kind.name.toUpperCase()} ${check.route.label}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  usable
                      ? 'two-way confirmed${latency == null ? '' : ' • ${latency.inMilliseconds}ms'}'
                      : available
                      ? 'path accepts send; waiting for peer reply${latency == null ? '' : ' • ${latency.inMilliseconds}ms'}'
                      : check.error ?? 'unavailable',
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
                ? 'usable'
                : available
                ? 'one-way'
                : 'skip',
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
            'Share your invite, then either scan the QR code or enter only the current codephrase on the other device to add the contact.',
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
                    'Start with one trusted contact',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'This release pairs through a QR invite alone or through a codephrase alone, prefers nearby LAN routes, and falls back to internet relay routes after that.',
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
  ) {
    switch (mode) {
      case EffectiveRoutingMode.lanFirst:
        return (
          label: 'LAN first',
          icon: Icons.swap_horiz,
          color: palette.primary,
        );
      case EffectiveRoutingMode.lanOnly:
        return (
          label: 'LAN only',
          icon: Icons.wifi_tethering,
          color: palette.primary,
        );
      case EffectiveRoutingMode.onlineFirst:
        return (
          label: 'Online first',
          icon: Icons.public,
          color: palette.primary,
        );
      case EffectiveRoutingMode.onlineOnly:
        return (
          label: 'Online only',
          icon: Icons.cloud_outlined,
          color: palette.primary,
        );
      case EffectiveRoutingMode.offline:
        return (label: 'Offline', icon: Icons.cloud_off, color: palette.danger);
    }
  }

  Future<void> _open(BuildContext context) async {
    final global =
        controller.identity?.connectivity ??
        const GlobalConnectivityPreferences();
    if (!global.anyEnabled) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text(
            'Connectivity is off. Enable LAN or Online in Settings.',
          ),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => _ConnectivityDialog(
        title: 'Routing — ${contact.alias}',
        initial: contact.routing,
        global: global,
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
    final info = _labelFor(mode);
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
    required this.onSave,
  });

  final String title;
  final ContactRoutingPreferences initial;
  final GlobalConnectivityPreferences global;
  final void Function(ContactRoutingPreferences) onSave;

  @override
  State<_ConnectivityDialog> createState() => _ConnectivityDialogState();
}

class _ConnectivityDialogState extends State<_ConnectivityDialog> {
  late bool _lan = widget.initial.lanEnabled;
  late bool _online = widget.initial.onlineEnabled;
  late bool _irohRelay = widget.initial.irohRelayEnabled;
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
        return 'Uses LAN when available, falls back to Online.';
      case EffectiveRoutingMode.lanOnly:
        return 'Uses LAN only. No relay traffic for this contact.';
      case EffectiveRoutingMode.onlineFirst:
        return 'Uses Online when available, falls back to LAN.';
      case EffectiveRoutingMode.onlineOnly:
        return 'Uses Online only. No LAN traffic for this contact.';
      case EffectiveRoutingMode.offline:
        return widget.global.anyEnabled
            ? 'No transport selected — this contact is unreachable.'
            : 'Global connectivity is off — adjust Settings to send.';
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
            title: const Text('LAN'),
            subtitle: widget.global.lanEnabled
                ? const Text('Same-network delivery')
                : const Text('Disabled by global setting'),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile.adaptive(
            value: _irohRelay,
            onChanged: _online && widget.global.irohRelayEnabled
                ? (value) => setState(() => _irohRelay = value)
                : null,
            title: const Text('Allow Iroh relay fallback'),
            subtitle: widget.global.irohRelayEnabled
                ? const Text(
                    'Visible and online-only; direct Iroh is preferred.',
                  )
                : const Text('Disabled by global setting'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          for (final kind in const [
            TransportKind.lan,
            TransportKind.iroh,
            TransportKind.conestRelay,
            TransportKind.optical,
            TransportKind.deltaChat,
            TransportKind.reticulum,
          ])
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
            title: const Text('Online'),
            subtitle: widget.global.onlineEnabled
                ? const Text('Relay / internet delivery')
                : const Text('Disabled by global setting'),
            contentPadding: EdgeInsets.zero,
          ),
          if (_lan && _online) ...[
            const SizedBox(height: 8),
            const Text('Prefer'),
            const SizedBox(height: 4),
            SegmentedButton<RoutingPreference>(
              segments: const [
                ButtonSegment(value: RoutingPreference.lan, label: Text('LAN')),
                ButtonSegment(
                  value: RoutingPreference.online,
                  label: Text('Online'),
                ),
              ],
              selected: {_preferred},
              onSelectionChanged: (sel) =>
                  setState(() => _preferred = sel.first),
            ),
          ],
          const SizedBox(height: 12),
          Text(_resolvedLabel(), style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
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
                      transportPolicies: Map.unmodifiable(_policies),
                    ),
                  );
                  Navigator.of(context).pop();
                }
              : null,
          child: const Text('Save'),
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
        Expanded(child: Text(kind.label)),
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
                  TransportPolicy.automatic => 'Automatic',
                  TransportPolicy.preferred => 'Preferred',
                  TransportPolicy.disabled => 'Disabled',
                  TransportPolicy.askBeforeUse => 'Ask first',
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
    required this.members,
    required this.controller,
    required this.palette,
    required this.outbound,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelection,
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
      child: Align(
        alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
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
                        if (m.attachment != null)
                          _AttachmentRow(
                            descriptor: m.attachment!,
                            outbound: outbound,
                            controller: controller,
                            palette: palette,
                            messageState: m.state,
                          ),
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
                        'Retry failed',
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
                    tooltip: 'Album actions',
                    icon: Icon(
                      Icons.more_horiz,
                      size: 18,
                      color: outbound
                          ? palette.outboundMeta
                          : palette.inboundMeta,
                    ),
                    onSelected: (value) async {
                      switch (value) {
                        case 'cancel':
                          await controller.cancelAlbum(albumId);
                          break;
                        case 'delete':
                          await controller.deleteAlbum(albumId);
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      if (anyInFlight)
                        const PopupMenuItem(
                          value: 'cancel',
                          child: Text('Cancel album'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete album'),
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
    required this.onSave,
    required this.onDelete,
    this.showDelete = true,
  });

  final ConestPalette palette;
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onCopy;
  final VoidCallback? onSave;
  final VoidCallback? onDelete;

  /// `onDelete: null` means "temporarily unavailable for this selection"
  /// (button renders disabled). When the surface can never delete — group
  /// chats until controller support lands — hide the affordance entirely
  /// instead of showing a permanently dead button.
  final bool showDelete;

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
            tooltip: 'Cancel selection',
          ),
          const SizedBox(width: 4),
          Text(
            '$count selected',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          IconButton(
            onPressed: onCopy,
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copy',
          ),
          IconButton(
            onPressed: onSave,
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Save attachments',
          ),
          if (showDelete)
            IconButton(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
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

  String _phase(TransferPhase phase) => switch (phase) {
    TransferPhase.preparing => 'Preparing',
    TransferPhase.queued => 'Queued',
    TransferPhase.awaitingApproval => 'Waiting for approval',
    TransferPhase.waitingForPeer => 'Waiting for peer',
    TransferPhase.transferring => 'Transferring',
    TransferPhase.reconnecting => 'Reconnecting',
    TransferPhase.paused => 'Paused',
    TransferPhase.verifying => 'Verifying',
    TransferPhase.completed => 'Complete',
    TransferPhase.failed => 'Failed',
    TransferPhase.canceled => 'Canceled',
    TransferPhase.unavailable => 'Unavailable',
  };

  String _eta(Duration value) {
    if (value.inHours > 0) {
      return '${value.inHours}h ${value.inMinutes.remainder(60)}m';
    }
    if (value.inMinutes > 0) {
      return '${value.inMinutes}m ${value.inSeconds.remainder(60)}s';
    }
    return '${value.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
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
            title: const Text('Transfers'),
            actions: [
              IconButton(
                tooltip: 'Pause all',
                onPressed:
                    active.any(
                      (entry) => entry.phase.isActive && !entry.pausedByPeer,
                    )
                    ? () => unawaited(controller.pauseAllTransfers())
                    : null,
                icon: const Icon(Icons.pause_circle_outline),
              ),
              IconButton(
                tooltip: 'Resume all',
                onPressed: active.any((entry) => entry.pausedByMe)
                    ? () => unawaited(controller.resumeAllTransfers())
                    : null,
                icon: const Icon(Icons.play_circle_outline),
              ),
              IconButton(
                tooltip: 'Clear completed',
                onPressed: recent.isEmpty
                    ? null
                    : controller.clearCompletedTransfers,
                icon: const Icon(Icons.cleaning_services_outlined),
              ),
            ],
          ),
          body: snapshots.isEmpty
              ? const Center(child: Text('No transfers yet.'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                  children: [
                    if (active.isNotEmpty) ...[
                      _TransferSectionLabel(label: 'Active (${active.length})'),
                      for (final snapshot in active)
                        _TransferManagerTile(
                          snapshot: snapshot,
                          controller: controller,
                          palette: palette,
                          bytesLabel: _bytes,
                          phaseLabel: _phase,
                          etaLabel: _eta,
                        ),
                    ],
                    if (recent.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _TransferSectionLabel(label: 'Recent (${recent.length})'),
                      for (final snapshot in recent)
                        _TransferManagerTile(
                          snapshot: snapshot,
                          controller: controller,
                          palette: palette,
                          bytesLabel: _bytes,
                          phaseLabel: _phase,
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
      if (snapshot.eta != null) '${etaLabel(snapshot.eta!)} left',
      if (route != null && route.isNotEmpty) route,
      if (snapshot.queuePriority > 0) 'queue #${snapshot.queuePriority}',
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
                          '${controller.transferConversationLabel(snapshot.id)} · ${phaseLabel(snapshot.phase)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (snapshot.queuePriority > 1)
                    IconButton(
                      tooltip: 'Move to top',
                      onPressed: () =>
                          controller.prioritizeTransfer(snapshot.id),
                      icon: const Icon(Icons.vertical_align_top),
                    ),
                  if (snapshot.phase == TransferPhase.awaitingApproval &&
                      snapshot.direction == TransferDirection.inbound)
                    IconButton(
                      tooltip:
                          controller.attachmentAcceptanceInProgress(snapshot.id)
                          ? 'Preparing download'
                          : 'Download',
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
                      tooltip: 'Resume',
                      onPressed: () =>
                          unawaited(controller.resumeAttachment(snapshot.id)),
                      icon: const Icon(Icons.play_circle_outline),
                    )
                  else if (snapshot.phase.isActive)
                    IconButton(
                      tooltip: 'Pause',
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
                      tooltip: 'Retry',
                      onPressed: () => controller.retryAttachment(snapshot.id),
                      icon: const Icon(Icons.refresh),
                    ),
                  if (canCancel)
                    IconButton(
                      tooltip: 'Cancel',
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
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    onPressed: () => unawaited(
                      controller.continueLargeTransferOverIrohRelay(
                        snapshot.id,
                      ),
                    ),
                    icon: const Icon(Icons.cloud_upload_outlined),
                    label: const Text('Continue over Iroh relay'),
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
    child: const Text('Download anyway'),
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
  });

  final AttachmentDescriptor descriptor;
  final bool outbound;
  final ConestPalette palette;
  final MessengerController controller;
  final DeliveryState messageState;

  /// Set on 1:1 chat bubbles so the full-screen viewer can list every
  /// other image in the same conversation for swipe navigation. Null
  /// for group bubbles (group-wide swipe is a future enhancement).
  final String? conversationPeerDeviceId;

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

  String _phaseLabel(TransferPhase phase) => switch (phase) {
    TransferPhase.preparing => 'Preparing',
    TransferPhase.queued => 'Queued',
    TransferPhase.awaitingApproval => 'Download',
    TransferPhase.waitingForPeer => 'Waiting',
    TransferPhase.transferring => 'Transferring',
    TransferPhase.reconnecting => 'Reconnecting',
    TransferPhase.paused => 'Paused',
    TransferPhase.verifying => 'Verifying',
    TransferPhase.completed => 'Complete',
    TransferPhase.failed => 'Failed',
    TransferPhase.canceled => 'Canceled',
    TransferPhase.unavailable => 'Unavailable',
  };

  bool get _isImage => descriptor.mimeType.startsWith('image/');
  bool get _isVideo => descriptor.mimeType.startsWith('video/');

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
        dialogTitle: 'Save $safeFileName',
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
  Future<void> _showContextMenu(BuildContext context, Offset globalPos) async {
    final bytes = controller.attachmentBytesFor(descriptor.id);
    final hasBytes = bytes != null;
    final hasLocalFile = controller.attachmentAvailableLocally(descriptor.id);
    final keptOffline = controller.attachmentKeptOffline(descriptor.id);
    final inFlight =
        controller.attachmentTransferProgress(descriptor.id) != null ||
        controller.outboundAttachmentProgress(descriptor.id) != null;
    final isFailed = messageState == DeliveryState.failed;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPos, globalPos),
        Offset.zero & overlay.size,
      ),
      items: [
        if (hasBytes && _isImage)
          const PopupMenuItem(value: 'copy_image', child: Text('Copy')),
        if (hasLocalFile)
          const PopupMenuItem(value: 'save', child: Text('Save')),
        if (hasLocalFile)
          const PopupMenuItem(
            value: 'copy_path',
            child: Text('Copy cache path'),
          ),
        if (hasLocalFile)
          PopupMenuItem(
            value: 'keep_offline',
            child: Text(keptOffline ? 'Stop keeping offline' : 'Keep offline'),
          ),
        if (hasLocalFile && !keptOffline && !inFlight)
          const PopupMenuItem(
            value: 'evict',
            child: Text('Free up local space'),
          ),
        if (inFlight)
          const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
        if (isFailed && outbound)
          const PopupMenuItem(value: 'retry', child: Text('Retry')),
        const PopupMenuItem(value: 'delete', child: Text('Delete')),
      ],
    );
    if (selected == null || !context.mounted) return;
    switch (selected) {
      case 'copy_image':
        if (bytes != null) {
          await _copyImageBytesFor(bytes, descriptor.fileName);
        }
        break;
      case 'save':
        if (bytes != null) {
          await _saveToDisk(context, bytes);
        } else {
          await _saveLocalFileToDisk();
        }
        break;
      case 'copy_path':
        await _copyCachePath();
        break;
      case 'keep_offline':
        await controller.setAttachmentKeepOffline(descriptor.id, !keptOffline);
        break;
      case 'evict':
        try {
          await controller.evictAttachment(descriptor.id);
          controller.setStatus(
            'Local copy removed. Conest has no permanent cloud copy; '
            're-download depends on the sender still having it.',
          );
        } catch (error) {
          controller.setStatus('Could not remove the local copy: $error');
        }
        break;
      case 'cancel':
      case 'delete':
        // For now both route to the cancel-by-id path which sends an
        // attachment_cancel envelope + clears local state. Full delete
        // (including remote tombstone) requires the parent ChatMessage
        // context — deferred until the bubble passes it down.
        controller.cancelAttachmentById(descriptor.id);
        break;
      case 'retry':
        controller.retryAttachment(descriptor.id);
        break;
    }
  }

  Widget _wrapContextMenu({
    required BuildContext context,
    required Widget child,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPressStart: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Listener(
        behavior: HitTestBehavior.deferToChild,
        onPointerDown: (event) {
          // Secondary mouse button (right-click) on desktop.
          if (event.buttons & kSecondaryMouseButton != 0) {
            _showContextMenu(context, event.position);
          }
        },
        child: child,
      ),
    );
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
  Widget build(BuildContext context) {
    // Defensive guard: a malformed descriptor used to surface as a blank
    // attachment bubble. Reject early so the user sees an explicit error
    // rather than an empty card.
    if (descriptor.fileName.isEmpty ||
        descriptor.effectiveChunkCount <= 0 ||
        descriptor.fileHashBase64.isEmpty ||
        descriptor.encryptionKeyBase64.isEmpty) {
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
            Text(
              'Attachment metadata unavailable',
              style: TextStyle(color: palette.danger),
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
    final transferInFlight =
        snapshot?.phase.isActive == true ||
        snapshot?.phase == TransferPhase.paused;

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
                  ? '${sizeMb.toStringAsFixed(1)} MB · preparing download…'
                  : descriptor.sizeBytes >
                        MessengerController.maxAttachmentSizeBytes
                  ? '${sizeMb.toStringAsFixed(1)} MB · direct route required'
                  : '${sizeMb.toStringAsFixed(1)} MB · tap to download',
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
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Preparing download…'),
                          ],
                        )
                      : const Text('Download'),
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
                  child: const Text('Reject'),
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
                    route: outbound
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
                    route: outbound
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
                        ? 'Transferring · ${(progress * 100).toStringAsFixed(0)}% · '
                              '${_formatBytes(descriptor.sizeBytes)}'
                        : 'Transferring · ${_formatBytes(descriptor.sizeBytes)}',
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
                          '${descriptor.fileName} · ${_formatBytes(descriptor.sizeBytes)}',
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
                          route: outbound
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

    final icon = _isVideo
        ? Icons.play_circle_outline
        : (_isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined);
    final String pauseSuffix;
    if (pauseState != null && pauseState.pausedByMe) {
      pauseSuffix = ' · Paused';
    } else if (pauseState != null && pauseState.pausedByPeer) {
      pauseSuffix = ' · Paused by peer';
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
        _phaseLabel(snapshot.phase),
        '${(snapshot.progress * 100).toStringAsFixed(0)}%',
        '${_formatBytes(snapshot.bytesTransferred)} / ${_formatBytes(snapshot.totalBytes)}',
        if (snapshot.bytesPerSecond != null && snapshot.bytesPerSecond! > 0)
          '${_formatBytes(snapshot.bytesPerSecond!.round())}/s',
        if (snapshot.eta != null) '${_formatEta(snapshot.eta!)} left',
        if ((snapshot.routeLabel ?? '').isNotEmpty) snapshot.routeLabel!,
      ];
      statusLine = details.join(' · ');
    } else if (messageState == DeliveryState.failed) {
      statusLine =
          'Failed · ${_formatBytes(descriptor.sizeBytes)}'
          '${outbound ? " · tap to retry" : ""}';
    } else if (hasLocalFile && !outbound) {
      statusLine = _formatBytes(descriptor.sizeBytes);
    } else if (outbound && outboundProgress != null) {
      final reroutePrefix = controller.isOutboundReroutingFor(descriptor.id)
          ? 'Rerouting · '
          : '';
      statusLine =
          '${reroutePrefix}Transferring · ${(outboundProgress * 100).toStringAsFixed(0)}% · '
          '${_formatBytes(descriptor.sizeBytes)}$pauseSuffix';
    } else if (outbound && queuePosition > 0) {
      statusLine =
          'Queued · #$queuePosition · ${_formatBytes(descriptor.sizeBytes)}';
    } else if (hasLocalFile) {
      statusLine = _formatBytes(descriptor.sizeBytes);
    } else if (progress != null) {
      statusLine =
          'Transferring · ${(progress * 100).toStringAsFixed(0)}% · '
          '${_formatBytes(descriptor.sizeBytes)}$pauseSuffix';
    } else {
      statusLine = 'Transferring · ${_formatBytes(descriptor.sizeBytes)}';
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
                  if (outbound)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
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
                      tooltip: pauseState.pausedByMe ? 'Resume' : 'Pause',
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
                      tooltip: 'Cancel',
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
                  padding: const EdgeInsets.only(right: 8),
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
                            '${i + 1}',
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
                          tooltip: 'Send mode',
                          initialValue: item.presentation,
                          onSelected: (presentation) =>
                              controller.setStagedPresentation(
                                deviceId: contact.deviceId,
                                stagedId: item.id,
                                presentation: presentation,
                              ),
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: AttachmentPresentation.media,
                              child: Text('Send as media'),
                            ),
                            PopupMenuItem(
                              value: AttachmentPresentation.file,
                              child: Text('Send as file'),
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
                                  ? 'MEDIA'
                                  : 'FILE',
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
                          ? 'Paused'
                          : pausedByPeer
                          ? 'Paused by peer'
                          : (pct != null ? '$pct%' : ''),
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
            tooltip: 'Save',
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
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Text(
                    'Could not decode this image.',
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
              ? '${activePage.fileName}  ·  ${_index + 1}/${widget.pages.length}'
              : activePage.fileName,
        ),
        actions: [
          if (widget.onCopy != null)
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: 'Copy',
              onPressed: () => widget.onCopy!(activePage),
            ),
          if (widget.onSave != null)
            IconButton(
              icon: const Icon(Icons.download_outlined),
              tooltip: 'Save',
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
        label: 'LAN',
        color: const Color(0xFF4ADE80),
      ),
      OutboundDeliveryRoute.irohDirect => (
        label: 'direct',
        color: const Color(0xFF22D3EE),
      ),
      OutboundDeliveryRoute.irohRelay => (
        label: 'Iroh relay',
        color: const Color(0xFFC084FC),
      ),
      OutboundDeliveryRoute.conestRelay => (
        label: 'relay',
        color: const Color(0xFFFBBF24),
      ),
      OutboundDeliveryRoute.unknown => (
        label: 'routing',
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

class _MessageRouteChip extends StatelessWidget {
  const _MessageRouteChip({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final kind = message.transportKind;
    final path = message.transportPath;
    if (kind == null || path == null) return const SizedBox.shrink();
    final label = switch ((kind, path)) {
      (TransportKind.lan, _) => 'LAN',
      (TransportKind.iroh, TransportPathKind.direct) => 'direct',
      (TransportKind.iroh, TransportPathKind.relayed) => 'Iroh relay',
      (TransportKind.conestRelay, TransportPathKind.storeForward) =>
        'Conest relay',
      (TransportKind.optical, _) => 'optical',
      (TransportKind.deltaChat, _) => 'Delta',
      (TransportKind.reticulum, _) => 'Reticulum',
      (TransportKind.localSend, _) => 'LocalSend',
      _ => kind.label,
    };
    return Tooltip(
      message: message.transportDetail ?? label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: 0.42)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600),
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
        '$position',
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
    // nightly.11: when the libmpv platform impl failed to initialize at
    // app boot (libmpv missing on this desktop), don't even try inline
    // playback — instantly route to xdg-open / start / open. Avoids the
    // crash that battle-tested users on Linux without libmpv hit.
    if (!_mediaKitAvailable && (Platform.isLinux || Platform.isWindows)) {
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
        await Process.start('xdg-open', [widget.cachePath]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [widget.cachePath]);
      } else if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', widget.cachePath]);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // Best-effort; the error UI already shows the underlying problem.
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
              tooltip: 'Save',
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
                        'Could not play this video: $_initError',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _openInSystemPlayer,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open in default player'),
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
        'You left',
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
      state.label,
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
        border: Border(left: BorderSide(color: borderColor, width: 3)),
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
                  'Replying to $senderLabel',
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
            tooltip: 'Cancel reply',
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
