import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../models/song_tag.dart';
import '../services/library.dart';
import '../theme.dart';

/// Colours offered for new tags.
const tagColors = [
  Color(0xFFFF9F43),
  Color(0xFFF15E6C),
  Color(0xFFFFD43B),
  Color(0xFF1ED760),
  Color(0xFF4FC3F7),
  Color(0xFF7C4DFF),
  Color(0xFFF06292),
  Color(0xFFB0BEC5),
];

/// The song's tags as small coloured dots, for song rows.
class TagDots extends StatelessWidget {
  final Track track;

  const TagDots({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final tags = Library.instance.tagsOf(track);
    if (tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tag in tags)
            Tooltip(
              message: tag.name,
              child: Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  color: tag.color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Lets the user switch tags on and off for [track], make new ones, and
/// delete them (long press).
Future<void> showTagSheet(BuildContext context, Track track) {
  final library = Library.instance;
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: ListenableBuilder(
          listenable: library,
          builder: (_, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Tag',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 8),
                child: Text(
                  'Mark songs to find them later, e.g. ones to replace with '
                  'a better file.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.subtle, fontSize: 13),
                ),
              ),
              for (final tag in library.tags)
                ListTile(
                  leading: _Dot(color: tag.color),
                  title: Text(tag.name),
                  trailing: library.hasTag(track, tag)
                      ? Icon(Icons.check_circle, color: AppColors.green)
                      : const Icon(Icons.circle_outlined),
                  onTap: () => library.toggleTag(track, tag),
                  onLongPress: () => _confirmDelete(sheet, tag),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New tag'),
                onTap: () async {
                  final tag = await _newTag(sheet);
                  if (tag != null) library.toggleTag(track, tag);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Dot extends StatelessWidget {
  final Color color;

  const _Dot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

Future<SongTag?> _newTag(BuildContext context) async {
  final result = await showDialog<(String, Color)>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _NewTagDialog(
      initial: tagColors[Library.instance.tags.length % tagColors.length],
    ),
  );
  if (result == null) return null;
  return Library.instance.createTag(result.$1, result.$2);
}

/// Name and colour for a new tag. Owns its text field's controller so it
/// lives until the dialog has finished closing.
class _NewTagDialog extends StatefulWidget {
  final Color initial;

  const _NewTagDialog({required this.initial});

  @override
  State<_NewTagDialog> createState() => _NewTagDialogState();
}

class _NewTagDialogState extends State<_NewTagDialog> {
  final _name = TextEditingController();
  late Color _color = widget.initial;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((name, _color));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.elevated,
      title: const Text('New tag'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            cursorColor: AppColors.green,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'Name'),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in tagColors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c == _color
                            ? AppColors.text
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _create, child: const Text('Create')),
      ],
    );
  }
}

Future<void> _confirmDelete(BuildContext context, SongTag tag) async {
  final delete = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: AppColors.elevated,
      title: Text('Delete tag "${tag.name}"?'),
      content: const Text('It comes off every song. The songs stay.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFF15E6C)),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (delete == true) Library.instance.deleteTag(tag);
}
