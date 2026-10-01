import 'package:fi/controllers.dart';
import 'package:fi/src/rust/api/models.dart';
import 'package:fi/theme/nocturne.dart';
import 'package:flutter/material.dart';

/// The muted, selectable build label: `fi <version> · <hash>`.
class BuildLabel extends StatelessWidget {
  const BuildLabel(this.info, {super.key});
  final BuildInfoDto info;

  @override
  Widget build(BuildContext context) => SelectableText(
    buildLabel(info),
    key: const Key('build-version'),
    style: TextStyle(
      fontSize: 11,
      fontFamily: Nocturne.monoFamily,
      color: Nocturne.muted(.45),
    ),
  );
}
