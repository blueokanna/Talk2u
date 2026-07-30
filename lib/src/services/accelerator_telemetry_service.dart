import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

@immutable
class AcceleratorTelemetrySample {
  const AcceleratorTelemetrySample({
    required this.available,
    required this.percent,
    required this.active,
    required this.intervalMilliseconds,
    required this.invocations,
    required this.source,
  });

  final bool available;
  final double? percent;
  final bool active;
  final int intervalMilliseconds;
  final int invocations;
  final String source;

  factory AcceleratorTelemetrySample.fromMap(Map<dynamic, dynamic> value) {
    final percent = value['percent'];
    return AcceleratorTelemetrySample(
      available: value['available'] == true,
      percent: percent is num
          ? percent.toDouble().clamp(0, 100).toDouble()
          : null,
      active: value['active'] == true,
      intervalMilliseconds: (value['intervalMillis'] as num?)?.toInt() ?? 0,
      invocations: (value['invocations'] as num?)?.toInt() ?? 0,
      source: value['source']?.toString() ?? '',
    );
  }
}

class AcceleratorTelemetryService {
  AcceleratorTelemetryService._();

  static final instance = AcceleratorTelemetryService._();
  static const _channel = MethodChannel('talk2u/accelerator_telemetry');

  Timer? _timer;
  bool _sampling = false;
  AcceleratorTelemetrySample? latest;

  void start() {
    if (_timer != null || kIsWeb) return;
    unawaited(sample());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(sample());
    });
  }

  Future<AcceleratorTelemetrySample?> sample() async {
    if (_sampling || kIsWeb) return latest;
    _sampling = true;
    try {
      final value = await _channel.invokeMapMethod<dynamic, dynamic>('sample');
      if (value != null) latest = AcceleratorTelemetrySample.fromMap(value);
    } on PlatformException {
      latest = null;
    } finally {
      _sampling = false;
    }
    return latest;
  }
}
