import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_locales.dart';
import '../messenger_controller.dart';
import '../voice_settings.dart';

bool get _desktopAudio => !kIsWeb && (Platform.isLinux || Platform.isWindows);

/// Settings → Voice: microphone and output, volumes, a microphone test,
/// how the voice is sent, processing and call sounds. Also opened from a
/// call, where changes apply at once.
class VoiceSettingsPanel extends StatefulWidget {
  const VoiceSettingsPanel({super.key, required this.controller});

  final MessengerController controller;

  @override
  State<VoiceSettingsPanel> createState() => _VoiceSettingsPanelState();
}

class _VoiceSettingsPanelState extends State<VoiceSettingsPanel> {
  List<String> _inputs = const [];
  List<String> _outputs = const [];
  Timer? _meter;
  double _level = 0;
  bool _loopback = false;
  bool _capturingKey = false;
  // A slider's value while it is dragged (saved when let go).
  final Map<Key, double> _dragging = {};
  final _keyFocus = FocusNode(debugLabel: 'push-to-talk key');

  MessengerController get _controller => widget.controller;
  VoiceSettings get _settings => _controller.voiceSettings;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDevices());
    // The meter runs while the microphone is open (a call or the test).
    _meter = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!mounted) return;
      final level = _controller.microphoneLevel;
      if ((level - _level).abs() > 0.005) setState(() => _level = level);
    });
  }

  Future<void> _loadDevices() async {
    if (!_desktopAudio) return;
    try {
      final inputs = await _controller.voiceInputDevices();
      final outputs = await _controller.voiceOutputDevices();
      if (mounted) {
        setState(() {
          _inputs = inputs;
          _outputs = outputs;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _meter?.cancel();
    _keyFocus.dispose();
    // The test never outlives the page.
    unawaited(_controller.stopMicrophoneTest());
    super.dispose();
  }

  Future<void> _update(VoiceSettings next) async {
    await _controller.updateVoiceSettings(next);
    if (mounted) setState(() {});
  }

  Widget _devicePicker({
    required Key key,
    required String label,
    required String? value,
    required List<String> devices,
    required ValueChanged<String?> onChanged,
  }) {
    final l10n = l10nOf(context);
    final known = value == null || devices.contains(value);
    return DropdownButtonFormField<String?>(
      key: key,
      initialValue: known ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(value: null, child: Text(l10n.voiceSystemDefault)),
        for (final device in devices)
          DropdownMenuItem(
            value: device,
            child: Text(device, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _slider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String Function(double) text,
    required ValueChanged<double> onChanged,
  }) {
    final shown = (_dragging[key] ?? value).clamp(min, max);
    return Row(
      children: [
        Expanded(flex: 2, child: Text(label)),
        Expanded(
          flex: 3,
          child: Slider(
            key: key,
            value: shown,
            min: min,
            max: max,
            divisions: divisions,
            label: text(shown),
            onChanged: (v) => setState(() => _dragging[key] = v),
            onChangeEnd: (v) {
              _dragging.remove(key);
              onChanged(v);
            },
          ),
        ),
        SizedBox(width: 56, child: Text(text(shown))),
      ],
    );
  }

  Widget _volume({
    required Key key,
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) => _slider(
    key: key,
    label: label,
    value: value,
    min: 0,
    max: 2,
    divisions: 40,
    text: (v) => '${(v * 100).round()}%',
    onChanged: onChanged,
  );

  Widget _meterBar(double threshold01) {
    final scheme = Theme.of(context).colorScheme;
    // The level in dB, drawn from -90 dB (left) to 0 dB (right).
    final db = _level <= 0 ? -90.0 : 20 * math.log(_level) / math.ln10;
    final fill = ((db + 90) / 90).clamp(0.0, 1.0);
    return SizedBox(
      key: const ValueKey('voice-level-meter'),
      height: 10,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            FractionallySizedBox(
              widthFactor: fill,
              child: Container(
                decoration: BoxDecoration(
                  color: fill >= threshold01 ? scheme.primary : scheme.outline,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
            if (threshold01 > 0)
              Positioned(
                left: constraints.maxWidth * threshold01 - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: scheme.error),
              ),
          ],
        ),
      ),
    );
  }

  KeyEventResult _captureKey(FocusNode _, KeyEvent event) {
    if (!_capturingKey || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    setState(() => _capturingKey = false);
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      unawaited(
        _update(_settings.copyWith(pushToTalkKey: event.logicalKey.keyId)),
      );
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = l10nOf(context);
    final settings = _settings;
    final testing = _controller.microphoneTestOpen;
    final key = settings.pushToTalkKey == null
        ? null
        : LogicalKeyboardKey.findKeyByKeyId(settings.pushToTalkKey!);
    final manualThreshold =
        settings.inputMode == VoiceInputMode.voiceActivity &&
            !settings.automaticSensitivity
        ? (settings.sensitivityDb + 90) / 90
        : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_desktopAudio) ...[
          _devicePicker(
            key: const ValueKey('voice-input-device'),
            label: l10n.voiceInputDevice,
            value: settings.inputDevice,
            devices: _inputs,
            onChanged: (device) => _update(
              settings.copyWith(
                inputDevice: device,
                clearInputDevice: device == null,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _devicePicker(
            key: const ValueKey('voice-output-device'),
            label: l10n.voiceOutputDevice,
            value: settings.outputDevice,
            devices: _outputs,
            onChanged: (device) => _update(
              settings.copyWith(
                outputDevice: device,
                clearOutputDevice: device == null,
              ),
            ),
          ),
        ] else
          Text(l10n.voiceDevicesOnPhone),
        const SizedBox(height: 8),
        _volume(
          key: const ValueKey('voice-input-volume'),
          label: l10n.voiceInputVolume,
          value: settings.inputVolume,
          onChanged: (v) => _update(settings.copyWith(inputVolume: v)),
        ),
        _volume(
          key: const ValueKey('voice-output-volume'),
          label: l10n.voiceOutputVolume,
          value: settings.outputVolume,
          onChanged: (v) => _update(settings.copyWith(outputVolume: v)),
        ),
        const Divider(),
        Text(l10n.voiceMicTest, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _meterBar(manualThreshold),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.tonal(
              key: const ValueKey('voice-mic-test'),
              onPressed: () async {
                if (testing) {
                  await _controller.stopMicrophoneTest();
                } else if (!await _controller.startMicrophoneTest(
                      loopback: _loopback,
                    ) &&
                    context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.voiceMicTestUnavailable)),
                  );
                }
                if (mounted) setState(() {});
              },
              child: Text(
                testing ? l10n.voiceMicTestStop : l10n.voiceMicTestStart,
              ),
            ),
            FilterChip(
              key: const ValueKey('voice-mic-loopback'),
              label: Text(l10n.voiceMicTestLoopback),
              selected: _loopback,
              onSelected: (on) {
                setState(() => _loopback = on);
                _controller.setMicrophoneTestLoopback(on);
              },
            ),
          ],
        ),
        const Divider(),
        Text(
          l10n.voiceInputMode,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        SegmentedButton<VoiceInputMode>(
          key: const ValueKey('voice-input-mode'),
          segments: [
            ButtonSegment(
              value: VoiceInputMode.always,
              label: Text(l10n.voiceInputModeAlways),
            ),
            ButtonSegment(
              value: VoiceInputMode.voiceActivity,
              label: Text(l10n.voiceInputModeActivity),
            ),
            ButtonSegment(
              value: VoiceInputMode.pushToTalk,
              label: Text(l10n.voiceInputModePushToTalk),
            ),
          ],
          selected: {settings.inputMode},
          onSelectionChanged: (modes) =>
              _update(settings.copyWith(inputMode: modes.first)),
        ),
        if (settings.inputMode == VoiceInputMode.voiceActivity) ...[
          SwitchListTile(
            key: const ValueKey('voice-sensitivity-automatic'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.voiceSensitivityAutomatic),
            value: settings.automaticSensitivity,
            onChanged: (on) =>
                _update(settings.copyWith(automaticSensitivity: on)),
          ),
          if (!settings.automaticSensitivity)
            _slider(
              key: const ValueKey('voice-sensitivity'),
              label: l10n.voiceSensitivity,
              value: settings.sensitivityDb,
              min: -90,
              max: 0,
              divisions: 90,
              text: (v) => '${v.round()} dB',
              onChanged: (v) => _update(settings.copyWith(sensitivityDb: v)),
            ),
        ],
        if (settings.inputMode == VoiceInputMode.pushToTalk && _desktopAudio)
          Focus(
            focusNode: _keyFocus,
            onKeyEvent: _captureKey,
            child: ListTile(
              key: const ValueKey('voice-push-to-talk-key'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.voicePushToTalkKey),
              subtitle: Text(
                _capturingKey
                    ? l10n.voicePushToTalkKeyPress
                    : '${key?.keyLabel ?? l10n.voicePushToTalkKeyNone}'
                          ' · ${l10n.voicePushToTalkKeyHint}',
              ),
              trailing: Wrap(
                spacing: 4,
                children: [
                  OutlinedButton(
                    onPressed: () {
                      setState(() => _capturingKey = true);
                      _keyFocus.requestFocus();
                    },
                    child: Text(l10n.voicePushToTalkKeyPress),
                  ),
                  if (key != null)
                    TextButton(
                      onPressed: () =>
                          _update(settings.copyWith(clearPushToTalkKey: true)),
                      child: Text(l10n.voiceClear),
                    ),
                ],
              ),
            ),
          ),
        const Divider(),
        Text(
          l10n.voiceProcessing,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SwitchListTile(
          key: const ValueKey('voice-noise-suppression'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.voiceNoiseSuppression),
          value: _controller.identity?.voiceNoiseSuppressionEnabled ?? true,
          onChanged: (on) async {
            await _controller.setVoiceNoiseSuppression(on);
            if (mounted) setState(() {});
          },
        ),
        SwitchListTile(
          key: const ValueKey('voice-echo-cancellation'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.voiceEchoCancellation),
          value: settings.echoCancellation,
          onChanged: (on) => _update(settings.copyWith(echoCancellation: on)),
        ),
        SwitchListTile(
          key: const ValueKey('voice-auto-gain'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.voiceAutoGain),
          value: settings.autoGain,
          onChanged: (on) => _update(settings.copyWith(autoGain: on)),
        ),
        const Divider(),
        SwitchListTile(
          key: const ValueKey('voice-call-sounds'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.voiceCallSounds),
          subtitle: Text(l10n.voiceCallSoundsHint),
          value: settings.callSounds,
          onChanged: (on) => _update(settings.copyWith(callSounds: on)),
        ),
      ],
    );
  }
}

/// Opens [VoiceSettingsPanel] over a call screen.
Future<void> showVoiceSettingsSheet(
  BuildContext context,
  MessengerController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => VoiceSettingsPanel(controller: controller),
      ),
    ),
  ),
);

/// The push-to-talk key, anywhere in the app while a call uses
/// push-to-talk (a key typed into a chat is not taken otherwise).
class PushToTalkKeyHandler {
  PushToTalkKeyHandler(this.controller);

  final MessengerController controller;

  bool _handle(KeyEvent event) {
    final settings = controller.voiceSettings;
    final key = settings.pushToTalkKey;
    if (key == null ||
        settings.inputMode != VoiceInputMode.pushToTalk ||
        event.logicalKey.keyId != key ||
        !controller.callUsesMicrophone) {
      return false;
    }
    if (event is KeyDownEvent) unawaited(controller.setPushToTalkHeld(true));
    if (event is KeyUpEvent) unawaited(controller.setPushToTalkHeld(false));
    return true;
  }

  void attach() => HardwareKeyboard.instance.addHandler(_handle);
  void detach() => HardwareKeyboard.instance.removeHandler(_handle);
}
