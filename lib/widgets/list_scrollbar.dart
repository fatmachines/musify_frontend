import 'package:flutter/material.dart';

import '../theme.dart';

/// A scrollbar that's always there on a list of songs, to drag through long
/// playlists (on the phone too, where lists normally have none). Replaces
/// the Mac's own (shown on hover), so there's only one.
class ListScrollbar extends StatelessWidget {
  final ScrollController controller;
  final Widget child;

  /// Keeps the thumb clear of bars over the list (a title bar, the tab bar
  /// and mini player).
  final EdgeInsets padding;

  const ListScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return RawScrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      thickness: 6,
      radius: const Radius.circular(3),
      thumbColor: AppColors.text.withValues(alpha: 0.35),
      padding: padding,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: child,
      ),
    );
  }
}
