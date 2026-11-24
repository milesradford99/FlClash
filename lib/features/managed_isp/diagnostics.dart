import 'dart:convert';
import 'dart:io';

enum IspCheckStatus {
  passed,
  failed,
  unverified,
  actionRequired,
  notApplicable,
}

typedef IspCheck = ({
  String id,
  IspCheckStatus status,
  String evidence,
  String next,
});

String ispReport({
  required String mode,
  required DateTime observedAt,
  required Iterable<IspCheck> checks,
  String? profile,
  Map<String, DateTime> checkTimes = const {},
}) => const JsonEncoder.withIndent('  ').convert([
  for (final check in checks)
    {
      'check_id': check.id,
      'status': check.status.name,
      'observed_at': (checkTimes[check.id] ?? observedAt)
          .toUtc()
          .toIso8601String(),
      'mode': mode,
      'chrome_profile': ?profile,
      'evidence': check.evidence,
      'next_action': check.next,
    },
]);

typedef BrowserProbeEvidence = ({
  String https,
  String ice,
  int candidateCount,
  Map<String, int> counts,
  String timeZone,
});

BrowserProbeEvidence decodeBrowserProbe(String input, {required String nonce}) {
  const addressClasses = {'public', 'private', 'local', 'mdns', 'unknown'};
  const candidateTypes = {'host', 'srflx', 'prflx', 'relay', 'unknown'};
  const outcomes = {'passed', 'failed', 'skipped', 'timeout'};
  if (input.length > 12000) throw const FormatException();
  final data = jsonDecode(input);
  if (data is! Map ||
      data['version'] != 1 ||
      data['nonce'] != nonce ||
      !outcomes.contains(data['https']) ||
      !outcomes.contains(data['ice']) ||
      data['counts'] is! Map ||
      data['candidateCount'] is! int ||
      data['timeZone'] is! String) {
    throw const FormatException();
  }
  final timeZone = data['timeZone'] as String;
  final count = data['candidateCount'] as int;
  if (count < 0 ||
      count > 10000 ||
      !RegExp(r'^[A-Za-z0-9_+/-]{1,80}$').hasMatch(timeZone)) {
    throw const FormatException();
  }
  final counts = <String, int>{};
  for (final entry in (data['counts'] as Map).entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! int || value < 1 || value > count) {
      throw const FormatException();
    }
    final parts = key.split('/');
    if (parts.length != 3 ||
        !candidateTypes.contains(parts[0]) ||
        !addressClasses.contains(parts[1]) ||
        !addressClasses.contains(parts[2])) {
      throw const FormatException();
    }
    counts[key] = value;
  }
  if (counts.values.fold(0, (total, n) => total + n) != count) {
    throw const FormatException();
  }
  return (
    https: data['https'] as String,
    ice: data['ice'] as String,
    candidateCount: count,
    counts: counts,
    timeZone: timeZone,
  );
}

Uri authorizedProbeUrl(String input) {
  final uri = Uri.parse(input.trim());
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException();
  }
  return uri;
}

Future<({bool https, String? ip, bool? systemResolved})> probeIspHttps(
  Uri url, {
  required int? proxyPort,
  required bool resolveSystem,
}) async {
  bool? systemResolved;
  if (resolveSystem) {
    try {
      systemResolved = (await InternetAddress.lookup(
        url.host,
      ).timeout(const Duration(seconds: 6))).isNotEmpty;
    } on Exception {
      systemResolved = false;
    }
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  client.findProxy = (_) =>
      proxyPort == null ? 'DIRECT' : 'PROXY 127.0.0.1:$proxyPort';
  try {
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 9));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 9));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return (https: false, ip: null, systemResolved: systemResolved);
    }
    return (
      https: true,
      ip: await _readObservedIp(
        response,
      ).timeout(const Duration(seconds: 5), onTimeout: () => null),
      systemResolved: systemResolved,
    );
  } on Exception {
    return (https: false, ip: null, systemResolved: systemResolved);
  } finally {
    client.close(force: true);
  }
}

Future<String?> _readObservedIp(HttpClientResponse response) async {
  final bytes = <int>[];
  await for (final part in response) {
    if (bytes.length + part.length > 4096) return null;
    bytes.addAll(part);
  }
  final text = utf8.decode(bytes, allowMalformed: true).trim();
  final direct = InternetAddress.tryParse(text);
  if (direct != null) return direct.address;
  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('ip=')) {
      return InternetAddress.tryParse(line.substring(3).trim())?.address;
    }
  }
  try {
    final parsed = jsonDecode(text);
    if (parsed is Map && parsed['ip'] is String) {
      return InternetAddress.tryParse(parsed['ip'] as String)?.address;
    }
  } on FormatException {
    return null;
  }
  return null;
}

typedef ChromeIspPolicy = ({
  String value,
  String source,
  String scope,
  String level,
  bool blocked,
});

typedef ChromeIspPolicies = ({
  ChromeIspPolicy? webRtc,
  ChromeIspPolicy? doh,
  bool templatesSet,
});

ChromeIspPolicies decodeChromeIspPolicies(String input) {
  if (input.length > 1024 * 1024) throw const FormatException();
  final data = jsonDecode(input);
  if (data is! Map) throw const FormatException();
  final container = data['policyGroups'] ?? data['policyValues'];
  final section = container is Map
      ? container['chrome'] ?? container['chromePolicies']
      : data['chromePolicies'];
  final policies = section is Map ? section['policies'] ?? section : null;
  if (policies is! Map) throw const FormatException();

  ChromeIspPolicy? read(String key, Set<String> allowed) {
    final policy = policies[key];
    if (policy == null) return null;
    if (policy is! Map) throw const FormatException();
    final value = policy['value'];
    return (
      value: allowed.contains(value) ? value as String : '—',
      source: _policyToken(policy['source']),
      scope: _policyToken(policy['scope']),
      level: _policyToken(policy['level']),
      blocked:
          policy['ignored'] == true ||
          policy['restartRequired'] == true ||
          _hasPolicyDetail(policy['error']) ||
          _hasPolicyDetail(policy['conflicts']),
    );
  }

  return (
    webRtc: read('WebRtcIPHandling', const {
      'default',
      'default_public_and_private_interfaces',
      'default_public_interface_only',
      'disable_non_proxied_udp',
    }),
    doh: read('DnsOverHttpsMode', const {'off', 'automatic', 'secure'}),
    templatesSet: policies.containsKey('DnsOverHttpsTemplates'),
  );
}

bool _hasPolicyDetail(Object? value) => switch (value) {
  null => false,
  final List values => values.isNotEmpty,
  final Map values => values.isNotEmpty,
  final String text => text.isNotEmpty,
  _ => true,
};

String _policyToken(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(value)
    ? value
    : '—';
