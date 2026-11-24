import 'package:fl_clash/features/managed_isp/profile.dart';
import 'package:flutter_test/flutter_test.dart';

ManagedIspProfile _profile({
  String url = 'https://subscription.example.test/profile?token=fixture',
  String ispHost = 'isp.example.test',
  int ispPort = 1080,
  String username = 'test user',
  String password = ' fixture password ',
}) => ManagedIspProfile(
  subscription: Uri.parse(url),
  ispHost: ispHost,
  ispPort: ispPort,
  username: username,
  password: password,
);

Map<String, Object> _node(String name, String server) => {
  'name': name,
  'type': 'socks5',
  'server': server,
  'port': 1081,
  'udp': true,
};

void main() {
  test('imports a SOCKS5 URL with percent-encoded credentials', () {
    final input = ManagedIspProfile.fromConnectionString(
      subscription: Uri.parse('https://subscription.example.test/profile'),
      connectionString: ' socks5://test%3Auser:p%40ss%3Aword@192.0.2.4:50101 ',
    );
    expect(
      input.storage(digest: 'fixture', addresses: const {}),
      containsPair('username', 'test:user'),
    );
    expect(
      input.storage(digest: 'fixture', addresses: const {}),
      containsPair('password', 'p@ss:word'),
    );
    expect(input.ispPort, 50101);
  });

  test('requires the SOCKS5 scheme, credentials and explicit port', () {
    for (final connectionString in [
      'https://user:password@isp.example.test:1080',
      'socks5://isp.example.test:1080',
      'socks5://user:password@isp.example.test',
      'socks5://user:password@isp.example.test:1080/path',
      'socks5://user:password@isp.example.test:1080?query=value',
      'socks5://user:password@isp.example.test:1080#fragment',
    ]) {
      expect(
        () => ManagedIspProfile.fromConnectionString(
          subscription: Uri.parse('https://subscription.example.test/profile'),
          connectionString: connectionString,
        ),
        throwsFormatException,
        reason: connectionString,
      );
    }
  });

  test(
    'TUN keeps subscription rules and routes Chrome through the shared VPN',
    () {
      final original = {
        'proxies': [_node('VPN A', '192.0.2.4'), _node('VPN B', '192.0.2.5')],
        'proxy-groups': [
          {
            'name': 'Original',
            'type': 'select',
            'proxies': ['DIRECT'],
            'include-all-proxies': true,
          },
        ],
        'rules': ['DOMAIN,local.example.test,DIRECT', 'MATCH,Original'],
        'dns': {
          'enable': true,
          'nameserver': ['https://example.test/dns-query'],
        },
        'tun': {'enable': true},
      };
      final plan = _profile().sharedConfig(original, port: 17890);
      expect(plan['rules'], original['rules']);
      expect(plan['tun'], original['tun']);
      expect(plan['dns'], original['dns']);

      final groups = {
        for (final group in plan['proxy-groups'] as List) group['name']: group,
      };
      expect(groups[sharedIspVpnGroup]['proxies'], [
        'VPN / VPN A',
        'VPN / VPN B',
      ]);
      expect(groups['Original']['proxies'], ['DIRECT', 'VPN A', 'VPN B']);
      expect(groups['VPN A']['proxies'], [sharedIspVpnGroup]);
      expect(groups['VPN B']['proxies'], [sharedIspVpnGroup]);
      final exit = (plan['proxies'] as List).last as Map;
      expect(exit['dialer-proxy'], sharedIspVpnGroup);
      expect(exit['udp'], isFalse);
      final chrome = (plan['listeners'] as List).single as Map;
      expect(chrome['listen'], '127.0.0.1');
      expect(chrome['proxy'], exit['name']);
      expect(chrome['udp'], isFalse);
    },
  );

  test('existing subscription listeners cannot take the Chrome port', () {
    expect(
      () => _profile().sharedConfig({
        'proxies': [_node('VPN A', '192.0.2.4')],
        'listeners': [
          {'name': 'custom', 'port': 17890},
        ],
      }, port: 17890),
      throwsFormatException,
    );
  });

  test('keeps the original profile and uses only ISP chains in 01', () {
    final first = _node('Node A', 'one.example.test');
    final second = _node('Node B', 'two.example.test');
    final subscription = {
      'proxies': [
        first,
        {'name': 'DIRECT', 'type': 'direct'},
        {...first, 'name': 'Nested', 'dialer-proxy': 'subscription group'},
        second,
      ],
      'rules': ['MATCH,DIRECT'],
      'listeners': [
        {'name': 'test inbound', 'proxy': 'DIRECT'},
      ],
    };

    final config = _profile().buildOutbounds(subscription);
    final proxies = config['proxies'] as List<Map<String, dynamic>>;
    expect(proxies, hasLength(4));
    expect(proxies[0], {...first, 'name': 'VPN 1 / Node A'});
    expect(proxies[2], {...second, 'name': 'VPN 2 / Node B'});
    expect(proxies[1], {
      'name': 'ISP 1 / Node A',
      'type': 'socks5',
      'server': 'isp.example.test',
      'port': 1080,
      'username': 'test user',
      'password': ' fixture password ',
      'udp': false,
      'dialer-proxy': 'VPN 1 / Node A',
    });
    expect(proxies[3]['dialer-proxy'], 'VPN 2 / Node B');

    final group = (config['proxy-groups'] as List).single as Map;
    expect(group['type'], 'fallback');
    expect(group['proxies'], ['ISP 1 / Node A', 'ISP 2 / Node B']);
    expect(group['empty-fallback'], 'REJECT');
    expect(group['disable-udp'], isTrue);
    expect(group['url'], startsWith('https://'));
    expect(config['rules'], ['MATCH,Managed ISP']);
    expect(config, isNot(contains('listeners')));
    expect(subscription['rules'], ['MATCH,DIRECT']);
    expect(first['name'], 'Node A');
  });

  test(
    'regenerates from the latest subscription and handles duplicate names',
    () {
      final profile = _profile();
      final initial = profile.buildOutbounds({
        'proxies': [_node('Old name', 'one.example.test')],
      });
      final refreshed = profile.buildOutbounds({
        'proxies': [
          _node('Renamed', 'one.example.test'),
          _node('Renamed', 'two.example.test'),
        ],
      });
      final initialGroup = (initial['proxy-groups'] as List).single as Map;
      final refreshedGroup = (refreshed['proxy-groups'] as List).single as Map;
      expect(initialGroup['proxies'], ['ISP 1 / Old name']);
      expect(refreshedGroup['proxies'], ['ISP 1 / Renamed', 'ISP 2 / Renamed']);
    },
  );

  test('stops when a refresh contains no usable upstream nodes', () {
    final profile = _profile();
    for (final source in <Map<String, Object>>[
      {},
      {'proxies': <Object>[]},
      {
        'proxies': [
          {'name': 'DIRECT', 'type': 'direct'},
          {..._node('Bad address', '10.2.3.4'), 'port': 0},
        ],
      },
      {'proxy-providers': <String, Object>{}},
    ]) {
      expect(() => profile.buildOutbounds(source), throwsFormatException);
    }
  });

  test(
    'validates subscription, ISP endpoint and SOCKS5 credential lengths',
    () {
      expect(
        () => _profile(url: 'http://insecure.test'),
        throwsFormatException,
      );
      expect(
        () => _profile(url: 'https://user:secret@test'),
        throwsFormatException,
      );
      expect(
        () => _profile(ispHost: 'https://isp.test'),
        throwsFormatException,
      );
      expect(() => _profile(ispHost: 'name.test:80'), throwsFormatException);
      expect(() => _profile(ispPort: 65536), throwsFormatException);
      expect(() => _profile(password: ''), throwsFormatException);
      expect(() => _profile(username: '界' * 86), throwsFormatException);
      expect(_profile(ispHost: '2001:db8::10').ispPort, 1080);
    },
  );

  test('builds DNS and VPN policy from one pinned snapshot', () {
    final profile = _profile();
    final raw = {
      'proxies': [
        {..._node('AnyTLS', 'one.example.test'), 'type': 'anytls'},
        {..._node('HY2', 'two.example.test'), 'type': 'hysteria2'},
        _node('Unresolved', 'three.example.test'),
        {
          ..._node('Hopping', 'four.example.test'),
          'type': 'hysteria2',
          'ports': '8888-9999',
        },
      ],
    };
    final plan = profile.protectedConfig(
      raw,
      {
        'one.example.test': ['192.0.2.1', '198.18.0.2'],
        'two.example.test': ['198.51.100.2'],
        'four.example.test': ['203.0.113.3'],
        'isp.example.test': ['203.0.113.5'],
      },
      tun: 'utun223',
      mixedPort: 7890,
      enableTun: true,
    );
    expect(plan.endpoints, ['tcp/192.0.2.1/1081', 'udp/198.51.100.2/1081']);
    expect(plan.config['hosts'], {
      'isp.example.test': ['203.0.113.5'],
      'one.example.test': ['192.0.2.1'],
      'two.example.test': ['198.51.100.2'],
    });
    final dns = plan.config['dns'] as Map;
    expect(dns['nameserver'], ['https://1.1.1.1/dns-query#Managed ISP']);
    expect(dns['use-system-hosts'], isFalse);
    expect(plan.config['rules'], ['MATCH,Managed ISP']);
    expect(plan.config['allow-lan'], isFalse);
    expect(plan.config['bind-address'], '127.0.0.1');
    final tun = plan.config['tun'] as Map;
    expect(tun['enable'], isTrue);
    expect(tun['device'], 'utun223');
    expect(tun['strict-route'], isTrue);
  });

  test('local proxy keeps the fixed exit and disables host listeners', () {
    final plan = _profile().protectedConfig(
      {
        'proxies': [_node('VPN', '192.0.2.4')],
        'rules': ['MATCH,DIRECT'],
        'listeners': [
          {'name': 'other inbound', 'proxy': 'DIRECT'},
        ],
      },
      {
        '192.0.2.4': ['192.0.2.4'],
        'isp.example.test': ['203.0.113.5'],
      },
      tun: 'utun223',
      mixedPort: 17890,
      enableTun: false,
    );

    expect(plan.config['mixed-port'], 17890);
    expect(plan.config['bind-address'], '127.0.0.1');
    expect(plan.config['allow-lan'], isFalse);
    expect(plan.config['tun'], {'enable': false});
    expect(plan.config['rules'], ['MATCH,Managed ISP']);
    expect(plan.config, isNot(contains('external-controller')));
    expect(plan.config, isNot(contains('listeners')));
    expect((plan.config['dns'] as Map), isNot(contains('listen')));
  });

  test(
    'protected refresh uses an injected resolver and retains old pins on failure',
    () async {
      final profile = _profile();
      final result = await profile.resolve(
        {
          'proxies': [
            _node('Old', 'old.example.test'),
            _node('New', 'new.example.test'),
          ],
        },
        previous: {
          'old.example.test': ['192.0.2.8'],
        },
        resolver: (host) async => switch (host) {
          'old.example.test' => throw const FormatException(),
          'new.example.test' => ['2001:db8::1', '198.51.100.3', '198.18.0.2'],
          'isp.example.test' => ['203.0.113.7'],
          _ => [],
        },
      );
      expect(result, {
        'old.example.test': ['192.0.2.8'],
        'new.example.test': ['198.51.100.3'],
        'isp.example.test': ['203.0.113.7'],
      });
    },
  );

  test('traces the managed profile to the ID of the pure VPN entry', () {
    expect(managedIspSourceId(managedIspUrl(10)), 10);
    expect(managedIspSourceId('https://example.test/subscription'), isNull);
  });
}
