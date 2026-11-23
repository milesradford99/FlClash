import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/features/managed_isp/profile.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ManagedIspForm extends ConsumerStatefulWidget {
  const ManagedIspForm({super.key});

  @override
  ConsumerState<ManagedIspForm> createState() => _ManagedIspFormState();
}

class _ManagedIspFormState extends ConsumerState<ManagedIspForm> {
  final _subscription = TextEditingController();
  final _server = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _exitIp = TextEditingController();
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;
    final labels = context.appLocalizations;
    final subscription = Uri.tryParse(_subscription.text.trim());
    final port = int.tryParse(_port.text.trim());
    final exitIp = _exitIp.text.trim();
    final ManagedIspProfile input;
    try {
      if (subscription == null || port == null) throw const FormatException();
      input = ManagedIspProfile(
        subscription: subscription,
        ispHost: _server.text,
        ispPort: port,
        username: _username.text,
        password: _password.text,
        expectedIp: exitIp.isEmpty ? null : exitIp,
      );
    } on FormatException {
      setState(() => _error = labels.managedIspInvalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(profilesActionProvider.notifier).createManagedIsp(input);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = labels.managedIspSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _subscription.dispose();
    _server.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _exitIp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    return FormPage(
      title: labels.managedIspSetup,
      onSave: () => unawaited(_save()),
      saving: _saving,
      error: _error,
      children: [
        generateSection(
          items: [
            FormRow(
              title: labels.link,
              trailing: FormRowSecretTextField(
                controller: _subscription,
                hintText: labels.required,
              ),
            ),
            FormRow(
              title: labels.server,
              trailing: FormRowTextField(
                controller: _server,
                hintText: labels.required,
              ),
            ),
            FormRow(
              title: labels.port,
              trailing: FormRowTextField(
                controller: _port,
                keyboardType: TextInputType.number,
                hintText: labels.required,
              ),
            ),
            FormRow(
              title: labels.username,
              trailing: FormRowTextField(
                controller: _username,
                hintText: labels.required,
              ),
            ),
            FormRow(
              title: labels.password,
              trailing: FormRowSecretTextField(
                controller: _password,
                hintText: labels.required,
              ),
            ),
            FormRow(
              title: labels.managedIspExpected,
              trailing: FormRowTextField(
                controller: _exitIp,
                hintText: labels.optional,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
