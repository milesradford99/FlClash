import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/profiles/managed_isp_diagnostics.dart';
import 'package:fl_clash/views/profiles/managed_isp_applications.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:prism_ui/switch.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';
import '../../helpers/preferences.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  testWidgets('routine setup hides probe fields until advanced is opened', (
    tester,
  ) async {
    await mockPreferences();
    const channel = MethodChannel('flclash/managed_isp');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'environment') {
        return {
          'chromeInstalled': true,
          'chromeProfiles': <Object>[],
          'locale': 'en_US',
          'timeZone': 'America/Los_Angeles',
          'webRtcForced': false,
        };
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final core = _Core();
    when(core.getIspStatus).thenAnswer((_) async => {'loaded': false});
    final target = Profile.normal(url: 'flclash-isp://901').copyWith(id: 902);

    await tester.pumpWidget(
      TestApp(
        locale: const Locale('en'),
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          profilesProvider.overrideWith(() => TestProfiles([target])),
        ],
        child: const ManagedIspDiagnostics(profileId: 902),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Open Chrome with fixed ISP'), findsOneWidget);
    expect(find.text('Authorized HTTPS endpoint'), findsNothing);
    expect(find.text('Advanced diagnostics'), findsOneWidget);
    expect(calls, ['environment']);

    await tester.tap(find.text('Link check settings'));
    await tester.pumpAndSettle();
    final sweep = find.byWidgetPredicate((widget) => widget is Switch);
    expect(tester.widget<Switch>(sweep).value, isFalse);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '120',
    );
    await tester.tap(sweep);
    await tester.enterText(find.byType(EditableText), '300');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(await preferences.ispMonitorSettings(), (
      enabled: true,
      seconds: 300,
    ));
    expect(calls, ['environment']);

    await tester.tap(find.text('System policy not set · Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('Open Chrome policy installer'), findsOneWidget);
    expect(calls, ['environment']);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, ['environment']);

    await tester.tap(find.text('System policy not set · Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(calls, [
      'environment',
      'openChromeProfile',
      'environmentShortcut',
      'environment',
    ]);
    expect(find.text('Awaiting confirmation in macOS'), findsOneWidget);

    await tester.ensureVisible(find.text('Advanced diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced diagnostics'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Authorized HTTPS endpoint'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Authorized HTTPS endpoint'), findsOneWidget);
    expect(
      calls.where((method) => method == 'openChromeProfile'),
      hasLength(1),
    );
  });

  testWidgets('creates, renames and launches each ISP Chrome space by ID', (
    tester,
  ) async {
    const channel = MethodChannel('flclash/managed_isp');
    const first = 'flclash-isp-chrome';
    const second = '2e169c76-1ced-4d24-bc78-54696784930e';
    final spaces = {first: 'Chrome ISP'};
    final launched = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'environment':
          final entries = [
            for (final MapEntry(:key, :value) in spaces.entries)
              {'id': key, 'name': value},
          ];
          return {
            'chromeInstalled': true,
            'chromeProfiles': entries,
            'ispChromeSpaces': entries,
          };
        case 'saveIspChromeSpace':
          final args = Map<String, String>.from(call.arguments as Map);
          spaces[args['id'] ?? second] = args['name']!;
        case 'openIspChrome':
          launched.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final core = _Core();
    when(core.getIspStatus).thenAnswer(
      (_) async => {
        'loaded': true,
        'running': true,
        'rule_mode': true,
        'chrome_isp': true,
        'tun_running': true,
      },
    );
    final target = Profile.normal(url: 'flclash-isp://901').copyWith(id: 902);
    await tester.pumpWidget(
      TestApp(
        locale: const Locale('en'),
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          profilesProvider.overrideWith(() => TestProfiles([target])),
          currentProfileIdProvider.overrideWithBuild((_, _) => target.id),
          isStartProvider.overrideWithValue(true),
          patchClashConfigProvider.overrideWithValue(
            const PatchClashConfig().copyWith.tun(enable: true),
          ),
        ],
        child: const ManagedIspDiagnostics(profileId: 902),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New space'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(find.byType(EditableText), 'Work');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    expect(launched, isEmpty);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Work'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.enterText(find.byType(EditableText), 'Client');
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();
    expect(spaces, {first: 'Chrome ISP', second: 'Client'});

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chrome ISP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Client'));
    await tester.pumpAndSettle();
    expect(launched, [first, second]);
  });

  testWidgets('picks a local app, saves it, and can disable the route', (
    tester,
  ) async {
    await mockPreferences();
    const channel = MethodChannel('flclash/managed_isp');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'pickIspApplication');
      return {
        'name': 'Antigravity',
        'path': '/Applications/Antigravity.app',
        'bundle': true,
      };
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final profile = Profile.normal(url: 'flclash-isp://901').copyWith(id: 902);
    await tester.pumpWidget(
      TestApp(
        locale: const Locale('en'),
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          isStartProvider.overrideWithValue(false),
        ],
        child: ManagedIspApplications(profileId: profile.id),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add app'));
    await tester.pumpAndSettle();
    expect(find.text('Antigravity'), findsOneWidget);
    expect(find.text('Waiting for TUN'), findsOneWidget);
    expect(
      (await preferences.managedIspApplications(profile.id)).single.enabled,
      isTrue,
    );
    await tester.tap(find.text('Antigravity'));
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsOneWidget);
    expect(
      (await preferences.managedIspApplications(profile.id)).single.enabled,
      isFalse,
    );
  });
}
