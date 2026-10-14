import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Light, dark, or as the device is set: chosen in Settings, kept between
/// launches.
class Appearance {
  Appearance._();

  static const _key = 'appearance';

  static final mode = ValueNotifier<ThemeMode>(ThemeMode.dark);

  static Future<void> load() async {
    try {
      final saved = (await SharedPreferences.getInstance()).getString(_key);
      mode.value = ThemeMode.values.asNameMap()[saved] ?? ThemeMode.dark;
    } catch (_) {}
  }

  static Future<void> set(ThemeMode value) async {
    mode.value = value;
    (await SharedPreferences.getInstance()).setString(_key, value.name);
  }
}
