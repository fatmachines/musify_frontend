import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// A muted, dark-enough version of a cover's average colour, for the
/// gradient behind a playlist header (white text has to stay readable).
Future<Color?> coverColor(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes,
        targetWidth: 24, targetHeight: 24);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (data == null) return null;

    var r = 0, g = 0, b = 0, n = 0;
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      r += data.getUint8(i);
      g += data.getUint8(i + 1);
      b += data.getUint8(i + 2);
      n++;
    }
    if (n == 0) return null;
    final hsl = HSLColor.fromColor(Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n));
    return hsl
        .withSaturation((hsl.saturation * 1.3).clamp(0.25, 0.75))
        .withLightness(hsl.lightness.clamp(0.22, 0.38))
        .toColor();
  } catch (_) {
    return null;
  }
}
