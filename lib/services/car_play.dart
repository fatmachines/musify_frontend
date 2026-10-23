import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'library.dart';

/// CarPlay's library screens (iOS): the native side (CarPlaySceneDelegate
/// in ios/Runner/AppDelegate.swift) shows the same tree Android Auto
/// browses, read from the audio handler over the musify/carplay channel.
class CarPlay {
  static const _channel = MethodChannel('musify/carplay');
  static Timer? _changedSoon;

  static Future<void> init(AudioHandler handler) async {
    if (!Platform.isIOS) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'children':
          final items = await handler.getChildren(call.arguments as String);
          return [
            for (final item in items)
              {
                'id': item.id,
                'title': item.title,
                'subtitle': item.displaySubtitle ?? item.artist,
                'playable': item.playable ?? true,
              },
          ];
        case 'play':
          AppLog.add('carplay: play ${call.arguments}');
          await handler.playFromMediaId(call.arguments as String);
          return null;
      }
      return null;
    });
    // The native side may register its channel just after Dart starts.
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await _channel.invokeMethod('ready');
        break;
      } on MissingPluginException {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        AppLog.add('carplay: ready failed: $e');
        break;
      }
    }
    Library.instance.addListener(_changedLater);
  }

  /// Refreshes the car's playlist list after library edits.
  static void _changedLater() {
    _changedSoon?.cancel();
    _changedSoon = Timer(const Duration(seconds: 1), () {
      _channel.invokeMethod('changed').catchError((Object e) {
        AppLog.add('carplay: changed failed: $e');
      });
    });
  }
}
