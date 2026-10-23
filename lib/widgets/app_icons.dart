import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Musify's own soft, rounded player icons (assets/icons), drawn in the
/// surrounding icon colour and size like an [Icon].
enum AppIcon { shuffle, repeat, repeatOne, share }

class AppIconView extends StatelessWidget {
  final AppIcon icon;
  final double? size;
  final Color? color;

  const AppIconView(this.icon, {super.key, this.size, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final box = size ?? theme.size ?? 24;
    final paint = color ?? theme.color ?? Colors.white;
    // The shuffle and repeat artwork fills its whole box, where Material's
    // icons leave a margin: drawn a little smaller to match them. Share's
    // artwork has its own margin.
    final glyph = icon == AppIcon.share ? box : box * 0.8;
    Widget svg(String name) => SvgPicture.asset(
      'assets/icons/$name.svg',
      width: glyph,
      height: glyph,
      colorFilter: ColorFilter.mode(paint, BlendMode.srcIn),
    );
    return SizedBox.square(
      dimension: box,
      child: Center(
        child: switch (icon) {
          AppIcon.shuffle => svg('shuffle'),
          AppIcon.share => svg('share'),
          AppIcon.repeat => svg('repeat'),
          AppIcon.repeatOne => Stack(
            alignment: Alignment.center,
            children: [
              svg('repeat'),
              Text(
                '1',
                style: TextStyle(
                  color: paint,
                  fontSize: glyph * 0.36,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
            ],
          ),
        },
      ),
    );
  }
}
