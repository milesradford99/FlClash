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
}
