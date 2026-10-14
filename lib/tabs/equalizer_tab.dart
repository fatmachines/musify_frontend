import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../services/equalizer_service.dart';
import '../theme.dart';

class EqualizerTab extends StatelessWidget {
  const EqualizerTab({super.key});

  @override
  Widget build(BuildContext context) {
    final eq = EqualizerService.instance;
    return ListenableBuilder(
      listenable: eq,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.green,
                child: Icon(Icons.graphic_eq, size: 18, color: Colors.black),
              ),
              SizedBox(width: 12),
              Text('Equalizer'),
            ],
          ),
          actions: [
            Switch(
              value: eq.enabled,
              onChanged: eq.setEnabled,
              activeThumbColor: Colors.white,
              activeTrackColor: AppColors.green,
            ),
            const SizedBox(width: 8),
          ],
        ),
        // The graph stays put (dragging its points never scrolls the
        // page); only the presets below it scroll.
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: eq.enabled ? 1 : 0.45,
                child: const _EqGraph(),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  MediaQuery.paddingOf(context).bottom + 16,
                ),
                children: [
                  Row(
                    children: [
                      const Text(
                        'Presets',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: eq.reset,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.subtle,
                        ),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in eqPresets)
                        _PresetChip(
                          label: preset.name,
                          selected: eq.enabled && eq.preset == preset.name,
                          onTap: () => eq.choosePreset(preset),
                        ),
                      if (eq.preset == customPreset)
                        _PresetChip(
                          label: customPreset,
                          selected: eq.enabled,
                          onTap: () => eq.setEnabled(true),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    Platform.isAndroid
                        ? 'Uses your phone\'s built-in equalizer.'
                        : 'Drag a point up or down to shape the sound. Changes '
                              'apply straight away, to every song.',
                    style: TextStyle(color: AppColors.subtle, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        color: selected ? Colors.black : AppColors.text,
        fontWeight: FontWeight.w500,
      ),
      selectedColor: AppColors.green,
      backgroundColor: AppColors.chip,
      side: BorderSide.none,
      shape: const StadiumBorder(),
    );
  }
}

/// The equalizer curve: one point per band, dragged up or down to set its
/// gain, with a smooth line through them.
class _EqGraph extends StatefulWidget {
  const _EqGraph();

  @override
  State<_EqGraph> createState() => _EqGraphState();
}

class _EqGraphState extends State<_EqGraph> {
  static const _height = 240.0;
  static const _labelsHeight = 24.0;

  int? _dragging;

  /// The dragged band's gain before snapping, so small moves add up.
  double _dragDb = 0;

  EqualizerService get _eq => EqualizerService.instance;

  int _bandAt(double x, double width) {
    final count = _eq.frequencies.length;
    final step = width / count;
    return (x / step).floor().clamp(0, count - 1);
  }

  double get _dbPerPixel => (_eq.maxDb - _eq.minDb) / (_height - _labelsHeight);

  double _dbAt(double y) {
    final t = (y / (_height - _labelsHeight)).clamp(0.0, 1.0);
    return _eq.maxDb - t * (_eq.maxDb - _eq.minDb);
  }

  /// Half-dB steps, with a little pull to 0.
  static double _snap(double db) {
    final snapped = (db * 2).round() / 2;
    return snapped.abs() < 0.5 ? 0 : snapped;
  }

  /// Touching picks the nearest band without moving it.
  void _grab(Offset local, double width) {
    final band = _bandAt(local.dx, width);
    setState(() {
      _dragging = band;
      _dragDb = _eq.gains[band];
    });
  }

  /// Dragging moves the band from where it was.
  void _drag(DragUpdateDetails details) {
    final band = _dragging;
    if (band == null) return;
    _dragDb = (_dragDb - details.delta.dy * _dbPerPixel).clamp(
      _eq.minDb,
      _eq.maxDb,
    );
    _eq.setGain(band, _snap(_dragDb));
  }

  /// A tap puts the band where the finger is.
  void _tap(TapUpDetails details, double width) {
    _eq.setGain(
      _bandAt(details.localPosition.dx, width),
      _snap(_dbAt(details.localPosition.dy)),
    );
    setState(() => _dragging = null);
  }

