import 'dart:io';

import 'package:flutter/services.dart';

/// What only Android's side of the app knows (MainActivity).
class AndroidApp {
  static const _channel = MethodChannel('musify/app');

  /// The Android version (API level); 0 elsewhere or before [load].
  static int sdk = 0;

  /// The phone's name as the user set it, else its model; null elsewhere.
  static String? deviceName;

  static Future<void> load() async {
    if (!Platform.isAndroid) return;
    try {
      final device = await _channel.invokeMapMethod<String, Object?>('device');
      sdk = device?['sdk'] as int? ?? 0;
      deviceName = device?['name'] as String?;
    } catch (_) {}
  }

  /// Back on Home's first page: the app goes to the background, as Android
  /// apps do (the music carries on).
  static Future<void> toBackground() async {
    try {
      await _channel.invokeMethod('toBackground');
    } catch (_) {
      await SystemNavigator.pop();
    }
  }
}
