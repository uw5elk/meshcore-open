import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import 'mesh_nav_tile.dart';
import 'mesh_ui.dart';

/// App UI languages offered in settings, in display order. A null code means
/// "follow the system language". Add a locale here (and only here) to make it
/// selectable and labelled.
final List<(String?, String Function(AppLocalizations))> appLanguageOptions = [
  (null, (l) => l.appSettings_languageSystem),
  ('en', (l) => l.appSettings_languageEn),
  ('uk', (l) => l.appSettings_languageUk),
];

/// Localized label for [languageCode]; unknown codes and null read as
/// "System".
String appLanguageLabel(BuildContext context, String? languageCode) {
  final l10n = context.l10n;
  for (final (code, label) in appLanguageOptions) {
    if (code == languageCode) return label(l10n);
  }
  return l10n.appSettings_languageSystem;
}

/// Bottom sheet for choosing the app UI language override.
void showLanguagePickerSheet(
  BuildContext context,
  AppSettingsService settingsService,
) {
  final l10n = context.l10n;
  final current = settingsService.settings.languageOverride;
  showMeshSheet(
    context,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        BottomSheetHeader(title: l10n.appSettings_language),
        SizedBox(
          // Capped so the sheet still fits short screens and landscape.
          height: math.min(400, MediaQuery.sizeOf(ctx).height * 0.6),
          child: ListView(
            children: [
              for (final (code, label) in appLanguageOptions)
                MeshSheetOption(
                  label: label(l10n),
                  selected: current == code,
                  onTap: () {
                    settingsService.setLanguageOverride(code);
                    Navigator.pop(ctx);
                  },
                ),
              SizedBox(height: MediaQuery.paddingOf(ctx).bottom + 8),
            ],
          ),
        ),
      ],
    ),
  );
}
