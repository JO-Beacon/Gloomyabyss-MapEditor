import 'package:flutter/foundation.dart';

/// 开发者模式的默认值（编译期）。
const bool kDeveloperModeDefault = false;

/// 运行期设置。首选项里可改，不落盘。
class AppSettings extends ChangeNotifier {
  bool developerMode = kDeveloperModeDefault;
  bool dark = true;

  void setDeveloperMode(bool value) {
    developerMode = value;
    notifyListeners();
  }

  void setDark(bool value) {
    dark = value;
    notifyListeners();
  }
}

final AppSettings appSettings = AppSettings();

/// 编辑器版本。
const String kAppVersion = '0.1.0';

/// 项目主页；检查更新会打开它的 releases 页面。
const String kProjectUrl = 'https://github.com/JO-Beacon/Gloomyabyss-MapEditor';
