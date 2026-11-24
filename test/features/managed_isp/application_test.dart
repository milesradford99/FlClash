import 'package:fl_clash/features/managed_isp/application.dart';
import 'package:fl_clash/features/managed_isp/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an app bundle matches its executable and helpers only', () {
    const app = ManagedIspApplication(
      name: 'Antigravity',
      path: '/Applications/Antigravity.app',
      bundle: true,
    );
    expect(
      app.matches('/Applications/Antigravity.app/Contents/MacOS/Antigravity'),
      isTrue,
    );
    expect(
      app.matches(
        '/Applications/Antigravity.app/Contents/Resources/bin/language_server',
      ),
      isTrue,
    );
    expect(
      app.matches(
        '/Applications/Antigravity.app.backup/Contents/MacOS/Antigravity',
      ),
      isFalse,
    );
    expect(app.matches('/usr/local/bin/Antigravity'), isFalse);
    expect(app.rules.first, endsWith('(NETWORK,UDP)),REJECT'));
    expect(app.rules.last, endsWith('(NETWORK,TCP)),$sharedIspOutbound'));
  });

  test(
    'an executable uses an exact path and safely encodes rule delimiters',
    () {
      const app = ManagedIspApplication(
        name: 'Client',
        path: '/opt/Client (Test), 1',
        bundle: false,
      );
      expect(app.matches(app.path), isTrue);
      expect(app.matches('${app.path}.backup'), isFalse);
      expect(
        app.rules.join(),
        contains(r'^/opt/Client\x20\x28Test\x29\x2c\x201\z'),
      );
      expect(
        ManagedIspApplication.fromJson(app.withEnabled(false).toJson()).enabled,
        isFalse,
      );
    },
  );
}
