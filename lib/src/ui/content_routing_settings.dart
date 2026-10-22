import 'package:flutter/material.dart';

import '../app_locales.dart';
import '../content_routing.dart';
import '../transport_models.dart';

/// Settings > Connectivity: what may go over which transport. A choice of
/// presets for everyone; with [showTable] (Advanced mode), the table
/// behind them.
class ContentRoutingSettings extends StatelessWidget {
  const ContentRoutingSettings({
    super.key,
    required this.refusals,
    required this.showTable,
    required this.onChanged,
  });

  final ContentRefusals refusals;
  final bool showTable;
  final ValueChanged<ContentRefusals> onChanged;

  /// Classes a person may leave out (control and receipts never).
  static const refusable = [
    ContentClass.text,
    ContentClass.ownSync,
    ContentClass.history,
    ContentClass.fileSmall,
    ContentClass.fileMedium,
    ContentClass.fileLarge,
    ContentClass.callSignal,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    return Builder(
      builder: (context) {
        final preset = ContentRoutingPreset.of(refusals);
        String label(ContentRoutingPreset preset) => switch (preset) {
          ContentRoutingPreset.everything => l10n.contentRoutingEverything,
          ContentRoutingPreset.messagesAndSmallFiles =>
            l10n.contentRoutingMessagesAndSmallFiles,
          ContentRoutingPreset.messagesOnly => l10n.contentRoutingMessagesOnly,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.contentRoutingTitle),
              subtitle: Text(l10n.contentRoutingHelp),
            ),
            DropdownButton<ContentRoutingPreset>(
              key: const ValueKey('content-routing-preset'),
              isExpanded: true,
              value: preset,
              // A hand-made table matches no preset.
              hint: Text(l10n.contentRoutingCustom),
              onChanged: (value) {
                if (value != null) onChanged(value.refusals);
              },
              items: [
                for (final option in ContentRoutingPreset.values)
                  DropdownMenuItem(value: option, child: Text(label(option))),
              ],
            ),
            if (showTable)
              ExpansionTile(
                key: const ValueKey('content-routing-table'),
                tilePadding: EdgeInsets.zero,
                title: Text(l10n.contentRoutingByTransport),
                children: [_table(context, refusals)],
              ),
          ],
        );
      },
    );
  }

  Widget _table(BuildContext context, ContentRefusals refusals) {
    final l10n = l10nOf(context);
    String header(ContentClass content) => switch (content) {
      ContentClass.text => l10n.contentClassText,
      ContentClass.ownSync => l10n.contentClassOwnSync,
      ContentClass.history => l10n.contentClassHistory,
      ContentClass.fileSmall => l10n.contentClassFileSmall,
      ContentClass.fileMedium => l10n.contentClassFileMedium,
      ContentClass.fileLarge => l10n.contentClassFileLarge,
      ContentClass.callSignal => l10n.contentClassCallSignal,
      _ => content.name,
    };
    final kinds = [
      for (final kind in TransportKind.values)
        if (kind.userVisible) kind,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 12,
        headingRowHeight: 40,
        columns: [
          const DataColumn(label: SizedBox.shrink()),
          for (final content in refusable)
            DataColumn(label: Text(header(content))),
        ],
        rows: [
          for (final kind in kinds)
            DataRow(
              cells: [
                DataCell(Text(kind.label)),
                for (final content in refusable)
                  DataCell(
                    transportCarries(kind, content)
                        ? Checkbox(
                            key: ValueKey(
                              'content-${kind.name}-${content.name}',
                            ),
                            value: !refusals.refuses(kind, content),
                            onChanged: (allowed) => onChanged(
                              refusals.withRefused(
                                kind,
                                content,
                                allowed != true,
                              ),
                            ),
                          )
                        : Tooltip(
                            message: l10n.contentRoutingCannotCarry,
                            child: const Checkbox(
                              value: false,
                              onChanged: null,
                            ),
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
