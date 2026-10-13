import 'package:flutter/material.dart';

import '../theme.dart';

/// A short message near the bottom of the screen, above everything (the
/// full player too, which covers the app's own snack bars).
void showToast(BuildContext context, String message) =>
    showToastOn(Overlay.of(context, rootOverlay: true), message);

/// For when the calling screen may be gone by the time the message shows
/// (look the overlay up first, while it's still mounted).
void showToastOn(OverlayState overlay, String message) {
  if (!overlay.mounted) return;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) =>
        _Toast(message: message, onDone: () => entry.remove()),
  );
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  final String message;
  final VoidCallback onDone;

  const _Toast({required this.message, required this.onDone});

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await _fade.forward();
    await Future.delayed(const Duration(milliseconds: 1800));
    if (!mounted) return;
    await _fade.reverse();
    widget.onDone();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      // Clear of the tab bar and the mini player.
      bottom: MediaQuery.paddingOf(context).bottom + 150,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _fade,
          child: Material(
            color: AppColors.text,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text(
                widget.message,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
