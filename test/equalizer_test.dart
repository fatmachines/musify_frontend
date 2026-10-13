import 'package:flutter_test/flutter_test.dart';
import 'package:musify/services/equalizer_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('presets interpolate between their points on a log scale', () {
    const preset = EqPreset('Test', {100: 0, 1000: 6});
    expect(preset.gainAt(50), 0);
    expect(preset.gainAt(1000), 6);
    expect(preset.gainAt(5000), 6);
    // 316 Hz is halfway between 100 and 1000 in octaves.
    expect(preset.gainAt(316.23), closeTo(3, 0.01));
  });

  test('choosing presets, dragging bands and coming back later', () async {
    SharedPreferences.setMockInitialValues({});
    final eq = EqualizerService.instance..debugReset();
    await eq.init();
    expect(eq.enabled, isFalse);
    expect(eq.frequencies, hasLength(10));
    expect(eq.gains, everyElement(0));

    final bass = eqPresets.firstWhere((p) => p.name == 'Bass Booster');
    eq.choosePreset(bass);
    expect(eq.enabled, isTrue);
    expect(eq.preset, 'Bass Booster');
    expect(eq.gains.first, 6);
    expect(eq.gains.last, 0);

    eq.setGain(9, 4);
    expect(eq.preset, customPreset);
    expect(eq.gains.last, 4);
    eq.setGain(0, 40); // out of range
    expect(eq.gains.first, eq.maxDb);

    // Saved: a fresh start comes back the same.
    await Future<void>.delayed(Duration.zero);
    eq.debugReset();
    await eq.init();
    expect(eq.enabled, isTrue);
    expect(eq.preset, customPreset);
    expect(eq.gains.first, 12);
    expect(eq.gains.last, 4);

    eq.reset();
    expect(eq.preset, 'Flat');
    expect(eq.gains, everyElement(0));
  });
}
