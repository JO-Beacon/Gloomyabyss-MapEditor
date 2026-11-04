import 'package:flutter/material.dart' show DefaultMaterialLocalizations;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import 'config.dart';
import 'ui/editor_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MapEditorApp());
}

class MapEditorApp extends StatefulWidget {
  const MapEditorApp({super.key});

  @override
  State<MapEditorApp> createState() => _MapEditorAppState();
}

class _MapEditorAppState extends State<MapEditorApp> {
  static const MethodChannel _windowChannel = MethodChannel('jodraft/window');

  @override
  void initState() {
    super.initState();
    appSettings.addListener(_pushCaption);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushCaption());
  }

  @override
  void dispose() {
    appSettings.removeListener(_pushCaption);
    super.dispose();
  }

  void _pushCaption() {
    final p = appSettings.dark ? JoPalette.dark : JoPalette.light;
    _sendCaption(p);
  }

  Future<void> _sendCaption(JoPalette p) async {
    try {
      await _windowChannel.invokeMethod<void>('setCaption', <String, int>{
        'caption': p.bg.toARGB32(),
        'text': p.text.toARGB32(),
        'border': p.border.toARGB32(),
        'dark': p.isDark ? 1 : 0,
      });
    } catch (_) {
      // 非 Windows 或没有这条通道，忽略
    }
  }

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
            JoCupertinoLocalizationsDelegate(),
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
