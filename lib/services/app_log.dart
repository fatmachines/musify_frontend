import 'package:flutter/foundation.dart';

/// In-memory diagnostic log. Lines also go to the console tagged [Musify];
/// the Library tab can copy the whole buffer for sharing.
class AppLog {
  static const _maxLines = 1000;
  static final _lines = <String>[];

  static void add(String message) {
    final time = DateTime.now().toIso8601String().substring(11, 23);
    _lines.add('$time $message');
    if (_lines.length > _maxLines) _lines.removeAt(0);
    debugPrint('[Musify] $message');
  }

  static void addAll(Iterable<String> messages) => messages.forEach(add);

  static String dump() => _lines.join('\n');
}
