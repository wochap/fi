import 'package:fi/theme/nocturne.dart';
import 'package:fi/theme/nocturne_widgets.dart';
import 'package:fi/theme/side_sheet.dart';
import 'package:flutter/material.dart';

/// One action in an [ActionSheet].
final class ActionSheetItem<T> {
  const ActionSheetItem({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final IconData icon;
}

/// A group of [ActionSheetItem]s, optionally labelled ("Data").
final class ActionSheetGroup<T> {
  const ActionSheetGroup(this.items, {this.label});

  final String? label;
  final List<ActionSheetItem<T>> items;
}

/// A phone row menu as a bottom sheet (mock 4f): a header naming what the actions apply to, then
/// 48px action rows in groups separated by rules. Picking a row pops the sheet with its value.
class ActionSheet<T> extends StatelessWidget {
  const ActionSheet({
    required this.icon,
    required this.title,
    required this.groups,
    this.subtitle,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final List<ActionSheetGroup<T>> groups;

  @override
  Widget build(BuildContext context) => BottomSheetInsets(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
            child: Row(
              children: [
                IconTile(icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (subtitle case final subtitle?)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontFeatures: Nocturne.tabular,
                            color: Nocturne.muted(.55),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final (index, group) in groups.indexed) ...[
            if (index > 0)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: FadedRule(),
              ),
            if (group.label case final label?)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                child: SectionLabel(label),
              ),
            for (final item in group.items)
              InkWell(
                borderRadius: BorderRadius.circular(Nocturne.radius),
                onTap: () => Navigator.pop(context, item.value),
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Icon(item.icon, size: 18, color: Nocturne.muted(.7)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    ),
  );
}

/// Opens an [ActionSheet] and returns the picked value, or null when dismissed.
Future<T?> showActionSheet<T>(
  BuildContext context, {
  required IconData icon,
  required String title,
  required List<ActionSheetGroup<T>> groups,
  String? subtitle,
}) => showModalBottomSheet<T>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (_) => ActionSheet<T>(
    icon: icon,
    title: title,
    subtitle: subtitle,
    groups: groups,
  ),
);
