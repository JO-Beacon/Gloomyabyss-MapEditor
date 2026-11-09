import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import '../preview/bundled_definitions.dart';
import '../preview/legacy_world_adapter.dart';
import '../preview/new_world_edit_session.dart';
import '../preview/preview_world.dart';
import '../state/editor_state.dart';
import 'editor_page.dart';

/// 直接以旧 UI 只读打开一个新格式/旧格式世界。
///
/// 只用于命令行 `--legacy-preview=...` 和测试；正常入口在编辑器菜单里。
class LegacyPreviewLoader extends StatefulWidget {
  const LegacyPreviewLoader({
    super.key,
    required this.path,
    required this.onClose,
    this.editable = false,
  });

  final String path;
  final VoidCallback onClose;
  final bool editable;

  @override
  State<LegacyPreviewLoader> createState() => _LegacyPreviewLoaderState();
}

class _LegacyPreviewLoaderState extends State<LegacyPreviewLoader> {
  PreviewWorld? _preview;
  EditorState? _state;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final definitions = await loadBundledDefaultDefinitions();
      final preview = PreviewWorld.loadOrMigrate(
        path: widget.path,
        definitions: definitions,
      );
      if (widget.editable && preview.temporaryDirectory != null) {
        preview.dispose();
        throw const FormatException(
          'V2 地形编辑只支持新格式目录（含 world.meta.json）。',
        );
      }
      final data = LegacyWorldAdapter.fromPreview(preview);
      final state = EditorState()
        ..world = data.world
        ..terrain = data.terrain
        ..propTypes = data.propTypes
        ..objectTypes = data.objectTypes
        ..selectedLevel = data.selectedLevel
        ..selectedCode = data.terrain.types.first.code
        ..newFormatEditing = true
        ..notice = widget.editable
            ? 'V7 编辑：地形/道具/对象/传送门/传送格/碰撞'
            : (preview.temporaryDirectory == null
                ? '只读预览：新格式世界'
                : '只读预览：已从旧格式迁移到临时副本');
      final levelSegments = data.world.segments
          .where((s) => s.spec.originZ == data.selectedLevel)
          .toList(growable: false);
      if (levelSegments.isNotEmpty) {
        state.selectedSegment =
            data.world.segments.indexOf(levelSegments.first);
      }
      if (widget.editable) {
        final editSession = NewWorldEditSession(
          preview: preview,
          state: state,
        );
        state.newFormatSaveHandler = editSession.save;
      }
      if (!mounted) {
        preview.dispose();
        return;
      }
      setState(() {
        _preview = preview;
        _state = state;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state != null) {
      return EditorPage(
        initialState: state,
        readOnly: !widget.editable,
        terrainOnly: widget.editable,
        allowEntities: widget.editable,
        allowPortals: widget.editable,
        allowCollision: widget.editable,
        onClosePreview: widget.onClose,
      );
    }
    final p = JoTheme.of(context);
    return ColoredBox(
      color: p.bg,
      child: Center(
        child: Text(
          _error == null ? '正在加载预览…' : '预览失败：$_error',
          style: JoTheme.ui(context).copyWith(
            color: _error == null ? p.secondary : const Color(0xFFC42B1C),
          ),
        ),
      ),
    );
  }
}
