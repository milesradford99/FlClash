import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/views/profiles/managed_isp_diagnostics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}

void main() {
  testWidgets('routine setup hides probe fields until advanced is opened', (
    tester,
  ) async {
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
}
