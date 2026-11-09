import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 开发者模式的默认值（编译期）。
const bool kDeveloperModeDefault = false;

/// 运行期设置，落盘到用户目录，重启后保留。
class AppSettings extends ChangeNotifier {
  bool developerMode = kDeveloperModeDefault;

  /// 是否显示已弃用的历史功能入口。
  bool legacyFeatures = false;
  bool dark = true;
  double leftWidth = 220;
  double rightWidth = 300;
  double layerHeight = 120;
  double portalListHeight = 240;
  Map<String, String> bindings = <String, String>{
    'save': 'Ctrl+S',
    'undo': 'Ctrl+Z',
    'redo': 'Ctrl+Y',
    'fit': 'Ctrl+0',
    'delete': 'Delete',
  };

  AppSettings() {
    _load();
  }

  static File get _file {
    final String base = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return File('$base${Platform.pathSeparator}GloomyabyssMapEditor'
        '${Platform.pathSeparator}settings.json');
  }

  void _load() {
    try {
      if (!_file.existsSync()) return;
      final Object? decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return;
      developerMode = decoded['developer_mode'] == true;
      legacyFeatures = decoded['legacy_features'] == true;
      dark = decoded['dark'] != false;
      leftWidth = ((decoded['left_width'] as num?) ?? 220).toDouble();
      rightWidth = ((decoded['right_width'] as num?) ?? 300).toDouble();
      layerHeight = ((decoded['layer_height'] as num?) ?? 120).toDouble();
      portalListHeight =
          ((decoded['portal_list_height'] as num?) ?? 240).toDouble();
      final Object? b = decoded['bindings'];
      if (b is Map) {
        for (final key in bindings.keys.toList()) {
          final Object? v = b[key];
          if (v is String) bindings[key] = v;
        }
      }
    } catch (_) {
      // 设置文件坏了就用默认值，不阻塞启动。
    }
  }

  void _save() {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(<String, Object>{
        'developer_mode': developerMode,
        'legacy_features': legacyFeatures,
        'dark': dark,
        'left_width': leftWidth,
        'right_width': rightWidth,
        'layer_height': layerHeight,
        'portal_list_height': portalListHeight,
        'bindings': bindings,
      }));
    } catch (_) {
      // 写不进去就算了，不影响使用。
    }
  }

  void setDeveloperMode(bool value) {
    developerMode = value;
    _save();
    notifyListeners();
  }

  void setLegacyFeatures(bool value) {
    legacyFeatures = value;
    _save();
    notifyListeners();
  }

  void setDark(bool value) {
    dark = value;
    _save();
    notifyListeners();
  }

  void setLeftWidth(double value) {
    leftWidth = value;
    notifyListeners();
  }

  void setRightWidth(double value) {
    rightWidth = value;
    notifyListeners();
  }

  void setLayerHeight(double value) {
    layerHeight = value;
    notifyListeners();
  }

  void setPortalListHeight(double value) {
    portalListHeight = value;
    notifyListeners();
  }

  void setBinding(String action, String spec) {
    bindings[action] = spec;
    _save();
    notifyListeners();
  }

  void saveLayout() => _save();

}

final AppSettings appSettings = AppSettings();

/// 编辑器版本。
const String kAppVersion = '0.2.0';

/// 项目主页；检查更新会打开它的 releases 页面。
const String kProjectUrl = 'https://github.com/JO-Beacon/Gloomyabyss-MapEditor';
