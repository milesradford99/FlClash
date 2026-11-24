import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const managedIspTun = 'utun223';
const managedIspLocalPort = 17890;
const managedIspLocalAddress = '127.0.0.1:$managedIspLocalPort';
const managedIspSystemProtection = bool.fromEnvironment(
  'MANAGED_ISP_PROTECTION',
);
final managedIspExit = ValueNotifier<({int profileId, String? ip})?>(null);

class ManagedIspPlatform {
  const ManagedIspPlatform();

  static const _channel = MethodChannel('flclash/managed_isp');

  Future<bool> get available async =>
      managedIspSystemProtection &&
      (await _channel.invokeMethod<bool>('available') ?? false);

  Future<int?> get protectedProfile async {
    if (!managedIspSystemProtection) return null;
    try {
      return await _channel.invokeMethod<int>('protectedProfile');
    } on MissingPluginException {
      return null;
    }
  }

  Future<Map<String, dynamic>?> load(int id) =>
      _channel.invokeMapMethod<String, dynamic>('load', id);

  Future<void> save(int id, Map<String, Object?> data) =>
      _channel.invokeMethod<void>('save', {'id': id, 'data': data});

  Future<void> remove(int id) => _channel.invokeMethod<void>('remove', id);

  Future<void> arm({
    required int id,
    required int sourceId,
    required List<String> endpoints,
  }) => _channel.invokeMethod<void>('arm', {
    'id': id,
    'sourceId': sourceId,
    'tun': managedIspTun,
    'endpoints': endpoints,
  });

  Future<int?> get protectedSource =>
      _channel.invokeMethod<int>('protectedSource');

  Future<void> disarm() => _channel.invokeMethod<void>('disarm');

  Future<bool> get tunReady async =>
      await _channel.invokeMethod<bool>('tunReady') ?? false;

  Future<Map<String, dynamic>?> environment() =>
      _channel.invokeMapMethod<String, dynamic>('environment');

  Future<void> environmentShortcut(String kind, {String? directory}) =>
      _channel.invokeMethod<void>('environmentShortcut', {
        'kind': kind,
        'directory': ?directory,
      });

  Future<void> openIspChrome() =>
      _channel.invokeMethod<void>('openIspChrome', managedIspLocalPort);

  Future<void> openBrowserProbe(String html, String directory) =>
      _channel.invokeMethod<void>('openBrowserProbe', {
        'html': html,
        'directory': directory,
      });

  Future<void> openChromeProfile() =>
      _channel.invokeMethod<void>('openChromeProfile');

  Future<void> writePrivate(String path, String config) => _channel
      .invokeMethod<void>('writePrivate', {'path': path, 'config': config});
}
