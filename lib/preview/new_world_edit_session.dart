/// V2：把 EditorState 的保存动作接到新格式保存事务。
library;

import '../state/editor_state.dart';
import 'new_world_save.dart';
import 'preview_world.dart';

class NewWorldEditSession {
  NewWorldEditSession({
    required this.preview,
    required this.state,
  }) : _saveSession = NewWorldSaveSession(
          preview: preview,
          world: state.world!,
        );

  final PreviewWorld preview;
  final EditorState state;
  final NewWorldSaveSession _saveSession;

  Future<void> save() async {
    try {
      final result = _saveSession.save();
      _saveSession.syncWorldSolids();
      state
        ..dirty = false
        ..selectedSolid = -1
        ..notice = '已保存到新格式（revision ${result.revision}）';
      state.notifyChanged();
    } catch (error) {
      state
        ..notice = null
        ..errors = <String>['保存失败：$error'];
      state.notifyChanged();
    }
  }
}
