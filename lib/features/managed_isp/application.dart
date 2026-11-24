import 'package:fl_clash/features/managed_isp/profile.dart';

class ManagedIspApplication {
  const ManagedIspApplication({
    required this.name,
    required this.path,
    required this.bundle,
    this.enabled = true,
  });

  final String name;
  final String path;
  final bool bundle;
  final bool enabled;

  static ManagedIspApplication fromJson(Map<dynamic, dynamic> json) {
    final name = json['name'];
    final path = json['path'];
    final bundle = json['bundle'];
    if (name is! String ||
        name.isEmpty ||
        path is! String ||
        !path.startsWith('/') ||
        path.endsWith('/') ||
        bundle is! bool ||
        (bundle && !path.toLowerCase().endsWith('.app'))) {
      throw const FormatException('Invalid fixed ISP application.');
    }
    return ManagedIspApplication(
      name: name,
      path: path,
      bundle: bundle,
      enabled: json['enabled'] != false,
    );
  }

  Map<String, Object> toJson() => {
    'name': name,
    'path': path,
    'bundle': bundle,
    'enabled': enabled,
  };

  ManagedIspApplication withEnabled(bool value) => ManagedIspApplication(
    name: name,
    path: path,
    bundle: bundle,
    enabled: value,
  );

  String get _matchPath => bundle ? '$path/Contents/' : path;

  bool matches(String processPath) {
    final target = processPath.toLowerCase();
    final expected = _matchPath.toLowerCase();
    return bundle ? target.startsWith(expected) : target == expected;
  }

  String get _pattern {
    final text = _matchPath.replaceAllMapped(
      RegExp(r'[\\.^$|?*+()\[\]{},\x00-\x20\x7f]'),
      (match) =>
          '\\x${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}',
    );
    return '^$text${bundle ? '' : r'\z'}';
  }

  List<String> get rules {
    final process = '(PROCESS-PATH-REGEX,$_pattern)';
    const local =
        '(OR,((IN-TYPE,TUN),(SRC-IP-CIDR,127.0.0.0/8),(SRC-IP-CIDR,::1/128)))';
    return [
      'AND,($local,$process,(NETWORK,UDP)),REJECT',
      'AND,($local,$process,(NETWORK,TCP)),$sharedIspOutbound',
    ];
  }
}
