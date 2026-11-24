import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/features/managed_isp/application.dart';
import 'package:fl_clash/features/managed_isp/platform.dart';
import 'package:fl_clash/features/managed_isp/profile.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ManagedIspApplications extends ConsumerStatefulWidget {
  const ManagedIspApplications({super.key, required this.profileId});

  final int profileId;

  @override
  ConsumerState<ManagedIspApplications> createState() =>
      _ManagedIspApplicationsState();
}

class _ManagedIspApplicationsState
    extends ConsumerState<ManagedIspApplications> {
  static const _platform = ManagedIspPlatform();
  List<ManagedIspApplication> _apps = const [];
  Set<String> _hits = const {};
  bool _tun = false;
  bool _busy = false;
  String? _error;

  bool get _selected =>
      ref.read(currentProfileIdProvider) == widget.profileId &&
      ref.read(isStartProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_run(_refresh));
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.appLocalizations.ispAppsFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final apps = await preferences.managedIspApplications(widget.profileId);
    if (!mounted) return;
    final core = ref.read(coreHandlerProvider);
    final active =
        _selected && (await core.getIspStatus())['tun_running'] == true;
    final hits = active
        ? await core.getConnectionsWith(
            (connections) => {
              for (final connection in connections)
                if (connection.chains.contains(sharedIspOutbound))
                  connection.metadata.processPath,
            },
          )
        : <String>{};
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _tun = active && _selected;
      _hits = _tun ? hits : const {};
    });
  }

  Future<void> _change(ManagedIspApplication app, {bool remove = false}) async {
    await ref
        .read(profilesActionProvider.notifier)
        .changeManagedIspApplication(widget.profileId, app, remove: remove);
    if (mounted) await _refresh();
  }

  Future<void> _add() async {
    final app = await _platform.pickIspApplication();
    if (app != null && mounted) await _change(app);
  }

  Future<void> _start() async {
    await ref
        .read(profilesActionProvider.notifier)
        .selectProfile(widget.profileId);
    if (mounted) await _refresh();
  }

  String _status(
    ManagedIspApplication app,
    AppLocalizations labels,
    bool active,
  ) {
    if (!app.enabled) return labels.disabled;
    if (!active) return labels.ispAppsNeedsTun;
    return _hits.any(app.matches)
        ? labels.ispAppsMatched
        : labels.ispAppsWaiting;
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final active =
        _tun &&
        ref.watch(isStartProvider) &&
        ref.watch(currentProfileIdProvider) == widget.profileId;
    return FormPage(
      title: labels.ispAppsTitle,
      saveLabel: labels.ispDiagDetect,
      onSave: () => unawaited(_run(_refresh)),
      saving: _busy,
      error: _error,
      children: [
        generateSection(
          items: [
            for (final app in _apps)
              ContextMenuRegion(
                menuItems: _busy
                    ? null
                    : [
                        PopupMenuItem(
                          glyph: AppGlyphs.delete,
                          label: labels.remove,
                          onPressed: () =>
                              unawaited(_run(() => _change(app, remove: true))),
                        ),
                      ],
                child: ListItem.toggle(
                  key: ValueKey(app.path),
                  title: Text(app.name),
                  subtitle: Tooltip(
                    message: app.path,
                    child: Text(_status(app, labels, active)),
                  ),
                  value: app.enabled,
                  onChanged: _busy
                      ? null
                      : (value) => unawaited(
                          _run(() => _change(app.withEnabled(value))),
                        ),
                ),
              ),
            FormRow(
              title: labels.ispAppsAdd,
              trailing: const GlyphIcon(AppGlyphs.addCircle),
              onPressed: _busy ? null : () => unawaited(_run(_add)),
            ),
            if (!active && _apps.any((app) => app.enabled))
              FormRow(
                title: labels.ispAppsStart,
                onPressed: _busy ? null : () => unawaited(_run(_start)),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            labels.ispAppsHint,
            style: AppTextStyle.footnote.of(context),
          ),
        ),
      ],
    );
  }
}
