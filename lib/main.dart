import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import 'config.dart';
import 'ui/editor_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MapEditorApp());
}

class MapEditorApp extends StatelessWidget {
  const MapEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appSettings,
      builder: (context, _) {
        final palette = appSettings.dark ? JoPalette.dark : JoPalette.light;
        return WidgetsApp(
          title: 'Gloomyabyss Map Editor',
          color: palette.bg,
          localizationsDelegates: const [
            DefaultWidgetsLocalizations.delegate,
            DefaultMaterialLocalizations.delegate,
          ],
          builder: (context, child) => JoTheme(
            settings: JoSettings(isDark: appSettings.dark),
            palette: palette,
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (_) => ColoredBox(
                    color: palette.bg,
                    child: const EditorPage(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
