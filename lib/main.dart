import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'src/messenger_controller.dart';
import 'src/models.dart';
import 'src/qr_scan_screen.dart';
import 'src/relay_client.dart';
import 'src/storage.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final instanceLock = AppInstanceLock();
  if (!await instanceLock.acquire()) {
    runApp(const ConestAlreadyRunningApp());
    return;
  }
  final controller = MessengerController(
    vaultStore: VaultStore(),
    relayClient: const RelayClient(),
  );
  await controller.initialize();
  runApp(ConestApp(controller: controller, instanceLock: instanceLock));
}

class ConestAlreadyRunningApp extends StatelessWidget {
  const ConestAlreadyRunningApp({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = ConestPalette();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Conest',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: palette.paper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: palette.ember,
          surface: palette.paper,
        ),
        fontFamily: 'monospace',
        useMaterial3: true,
      ),
      home: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [palette.paperStrong, palette.paper, palette.paper],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Center(
            child: Card(
              elevation: 0,
              color: palette.paperStrong,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(color: palette.stroke),
              ),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_clock, color: palette.ember, size: 34),
                      const SizedBox(height: 18),
                      Text(
                        'Conest is already running',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Close the existing Conest window first. A second instance would race the local relay port and encrypted vault.',
                        style: TextStyle(color: palette.inkSoft, height: 1.35),
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
  }
}

class ConestApp extends StatefulWidget {
  const ConestApp({
    super.key,
    required this.controller,
    required this.instanceLock,
  });

  final MessengerController controller;
  final AppInstanceLock instanceLock;

  @override
  State<ConestApp> createState() => _ConestAppState();
}

