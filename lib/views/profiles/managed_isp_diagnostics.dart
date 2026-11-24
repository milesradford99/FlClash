import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/features/managed_isp/browser_probe.dart';
import 'package:fl_clash/features/managed_isp/diagnostics.dart';
import 'package:fl_clash/features/managed_isp/platform.dart';
import 'package:fl_clash/features/managed_isp/profile.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ManagedIspDiagnostics extends ConsumerStatefulWidget {
  const ManagedIspDiagnostics({super.key, this.profileId});

  final int? profileId;

  @override
  ConsumerState<ManagedIspDiagnostics> createState() =>
      _ManagedIspDiagnosticsState();
}

class _ManagedIspDiagnosticsState extends ConsumerState<ManagedIspDiagnostics>
    with WidgetsBindingObserver {
  static const _platform = ManagedIspPlatform();
  final _endpoint = TextEditingController();
  final _expected = TextEditingController();
  final _locale = TextEditingController();
  final _zone = TextEditingController();
  final _browserResult = TextEditingController();
  Map<String, dynamic> _native = const {};
  Map<String, dynamic> _core = const {};
  DateTime? _observedAt;
  DateTime? _httpsAt;
  DateTime? _browserAt;
  DateTime? _policyAt;
  String _mode = 'inactive';
  int? _observedProfile;
  int? _protectedProfile;
  String? _profile;
  String? _probeNonce;
  String? _error;
  bool _profileConfirmed = false;
  bool _busy = false;
  bool _advanced = false;
  bool _webRtcPending = false;
  ({bool https, String? ip, bool? systemResolved})? _https;
  BrowserProbeEvidence? _browser;
  ChromeIspPolicies? _policies;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run(_detect));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_run(_detect));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _endpoint.dispose();
    _expected.dispose();
    _locale.dispose();
    _zone.dispose();
    _browserResult.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await operation();
    } catch (_) {
      if (mounted) setState(() => _error = context.appLocalizations.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<T?> _read<T>(Future<T> Function() read) async {
    try {
      return await read().timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  Future<void> _detect() async {
    final selected = ref.read(currentProfileProvider);
    final running = ref.read(isStartProvider);
    final handler = ref.read(coreHandlerProvider);
    final (native, core, filter) = await (
      _read(_platform.environment),
      _read(handler.getIspStatus),
      _read(() => _platform.protectedProfile),
    ).wait;
    if (!mounted) return;
    final stable =
        selected?.id == ref.read(currentProfileIdProvider) &&
        running == ref.read(isStartProvider);
    final managed = managedIspSourceId(selected?.url ?? '') != null;
    final mode = !stable || !running
        ? 'inactive'
        : managed
        ? (managedIspSystemProtection ? 'protected' : 'local_proxy')
        : 'vpn';
    setState(() {
      if (_mode != mode || _observedProfile != selected?.id) {
        _clearProbeResults();
      }
      _mode = mode;
      _observedAt = DateTime.now();
      _observedProfile = stable ? selected?.id : null;
      _native = native ?? const {};
      if (_webRtcForced) _webRtcPending = false;
      _core = stable ? core ?? const {} : const {};
      _protectedProfile = filter;
      if (!_profiles.containsKey(_profile)) {
        _profile = null;
        _profileConfirmed = false;
        _policies = null;
        _policyAt = null;
        _clearProbeResults();
      }
    });
  }

  void _clearProbeResults() {
    _https = null;
    _httpsAt = null;
    _browser = null;
    _browserAt = null;
    _probeNonce = null;
    _browserResult.clear();
  }

  Map<String, String> get _profiles => {
    if (_native['chromeProfiles'] case final List items)
      for (final item in items)
        if (item case {'id': final String id, 'name': final String name})
          id: name,
  };

  bool get _managed => _mode == 'local_proxy' || _mode == 'protected';
  bool get _coreReady => _core['loaded'] == true && _core['running'] == true;
  bool get _strictReady =>
      _protectedProfile != null &&
      _protectedProfile == _observedProfile &&
      _native['tunReady'] == true &&
      _core['tun'] == true &&
      _core['native_dns'] == true;
  bool get _routesReady =>
      _core['rule_mode'] == true &&
      _core['rule_chain'] == true &&
      _core['managed_doh'] == true &&
      _core['ipv6'] == false &&
      _core['has_hosts'] == true &&
      _core['allow_lan'] == false &&
      (_mode != 'local_proxy' ||
          (_core['tun'] == false &&
              _core['mixed_port'] == managedIspLocalPort));

  bool get _canProbe =>
      _coreReady &&
      _managed &&
      _routesReady &&
      (_mode != 'protected' || _strictReady);

  bool get _repair => _managed && _coreReady && !_routesReady;
  bool get _chrome => _native['chromeInstalled'] == true;
  bool get _webRtcForced => _native['webRtcForced'] == true;
  bool get _webRtcMatched =>
      _native['webRtcValue'] == 'disable_non_proxied_udp';
  bool get _canOpenWebRtc =>
      _chrome && _native['webRtcForced'] == false && _policies?.webRtc == null;
  bool get _install => _profileConfirmed && _policies != null && _canOpenWebRtc;

  Future<void> _quickWebRtc() async {
    final labels = context.appLocalizations;
    if (!_canOpenWebRtc) {
      final browser = _policies?.webRtc;
      final conflict =
          (_webRtcForced && !_webRtcMatched) ||
          (browser != null &&
              (browser.blocked || browser.value != 'disable_non_proxied_udp'));
      final confirmed = await dialogs.showMessage(
        title: 'WebRTC',
        message: TextSpan(
          text: conflict
              ? labels.ispDiagPolicyConflict
              : labels.ispDiagPolicyReview,
        ),
        confirmText: 'chrome://policy',
      );
      if (confirmed == true && mounted) await _shortcut('policy');
      return;
    }
    final confirmed = await dialogs.showMessage(
      title: labels.managedIspChromeInstall,
      message: TextSpan(
        text: '${labels.ispDiagInstall}\n\n${labels.ispDiagWebRtcManagedNote}',
      ),
      confirmText: labels.confirm,
    );
    if (confirmed != true || !mounted) return;
    await _openWebRtcInstaller();
    if (mounted) await _detect();
  }

  Future<void> _openWebRtcInstaller() async {
    await _platform.openChromeProfile();
    if (!mounted) return;
    setState(() {
      _webRtcPending = true;
      _policies = null;
      _policyAt = null;
    });
    await _shortcut('profiles');
  }

  Profile? _targetProfile(List<Profile> profiles, int? currentId) {
    final managed = profiles
        .where((profile) => managedIspSourceId(profile.url) != null)
        .toList();
    if (widget.profileId case final id?) {
      return managed.where((profile) => profile.id == id).firstOrNull;
    }
    return managed.where((profile) => profile.id == currentId).firstOrNull ??
        (managed.length == 1 ? managed.single : null);
  }

  Future<void> _openIspChrome() async {
    final labels = context.appLocalizations;
    final id = ref.read(currentProfileIdProvider);
    final target = _targetProfile(ref.read(profilesProvider), id);
    if (managedIspSystemProtection ||
        target == null ||
        !_chrome ||
        ref.read(safeModeProvider)) {
      return;
    }
    if (id != target.id || !ref.read(isStartProvider)) {
      try {
        await ref
            .read(profilesActionProvider.notifier)
            .selectProfile(target.id);
      } catch (_) {
        if (mounted) setState(() => _error = labels.managedIspLocalFailed);
        return;
      }
    }
    if (!mounted) return;
    await _detect();
    if (!mounted) return;
    if (_observedProfile != target.id || _mode != 'local_proxy' || !_canProbe) {
      setState(() => _error = labels.managedIspLocalFailed);
      return;
    }
    try {
      await _platform.openIspChrome();
    } catch (_) {
      if (mounted) setState(() => _error = labels.ispDiagChromeLaunchFailed);
    }
  }

  List<String> _plan(AppLocalizations labels) => [
    if (_repair) labels.ispDiagRepair,
    if (_install) labels.ispDiagInstall,
  ];

  Future<void> _configure() async {
    final labels = context.appLocalizations;
    final plan = _plan(labels);
    if (plan.isEmpty) return;
    final selected = _observedProfile;
    final confirmed = await dialogs.showMessage(
      title: labels.ispDiagReview,
      message: TextSpan(text: plan.join('\n\n')),
      confirmText: labels.confirm,
    );
    if (confirmed != true ||
        !mounted ||
        selected != ref.read(currentProfileIdProvider)) {
      return;
    }
    final repair = _repair;
    final install = _install;
    if (repair && ref.read(isStartProvider)) {
      final applied = await ref
          .read(setupActionProvider.notifier)
          .applyProfile(force: true);
      if (!applied) throw StateError(labels.error);
    }
    if (install) await _openWebRtcInstaller();
    if (mounted) await _detect();
  }

  Future<void> _selectChrome() async {
    final profiles = _profiles;
    if (profiles.isEmpty) {
      await _shortcut('picker');
      return;
    }
    final directory = await showFormSheet<String>(
      context: context,
      builder: (context) => SelectionSheet<String>(
        title: 'Chrome ${context.appLocalizations.profile}',
        sections: [
          SelectionSection(
            items: profiles.keys.toList(),
            subtitleBuilder: (_, item) => item,
          ),
        ],
        labelBuilder: (item) => profiles[item] ?? item,
        selectedOf: (_) => _profile,
        onSelected: (item) => Navigator.of(context).pop(item),
      ),
    );
    if (!mounted || directory == null || directory == _profile) return;
    setState(() {
      _profile = directory;
      _profileConfirmed = false;
      _policies = null;
      _policyAt = null;
      _clearProbeResults();
    });
    await _shortcut('version');
  }

  Future<void> _shortcut(String kind) => _platform.environmentShortcut(
    kind,
    directory: kind == 'picker' ? null : _profile,
  );

  Future<void> _probeHttps() async {
    if (!_canProbe) return;
    final labels = context.appLocalizations;
    final url = authorizedProbeUrl(_endpoint.text);
    if (_expected.text.trim().isNotEmpty &&
        InternetAddress.tryParse(_expected.text.trim()) == null) {
      throw const FormatException();
    }
    final allow = await dialogs.showMessage(
      title: labels.ispDiagBrowserBehavior,
      message: TextSpan(text: labels.ispDiagProbeApprove),
      confirmText: labels.start,
    );
    if (allow != true || !mounted) return;
    await _detect();
    if (!mounted || !_canProbe) return;
    final selected = _observedProfile;
    final port = _core['mixed_port'];
    if (port is! int || !isUsableMixedPort(port)) return;
    final result = await probeIspHttps(
      url,
      proxyPort: port,
      resolveSystem: _mode == 'protected',
    );
    if (!mounted ||
        selected != ref.read(currentProfileIdProvider) ||
        !ref.read(isStartProvider)) {
      return;
    }
    setState(() {
      _https = result;
      _httpsAt = DateTime.now();
    });
  }

  Future<void> _openBrowserProbe() async {
    final directory = _profile;
    if (!_profileConfirmed || directory == null) return;
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _platform.openBrowserProbe(
      ispBrowserProbePage(
        chinese: context.appLocalizations.localeName.startsWith('zh'),
        nonce: nonce,
      ),
      directory,
    );
    if (mounted) {
      setState(() {
        _browser = null;
        _browserAt = null;
        _browserResult.clear();
        _probeNonce = nonce;
      });
    }
  }

  void _importBrowser() {
    final nonce = _probeNonce;
    if (!_profileConfirmed || nonce == null) return;
    try {
      if (_observedProfile != ref.read(currentProfileIdProvider) ||
          (_mode != 'inactive') != ref.read(isStartProvider)) {
        throw const FormatException();
      }
      final result = decodeBrowserProbe(_browserResult.text, nonce: nonce);
      setState(() {
        _browser = result;
        _browserAt = DateTime.now();
        _browserResult.clear();
        _error = null;
      });
    } on FormatException {
      setState(() => _error = context.appLocalizations.importConfigInvalid);
    }
  }

  Future<void> _importPolicies({required bool fromClipboard}) async {
    if (!_profileConfirmed) return;
    final String? text;
    if (fromClipboard) {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } else {
      final selection = await picker.pickerFile();
      final path = selection?.path;
      if (path == null) return;
      final file = File(path);
      if (await file.length() > 1024 * 1024) throw const FormatException();
      text = await file.readAsString();
    }
    if (!mounted || text == null) return;
    final policies = decodeChromeIspPolicies(text);
    setState(() {
      _policies = policies;
      _policyAt = DateTime.now();
    });
  }

  String _policyEvidence(ChromeIspPolicy policy) =>
      '${policy.value} · ${policy.source} · ${policy.scope} · ${policy.level}';

  IspCheck _check(
    String id,
    IspCheckStatus status,
    String evidence, [
    String next = '',
  ]) => (id: id, status: status, evidence: evidence, next: next);

  List<IspCheck> _checks(AppLocalizations labels) {
    const pass = IspCheckStatus.passed;
    const fail = IspCheckStatus.failed;
    const pending = IspCheckStatus.unverified;
    const action = IspCheckStatus.actionRequired;
    const skip = IspCheckStatus.notApplicable;
    final locale = _native['locale'];
    final zone = _native['timeZone'];
    final languages = (_native['languages'] as List?)?.whereType<String>().join(
      ', ',
    );
    final resolvers = _native['resolvers'];
    final doh = _native['dohMode'];
    final dohMode = const {'off', 'automatic', 'secure'}.contains(doh)
        ? doh
        : '—';
    final expected = InternetAddress.tryParse(_expected.text.trim());
    final exit = _https?.ip;
    final actual = exit == null ? null : InternetAddress.tryParse(exit);
    final localeExpected = _locale.text.trim().replaceAll('-', '_');
    final zoneExpected = _zone.text.trim();
    final rtc = _browser;
    final export = _policies;
    final effective = export?.webRtc;
    final browserDoh = export?.doh;
    return [
      _check('mode', _coreReady ? pass : pending, _mode),
      _check(
        'core_routes',
        _managed ? (_coreReady ? (_routesReady ? pass : fail) : pending) : skip,
        '${labels.ispDiagCoreRoute} · ${_core['candidates'] ?? 0}',
        _repair ? labels.ispDiagRepair : '',
      ),
      _check(
        'system_protection',
        _mode == 'protected' ? (_strictReady ? pass : pending) : skip,
        '${labels.ispDiagSystemProtection} · TUN=${_native['tunReady'] ?? '—'} · Filter=${_protectedProfile != null}',
        _mode == 'protected' ? labels.ispDiagBrowserExternal : '',
      ),
      _check(
        'system_resolvers',
        resolvers is Map && resolvers.isNotEmpty ? pass : pending,
        resolvers is Map && resolvers.isNotEmpty
            ? 'default=${resolvers['default']} · domain=${resolvers['domain']} · scoped=${resolvers['scoped']}'
            : labels.noData,
        labels.ispDiagBrowserExternal,
      ),
      _check(
        'locale',
        locale is! String
            ? pending
            : localeExpected.isEmpty
            ? pending
            : locale.replaceAll('-', '_') == localeExpected
            ? pass
            : action,
        [if (locale is String) locale, ?languages].join(' · '),
        labels.settings,
      ),
      _check(
        'time_zone',
        zone is! String || zoneExpected.isEmpty
            ? pending
            : zone == zoneExpected
            ? pass
            : action,
        zone is String ? zone : labels.noData,
        labels.settings,
      ),
      _check(
        'chrome_profile',
        !_chrome
            ? skip
            : _profileConfirmed
            ? pass
            : action,
        _profile ?? labels.noData,
        _profileConfirmed ? '' : labels.ispDiagMissingProfile,
      ),
      _check(
        'chrome_webrtc_policy',
        !_chrome
            ? skip
            : _webRtcForced && _webRtcMatched
            ? pass
            : action,
        _webRtcForced
            ? (_webRtcMatched
                  ? 'WebRtcIPHandling=disable_non_proxied_udp · macOS'
                  : labels.ispDiagPolicyConflict)
            : labels.managedIspChromeMissing,
        labels.ispDiagPolicyReview,
      ),
      _check(
        'chrome_effective_policy',
        !_chrome
            ? skip
            : export == null
            ? pending
            : effective != null &&
                  !effective.blocked &&
                  effective.value == 'disable_non_proxied_udp' &&
                  effective.level == 'mandatory'
            ? pass
            : action,
        effective == null ? 'chrome://policy' : _policyEvidence(effective),
        effective != null &&
                (effective.blocked ||
                    effective.value != 'disable_non_proxied_udp')
            ? labels.ispDiagPolicyConflict
            : labels.ispDiagPolicyReview,
      ),
      _check(
        'chrome_secure_dns',
        !_chrome ? skip : pending,
        browserDoh == null
            ? 'DnsOverHttpsMode=$dohMode · managed=${_native['dohForced'] ?? '—'} · templates=${export?.templatesSet ?? _native['dohTemplatesSet'] ?? '—'}'
            : 'DnsOverHttpsMode=${_policyEvidence(browserDoh)} · templates=${export!.templatesSet}',
        'chrome://policy · chrome://settings/security',
      ),
      _check(
        'https',
        _https == null
            ? pending
            : _https!.https
            ? pass
            : fail,
        exit ?? 'HTTPS',
      ),
      _check(
        'isp_exit_match',
        expected == null || actual == null
            ? pending
            : expected == actual
            ? pass
            : fail,
        exit ?? labels.noData,
      ),
      _check(
        'system_dns_behavior',
        _mode != 'protected'
            ? skip
            : _https?.systemResolved == null
            ? pending
            : _https!.systemResolved!
            ? pass
            : fail,
        'getaddrinfo',
        labels.ispDiagBrowserExternal,
      ),
      _check(
        'chrome_https',
        !_chrome
            ? skip
            : rtc?.https == 'passed'
            ? pass
            : pending,
        'HTTPS · ${rtc?.https ?? '—'}',
      ),
      _check(
        'chrome_webrtc_behavior',
        !_chrome ? skip : pending,
        rtc == null
            ? 'ICE'
            : 'ICE=${rtc.ice} · ${rtc.candidateCount} · ${rtc.counts}',
        labels.ispDiagBrowserExternal,
      ),
      _check(
        'chrome_time_zone',
        !_chrome
            ? skip
            : rtc == null || zoneExpected.isEmpty
            ? pending
            : rtc.timeZone == zoneExpected
            ? pass
            : action,
        rtc?.timeZone ?? labels.noData,
        'chrome://version',
      ),
    ];
  }

  String _statusLabel(AppLocalizations labels, IspCheckStatus status) =>
      switch (status) {
        IspCheckStatus.passed => labels.ispDiagPassed,
        IspCheckStatus.failed => labels.ispDiagFailed,
        IspCheckStatus.unverified => labels.ispDiagUnverified,
        IspCheckStatus.actionRequired => labels.ispDiagAction,
        IspCheckStatus.notApplicable => labels.ispDiagNotApplicable,
      };

  String _checkLabel(AppLocalizations labels, String id) => switch (id) {
    'core_routes' => labels.ispDiagCoreRoute,
    'system_protection' => labels.ispDiagSystemProtection,
    'system_resolvers' => labels.ispDiagResolver,
    'locale' => labels.language,
    'time_zone' => 'macOS · Time Zone',
    'chrome_profile' => 'Chrome Profile',
    'chrome_webrtc_policy' => 'WebRTC · macOS',
    'chrome_effective_policy' => 'Chrome · chrome://policy',
    'chrome_secure_dns' => 'Chrome · Secure DNS',
    'https' => 'HTTPS',
    'isp_exit_match' => labels.managedIspExpected,
    'system_dns_behavior' => 'DNS · macOS',
    'chrome_https' => 'HTTPS · Chrome',
    'chrome_webrtc_behavior' => 'WebRTC · Chrome',
    'chrome_time_zone' => 'Chrome · Time Zone',
    _ => 'FlClash ISP',
  };

  Widget _action(String title, Future<void> Function() operation) => FormRow(
    title: title,
    onPressed: _busy ? null : () => unawaited(_run(operation)),
  );

  Widget _field(String title, TextEditingController controller, String hint) =>
      FormRow(
        title: title,
        trailing: FormRowTextField(
          controller: controller,
          hintText: hint,
          onChanged: (_) => setState(() {}),
        ),
      );

  Widget _status(String title, String status, {VoidCallback? onPressed}) =>
      FormRow(
        title: title,
        onPressed: onPressed,
        trailing: TooltipLabel(status, maxLines: 2),
      );

  List<Widget> _overview(
    AppLocalizations labels,
    Profile? target,
    bool stable,
  ) {
    final observed = _observedAt;
    const local = !managedIspSystemProtection;
    final ready = stable && _canProbe && target?.id == _observedProfile;
    final startHint = target == null
        ? labels.ispDiagNoIspProfile
        : !_chrome
        ? labels.managedIspChromeAbsent
        : labels.ispDiagChromeIsolation;
    final connection = observed == null || !stable
        ? labels.loading
        : ready
        ? labels.managedIspWaiting
        : target == null
        ? labels.ispDiagNoIspProfile
        : labels.disconnected;
    return [
      if (local)
        FilledButton(
          onPressed: _busy || !_chrome || target == null
              ? null
              : () => unawaited(_run(_openIspChrome)),
          child: Text(labels.ispDiagOpenIspChrome),
        ),
      if (local && observed != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(startHint, style: AppTextStyle.footnote.of(context)),
        ),
      generateSection(
        items: [
          ValueListenableBuilder(
            valueListenable: managedIspExit,
            builder: (context, observedExit, child) {
              final ip = ready && observedExit?.profileId == target?.id
                  ? observedExit?.ip
                  : null;
              return _status(labels.connection, ip ?? connection);
            },
          ),
          _status(
            'Chrome',
            observed == null
                ? labels.loading
                : _native.isEmpty
                ? labels.ispDiagUnverified
                : _chrome
                ? labels.ispDiagChromeAvailable
                : labels.managedIspChromeAbsent,
          ),
          _status(
            'WebRTC',
            observed == null
                ? labels.loading
                : !_chrome
                ? labels.ispDiagNotApplicable
                : _webRtcForced && _webRtcMatched
                ? labels.enabled
                : _webRtcForced
                ? labels.ispDiagAction
                : _webRtcPending
                ? labels.ispDiagWebRtcPending
                : '${labels.ispDiagWebRtcUnset} · ${labels.settings}',
            onPressed: _busy || !_chrome
                ? null
                : () => unawaited(_run(_quickWebRtc)),
          ),
          _status(
            labels.language,
            _native['locale'] as String? ?? labels.noData,
            onPressed: _busy
                ? null
                : () => unawaited(_run(() => _shortcut('locale'))),
          ),
          _status(
            labels.ispDiagTimeZone,
            _native['timeZone'] as String? ?? labels.noData,
            onPressed: _busy
                ? null
                : () => unawaited(_run(() => _shortcut('timeZone'))),
          ),
        ],
      ),
      generateSection(
        items: [
          FormRow(
            title: labels.ispDiagAdvanced,
            trailing: GlyphIcon(
              _advanced ? AppGlyphs.chevronUp : AppGlyphs.chevronDown,
            ),
            onPressed: _busy
                ? null
                : () => setState(() => _advanced = !_advanced),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final checks = _advanced ? _checks(labels) : const <IspCheck>[];
    final observed = _observedAt;
    final stable =
        _observedProfile == ref.watch(currentProfileIdProvider) &&
        (_mode != 'inactive') == ref.watch(isStartProvider);
    final target = _targetProfile(
      ref.watch(profilesProvider),
      ref.watch(currentProfileIdProvider),
    );
    return FormPage(
      title: labels.managedIspEnvironment,
      saving: _busy,
      error: _error,
      saveLabel: labels.ispDiagDetect,
      onSave: () => unawaited(_run(_detect)),
      children: [
        ..._overview(labels, target, stable),
        if (_advanced) ...[
          generateSection(
            items: [
              _action(labels.ispDiagDetect, _detect),
              if (stable && _plan(labels).isNotEmpty)
                _action(labels.ispDiagConfigure, _configure),
              if (observed != null && stable)
                _action(
                  labels.copy,
                  () => Clipboard.setData(
                    ClipboardData(
                      text: ispReport(
                        mode: _mode,
                        observedAt: observed,
                        checks: checks,
                        profile: _profileConfirmed ? _profile : null,
                        checkTimes: {
                          if (_policyAt case final time?)
                            for (final id in [
                              'chrome_effective_policy',
                              'chrome_secure_dns',
                            ])
                              id: time,
                          if (_httpsAt case final time?)
                            for (final id in [
                              'https',
                              'isp_exit_match',
                              'system_dns_behavior',
                            ])
                              id: time,
                          if (_browserAt case final time?)
                            for (final id in [
                              'chrome_https',
                              'chrome_webrtc_behavior',
                              'chrome_time_zone',
                            ])
                              id: time,
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
          generateSection(
            items: [
              _action(
                'Chrome Profile · ${_profile ?? labels.settings}',
                _selectChrome,
              ),
              if (_chrome) ...[
                _action('Chrome Profile · +', () => _shortcut('picker')),
                if (_profile != null && !_profileConfirmed)
                  _action(
                    labels.ispDiagConfirmProfile,
                    () async => setState(() => _profileConfirmed = true),
                  ),
                _action('chrome://version', () => _shortcut('version')),
                _action('chrome://policy', () => _shortcut('policy')),
                if (_profileConfirmed) ...[
                  _action(
                    'chrome://policy · ${labels.importFile}',
                    () => _importPolicies(fromClipboard: false),
                  ),
                  _action(
                    'chrome://policy · JSON → ${labels.import}',
                    () => _importPolicies(fromClipboard: true),
                  ),
                ],
                _action(
                  'chrome://settings/security',
                  () => _shortcut('security'),
                ),
                _action(
                  'chrome://settings/languages',
                  () => _shortcut('languages'),
                ),
              ],
              _action('${labels.language} · macOS', () => _shortcut('locale')),
              _action('Time Zone · macOS', () => _shortcut('timeZone')),
              if (_webRtcForced)
                _action(
                  '${labels.settings} · .mobileconfig',
                  () => _shortcut('profiles'),
                ),
            ],
          ),
          generateSection(
            items: [
              _field(labels.language, _locale, 'en_US'),
              _field('Time Zone', _zone, 'America/Los_Angeles'),
              _field(labels.managedIspExpected, _expected, labels.optional),
              _field(labels.ispDiagProbeUrl, _endpoint, 'https://…'),
              if (stable && _canProbe && _endpoint.text.trim().isNotEmpty)
                _action('HTTPS · ${labels.start}', _probeHttps),
              if (stable && _profileConfirmed)
                _action(labels.ispDiagBrowserProbe, _openBrowserProbe),
              if (_probeNonce != null) ...[
                _field(labels.ispDiagProbeImport, _browserResult, 'JSON'),
                if (_browserResult.text.isNotEmpty)
                  FormRow(
                    title: labels.ispDiagProbeEvidence,
                    onPressed: _importBrowser,
                  ),
              ],
            ],
          ),
          if (!stable)
            generateSection(items: [FormRow(title: labels.ispDiagDetect)])
          else
            generateSection(
              items: [
                for (final check in checks)
                  FormRow(
                    title: _checkLabel(labels, check.id),
                    trailing: TooltipLabel(
                      [
                        _statusLabel(labels, check.status),
                        if (check.evidence.isNotEmpty) check.evidence,
                        if (check.next.isNotEmpty) check.next,
                      ].join('\n'),
                      maxLines: 5,
                    ),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}
