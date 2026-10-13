import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// A preset as a curve: dB at a few frequencies, interpolated (on a log
/// frequency scale) onto whatever bands the device has.
class EqPreset {
  final String name;

  /// dB by frequency in Hz.
  final Map<int, double> curve;

  const EqPreset(this.name, this.curve);

  double gainAt(double frequency) {
    if (curve.isEmpty) return 0;
    final points = curve.keys.toList()..sort();
    if (frequency <= points.first) return curve[points.first]!;
    if (frequency >= points.last) return curve[points.last]!;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      if (frequency <= b) {
        final t = (log(frequency) - log(a)) / (log(b) - log(a));
        return curve[a]! + (curve[b]! - curve[a]!) * t;
      }
    }
    return 0;
  }
}

const eqPresets = [
  EqPreset('Flat', {}),
  EqPreset('Bass Booster', {32: 6, 64: 5, 125: 4, 250: 2, 500: 0}),
  EqPreset('Bass Reducer', {32: -6, 64: -5, 125: -4, 250: -2, 500: 0}),
  EqPreset('Treble Booster', {1000: 0, 2000: 1, 4000: 3, 8000: 5, 16000: 6}),
  EqPreset('Treble Reducer', {
    1000: 0,
    2000: -1,
    4000: -3,
    8000: -5,
    16000: -6,
  }),
  EqPreset('Vocal', {
    32: -2,
    125: -1,
    500: 1,
    1000: 3,
    2000: 4,
    4000: 3,
    8000: 1,
    16000: 0,
  }),
  EqPreset('Rock', {
    32: 5,
    64: 4,
    125: 3,
    250: 1,
    500: -1,
    1000: -1,
    2000: 1,
    4000: 3,
    8000: 4,
    16000: 5,
  }),
  EqPreset('Pop', {
    32: -1,
    64: 1,
    125: 3,
    250: 4,
    500: 3,
    1000: 1,
    2000: -1,
    4000: -1,
    8000: 0,
    16000: 1,
  }),
  EqPreset('Hip-Hop', {
    32: 5,
    64: 4,
    125: 2,
    250: 3,
    500: -1,
    1000: -1,
    2000: 1,
    4000: 0,
    8000: 2,
    16000: 3,
  }),
  EqPreset('Electronic', {
    32: 4,
    64: 4,
    125: 1,
    250: 0,
    500: -2,
    1000: 2,
    2000: 1,
    4000: 1,
    8000: 4,
    16000: 5,
  }),
  EqPreset('Jazz', {
    32: 3,
    64: 2,
    125: 1,
    250: 2,
    500: -1,
    1000: -1,
    2000: 0,
    4000: 1,
    8000: 2,
    16000: 3,
  }),
  EqPreset('Classical', {
    32: 4,
    64: 3,
    125: 2,
    250: 1,
    500: -1,
    1000: -1,
    2000: 0,
    4000: 2,
    8000: 3,
    16000: 4,
  }),
  EqPreset('Acoustic', {
    32: 4,
    64: 4,
    125: 3,
    250: 1,
    500: 2,
    1000: 2,
    2000: 3,
    4000: 3,
    8000: 2,
    16000: 1,
  }),
  EqPreset('Loudness', {
    32: 5,
    64: 4,
    125: 1,
    250: 0,
    500: -1,
    1000: 0,
    2000: -1,
    4000: 1,
    8000: 4,
    16000: 3,
  }),
];

const customPreset = 'Custom';

/// The equalizer behind the Equalizer tab. On iOS it drives Musify's audio
/// tap in the vendored just_audio (10 bands, see packages/just_audio); on
/// Android just_audio's AndroidEqualizer with the device's own bands.
/// Settings are saved and applied at launch.
class EqualizerService extends ChangeNotifier {
  EqualizerService._();

  static final instance = EqualizerService._();

  static const _prefsKey = 'equalizer_v1';
  static const _channel = MethodChannel('musify/equalizer');

