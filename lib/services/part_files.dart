import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where a file being downloaded into [target] is written until it's
/// complete. Next to it as `<name>.part`, except on Android: there the
/// music folder only takes files with an audio extension, so it goes in
/// the app's own temporary folder.
Future<File> partFileFor(File target) async {
  if (!Platform.isAndroid) return File('${target.path}.part');
  final dir = Directory('${(await getTemporaryDirectory()).path}/downloads');
  await dir.create(recursive: true);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return File('${dir.path}/$stamp.part');
}

/// Puts a finished [part] (from [partFileFor]) in place as [target]:
/// renamed if it's on the same drive, copied across if not.
Future<void> finishPart(File part, File target) async {
  try {
    await part.rename(target.path);
  } on FileSystemException {
    await part.copy(target.path);
    await part.delete();
  }
}