class _ConestAppState extends State<ConestApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.setAppForegroundState(true);
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
    widget.controller.dispose();
    unawaited(widget.instanceLock.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ConestPalette();
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Conest',
          theme: ThemeData(
            brightness: Brightness.light,
            scaffoldBackgroundColor: palette.paper,
            colorScheme: ColorScheme.fromSeed(
              seedColor: palette.ember,
              surface: palette.paper,
            ),
            fontFamily: 'monospace',
            useMaterial3: true,
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: palette.paperStrong,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: palette.stroke),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: palette.stroke),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: palette.ember, width: 1.4),
              ),
            ),
          ),
          home: widget.controller.isReady
              ? widget.controller.hasIdentity
                    ? HomeScreen(
                        controller: widget.controller,
                        palette: palette,
                      )
                    : OnboardingScreen(
                        controller: widget.controller,
                        palette: palette,
                      )
              : SplashScreen(palette: palette),
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
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [palette.paperStrong, palette.paper, palette.paper],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Center(child: CircularProgressIndicator()),
      ),
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
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [palette.paperStrong, palette.paper, palette.paper],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
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
                                  color: palette.ink,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Pair by scanning a QR invite or by sharing only the current codephrase, deliver over LAN first, and continue over the internet through relay routes when LAN disappears.',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: palette.inkSoft, height: 1.4),
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
                                ?.copyWith(color: palette.inkSoft, height: 1.4),
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
                                style: Theme.of(context).textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'The local relay port is used for nearby LAN delivery, codephrase pairing, and desktop relay mode. The internet relay is optional but needed once peers leave the LAN.',
                                style: Theme.of(context).textTheme.bodyMedium
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
                                    : const Icon(Icons.shield_moon_outlined),
                                label: const Text('Create encrypted device'),
                              ),
                              if (widget.controller.statusMessage != null) ...[
                                const SizedBox(height: 14),
                                Text(
                                  widget.controller.statusMessage!,
                                  style: Theme.of(context).textTheme.bodySmall
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
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _selectedContactId;
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

  bool _replyTargetMatchesContact(ContactRecord contact) {
    final target = _replyTarget;
    if (target == null) {
      return false;
    }
    return target.senderDeviceId == contact.deviceId ||
        target.recipientDeviceId == contact.deviceId;
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

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => SettingsDialog(
        controller: widget.controller,
        palette: widget.palette,
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
    if (!kDebugMode) {
      return;
    }
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

  Future<void> _sendLanLobbyMessage() async {
    final body = _composerController.text.trim();
    if (body.isEmpty) {
      return;
    }
    _composerController.clear();
    await widget.controller.sendLanLobbyMessage(body);
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final selectedContact = _selectedContact;
    final lanLobbySelected = _lanLobbySelected && selectedContact == null;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [palette.paperStrong, palette.paper, palette.paper],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: PopScope(
          canPop: selectedContact == null && !lanLobbySelected,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && (_selectedContactId != null || _lanLobbySelected)) {
              setState(() {
                _selectedContactId = null;
                _lanLobbySelected = false;
              });
            }
          },
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth > 920;
                if (!isWide && selectedContact != null) {
                  return _ChatPanel(
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
                        lanLobbySelected: lanLobbySelected,
                        onAddContact: _showAddContact,
                        onLanLobbySelected: () {
                          setState(() {
                            _selectedContactId = null;
                            _lanLobbySelected = true;
                            _replyTarget = null;
                          });
                          unawaited(widget.controller.markLanLobbyRead());
                        },
                        onContactSelected: (contact) {
                          setState(() {
                            _lanLobbySelected = false;
                            _selectedContactId = contact.deviceId;
                            if (!_replyTargetMatchesContact(contact)) {
                              _replyTarget = null;
                            }
                          });
                          unawaited(
                            widget.controller.markConversationRead(
                              contact.deviceId,
                            ),
                          );
                        },
                        onContactProfile: _showContactProfile,
                        onShowDebug: kDebugMode ? _showDebugMenu : null,
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
                            : selectedContact == null
                            ? _EmptyChatState(palette: palette)
                            : _ChatPanel(
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
    required this.lanLobbySelected,
    required this.onAddContact,
    required this.onLanLobbySelected,
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
  final bool lanLobbySelected;
  final VoidCallback onAddContact;
  final VoidCallback onLanLobbySelected;
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
    final internetRelayLabel = identity.hasInternetRelay
        ? identity.configuredRelays.length == 1
              ? 'internet ${identity.primaryRelayRoute?.label}'
              : 'internet ${identity.primaryRelayRoute?.label} +${identity.configuredRelays.length - 1}'
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
                        color: palette.ink,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        identity.displayName.characters.first.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
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
              color: lanLobbySelected
                  ? palette.ink.withValues(alpha: 0.08)
                  : palette.paperStrong,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: lanLobbySelected ? palette.ember : palette.stroke,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: palette.ember.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.forum_outlined, color: palette.ember),
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
                      color: selected
                          ? palette.ink.withValues(alpha: 0.08)
                          : palette.paperStrong,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: selected ? palette.ember : palette.stroke,
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

class _ChatPanel extends StatelessWidget {
  const _ChatPanel({
    required this.controller,
    required this.palette,
    required this.contact,
    required this.composerController,
    required this.replyTarget,
    required this.onCancelReply,
    required this.onReplyToMessage,
    required this.onSend,
    required this.onShowProfile,
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
  final VoidCallback? onBack;

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

  @override
  Widget build(BuildContext context) {
    final messages = controller.messagesFor(contact.deviceId);
    final unreadCount = controller.unreadCountFor(contact.deviceId);
    if (controller.isAppForeground) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          controller.refreshConversationReachabilityIfStale(contact.deviceId),
        );
      });
    }
    if (unreadCount > 0 && controller.isAppForeground) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(controller.markConversationRead(contact.deviceId));
      });
    }
    final reachabilityState = controller.reachabilityStateFor(contact.deviceId);
    final activeReplyTarget =
        replyTarget != null &&
            (replyTarget!.senderDeviceId == contact.deviceId ||
                replyTarget!.recipientDeviceId == contact.deviceId)
        ? replyTarget
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
                    _StatusChip(
                      label: 'LAN first',
                      palette: palette,
                      icon: Icons.compare_arrows,
                    ),
                    IconButton(
                      onPressed: onShowProfile,
                      icon: const Icon(Icons.badge_outlined),
                      tooltip: 'Contact profile',
                    ),
                  ];
                  if (!compactHeader) {
                    return Row(
                      children: [
                        if (onBack != null)
                          IconButton(
                            onPressed: onBack,
                            icon: const Icon(Icons.arrow_back),
                          ),
                        Expanded(child: title),
                        const SizedBox(width: 12),
                        ...controls.expand(
                          (widget) => [widget, const SizedBox(width: 8)],
                        ),
                      ]..removeLast(),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (onBack != null)
                            IconButton(
                              onPressed: onBack,
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
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(18),
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[messages.length - index - 1];
                  final outbound = message.outbound;
                  final unread = controller.isUnreadMessage(
                    contact.deviceId,
                    message,
                  );
                  return Align(
                    alignment: outbound
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: GestureDetector(
                      onDoubleTap: () async {
                        if (outbound) {
                          await _editMessage(context, message);
                        } else {
                          onReplyToMessage(message);
                        }
                      },
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 520),
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: outbound ? palette.ink : palette.paper,
                          borderRadius: BorderRadius.circular(18),
                          border: outbound || !unread
                              ? null
                              : Border.all(
                                  color: palette.ember.withValues(alpha: 0.45),
                                ),
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
                                      senderLabel: _replyReferenceLabel(
                                        message,
                                      ),
                                      snippet: message.replySnippet!,
                                    ),
                                    const SizedBox(height: 10),
                                  ],
                                  Text(
                                    message.body,
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(
                                          color: outbound
                                              ? Colors.white
                                              : palette.ink,
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
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: outbound
                                            ? Colors.white70
                                            : palette.inkSoft,
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
                                          color: palette.ember,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ],
                                if (message.isEdited) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    'edited',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: outbound
                                              ? Colors.white70
                                              : palette.inkSoft,
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
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                                PopupMenuButton<String>(
                                  tooltip: 'Message actions',
                                  icon: Icon(
                                    Icons.more_horiz,
                                    size: 18,
                                    color: outbound
                                        ? Colors.white70
                                        : palette.inkSoft,
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
                                    if (outbound &&
                                        message.state == DeliveryState.pending)
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
                      onCancel: onCancelReply,
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: composerController,
                          minLines: 1,
                          maxLines: 5,
                          decoration: InputDecoration(
                            hintText: activeReplyTarget == null
                                ? 'Write an encrypted message'
                                : 'Write a reply',
                          ),
                          onSubmitted: (_) => onSend(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: onSend,
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
                              color: outbound ? palette.ink : palette.paper,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: outbound
                                    ? palette.ink
                                    : unread
                                    ? palette.ember.withValues(alpha: 0.45)
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
                                            ? Colors.white70
                                            : palette.inkSoft,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  message.body,
                                  style: Theme.of(context).textTheme.bodyLarge
                                      ?.copyWith(
                                        color: outbound
                                            ? Colors.white
                                            : palette.ink,
                                        height: 1.35,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  formatTimestamp(message.createdAt),
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: outbound
                                            ? Colors.white70
                                            : palette.inkSoft,
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
                                          color: palette.ember,
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
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _aliasController = TextEditingController(text: widget.contact.alias);
    _bioController = TextEditingController(text: widget.contact.bio);
  }

  @override
  void dispose() {
    _aliasController.dispose();
    _bioController.dispose();
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
      final checks = await widget.controller.checkContactRoutes(widget.contact);
      if (mounted) {
        setState(() => _checks = checks);
      }
    });
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
                      _RouteHealthTile(check: check, palette: widget.palette),
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
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [palette.paperStrong, palette.paper, palette.paper],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
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
                                    eyeStyle: QrEyeStyle(color: palette.ink),
                                    dataModuleStyle: QrDataModuleStyle(
                                      color: palette.ink,
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
                      eyeStyle: QrEyeStyle(color: palette.ink),
                      dataModuleStyle: QrDataModuleStyle(color: palette.ink),
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
    required this.palette,
  });

  final MessengerController controller;
  final ConestPalette palette;

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
    await _run(widget.controller.resetIdentity);
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
                    Text(
                      'Relay',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (report != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: widget.palette.paper,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: widget.palette.stroke),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              report.summary,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 10),
                            for (final note in report.notes)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Text(
                                  note,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: widget.palette.inkSoft),
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () =>
                                _run(widget.controller.checkRelayAvailability),
                      icon: const Icon(Icons.network_check),
                      label: const Text('Check Availability'),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      value: identity.relayModeEnabled,
                      onChanged: _busy
                          ? null
                          : (value) => _run(
                              () => widget.controller.updateRelayModeEnabled(
                                value,
                              ),
                            ),
                      title: const Text('Run this device as a relay'),
                      subtitle: const Text(
                        'Allow trusted contacts to use this device as a relay. LAN pairing and direct receive stay available while the app is open.',
                      ),
                    ),
                    SwitchListTile.adaptive(
                      value: identity.autoUseContactRelays,
                      onChanged: _busy
                          ? null
                          : (value) => _run(
                              () => widget.controller
                                  .updateAutoUseContactRelays(value),
                            ),
                      title: const Text('Auto-use contacts as relays'),
                      subtitle: Text(
                        'Use relay-capable routes learned from contacts automatically. ${contactRelays.length} candidate route(s) are available right now.',
                      ),
                    ),
                    SwitchListTile.adaptive(
                      value: identity.notificationsEnabled,
                      onChanged: _busy
                          ? null
                          : (value) => _run(
                              () => widget.controller
                                  .updateNotificationsEnabled(value),
                            ),
                      title: const Text('Message notifications'),
                      subtitle: const Text(
                        'Show a system notification when a direct message arrives. Android may ask for notification permission.',
                      ),
                    ),
                    if (!kIsWeb && Platform.isAndroid)
                      SwitchListTile.adaptive(
                        value: identity.androidBackgroundRuntimeEnabled,
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
                          'Keeps a foreground notification so Conest can keep polling and receiving while backgrounded. If Android battery/background access is blocked, notifications can be late or never arrive.',
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
                                  await widget.controller.updateLocalRelayPort(
                                    port,
                                  );
                                }),
                          child: const Text('Save Port'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Configured relays',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (configuredRelays.isEmpty)
                      Text(
                        'No relays added yet.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.palette.inkSoft,
                        ),
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final relay in configuredRelays)
                            InputChip(
                              label: Text(relay.label),
                              onDeleted: _busy
                                  ? null
                                  : () => _run(
                                      () =>
                                          widget.controller.removeRelay(relay),
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
                              hintText:
                                  'host auto-detects TCP/UDP; udp://host:port forces UDP',
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
                                    host: _relayHostController.text.trim(),
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
                    const SizedBox(height: 24),
                    Text(
                      'Identity',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
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
                                  () => widget.controller.updateDisplayName(
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
                    SelectableText(
                      'account ${identity.accountId}\ndevice ${identity.deviceId}\nsafety ${identity.safetyNumber}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: widget.palette.inkSoft,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _confirmReset,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Reset App Identity'),
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
        color: palette.paper,
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
        color: palette.paper,
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
  const _RouteHealthTile({required this.check, required this.palette});

  final PeerRouteHealth check;
  final ConestPalette palette;

  @override
  Widget build(BuildContext context) {
    final available = check.available;
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
            available ? Icons.check_circle_outline : Icons.error_outline,
            color: available ? Colors.green.shade700 : Colors.orange.shade800,
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
                  available
                      ? 'available${latency == null ? '' : ' • ${latency.inMilliseconds}ms'}'
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
            available ? 'usable' : 'skip',
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
          Icon(icon, size: 16, color: palette.inkSoft),
          const SizedBox(width: 8),
          if (expand) Expanded(child: labelWidget) else labelWidget,
        ],
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
        color: palette.ember,
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
      ContactReachabilityState.online => const Color(0xFF2F8F5B),
      ContactReachabilityState.seenRecently => palette.ember,
      ContactReachabilityState.known => palette.inkSoft,
      ContactReachabilityState.unknown => const Color(0xFF9A6A6A),
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
    final baseColor = outbound ? Colors.white : palette.ink;
    final borderColor = outbound
        ? Colors.white24
        : palette.ember.withValues(alpha: 0.4);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: outbound ? Colors.white10 : palette.paperStrong,
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
                    color: palette.ember,
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

class ConestPalette {
  final Color paper = const Color(0xFFF4EFE7);
  final Color paperStrong = const Color(0xFFF9F5EF);
  final Color ink = const Color(0xFF1E2430);
  final Color inkSoft = const Color(0xFF5F6673);
  final Color ember = const Color(0xFFB65C34);
  final Color stroke = const Color(0xFFD8CEC1);
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
