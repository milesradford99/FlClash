import 'package:flutter/foundation.dart';

typedef IspMonitorSettings = ({bool enabled, int seconds});

const IspMonitorSettings defaultIspMonitorSettings = (
  enabled: false,
  seconds: 120,
);

final managedIspMonitorState = ValueNotifier<({int profileId, String state})?>(
  null,
);

bool validIspMonitorSeconds(int seconds) => seconds >= 1 && seconds <= 86400;
