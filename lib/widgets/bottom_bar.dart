import 'package:flutter/material.dart';

import '../theme.dart';

/// Spotify-style tab bar: no indicator, white when selected and grey when
/// not, laid over the content on a gradient that fades it out to black.
class BottomBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  /// Shown above the tabs inside the bar's fade (the mini player).
  final Widget? header;

  const BottomBar({
    super.key,
    required this.index,
    required this.onSelect,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xE6000000), Color(0xFF000000)],
          stops: [0, 0.45, 1],
        ),
      ),
      padding: EdgeInsets.only(top: 16, bottom: bottom > 0 ? bottom : 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?header,
          Row(
            children: [
              _item(
                0,
                'Home',
                (c, s) => Icon(
                  s ? Icons.home_filled : Icons.home_outlined,
                  color: c,
                  size: 28,
                ),
              ),
              _item(
                1,
                'Search',
                (c, s) => Icon(
                  Icons.search,
                  color: c,
                  size: 28,
                  weight: s ? 700 : 400,
                ),
              ),
              _item(
                2,
                'Your Library',
                (c, s) => LibraryIcon(color: c, filled: s, size: 28),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _item(
    int i,
    String label,
    Widget Function(Color color, bool selected) icon,
  ) {
    final selected = i == index;
    final color = selected ? AppColors.text : AppColors.subtle;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkResponse(
          onTap: () => onSelect(i),
          radius: 36,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon(color, selected),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Spotify's library mark: two upright bars and a leaning book.
class LibraryIcon extends StatelessWidget {
  final Color color;
  final bool filled;
  final double size;

  const LibraryIcon({
    super.key,
    required this.color,
    this.filled = false,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _LibraryPainter(color, filled),
    );
  }
}

class _LibraryPainter extends CustomPainter {
  final Color color;
  final bool filled;

  _LibraryPainter(this.color, this.filled);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = Paint()
      ..color = color
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final top = s * 0.14, bottom = s * 0.86;

    canvas.drawLine(Offset(s * 0.18, top), Offset(s * 0.18, bottom), stroke);
    canvas.drawLine(Offset(s * 0.38, top), Offset(s * 0.38, bottom), stroke);

    final book = Path()
      ..moveTo(s * 0.54, s * 0.22)
      ..lineTo(s * 0.70, s * 0.16)
      ..lineTo(s * 0.88, bottom)
      ..lineTo(s * 0.70, bottom)
      ..close();
    if (filled) {
      canvas.drawPath(book, Paint()..color = color);
    } else {
      canvas.drawPath(book, stroke..strokeJoin = StrokeJoin.round);
    }
  }

  @override
  bool shouldRepaint(_LibraryPainter old) =>
      old.color != color || old.filled != filled;
}
