import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/sync_service.dart';
import '../theme.dart';

/// Spotify-style tab bar: no indicator, the text colour when selected and
/// grey when not, laid over the content on a gradient that fades it out
/// (to black, or white in the light theme).
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
      // Black in the dark theme, white in the light one.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.frame.withValues(alpha: 0),
            AppColors.dark
                ? AppColors.frame.withValues(alpha: 0.9)
                : AppColors.background.withValues(alpha: 0.92),
            AppColors.dark ? AppColors.frame : AppColors.background,
          ],
          stops: const [0, 0.45, 1],
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
                (c, s) => _SvgIcon(
                  s ? 'assets/icons/home_filled.svg' : 'assets/icons/home.svg',
                  color: c,
                ),
              ),
              _item(
                1,
                'Search',
                (c, s) => _SvgIcon('assets/icons/search.svg', color: c),
              ),
              _item(
                2,
                'Your Library',
                (c, s) => _SvgIcon(
                  s
                      ? 'assets/icons/library_filled.svg'
                      : 'assets/icons/library.svg',
                  color: c,
                ),
              ),
              _item(
                3,
                'Settings',
                (c, s) => SyncBadge(
                  child: _SvgIcon(
                    s
                        ? 'assets/icons/settings_filled.svg'
                        : 'assets/icons/settings.svg',
                    color: c,
                  ),
                ),
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

/// An icon drawn from an SVG in assets/icons, in [color].
class _SvgIcon extends StatelessWidget {
  final String asset;
  final Color color;

  const _SvgIcon(this.asset, {required this.color});

  @override
  Widget build(BuildContext context) {
    // Same box as the other tab icons, so the labels line up.
    return SizedBox.square(
      dimension: 28,
      child: Center(
        child: SvgPicture.asset(
          asset,
          width: 26,
          height: 26,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        ),
      ),
    );
  }
}

/// A green dot on [child] while a device waits for approval to sync.
class SyncBadge extends StatelessWidget {
  final Widget child;

  const SyncBadge({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => Badge(
        isLabelVisible: sync.requests.isNotEmpty,
        backgroundColor: AppColors.green,
        smallSize: 10,
        child: child,
      ),
    );
  }
}