  void _release() => setState(() => _dragging = null);

  @override
  Widget build(BuildContext context) {
    // Listens itself: as a const child it isn't rebuilt with the tab.
    return ListenableBuilder(
      listenable: _eq,
      builder: (context, _) => _buildGraph(),
    );
  }

  Widget _buildGraph() {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        // Count the whole drag, including the first few pixels.
        dragStartBehavior: DragStartBehavior.down,
        onPanDown: (d) => _grab(d.localPosition, box.maxWidth),
        onPanUpdate: _drag,
        onPanEnd: (_) => _release(),
        onPanCancel: _release,
        onTapUp: (d) => _tap(d, box.maxWidth),
        child: Container(
          height: _height,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: CustomPaint(
            painter: _CurvePainter(
              frequencies: _eq.frequencies,
              gains: _eq.gains,
              minDb: _eq.minDb,
              maxDb: _eq.maxDb,
              active: _dragging,
              labelsHeight: _labelsHeight,
            ),
            size: Size(box.maxWidth, _height),
          ),
        ),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  final List<double> frequencies;
  final List<double> gains;
  final double minDb;
  final double maxDb;
  final int? active;
  final double labelsHeight;

  _CurvePainter({
    required this.frequencies,
    required this.gains,
    required this.minDb,
    required this.maxDb,
    required this.active,
    required this.labelsHeight,
  });

  static String _label(double hz) => hz >= 1000
      ? '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)}K'
      : hz.round().toString();

  @override
  void paint(Canvas canvas, Size size) {
    final plotHeight = size.height - labelsHeight;
    final step = size.width / gains.length;
    double y(double db) => (maxDb - db) / (maxDb - minDb) * plotHeight;
    final points = [
      for (var i = 0; i < gains.length; i++)
        Offset(step * (i + 0.5), y(gains[i])),
    ];

    // 0 dB line and the ±dB guides.
    final guide = Paint()
      ..color = AppColors.faint
      ..strokeWidth = 1;
    for (final db in [maxDb, maxDb / 2, minDb / 2, minDb]) {
      canvas.drawLine(Offset(0, y(db)), Offset(size.width, y(db)), guide);
    }
    canvas.drawLine(
      Offset(0, y(0)),
      Offset(size.width, y(0)),
      Paint()
        ..color = AppColors.text.withValues(alpha: 0.3)
        ..strokeWidth = 1,
    );

    // A smooth line through the points (Catmull-Rom), held flat at the ends.
    final ends = [
      Offset(0, points.first.dy),
      ...points,
      Offset(size.width, points.last.dy),
    ];
    final curve = Path()..moveTo(ends.first.dx, ends.first.dy);
    for (var i = 0; i < ends.length - 1; i++) {
      final p0 = ends[i == 0 ? 0 : i - 1];
      final p1 = ends[i];
      final p2 = ends[i + 1];
      final p3 = ends[i + 2 < ends.length ? i + 2 : i + 1];
      curve.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }
    final fill = Path.from(curve)
      ..lineTo(size.width, plotHeight)
      ..lineTo(0, plotHeight)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x661ED760), Color(0x001ED760)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, plotHeight)),
    );
    canvas.drawPath(
      curve,
      Paint()
        ..color = AppColors.green
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );

    for (var i = 0; i < points.length; i++) {
      final big = i == active;
      canvas.drawCircle(
        points[i],
        big ? 9 : 6,
        Paint()..color = AppColors.text,
      );
      canvas.drawCircle(
        points[i],
        big ? 9 : 6,
        Paint()
          ..color = AppColors.green
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      if (big) {
        _text(
          canvas,
          '${gains[i] > 0 ? '+' : ''}${gains[i].toStringAsFixed(1)} dB',
          Offset(points[i].dx, (points[i].dy - 26).clamp(4, plotHeight)),
          bold: true,
        );
      }
      _text(
        canvas,
        _label(frequencies[i]),
        Offset(points[i].dx, plotHeight + 4),
      );
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset topCenter, {
    bool bold = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Figtree',
          color: bold ? AppColors.text : AppColors.subtle,
          fontSize: 11,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(topCenter.dx - painter.width / 2, topCenter.dy),
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) => true;
}
