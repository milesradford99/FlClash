import 'dart:convert';

import 'package:fl_clash/features/managed_isp/browser_probe.dart';
import 'package:fl_clash/features/managed_isp/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser evidence is scoped to the run and contains only counts', () {
    final payload = {
      'version': 1,
      'nonce': 'fixture',
      'https': 'passed',
      'ice': 'passed',
      'candidateCount': 2,
      'counts': {'host/mdns/unknown': 1, 'relay/public/private': 1},
      'timeZone': 'America/Los_Angeles',
    };
    final evidence = decodeBrowserProbe(jsonEncode(payload), nonce: 'fixture');
    expect(evidence.https, 'passed');
    expect(evidence.counts['host/mdns/unknown'], 1);
    expect(evidence.candidateCount, 2);
    expect(
      () => decodeBrowserProbe(jsonEncode(payload), nonce: 'previous'),
      throwsFormatException,
    );
    payload['counts'] = {'host/192.0.2.8/unknown': 2};
    expect(
      () => decodeBrowserProbe(jsonEncode(payload), nonce: 'fixture'),
      throwsFormatException,
    );
  });

  test('policy export keeps metadata and discards sensitive values', () {
    final result = decodeChromeIspPolicies(
      jsonEncode({
        'policyGroups': {
          'chrome': {
            'policies': {
              'WebRtcIPHandling': {
                'value': 'disable_non_proxied_udp',
                'source': 'platform',
                'scope': 'machine',
                'level': 'mandatory',
                'conflicts': [
                  {'value': 'default'},
                ],
              },
              'DnsOverHttpsMode': {'value': 'secure', 'source': 'cloud'},
              'DnsOverHttpsTemplates': {
                'value': 'https://private.test/dns-query',
              },
            },
          },
        },
        'status': {
          'user': {'username': 'private@example.test'},
        },
      }),
    );
    expect(result.webRtc?.source, 'platform');
    expect(result.webRtc?.blocked, isTrue);
    expect(result.doh?.value, 'secure');
    expect(result.templatesSet, isTrue);
    expect(result.toString(), isNot(contains('private')));
    expect(decodeChromeIspPolicies('{"chromePolicies":{}}').webRtc, isNull);
    expect(() => decodeChromeIspPolicies('{}'), throwsFormatException);
  });

  test('reports configuration and behavior independently', () {
    final observed = DateTime.utc(2026, 1, 1);
    final report =
        jsonDecode(
              ispReport(
                mode: 'local_proxy',
                observedAt: observed,
                profile: 'Profile 2',
                checkTimes: {'ice': observed.add(const Duration(seconds: 8))},
                checks: [
                  (
                    id: 'policy',
                    status: IspCheckStatus.passed,
                    evidence: 'configured',
                    next: '',
                  ),
                  (
                    id: 'ice',
                    status: IspCheckStatus.unverified,
                    evidence: 'ICE complete',
                    next: 'Verify egress',
                  ),
                ],
              ),
            )
            as List;
    expect(report.first, containsPair('status', 'passed'));
    expect(report.last, containsPair('status', 'unverified'));
    expect(
      report.last,
      containsPair('observed_at', '2026-01-01T00:00:08.000Z'),
    );
    expect(report.last, containsPair('chrome_profile', 'Profile 2'));
  });

  test('probe accepts only an authorized HTTPS URL without credentials', () {
    expect(
      authorizedProbeUrl('https://one-time.example.test/').host,
      'one-time.example.test',
    );
    for (final address in [
      'http://one-time.example.test/',
      'https://user:secret@one-time.example.test/',
      'https://one-time.example.test/#fragment',
    ]) {
      expect(() => authorizedProbeUrl(address), throwsFormatException);
    }
    final page = ispBrowserProbePage(chinese: true, nonce: 'fixture');
    expect(page, contains('data-nonce="fixture"'));
    expect(page, isNot(contains('1.1.1.1')));
    expect(page, contains('connection?.close()'));
  });
}
