import 'dart:io';

import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../build_info.dart';
import '../messenger_controller.dart';
import '../net/cable_links.dart';
import '../net/link_events.dart';
import '../net/link_interfaces.dart';
import '../net/link_watcher.dart';

/// What a link is called on the page, from its kind and name: tethering over
/// USB (the phone shows up as `usb0`, `rndis0`, `ncm0`, `enx<mac>` or a USB
/// Ethernet adapter), a cable, Wi-Fi, or anything else.
String cableLinkKindLabel(BuildContext context, CableLinkView link) {
  final l10n = l10nOf(context);
  final name = link.name.toLowerCase();
  final usb = RegExp(
    r'^(usb|rndis|ncm|enx|enp\d+s\d+f\d+u)|ndis',
  ).hasMatch(name);
  return switch (link.kind) {
    LinkKind.cable when usb => l10n.cableLinksKindUsb,
    LinkKind.cable => l10n.cableLinksKindCable,
    LinkKind.wifi => l10n.cableLinksKindWifi,
    LinkKind.other => l10n.cableLinksKindOther,
  };
}

/// Settings → Connectivity: one entry that opens the cable and USB page.
/// Behind the canary flag until it is promoted.
class CableLinksPanel extends StatefulWidget {
  const CableLinksPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<CableLinksPanel> createState() => _CableLinksPanelState();
}

class _CableLinksPanelState extends State<CableLinksPanel> {
  late final Future<ConestBuildInfo> _info = ConestBuildInfo.load();

  @override
  Widget build(BuildContext context) {
    final cable = widget.controller.cableLinks;
    if (cable == null) return const SizedBox.shrink();
    return FutureBuilder<ConestBuildInfo>(
      future: _info,
      builder: (context, snapshot) {
        if (snapshot.data?.canaryFeatures != true) {
          return const SizedBox.shrink();
        }
        final l10n = l10nOf(context);
        return ListenableBuilder(
          listenable: Listenable.merge([widget.controller, cable.revision]),
          builder: (context, _) {
            final enabled =
                widget.controller.identity?.connectivity.cableLinksEnabled ??
                true;
            final names = [for (final link in cable.views) link.name];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: ListTile(
                  key: const ValueKey('cable-links-entry'),
                  leading: const Icon(Icons.usb),
                  title: Text(l10n.cableLinksTitle),
                  subtitle: Text(
                    !enabled
                        ? l10n.cableLinksOff
                        : names.isEmpty
                        ? l10n.cableLinksNone
                        : names.join(', '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text(l10n.cableLinksTitle)),
                        body: CableLinksPage(controller: widget.controller),
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

/// The page: the switch, the links with the contacts found on each, and
/// short help.
class CableLinksPage extends StatelessWidget {
  const CableLinksPage({super.key, required this.controller});

  final MessengerController controller;

  @override
  Widget build(BuildContext context) {
    final cable = controller.cableLinks;
    if (cable == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([controller, cable.revision]),
      builder: (context, _) {
        final identity = controller.identity;
        return CableLinksView(
          cable: cable,
          enabled: identity?.connectivity.cableLinksEnabled ?? true,
          onEnabledChanged: identity == null
              ? null
              : (value) => controller.updateGlobalConnectivity(
                  identity.connectivity.copyWith(cableLinksEnabled: value),
                ),
          contactName: (deviceId) =>
              controller.contactByDeviceId(deviceId)?.alias ?? deviceId,
          onOpenTetherSettings: LinkEventSources.openTetherSettings,
          showTetherButton: Platform.isAndroid,
          showLinuxHelp: Platform.isLinux,
          showWindowsHelp: Platform.isWindows,
        );
      },
    );
  }
}

/// The page's content, with everything it needs given (tests drive it
/// without a controller). While it is shown the Android fallback may look at
/// the links.
class CableLinksView extends StatefulWidget {
  const CableLinksView({
    super.key,
    required this.cable,
    required this.enabled,
    required this.onEnabledChanged,
    required this.contactName,
    this.onOpenTetherSettings,
    this.showTetherButton = false,
    this.showLinuxHelp = false,
    this.showWindowsHelp = false,
  });

  final CableLinks cable;
  final bool enabled;
  final ValueChanged<bool>? onEnabledChanged;
  final String Function(String deviceId) contactName;
  final Future<bool> Function()? onOpenTetherSettings;
  final bool showTetherButton;
  final bool showLinuxHelp;
  final bool showWindowsHelp;

  @override
  State<CableLinksView> createState() => _CableLinksViewState();
}

class _CableLinksViewState extends State<CableLinksView> {
  @override
  void initState() {
    super.initState();
    widget.cable.watcher.setPageOpen(true);
    // What is shown is current: a look now.
    widget.cable.watcher.note(LinkEventSource.manual);
  }

  @override
  void dispose() {
    widget.cable.watcher.setPageOpen(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final links = widget.cable.views;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile.adaptive(
          key: const ValueKey('cable-links-enabled'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.cableLinksSwitchTitle),
          subtitle: Text(l10n.cableLinksSwitchHint),
          value: widget.enabled,
          onChanged: widget.onEnabledChanged,
        ),
        if (widget.enabled) ...[
          const SizedBox(height: 8),
          if (links.isEmpty)
            Text(l10n.cableLinksNone, key: const ValueKey('cable-links-none')),
          for (final link in links)
            ListTile(
              key: ValueKey('cable-link-${link.name}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                link.kind == LinkKind.wifi ? Icons.wifi : Icons.usb,
              ),
              title: Text(
                '${cableLinkKindLabel(context, link)} · ${link.name}',
              ),
              // Only IPv4 is shown; nothing link-scoped beyond 169.254.
              subtitle: Text(
                [
                  link.addresses.join(', '),
                  if (link.pingable)
                    link.contactDeviceIds.isEmpty
                        ? l10n.cableLinksLooking
                        : l10n.cableLinksContacts(
                            [
                              for (final id in link.contactDeviceIds)
                                widget.contactName(id),
                            ].join(', '),
                          ),
                ].join('\n'),
              ),
              isThreeLine: link.pingable,
            ),
          if (widget.showTetherButton) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton(
                key: const ValueKey('cable-links-open-tethering'),
                onPressed: widget.onOpenTetherSettings == null
                    ? null
                    : () => widget.onOpenTetherSettings!(),
                child: Text(l10n.cableLinksOpenTethering),
              ),
            ),
          ],
        ],
        const SizedBox(height: 16),
        Text(l10n.cableLinksHelpPlug),
        if (widget.showLinuxHelp) ...[
          const SizedBox(height: 8),
          Text(l10n.cableLinksHelpLinux),
        ],
        if (widget.showWindowsHelp) ...[
          const SizedBox(height: 8),
          Text(l10n.cableLinksHelpWindows),
        ],
      ],
    );
  }
}
