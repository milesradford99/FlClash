import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/features/managed_isp/monitor.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ManagedIspMonitorSettings extends ConsumerStatefulWidget {
  const ManagedIspMonitorSettings({super.key, required this.settings});

  final IspMonitorSettings settings;

  @override
  ConsumerState<ManagedIspMonitorSettings> createState() =>
      _ManagedIspMonitorSettingsState();
}

class _ManagedIspMonitorSettingsState
    extends ConsumerState<ManagedIspMonitorSettings> {
  late final _seconds = TextEditingController(
    text: '${widget.settings.seconds}',
  );
  late bool _enabled = widget.settings.enabled;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _seconds.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final labels = context.appLocalizations;
    final seconds = int.tryParse(_seconds.text.trim());
    if (seconds == null || !validIspMonitorSeconds(seconds)) {
      setState(() => _error = labels.ispMonitorInvalidInterval);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(setupActionProvider.notifier).saveIspMonitoring((
        enabled: _enabled,
        seconds: seconds,
      ));
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = labels.managedIspSaveFailed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    return FormPage(
      title: labels.ispMonitorSettings,
      onSave: () => unawaited(_save()),
      saving: _saving,
      error: _error,
      children: [
        generateSection(
          items: [
            FormRow(
              title: labels.ispMonitorPeriodic,
              trailing: Switch(
                value: _enabled,
                onChanged: _saving
                    ? null
                    : (enabled) => setState(() => _enabled = enabled),
              ),
            ),
            FormRow(
              title: labels.ispMonitorInterval,
              trailing: FormRowTextField(
                controller: _seconds,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            labels.ispMonitorHint,
            style: AppTextStyle.footnote.of(context),
          ),
        ),
      ],
    );
  }
}
