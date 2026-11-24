import 'dart:convert';
import 'dart:io';

const _ispGroup = 'Managed ISP';
const _scheme = 'flclash-isp';
const sharedIspVpnGroup = 'FlClash Shared VPN';
const sharedIspInbound = '__flclash_chrome_isp__';
const sharedIspOutbound = '__flclash_isp_exit__';

int? managedIspSourceId(String url) {
  final uri = Uri.tryParse(url);
  return uri?.scheme == _scheme ? int.tryParse(uri?.host ?? '') : null;
}

String managedIspUrl(int sourceId) => '$_scheme://$sourceId';

const managedIspHealthCheck = 'https://1.1.1.1/cdn-cgi/trace';

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
    this.expectedIp,
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
    if (expectedIp != null && InternetAddress.tryParse(expectedIp!) == null) {
      throw const FormatException('Invalid expected exit IP.');
    }
  }

  factory ManagedIspProfile.fromConnectionString({
    required Uri subscription,
    required String connectionString,
    String? expectedIp,
  }) {
    final uri = Uri.parse(connectionString.trim());
    final separator = uri.userInfo.indexOf(':');
    if (uri.scheme != 'socks5' ||
        !uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        separator < 0) {
      throw const FormatException('Expected a SOCKS5 connection URL.');
    }
    return ManagedIspProfile(
      subscription: subscription,
      ispHost: uri.host,
      ispPort: uri.port,
      username: Uri.decodeComponent(uri.userInfo.substring(0, separator)),
      password: Uri.decodeComponent(uri.userInfo.substring(separator + 1)),
      expectedIp: expectedIp,
    );
  }

  factory ManagedIspProfile.fromStorage(
    Uri subscription,
    Map<String, dynamic> data,
  ) => ManagedIspProfile(
    subscription: subscription,
    ispHost: data['host'] as String,
    ispPort: data['port'] as int,
    username: data['username'] as String,
    password: data['password'] as String,
    expectedIp: data['expectedIp'] as String?,
  );

  final Uri subscription;
  final int ispPort;
  final String? expectedIp;
  final String _host;
  final String _username;
  final String _password;

  Map<String, Object?> storage({
    required String digest,
    required Map<String, List<String>> addresses,
    Map<String, Object?>? previous,
  }) => {
    'host': _host,
    'port': ispPort,
    'username': _username,
    'password': _password,
    'expectedIp': expectedIp,
    'snapshot': {'digest': digest, 'addresses': addresses},
    'previous': previous,
  };

  Iterable<String> upstreamHosts(Map<String, dynamic> source) sync* {
    final nodes = source['proxies'];
    if (nodes is! List) return;
    final unique = <String>{};
    for (final node in nodes) {
      if (node is Map<String, dynamic> && _eligible(node)) {
        final host = node['server'] as String;
        if (unique.add(host)) yield host;
      }
    }
  }

  static bool _publicIpv4(String value) {
    final address = InternetAddress.tryParse(value);
    return address != null &&
        address.type == InternetAddressType.IPv4 &&
        !address.isLoopback &&
        !address.isLinkLocal &&
        !address.isMulticast &&
        address.rawAddress.first != 0 &&
        address.rawAddress.first < 224 &&
        !(address.rawAddress.first == 198 &&
            (address.rawAddress[1] == 18 || address.rawAddress[1] == 19));
  }

  Future<Map<String, List<String>>> resolve(
    Map<String, dynamic> source, {
    Map<String, List<String>> previous = const {},
    Future<List<String>> Function(String)? resolver,
  }) async {
    final result = <String, List<String>>{};
    final hosts = {...upstreamHosts(source), _host}.iterator;
    await Future.wait(
      List.generate(8, (_) async {
        while (hosts.moveNext()) {
          final host = hosts.current;
          List<String> addresses;
          final ip = InternetAddress.tryParse(host);
          if (ip != null) {
            addresses = [ip.address];
          } else {
            try {
              addresses = await (resolver ?? _systemLookup)(host);
              if (addresses.isEmpty) addresses = previous[host] ?? [];
            } on Exception {
              addresses = previous[host] ?? [];
            }
          }
          final usable = addresses.where(_publicIpv4).toSet().toList()..sort();
          if (usable.isNotEmpty) result[host] = usable;
        }
      }),
    );
    return result;
  }

  static Future<List<String>> _systemLookup(String name) async {
    final addresses = await InternetAddress.lookup(
      name,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 5));
    return addresses.map((ip) => ip.address).toList();
  }

  ({Map<String, Object> config, List<String> endpoints}) protectedConfig(
    Map<String, dynamic> source,
    Map<String, List<String>> addresses, {
    required String tun,
    required int mixedPort,
    required bool enableTun,
  }) {
    final outbounds = buildOutbounds(source, resolvedHosts: addresses);
    final proxies = outbounds['proxies'] as List<Map<String, dynamic>>;
    final endpoints = <String>{};
    final ispAddresses = addresses[_host]?.where(_publicIpv4).toList() ?? [];
    if (ispAddresses.isEmpty) {
      throw const FormatException(
        'The ISP server needs a usable IPv4 address.',
      );
    }
    final hosts = <String, List<String>>{_host: ispAddresses};
    for (var i = 0; i < proxies.length; i += 2) {
      final node = proxies[i];
      final host = node['server'] as String;
      final port = node['port'] as int;
      final ips = addresses[host]!.where(_publicIpv4).toList();
      hosts[host] = ips;
      final protocol = switch (node['type']) {
        'hysteria' ||
        'hysteria2' ||
        'tuic' ||
        'wireguard' ||
        'shadowquic' => 'udp',
        'vless' || 'vmess' when node['network'] == 'quic' => 'udp',
        _ => 'tcp',
      };
      for (final ip in ips) {
        endpoints.add('$protocol/$ip/$port');
      }
    }
    return (
      config: {
        ...outbounds,
        'mixed-port': mixedPort,
        'allow-lan': false,
        'bind-address': '127.0.0.1',
        'ipv6': false,
        'hosts': hosts,
        'profile': {'store-selected': false},
        'tun': enableTun
            ? {
                'enable': true,
                'device': tun,
                'stack': 'mixed',
                'auto-route': true,
                'auto-detect-interface': true,
                'strict-route': true,
                'dns-mode': 'native',
                'dns-hijack': ['any:53', 'tcp://any:53'],
              }
            : {'enable': false},
        'dns': {
          'enable': true,
          'ipv6': false,
          'use-hosts': true,
          'use-system-hosts': false,
          'enhanced-mode': 'fake-ip',
          'fake-ip-range': '198.18.128.1/17',
          'nameserver': ['https://1.1.1.1/dns-query#$_ispGroup'],
          'proxy-server-nameserver': ['https://1.1.1.1/dns-query#$_ispGroup'],
        },
      },
      endpoints: endpoints.toList()..sort(),
    );
  }

  /// Preserves subscription route targets while sharing the inline VPN leaves.
  Map<String, dynamic> sharedConfig(
    Map<String, dynamic> source, {
    required int port,
  }) {
    final proxies = _entries(source['proxies']);
    final groups = _entries(source['proxy-groups']);
    final listeners = _entries(source['listeners']);
    final names = <Object?>{
      for (final item in [...proxies, ...groups, ...listeners]) item['name'],
    };
    if (names.intersection({
          sharedIspVpnGroup,
          sharedIspInbound,
          sharedIspOutbound,
        }).isNotEmpty ||
        listeners.any((listener) => listener['port'].toString() == '$port')) {
      throw const FormatException(
        'The profile uses a reserved ISP listener or name.',
      );
    }
    final vpn = <String, String>{};
    for (final proxy in proxies.where(_eligible)) {
      final name = proxy['name'] as String;
      var runtimeName = 'VPN / $name';
      while (!names.add(runtimeName)) {
        runtimeName = 'VPN / $runtimeName';
      }
      vpn[name] = runtimeName;
    }
    if (vpn.isEmpty) {
      throw const FormatException(
        'The subscription needs supported inline VPN nodes.',
      );
    }

    return {
      ...source,
      'proxies': [
        for (final proxy in proxies)
          if (vpn[proxy['name']] case final String name)
            {...proxy, 'name': name}
          else
            proxy,
        {
          'name': sharedIspOutbound,
          'type': 'socks5',
          'server': _host,
          'port': ispPort,
          'username': _username,
          'password': _password,
          'udp': false,
          'dialer-proxy': sharedIspVpnGroup,
        },
      ],
      'proxy-groups': [
        {
          'name': sharedIspVpnGroup,
          'type': 'select',
          'proxies': vpn.values.toList(),
          'empty-fallback': 'REJECT',
        },
        for (final group in groups) _preserveGroup(group, proxies, vpn),
        for (final name in vpn.keys)
          {
            'name': name,
            'type': 'select',
            'hidden': true,
            'proxies': [sharedIspVpnGroup],
          },
      ],
      'listeners': [
        ...listeners,
        {
          'name': sharedIspInbound,
          'type': 'mixed',
          'listen': '127.0.0.1',
          'port': port,
          'udp': false,
          'proxy': sharedIspOutbound,
          'users': [],
        },
      ],
    };
  }

  static List<Map<String, dynamic>> _entries(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const [];

  static Map<String, dynamic> _preserveGroup(
    Map<String, dynamic> group,
    List<Map<String, dynamic>> proxies,
    Map<String, String> vpn,
  ) {
    final fallback = vpn[group['empty-fallback']];
    final includeAll = group['include-all'] == true;
    if (!includeAll && group['include-all-proxies'] != true) {
      return fallback == null ? group : {...group, 'empty-fallback': fallback};
    }
    final filters = (group['filter'] as String? ?? '')
        .split('`')
        .where((filter) => filter.isNotEmpty)
        .map(RegExp.new)
        .toList();
    final members = {
      if (group['proxies'] case final List items) ...items.whereType<String>(),
      for (final proxy in proxies)
        if (proxy['name'] case final String name
            when filters.isEmpty ||
                filters.any((filter) => filter.hasMatch(name)))
          name,
    };
    return {
      ...group,
      'include-all': false,
      'include-all-proxies': false,
      if (includeAll) 'include-all-providers': true,
      'proxies':
          members.isEmpty &&
              group['use'] == null &&
              !includeAll &&
              group['include-all-providers'] != true
          ? [group['empty-fallback'] ?? 'COMPATIBLE']
          : members.toList(),
      'empty-fallback': ?(fallback ?? group['empty-fallback']),
    };
  }

  static bool _validCredential(String value) =>
      value.isNotEmpty && utf8.encode(value).length <= 255;

  /// Builds the outbound portion of 01. The caller owns TUN and system protection.
  Map<String, Object> buildOutbounds(
    Map<String, dynamic> source, {
    Map<String, List<String>>? resolvedHosts,
  }) {
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
      final host = node['server'] as String;
      if (resolvedHosts != null &&
          !(resolvedHosts[host]?.any(_publicIpv4) ?? false)) {
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
          'url': managedIspHealthCheck,
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
        (dialer == null || dialer == '') &&
        node['ports'] == null &&
        node['port-hopping'] == null;
  }
}
