import 'dart:convert';
import 'dart:io';

const _ispGroup = 'Managed ISP';
const _healthCheckUrl = 'https://1.1.1.1/cdn-cgi/trace';

const _upstreamProtocols = {
  'anytls',
  'http',
  'hysteria',
  'hysteria2',
  'mieru',
  'shadowquic',
  'snell',
  'socks5',
  'ss',
  'ssr',
  'ssh',
  'sudoku',
  'trojan',
  'tuic',
  'vless',
  'vmess',
  'wireguard',
};

final _dnsLabel = RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$');

bool _validHost(String host) {
  if (InternetAddress.tryParse(host) != null) {
    return true;
  }
  final name = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  return name.length <= 253 && name.split('.').every(_dnsLabel.hasMatch);
}

class ManagedIspProfile {
  ManagedIspProfile({
    required this.subscription,
    required String ispHost,
    required this.ispPort,
    required String username,
    required String password,
  }) : _host = ispHost.trim(),
       _username = username,
       _password = password {
    if (subscription.scheme != 'https' ||
        subscription.host.isEmpty ||
        subscription.userInfo.isNotEmpty ||
        subscription.hasFragment) {
      throw const FormatException('Expected an HTTPS subscription URL.');
    }
    if (!_validHost(_host) || ispPort < 1 || ispPort > 65535) {
      throw const FormatException('Invalid SOCKS5 server address or port.');
    }
    if (!_validCredential(_username) || !_validCredential(_password)) {
      throw const FormatException('Invalid SOCKS5 authentication fields.');
    }
  }

  final Uri subscription;
  final int ispPort;
  final String _host;
  final String _username;
  final String _password;

  static bool _validCredential(String value) =>
      value.isNotEmpty && utf8.encode(value).length <= 255;

  /// Builds the outbound portion of 01. The caller owns TUN and system protection.
  Map<String, Object> buildOutbounds(Map<String, dynamic> source) {
    final sourceProxies = source['proxies'];
    if (sourceProxies is! List) {
      throw const FormatException('The subscription needs inline VPN nodes.');
    }

    final proxies = <Map<String, dynamic>>[];
    final chains = <String>[];
    for (final node in sourceProxies) {
      if (node is! Map<String, dynamic> || !_eligible(node)) {
        continue;
      }
      final index = chains.length + 1;
      final upstream = 'VPN $index / ${node['name']}';
      final chain = 'ISP $index / ${node['name']}';
      proxies.addAll([
        {...node, 'name': upstream},
        {
          'name': chain,
          'type': 'socks5',
          'server': _host,
          'port': ispPort,
          'username': _username,
          'password': _password,
          'udp': false,
          'dialer-proxy': upstream,
        },
      ]);
      chains.add(chain);
    }
    if (chains.isEmpty) {
      throw const FormatException(
        'The subscription has no supported VPN nodes.',
      );
    }

    return {
      'mode': 'rule',
      'proxies': proxies,
      'proxy-groups': [
        {
          'name': _ispGroup,
          'type': 'fallback',
          'proxies': chains,
          'empty-fallback': 'REJECT',
          'disable-udp': true,
          'url': _healthCheckUrl,
          'expected-status': '200',
          'interval': 30,
          'timeout': 8000,
          'lazy': false,
        },
      ],
      'rules': ['MATCH,$_ispGroup'],
    };
  }

  static bool _eligible(Map<String, dynamic> node) {
    final name = node['name'];
    final host = node['server'];
    final port = node['port'];
    final dialer = node['dialer-proxy'];
    return _upstreamProtocols.contains(node['type']) &&
        name is String &&
        name.trim().isNotEmpty &&
        host is String &&
        _validHost(host) &&
        port is int &&
        port >= 1 &&
        port <= 65535 &&
        (dialer == null || dialer == '');
  }
}