  /// iOS bands, matching MusifyEqualizer.m.
  static const _tapBands = <double>[
    32,
    64,
    125,
    250,
    500,
    1000,
    2000,
    4000,
    8000,
    16000,
  ];

  /// Passed to the AudioPlayer on Android (see PlayerService).
  final AndroidEqualizer? android = Platform.isAndroid
      ? AndroidEqualizer()
      : null;

  bool _enabled = false;
  String _preset = 'Flat';
  List<double> _frequencies = _tapBands;
  List<double> _gains = List.filled(_tapBands.length, 0);
  double _minDb = -12;
  double _maxDb = 12;

  /// Gains saved by frequency, so they carry over if the band set changes.
  Map<double, double> _saved = {};

  bool get enabled => _enabled;
  String get preset => _preset;
  List<double> get frequencies => _frequencies;
  List<double> get gains => List.unmodifiable(_gains);
  double get minDb => _minDb;
  double get maxDb => _maxDb;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        _enabled = data['enabled'] as bool? ?? false;
        _preset = data['preset'] as String? ?? 'Flat';
        _saved = {
          for (final e in (data['gains'] as Map<String, dynamic>).entries)
            double.parse(e.key): (e.value as num).toDouble(),
        };
      }
    } catch (e) {
      AppLog.add('equalizer: load failed: $e');
    }
    _gains = [for (final f in _frequencies) _gainFor(f)];
    notifyListeners();
    await _apply();

    // Android reports its bands once the player is up.
    android?.parameters.then((parameters) {
      _frequencies = [for (final b in parameters.bands) b.centerFrequency];
      _minDb = parameters.minDecibels;
      _maxDb = parameters.maxDecibels;
      _gains = [for (final f in _frequencies) _gainFor(f)];
      notifyListeners();
      _apply();
    });
  }

  double _gainFor(double frequency) {
    final preset = eqPresets.where((p) => p.name == _preset).firstOrNull;
    final gain = preset != null
        ? preset.gainAt(frequency)
        : _saved[frequency] ??
              EqPreset(customPreset, {
                for (final e in _saved.entries) e.key.round(): e.value,
              }).gainAt(frequency);
    return gain.clamp(_minDb, _maxDb);
  }

  void setEnabled(bool enabled) {
    _enabled = enabled;
    _changed();
  }

  void choosePreset(EqPreset preset) {
    _preset = preset.name;
    _gains = [
      for (final f in _frequencies) preset.gainAt(f).clamp(_minDb, _maxDb),
    ];
    _enabled = true;
    _changed();
  }

  /// Moving a band switches to the custom curve (and turns the EQ on).
  void setGain(int band, double db) {
    _gains[band] = db.clamp(_minDb, _maxDb);
    _preset = customPreset;
    _enabled = true;
    _changed();
  }

  void reset() => choosePreset(eqPresets.first);

  void _changed() {
    _saved = {
      for (var i = 0; i < _frequencies.length; i++) _frequencies[i]: _gains[i],
    };
    notifyListeners();
    _apply();
    _save();
  }

  Future<void> _apply() async {
    try {
      final eq = android;
      if (eq != null) {
        await eq.setEnabled(_enabled);
        // The bands exist once the player is up; set them then.
        final gains = List.of(_gains);
        eq.parameters.then((parameters) async {
          for (
            var i = 0;
            i < parameters.bands.length && i < gains.length;
            i++
          ) {
            await parameters.bands[i].setGain(gains[i]);
          }
        });
      } else if (Platform.isIOS || Platform.isMacOS) {
        await _channel.invokeMethod('set', {
          'enabled': _enabled,
          'gains': _gains,
        });
      }
    } catch (e) {
      AppLog.add('equalizer: apply failed: $e');
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'enabled': _enabled,
        'preset': _preset,
        'gains': {for (final e in _saved.entries) '${e.key}': e.value},
      }),
    );
  }

  @visibleForTesting
  void debugReset() {
    _enabled = false;
    _preset = 'Flat';
    _frequencies = _tapBands;
    _gains = List.filled(_tapBands.length, 0);
    _saved = {};
  }
}
