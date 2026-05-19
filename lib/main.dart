import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'src/app_storage.dart';
import 'src/build_info.dart';
import 'src/conest_theme.dart';
import 'src/media_picker_sheet.dart';
import 'src/messenger_controller.dart';
import 'src/models.dart';
import 'src/platform_bridge.dart';
import 'src/qr_scan_screen.dart';
import 'src/relay_client.dart';
import 'src/storage.dart';
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
  final buildInfo = await ConestBuildInfo.load();
  final platformBridge = PlatformBridge();
  final controller = MessengerController(
    vaultStore: vaultStore,
    relayClient: const RelayClient(),
    platformBridge: platformBridge,
  );
  final updateService = UpdateService(
    buildInfo: buildInfo,
    platformBridge: platformBridge,
    applicationSupportDirectoryProvider: () async => profile.dataRoot,
    tempDirectoryProvider: () async => profile.tempRoot,
    automaticStartupChecksEnabled: profile.automaticStartupChecksEnabled,
  );
  await controller.initialize();
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

  /// Nightly / stable / debug — surfaced so the chrome can gate the
  /// "Run Debug Tests" button on the nightly channel (the user installs
  /// nightly builds on real devices for battle testing; stable users
  /// don't see it).
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

  Future<void> _showDebugMenu() async {
    // Channel gating happens at the button (HomeScreen.build), so
    // _showDebugMenu trusts its caller. The old `if (!kDebugMode) return`
    // here defeated the nightly-channel button gate added in the prior
    // commit: button visible but tap did nothing.
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
    final body = _composerController.text.trim();
    if (contact == null || body.isEmpty) {
      return;
    }
    final replyTarget = _replyTarget;
    _composerController.clear();
    setState(() => _replyTarget = null);
    await widget.controller.sendMessage(
      contact: contact,
      body: body,
      replyTo: replyTarget,
    );
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

  Future<void> _openMediaPicker() async {
    final contact = _selectedContact;
    if (contact == null) {
      return;
    }
    final result = await showMediaPickerSheet(
      context: context,
      palette: widget.palette,
      maxBytes: MessengerController.maxAttachmentSizeBytes,
    );
    if (!mounted || result == null) {
      return;
    }
    if (result.fallbackToFilePicker) {
      await _pickAndSendAttachment();
      return;
    }
    if (result.items != null) {
      await _sendMultipleAttachments(contact: contact, items: result.items!);
      return;
    }
    await _sendAttachmentBytes(
      contact: contact,
      bytes: result.bytes!,
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
        withData: true,
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
        <({Uint8List bytes, String fileName, String mimeType})>[];
    for (final file in picked.files) {
      Uint8List? bytes = file.bytes;
      // Desktop picker often returns a path instead of bytes.
      if (bytes == null && file.path != null) {
        try {
          bytes = await File(file.path!).readAsBytes();
        } catch (error) {
          widget.controller.setStatus(
            'Could not read ${file.name}: $error',
          );
          continue;
        }
      }
      if (bytes == null) {
        widget.controller.setStatus(
          '${file.name}: picker returned no data.',
        );
        continue;
      }
      items.add(
        (
          bytes: bytes,
          fileName: file.name,
          mimeType: _guessMimeType(file.name),
        ),
      );
    }
    await _sendMultipleAttachments(contact: contact, items: items);
  }

  Future<void> _sendAttachmentBytes({
    required ContactRecord contact,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) {
    return _sendMultipleAttachments(
      contact: contact,
      items: [(bytes: bytes, fileName: fileName, mimeType: mimeType)],
    );
  }

  Future<void> _sendMultipleAttachments({
    required ContactRecord contact,
    required List<({Uint8List bytes, String fileName, String mimeType})> items,
  }) async {
    if (items.isEmpty) {
      return;
    }
    final cap = MessengerController.maxAttachmentsPerSend;
    final clamped = items.take(cap).toList(growable: false);
    if (items.length > cap) {
      widget.controller.setStatus(
        'Only the first $cap files will be sent (got ${items.length}).',
      );
    }
    final caption = _composerController.text.trim();
    if (caption.isNotEmpty) {
      _composerController.clear();
    }
    final capMb = MessengerController.maxAttachmentSizeBytes ~/ (1024 * 1024);
    for (var i = 0; i < clamped.length; i++) {
      final item = clamped[i];
      if (item.bytes.length > MessengerController.maxAttachmentSizeBytes) {
        widget.controller.setStatus(
          '${item.fileName} skipped: ${(item.bytes.length / (1024 * 1024)).toStringAsFixed(1)} '
          'MB exceeds the $capMb MB cap.',
        );
        continue;
      }
      try {
        await widget.controller.sendAttachment(
          contact: contact,
          bytes: item.bytes,
          fileName: item.fileName,
          mimeType: item.mimeType,
          caption: i == 0 ? caption : '',
        );
      } catch (error) {
        widget.controller.setStatus(
          'Send failed for ${item.fileName}: $error',
        );
      }
    }
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
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: palette.appGradient),
        child: PopScope(
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
                    onCancelReply: () => setState(() => _replyTarget = null),
                    onReplyToMessage: (message) =>
                        setState(() => _replyTarget = message),
                    onShowProfile: () => _showContactProfile(selectedContact),
                    onSend: _sendCurrentMessage,
                    onAttach: _openMediaPicker,
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
                    onCancelReply: () => setState(() => _replyTarget = null),
                    onReplyToMessage: (message) =>
                        setState(() => _replyTarget = message),
                    onShowDetails: () => _showGroupDetails(selectedGroup),
                    onSend: _sendCurrentGroupMessage,
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
                      child: _Sidebar(
                        controller: widget.controller,
                        palette: palette,
                        selectedContactId: _selectedContactId,
                        selectedGroupId: _selectedGroupId,
                        lanLobbySelected: lanLobbySelected,
                        onAddContact: _showAddContact,
                        onCreateGroup: _showCreateGroup,
                        onLanLobbySelected: () {
                          setState(() {
                            _selectedContactId = null;
                            _selectedGroupId = null;
                            _lanLobbySelected = true;
                            _replyTarget = null;
                          });
                          unawaited(widget.controller.markLanLobbyRead());
                        },
                        onGroupSelected: (group) {
                          setState(() {
                            _lanLobbySelected = false;
                            _selectedContactId = null;
                            _selectedGroupId = group.groupId;
                            if (!_replyTargetMatchesGroup(group)) {
                              _replyTarget = null;
                            }
                          });
                        },
                        onGroupDetails: _showGroupDetails,
                        onContactSelected: (contact) {
                          setState(() {
                            _lanLobbySelected = false;
                            _selectedGroupId = null;
                            _selectedContactId = contact.deviceId;
                            if (!_replyTargetMatchesContact(contact)) {
                              _replyTarget = null;
                            }
                          });
                        },
                        onContactProfile: _showContactProfile,
                        // Surface the Run Debug Tests button on nightly
                        // builds (and any debug build) so the user can
                        // exercise runDebugSelfTest on real hardware
                        // without rebuilding. Hidden on stable to avoid
                        // confusing end users.
                        onShowDebug:
                            (widget.buildInfo.channel ==
                                    UpdateChannel.nightly ||
                                kDebugMode)
                            ? _showDebugMenu
                            : null,
                        onPoll: widget.controller.pollNow,
                        onShowSettings: _showSettings,
                        onShowInvite: _showInvite,
                      ),
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
                                key: ValueKey('group-${selectedGroup.groupId}'),
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
                              ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.palette,
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
    this.onShowDebug,
  });

  final MessengerController controller;
  final ConestPalette palette;
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
  final Future<void> Function()? onShowDebug;

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
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: palette.outboundBubble,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        identity.displayName.characters.first.toUpperCase(),
                        style: TextStyle(
                          color: palette.outboundText,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
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
        if (controller.contacts.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _EmptyContactsState(palette: palette),
          )
        else
          for (var index = 0; index < controller.contacts.length; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final contact = controller.contacts[index];
                final preview = controller.lastMessageFor(contact.deviceId);
                final unreadCount = controller.unreadCountFor(contact.deviceId);
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
                                contact.alias,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                            Text(
                              contact.shortSafetyNumber,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(color: palette.inkSoft),
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
                              onPressed: () => onContactProfile(contact),
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
                );
              },
            ),
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
    this.onBack,
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
  final VoidCallback? onBack;

  @override
  State<_GroupChatPanel> createState() => _GroupChatPanelState();
}

class _GroupChatPanelState extends State<_GroupChatPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _messageListKey = GlobalKey();
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  bool _didInitialPosition = false;
  bool _initialPositionScheduled = false;
  bool _readSweepScheduled = false;

  MessengerController get controller => widget.controller;
  ConestPalette get palette => widget.palette;
  GroupRecord get group => widget.group;

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
    }
    _scheduleInitialPosition();
    _scheduleReadSweep();
  }

  @override
  void dispose() {
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPositionScheduled = false;
      if (!mounted || _didInitialPosition) {
        return;
      }
      final messages = controller.messagesForGroup(group.groupId);
      if (messages.isEmpty) {
        _didInitialPosition = true;
        return;
      }
      if (!_scrollController.hasClients) {
        _scheduleInitialPosition();
        return;
      }
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      _didInitialPosition = true;
      _scheduleReadSweep();
    });
  }

  void _scheduleReadSweep() {
    if (!mounted ||
        !_didInitialPosition ||
        _readSweepScheduled ||
        !controller.isAppForeground) {
      return;
    }
    _readSweepScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _readSweepScheduled = false;
      if (!mounted || !controller.isAppForeground) {
        return;
      }
      final latestVisibleUnread = _latestVisibleUnreadMessage();
      if (latestVisibleUnread == null) {
        return;
      }
      await controller.markGroupReadThroughMessage(
        group.groupId,
        latestVisibleUnread,
      );
    });
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

  Widget _buildMessageBubble(BuildContext context, ChatMessage message) {
    final outbound = message.outbound;
    final unread = controller.isUnreadGroupMessage(group.groupId, message);
    return Align(
      key: _messageKeyFor(message.id),
      alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onDoubleTap: () => widget.onReplyToMessage(message),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: outbound ? palette.outboundBubble : palette.inboundBubble,
            borderRadius: BorderRadius.circular(18),
            border: outbound || !unread
                ? null
                : Border.all(color: palette.unread.withValues(alpha: 0.55)),
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
            Expanded(
              child: ListView(
                key: _messageListKey,
                controller: _scrollController,
                padding: const EdgeInsets.all(18),
                children: [
                  for (final message in messages)
                    _buildMessageBubble(context, message),
                ],
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
    this.onBack,
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
  final VoidCallback? onBack;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _messageListKey = GlobalKey();
  final Map<String, GlobalKey> _messageKeys = <String, GlobalKey>{};
  bool _didInitialPosition = false;
  bool _initialPositionScheduled = false;
  bool _readSweepScheduled = false;

  MessengerController get controller => widget.controller;
  ConestPalette get palette => widget.palette;
  ContactRecord get contact => widget.contact;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant _ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contact.deviceId != widget.contact.deviceId) {
      _messageKeys.clear();
      _didInitialPosition = false;
      _initialPositionScheduled = false;
    }
    _scheduleInitialPosition();
    _scheduleReadSweep();
  }

  @override
  void dispose() {
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialPositionScheduled = false;
      if (!mounted || _didInitialPosition) {
        return;
      }
      final messages = controller.messagesFor(contact.deviceId);
      if (messages.isEmpty) {
        _didInitialPosition = true;
        return;
      }
      ChatMessage? firstUnread;
      for (final message in messages) {
        if (!message.outbound &&
            controller.isUnreadMessage(contact.deviceId, message)) {
          firstUnread = message;
          break;
        }
      }
      if (firstUnread != null) {
        final unreadContext = _messageKeyFor(firstUnread.id).currentContext;
        if (unreadContext == null) {
          _scheduleInitialPosition();
          return;
        }
        Scrollable.ensureVisible(
          unreadContext,
          alignment: 0.08,
          duration: Duration.zero,
        );
      } else {
        if (!_scrollController.hasClients) {
          _scheduleInitialPosition();
          return;
        }
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
      _didInitialPosition = true;
      _scheduleReadSweep();
    });
  }

  void _scheduleReadSweep() {
    if (!mounted ||
        !_didInitialPosition ||
        _readSweepScheduled ||
        !controller.isAppForeground) {
      return;
    }
    _readSweepScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _readSweepScheduled = false;
      if (!mounted || !controller.isAppForeground) {
        return;
      }
      final latestVisibleUnread = _latestVisibleUnreadMessage();
      if (latestVisibleUnread == null) {
        return;
      }
      await controller.markConversationReadThroughMessage(
        contact.deviceId,
        latestVisibleUnread,
      );
    });
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

  Widget _buildMessageBubble(BuildContext context, ChatMessage message) {
    final outbound = message.outbound;
    final unread = controller.isUnreadMessage(contact.deviceId, message);
    return Align(
      key: _messageKeyFor(message.id),
      alignment: outbound ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onDoubleTap: () async {
          if (outbound) {
            await _editMessage(context, message);
          } else {
            widget.onReplyToMessage(message);
          }
        },
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: outbound ? palette.outboundBubble : palette.inboundBubble,
            borderRadius: BorderRadius.circular(18),
            border: outbound || !unread
                ? null
                : Border.all(color: palette.unread.withValues(alpha: 0.55)),
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compactHeader = constraints.maxWidth < 560;
                  final title = Column(
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
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: palette.inkSoft),
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
            if (contact.pendingVerification)
              _PendingVerificationBanner(
                controller: controller,
                palette: palette,
                contact: contact,
              ),
            Expanded(
              child: ListView(
                key: _messageListKey,
                controller: _scrollController,
                padding: const EdgeInsets.all(18),
                children: [
                  for (final message in messages)
                    _buildMessageBubble(context, message),
                ],
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
                      IconButton(
                        onPressed: contact.canSendOutbound
                            ? widget.onAttach
                            : null,
                        icon: const Icon(Icons.attach_file_outlined),
                        tooltip: 'Attach a file or image',
                      ),
                      Expanded(
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
                                    eyeStyle: QrEyeStyle(color: palette.qrInk),
                                    dataModuleStyle: QrDataModuleStyle(
                                      color: palette.qrInk,
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
                        Text(
                          'Rotating codephrase',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: palette.inkSoft),
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          pairingSnapshot.codephrase,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Changes in ${pairingSnapshot.secondsRemaining}s',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: palette.inkSoft),
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
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    _relayHostController.dispose();
    _relayPortController.dispose();
    _localRelayPortController.dispose();
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
        }
        setState(() {
          _busy = false;
        });
      }
    }
  }

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
                              value: identity.androidBackgroundRuntimeEnabled,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _busy
                                  ? null
                                  : (value) => _run(
                                      () => widget.controller
                                          .updateAndroidBackgroundRuntimeEnabled(
                                            value,
                                          ),
                                    ),
                              title: const Text('Android background runtime'),
                              subtitle: const Text(
                                'Keeps foreground runtime active. If Android blocks background access, notifications can be late or never arrive.',
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
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
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
          ],
        );
      },
    );
  }

  IconData _themeModeIcon(ConestThemeMode mode) {
    return switch (mode) {
      ConestThemeMode.system => Icons.brightness_auto_outlined,
      ConestThemeMode.light => Icons.light_mode_outlined,
      ConestThemeMode.dark => Icons.dark_mode_outlined,
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
  String? _error;
  String? _notice;

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

  @override
  Widget build(BuildContext context) {
    final identity = widget.controller.identity;
    final contacts = widget.controller.contacts;
    final relays = widget.controller.configuredRelays;
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
  late RoutingPreference _preferred = widget.initial.preferred;

  String _resolvedLabel() {
    final effective = ContactRoutingPreferences(
      lanEnabled: _lan,
      onlineEnabled: _online,
      preferred: _preferred,
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

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.descriptor,
    required this.outbound,
    required this.palette,
    required this.controller,
  });

  final AttachmentDescriptor descriptor;
  final bool outbound;
  final ConestPalette palette;
  final MessengerController controller;

  String _formatBytes(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool get _isImage => descriptor.mimeType.startsWith('image/');

  Future<void> _saveToDisk(BuildContext context, Uint8List bytes) async {
    try {
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save ${descriptor.fileName}',
        fileName: descriptor.fileName,
        bytes: bytes,
      );
      if (path == null) {
        return;
      }
      // On desktop the file_picker writes the bytes automatically when
      // `bytes:` is supplied. On other platforms we still need to write
      // the file ourselves because the save dialog only returns a path.
      if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
        await File(path).writeAsBytes(bytes);
      }
      controller.setStatus('Saved ${descriptor.fileName} to $path.');
    } catch (error) {
      controller.setStatus('Save failed: $error');
    }
  }

  Future<void> _copyImageBytes(Uint8List bytes) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      controller.setStatus('Clipboard is not available on this platform.');
      return;
    }
    try {
      final item = DataWriterItem(suggestedName: descriptor.fileName);
      final mime = descriptor.mimeType.toLowerCase();
      if (mime == 'image/png') {
        item.add(Formats.png(bytes));
      } else if (mime == 'image/jpeg' || mime == 'image/jpg') {
        item.add(Formats.jpeg(bytes));
      } else if (mime == 'image/gif') {
        item.add(Formats.gif(bytes));
      } else if (mime == 'image/webp') {
        item.add(Formats.webp(bytes));
      } else {
        // Fall back to PNG: most paste targets understand it and the
        // browser/editor will re-encode anyway.
        item.add(Formats.png(bytes));
      }
      await clipboard.write([item]);
      controller.setStatus('Copied ${descriptor.fileName} to clipboard.');
    } catch (error) {
      controller.setStatus('Copy failed: $error');
    }
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

  void _openFullScreenImage(BuildContext context, Uint8List bytes) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _ImageViewerScreen(
          bytes: bytes,
          title: descriptor.fileName,
          palette: palette,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = controller.attachmentBytesFor(descriptor.id);
    final progress = controller.attachmentTransferProgress(descriptor.id);
    final textColor = outbound ? palette.outboundText : palette.inboundText;
    final metaColor = outbound ? palette.outboundMeta : palette.inboundMeta;
    final hasBytes = bytes != null;
    final showImage = _isImage && hasBytes;

    if (showImage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _openFullScreenImage(context, bytes),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: 640,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _AttachmentActions(
            metaColor: metaColor,
            actions: [
              _AttachmentAction(
                icon: Icons.copy_outlined,
                label: 'Copy',
                onTap: () => _copyImageBytes(bytes),
              ),
              _AttachmentAction(
                icon: Icons.download_outlined,
                label: 'Save',
                onTap: () => _saveToDisk(context, bytes),
              ),
            ],
          ),
        ],
      );
    }

    final icon = _isImage
        ? Icons.image_outlined
        : Icons.insert_drive_file_outlined;
    final statusLine = hasBytes
        ? _formatBytes(descriptor.sizeBytes)
        : (progress != null
              ? 'Transferring · ${(progress * 100).toStringAsFixed(0)}% '
                    '· ${_formatBytes(descriptor.sizeBytes)}'
              : 'Transferring · ${_formatBytes(descriptor.sizeBytes)}');
    return Container(
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
          if (hasBytes) ...[
            const SizedBox(height: 8),
            _AttachmentActions(
              metaColor: metaColor,
              actions: [
                _AttachmentAction(
                  icon: Icons.copy_outlined,
                  label: 'Copy path',
                  onTap: _copyCachePath,
                ),
                _AttachmentAction(
                  icon: Icons.download_outlined,
                  label: 'Save',
                  onTap: () => _saveToDisk(context, bytes),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AttachmentAction {
  const _AttachmentAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
}

class _AttachmentActions extends StatelessWidget {
  const _AttachmentActions({required this.metaColor, required this.actions});

  final Color metaColor;
  final List<_AttachmentAction> actions;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final action in actions)
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              foregroundColor: metaColor,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: Theme.of(context).textTheme.labelSmall,
            ),
            onPressed: () {
              action.onTap();
            },
            icon: Icon(action.icon, size: 16),
            label: Text(action.label),
          ),
      ],
    );
  }
}

class _ImageViewerScreen extends StatelessWidget {
  const _ImageViewerScreen({
    required this.bytes,
    required this.title,
    required this.palette,
  });

  final Uint8List bytes;
  final String title;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final dpr = MediaQuery.of(context).devicePixelRatio.clamp(1.0, 3.0);
          // Cap decoded width at the viewport's physical width — enough
          // for pixel-perfect rendering, far less than the source image
          // (a 30 MB photo could be 8 K × 6 K and OOM the platform
          // image codec without this).
          final cacheW = (constraints.maxWidth * dpr).round();
          return Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 6,
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                cacheWidth: cacheW,
              ),
            ),
          );
        },
      ),
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
