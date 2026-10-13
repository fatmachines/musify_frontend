import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Spotify-style swipe on a song row: the row slides with the finger,
/// uncovering an action icon that lights up once the swipe is far enough.
/// Letting go past that point runs the action; the row always springs back.
class SwipeActions extends StatefulWidget {
  final Widget child;

  /// Swiping right (left to right).
  final IconData rightIcon;
  final VoidCallback onSwipeRight;

  /// Swiping left (right to left).
  final IconData leftIcon;
  final Color leftColor;
  final VoidCallback onSwipeLeft;

  const SwipeActions({
    super.key,
    required this.child,
    required this.rightIcon,
    required this.onSwipeRight,
    required this.leftIcon,
    required this.leftColor,
    required this.onSwipeLeft,
  });

  @override
  State<SwipeActions> createState() => _SwipeActionsState();
}

class _SwipeActionsState extends State<SwipeActions>
    with SingleTickerProviderStateMixin {
  static const _trigger = 72.0;
  static const _max = 120.0;

  late final AnimationController _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() => setState(() => _dx = _from * (1 - _spring.value)));

  double _dx = 0;
  double _from = 0;
  bool _armed = false;

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails details) {
    _spring.stop();
    // Past the trigger point the row moves with some resistance.
    final delta = details.primaryDelta ?? 0;
    final damped = _dx.abs() > _trigger ? delta * 0.4 : delta;
    final dx = (_dx + damped).clamp(-_max, _max);
    final armed = dx.abs() >= _trigger;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _dx = dx;
      _armed = armed;
    });
  }

  void _onEnd(DragEndDetails details) {
    if (_armed) {
      _dx > 0 ? widget.onSwipeRight() : widget.onSwipeLeft();
    }
    _armed = false;
    _from = _dx;
    _spring.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final right = _dx > 0;
    final reveal = _dx.abs();
    final color = !_armed
        ? AppColors.chip
        : right
        ? AppColors.green
        : widget.leftColor;
    return GestureDetector(
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      child: Stack(
        children: [
          if (reveal > 0)
            Positioned.fill(
              child: Align(
                alignment: right ? Alignment.centerLeft : Alignment.centerRight,
                child: Container(
                  width: reveal,
                  color: color,
                  alignment: Alignment.center,
                  child: reveal > 32
                      ? Icon(
                          right ? widget.rightIcon : widget.leftIcon,
                          color: _armed ? Colors.black : AppColors.text,
                        )
                      : null,
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_dx, 0),
            child: ColoredBox(
              color: reveal > 0 ? AppColors.background : Colors.transparent,
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}
