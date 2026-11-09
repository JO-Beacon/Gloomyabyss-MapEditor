import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import '../config.dart';
import '../preview/bundled_definitions.dart';
import '../preview/gmap_export.dart';
import '../preview/legacy_world_adapter.dart';
import '../preview/new_world_edit_session.dart';
import '../preview/preview_world.dart';
import '../world/chunk_file.dart';
import '../world/gmap_container.dart';
import '../world/old_migration.dart';
import '../world/world_index.dart';
import '../world/world_meta.dart';
import '../models/world.dart';
import '../world/geometry.dart';
import '../models/line_portal.dart';
import '../state/editor_state.dart';
import 'map_canvas.dart';
import 'segment_dialogs.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    this.initialState,
    this.readOnly = false,
    this.terrainOnly = false,
    this.allowEntities = false,
    this.allowPortals = false,
    this.allowCollision = false,
    this.onClosePreview,
    this.manageWindow = true,
  });

  final EditorState? initialState;
  final bool readOnly;

  /// V2/V3：只允许编辑地形、道具、对象，其余编辑入口关闭。
  final bool terrainOnly;

  /// V3：在 [terrainOnly] 模式下额外开放道具/对象。
  final bool allowEntities;

  /// V4：在 [terrainOnly] 模式下额外开放传送门/传送格。
  final bool allowPortals;

  /// V5：在 [terrainOnly] 模式下额外开放碰撞。
  final bool allowCollision;
  final VoidCallback? onClosePreview;

  /// 只有窗口里的最外层 EditorPage 负责处理窗口关闭。
  final bool manageWindow;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final EditorState state = widget.initialState ?? EditorState();
  bool _aboutOpen = false;
  EditorState? _legacyPreviewState;
  PreviewWorld? _legacyPreviewSource;
  bool _newWorldOpen = false;
  bool _prefsOpen = false;
  bool _licensesOpen = false;
  bool _newSegOpen = false;
  bool _delSegOpen = false;
  bool _closePromptOpen = false;
  bool _historyOpen = false;
  bool _saveGuardOpen = false;
  Future<void> Function()? _pendingAction;
  String _newWorldName = '';
  int _newWorldWidth = 32;
  int _newWorldHeight = 24;
  int _panelTab = 0;
  String? _linkFrom;
  String? _linkTo;
  bool _linkBidirectional = false;
  int _prefsTab = 0;
  final Map<int, int> _toolByTab = <int, int>{}; // 每个页签各自的工具，不落盘
  int get _currentTool => _toolByTab[_panelTab] ?? 0;
  String? _portalLinkTo;
  String _portalLinkFace = 'A';
  int _selectedPortalLink = -1;
  final TextEditingController _portalNameCtrl = TextEditingController();
  int _fitEpoch = 0;
  double _zoomScale = 1;
  double _fitScale = 1;
  bool _fit = true;


  static const MethodChannel _windowChannel = MethodChannel('jodraft/window');

  @override
  void initState() {
    super.initState();
    if (widget.manageWindow) {
      _windowChannel.setMethodCallHandler(_onWindowCall);
    }
  }

  @override
  void dispose() {
    if (widget.manageWindow) {
      _windowChannel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  void _runGuarded(Future<void> Function() action) {
    if (!state.dirty) {
      action();
      return;
    }
    _pendingAction = action;
    setState(() => _saveGuardOpen = true);
  }

  Future<dynamic> _onWindowCall(MethodCall call) async {
    if (call.method == 'closeRequested') {
      if (!state.dirty) {
        _closeWindow();
      } else {
        setState(() => _closePromptOpen = true);
      }
      return null;
    }
    return null;
  }

  void _closeWindow() {
    _windowChannel.invokeMethod<void>('destroy');
  }

  Future<void> _openLegacyPreview() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择新格式世界目录',
    );
    if (path == null || path.isEmpty) return;
    await _openPreviewPath(path);
  }

  Future<void> _openPreviewPath(String path, {String? notice}) async {
    try {
      final definitions = await loadBundledDefaultDefinitions();
      final preview = PreviewWorld.loadOrMigrate(
        path: path,
        definitions: definitions,
      );
      if (preview.temporaryDirectory != null) {
        preview.dispose();
        throw const FormatException(
          '这里只能打开新格式目录（含 world.meta.json）。'
          '旧格式请先用“迁移旧版”生成副本。',
        );
      }
      await _installPreview(preview, notice: notice);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.errors = <String>['打开预览失败：$error'];
        state.notice = null;
      });
    }
  }

  Future<void> _openAnyGmap() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '打开 .gmap（自动识别版本）',
      type: FileType.custom,
      allowedExtensions: <String>['gmap'],
    );
    final path = picked?.path;
    if (path == null || path.isEmpty) return;
    try {
      final bytes = File(path).readAsBytesSync();
      final container = GmapContainer.decode(bytes, allowVersion1: true);
      final definitions = await loadBundledDefaultDefinitions();

      if (container.version == 2) {
        final preview = PreviewWorld.loadGmapFile(
          path: path,
          definitions: definitions,
        );
        await _installPreview(
          preview,
          notice: '已打开 .gmap v2 临时副本；编辑不会写回源包',
        );
        return;
      }

      if (container.version == 1) {
        var name = _basename(path);
        if (name.toLowerCase().endsWith('.gmap')) {
          name = name.substring(0, name.length - 5);
        }
        final parent = await FilePicker.getDirectoryPath(
          dialogTitle: '选择迁移后的 .gmap 存放目录',
        );
        if (parent == null || parent.isEmpty) return;
        final output = '$parent${Platform.pathSeparator}$name.v2.gmap';
        final result = OldMigration.migrateGmapFile(
          OldMigrationOptions(
            sourcePath: path,
            outputPath: output,
            oldDefinitions: definitions,
            targetDefinitions: definitions,
            name: name,
            keepUnknown: true,
          ),
        );
        final preview = PreviewWorld.loadGmapFile(
          path: output,
          definitions: definitions,
        );
        await _installPreview(
          preview,
          notice: '旧版 .gmap 已迁移为 $output；'
              '${result.report.segmentCount} 段，${result.report.chunkCount} 块',
        );
        return;
      }

      throw FormatException('不支持的 .gmap 容器版本：${container.version}');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.errors = <String>['打开 .gmap 失败：$error'];
        state.notice = null;
      });
    }
  }

  Future<void> _installPreview(PreviewWorld preview, {String? notice}) async {
    final data = LegacyWorldAdapter.fromPreview(preview);
    final previewState = EditorState()
      ..world = data.world
      ..terrain = data.terrain
      ..propTypes = data.propTypes
      ..objectTypes = data.objectTypes
      ..selectedLevel = data.selectedLevel
      ..selectedCode = data.terrain.types.first.code
      ..newFormatEditing = true
      ..notice = notice ??
          (preview.temporaryDirectory == null
              ? 'V7 编辑：地形/道具/对象/传送门/传送格/碰撞'
              : '只读预览：旧格式临时副本');
    final levelSegments = data.world.segments
        .where((s) => s.spec.originZ == data.selectedLevel)
        .toList(growable: false);
    if (levelSegments.isNotEmpty) {
      previewState.selectedSegment =
          data.world.segments.indexOf(levelSegments.first);
    }
    final editSession = NewWorldEditSession(
      preview: preview,
      state: previewState,
    );
    previewState.newFormatSaveHandler = editSession.save;
    previewState.newFormatGmapExportHandler = () async {
      try {
        final bytes = GmapExport.encodeDirectory(preview.worldPath);
        final uri = await FilePicker.saveFile(
          fileName: '${preview.meta.name}.gmap',
          bytes: bytes,
          dialogTitle: '另存为 .gmap',
        );
        if (uri == null) return;
        previewState
          ..notice = '已导出 .gmap：${uri.toFilePath()}'
          ..notifyChanged();
      } catch (error) {
        previewState
          ..errors = <String>['导出 .gmap 失败：$error']
          ..notifyChanged();
      }
    };
    if (!mounted) {
      preview.dispose();
      return;
    }
    final oldPreview = _legacyPreviewSource;
    setState(() {
      _legacyPreviewState = previewState;
      _legacyPreviewSource = preview;
    });
    oldPreview?.dispose();
  }

  Future<void> _createNewFormatWorld(
    String name,
    int width,
    int height,
  ) async {
    final parent = await FilePicker.getDirectoryPath(
      dialogTitle: '选择新世界存放目录',
    );
    if (parent == null || parent.isEmpty) return;
    final output = '$parent${Platform.pathSeparator}$name';
    try {
      final defs = await loadBundledDefaultDefinitions();
      final out = Directory(output);
      if (out.existsSync()) {
        throw FormatException('目录已存在：$output');
      }
      out.createSync(recursive: true);
      final blockSize = 128;
      final code = defs.terrain.types.first.code;
      final cols = width.clamp(4, 1024);
      final rows = height.clamp(4, 1024);
      final chunksDir = Directory('$output${Platform.pathSeparator}chunks');
      final lastCx = (cols - 1) ~/ blockSize;
      final lastCy = (rows - 1) ~/ blockSize;
      for (var cx = 0; cx <= lastCx; cx++) {
        for (var cy = 0; cy <= lastCy; cy++) {
          final localW = (cx == lastCx ? cols - cx * blockSize : blockSize);
          final localH = (cy == lastCy ? rows - cy * blockSize : blockSize);
          final chunk = ChunkFile(
            z: 0,
            cx: cx,
            cy: cy,
            blockSize: blockSize,
            instructions: const <ChunkInstruction>[],
            terrainRows: <String>[
              for (var r = 0; r < localH; r++) code * localW,
            ],
          );
          final file = File(
            '${chunksDir.path}${Platform.pathSeparator}0'
            '${Platform.pathSeparator}${cx}_$cy.chunk',
          );
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(chunk.encode(), flush: true);
        }
      }
      final meta = WorldMeta(
        version: 2,
        name: name,
        blockSize: blockSize,
        chunkFormatVersion: 1,
        definitions: DefinitionRef(
          id: defs.manifest.id,
          version: defs.manifest.version,
          hash: defs.manifest.hash,
        ),
        indexRevision: 1,
        start: WorldStart(
          col: 2.clamp(1, cols - 1),
          row: 2.clamp(1, rows - 1),
          z: 0,
        ),
        pads: const <WorldPad>[],
        padLinks: const <WorldPadLink>[],
        portalLinks: const <WorldPortalLink>[],
      );
      File('$output${Platform.pathSeparator}world.meta.json')
          .writeAsStringSync(meta.encode(), flush: true);
      final index = WorldIndex(
        revision: 1,
        fullCheckedAt: '',
        portals: const <IndexPortal>[],
        propsObjects: const <IndexPropsObject>[],
        solidGroups: const <IndexSolidGroup>[],
      );
      File('$output${Platform.pathSeparator}world.index.json')
          .writeAsStringSync(index.encode(), flush: true);
      await _openPreviewPath(output, notice: '已新建新格式世界：$name');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.errors = <String>['新建世界失败：$error'];
        state.notice = null;
      });
    }
  }

  String _basename(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isEmpty ? path : parts.last;
  }

  Future<void> _migrateOldDirectory() async {
    final source = await FilePicker.getDirectoryPath(
      dialogTitle: '选择旧世界目录（含 world.json）',
    );
    if (source == null || source.isEmpty) return;
    final parent = await FilePicker.getDirectoryPath(
      dialogTitle: '选择迁移副本存放目录',
    );
    if (parent == null || parent.isEmpty) return;
    final output = '$parent${Platform.pathSeparator}${_basename(source)}.v1';
    try {
      final definitions = await loadBundledDefaultDefinitions();
      final result = OldMigration.migrateDirectory(
        OldMigrationOptions(
          sourcePath: source,
          outputPath: output,
          oldDefinitions: definitions,
          targetDefinitions: definitions,
          name: _basename(source),
          keepUnknown: true,
        ),
      );
      await _openPreviewPath(
        output,
        notice: '迁移完成：${result.report.segmentCount} 段，'
            '${result.report.chunkCount} 块；'
            '${result.report.portalMapping.length} 个传送门',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        state.errors = <String>['迁移失败：$error'];
        state.notice = null;
      });
    }
  }

  void _closeLegacyPreview() {
    final source = _legacyPreviewSource;
    setState(() {
      _legacyPreviewState = null;
      _legacyPreviewSource = null;
    });
    source?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_legacyPreviewState != null) {
      return EditorPage(
        initialState: _legacyPreviewState,
        terrainOnly: true,
        allowEntities: true,
        allowPortals: true,
        allowCollision: true,
        onClosePreview: _closeLegacyPreview,
        manageWindow: false,
      );
    }
    final p = JoTheme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([state, appSettings]),
      builder: (context, _) {
        final pal = JoTheme.of(context);
        return ColoredBox(
          color: pal.bg,
          child: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            children: [
              Column(
                children: [
                  _menuBar(),
                  _toolbar(p),
                  Container(height: 1, color: p.border),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        const double canvasMin = 240;
                        final double total = constraints.maxWidth;
                        final double leftMax = (total -
                                appSettings.rightWidth -
                                canvasMin -
                                kJoSplitterTotal * 1)
                            .clamp(160.0, 520.0);
                        final double rightMax = (total -
                                appSettings.leftWidth -
                                canvasMin -
                                kJoSplitterTotal * 1)
                            .clamp(240.0, 560.0);
                        final double leftW = appSettings.leftWidth.clamp(160.0, leftMax);
                        final double rightW = appSettings.rightWidth.clamp(240.0, rightMax);
                        return Row(
                          children: [
                            _leftPanel(p, leftW),
                            JoSplitter(
                              palette: p,
                              width: leftW,
                              minWidth: 160,
                              maxWidth: leftMax,
                              defaultWidth: 220,
                              growsRight: true,
                              onResize: appSettings.setLeftWidth,
                              onResizeEnd: appSettings.saveLayout,
                            ),
                            Expanded(child: _canvas(p)),
                            JoSplitter(
                              palette: p,
                              width: rightW,
                              minWidth: 240,
                              maxWidth: rightMax,
                              defaultWidth: 300,
                              growsRight: false,
                              onResize: appSettings.setRightWidth,
                              onResizeEnd: appSettings.saveLayout,
                            ),
                            _rightPanel(p, rightW),
                          ],
                        );
                      },
                    ),
                  ),
                  _statusBar(),
                ],
              ),
              if (_aboutOpen) _aboutOverlay(p),
              if (_newWorldOpen) _newWorldOverlay(p),
              if (_newSegOpen)
                _modal(NewSegmentDialog(
                  onCancel: () => setState(() => _newSegOpen = false),
                  onCreate: (name, w, h, col, row) {
                    setState(() => _newSegOpen = false);
                    state.addSegment(name,
                        width: w, height: h, originCol: col, originRow: row);
                  },
                )),
              if (_closePromptOpen) _closePrompt(p),
              if (_historyOpen) _historyOverlay(p),
              if (_saveGuardOpen) _saveGuardOverlay(p),
              if (_delSegOpen)
                _modal(DeleteSegmentDialog(
                  name: state.segment?.spec.id ?? '',
                  onCancel: () => setState(() => _delSegOpen = false),
                  onConfirm: () {
                    setState(() => _delSegOpen = false);
                    state.removeSegment();
                  },
                )),
              if (_prefsOpen) _prefsOverlay(p),
              if (_licensesOpen) _licensesOverlay(p),
            ],
          ),
        ),
        );
      },
    );
  }

  Future<void> _openUrl(String url) async {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  }

  Future<void> _checkForUpdates() async {
    try {
      await _openUrl('$kProjectUrl/releases');
      state.setNotice('已在浏览器打开更新页面');
    } catch (e) {
      state.setError('打不开更新页面：$e');
    }
  }

  String? _specOf(KeyEvent event) {
    final LogicalKeyboardKey k = event.logicalKey;
    if (k == LogicalKeyboardKey.controlLeft ||
        k == LogicalKeyboardKey.controlRight ||
        k == LogicalKeyboardKey.shiftLeft ||
        k == LogicalKeyboardKey.shiftRight ||
        k == LogicalKeyboardKey.altLeft ||
        k == LogicalKeyboardKey.altRight ||
        k == LogicalKeyboardKey.metaLeft ||
        k == LogicalKeyboardKey.metaRight) {
      return null;
    }
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    final List<String> parts = <String>[];
    if (kb.isControlPressed) parts.add('Ctrl');
    if (kb.isShiftPressed) parts.add('Shift');
    if (kb.isAltPressed) parts.add('Alt');
    final String label = k.keyLabel;
    if (label.isEmpty) return null;
    parts.add(label);
    return parts.join('+');
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final String? spec = _specOf(event);
    if (spec == null) return KeyEventResult.ignored;
    final Map<String, String> b = appSettings.bindings;

    // 保存始终归编辑器，输入框里也能用
    if (spec == b['save']) {
      if (state.world != null) state.save();
      return KeyEventResult.handled;
    }

    // 输入框聚焦时，其余快捷键让给输入框
    if (JoTextField.isEditing) return KeyEventResult.ignored;

    // 复制/粘贴直接用逻辑键判断，避免不同平台 keyLabel 大小写不一致。
    if (HardwareKeyboard.instance.isControlPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        final selection = state.selection;
        if (selection != null) {
          state.copyRegion(selection);
          return KeyEventResult.handled;
        }
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        final clipboard = state.clipboard;
        if (clipboard != null) {
          final selection = state.selection;
          final segment = state.segment;
          final dest = selection != null
              ? CellRect(
                  selection.x,
                  selection.y,
                  clipboard.width,
                  clipboard.height,
                )
              : (segment == null
                  ? null
                  : CellRect(
                      segment.spec.originCol,
                      segment.spec.originRow,
                      clipboard.width,
                      clipboard.height,
                    ));
          if (dest != null) {
            state.pasteClipboard(dest);
            return KeyEventResult.handled;
          }
        }
      }
    }

    if (spec == b['fit']) {
      setState(() => _fitEpoch++);
      return KeyEventResult.handled;
    }

    if (spec == b['delete']) {
      final selection = state.selection;
      if (selection != null) {
        state.deleteRegion(selection);
        return KeyEventResult.handled;
      }
      if (_panelTab == 5 &&
          !state.solidPick &&
          state.selectedSolid >= 0 &&
          state.selectedSolid < state.solids.length) {
        state.removeSolid(state.solids[state.selectedSolid].instructionIndex);
        return KeyEventResult.handled;
      }
    }

    if (spec == b['undo']) {
      state.undo();
      return KeyEventResult.handled;
    }
    if (spec == b['redo']) {
      state.redo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _menuBar() {
    if (widget.readOnly) {
      return JoMenuBar(
        menus: [
          JoMenu('文件', [
            JoMenuItem('关闭预览', onTap: widget.onClosePreview),
            const JoMenuItem('', divider: true),
            JoMenuItem('退出', onTap: () => exit(0)),
          ]),
          JoMenu('视图', [
            JoMenuItem('适应窗口', onTap: () => setState(() => _fitEpoch++)),
          ]),
          JoMenu('帮助', [
            JoMenuItem('关于', onTap: () => setState(() => _aboutOpen = true)),
          ]),
        ],
      );
    }
    return JoMenuBar(
      menus: [
        JoMenu('文件', [
          JoMenuItem(
            '新建世界…',
            onTap: widget.readOnly
                ? null
                : () => setState(() {
                      _newWorldName = '';
                      _newWorldWidth = 32;
                      _newWorldHeight = 24;
                      _newWorldOpen = true;
                    }),
          ),
          if (widget.terrainOnly)
            JoMenuItem('打开 .gmap…', onTap: _openAnyGmap)
          else
            JoMenuItem(
              '打开旧格式 .gmap…',
              onTap: () => _runGuarded(state.openGmap),
            ),
          const JoMenuItem('', divider: true),
          JoMenuItem(
            '保存',
            onTap: widget.readOnly || state.world == null || !state.dirty
                ? null
                : state.save,
          ),
          JoMenuItem(
            '另存为 .gmap…',
            onTap: state.world == null ? null : state.saveAsGmap,
          ),
          const JoMenuItem('', divider: true),
          JoMenuItem('退出', onTap: () => exit(0)),
        ]),
        JoMenu('编辑', [
          JoMenuItem('撤销', onTap: state.canUndo ? state.undo : null),
          JoMenuItem('重做', onTap: state.canRedo ? state.redo : null),
          const JoMenuItem('', divider: true),
          JoMenuItem(
            '复制选区',
            onTap: state.selection == null
                ? null
                : () => state.copyRegion(state.selection!),
          ),
          JoMenuItem(
            '粘贴到选区',
            onTap: state.selection == null || state.clipboard == null
                ? null
                : () {
                    final cb = state.clipboard!;
                    state.pasteClipboard(
                      CellRect(state.selection!.x, state.selection!.y, cb.width, cb.height),
                    );
                  },
          ),
          JoMenuItem(
            '删除选区',
            onTap: state.selection == null
                ? null
                : () => state.deleteRegion(state.selection!),
          ),
          const JoMenuItem('', divider: true),
          JoMenuItem('历史记录…', onTap: () => setState(() => _historyOpen = true)),
          const JoMenuItem('', divider: true),
          JoMenuItem('首选项…', onTap: () => setState(() => _prefsOpen = true)),
        ]),
        JoMenu('视图', [
          JoMenuItem('校验地图', onTap: state.world == null ? null : state.validate),
          JoMenuItem(
            '适应窗口',
            onTap: () => setState(() => _fitEpoch++),
          ),
          const JoMenuItem('', divider: true),
          JoMenuItem(
            '重置布局',
            onTap: () {
              appSettings.setLeftWidth(220);
              appSettings.setRightWidth(300);
              appSettings.setLayerHeight(120);
              appSettings.setPortalListHeight(240);
              appSettings.saveLayout();
            },
          ),
        ]),
        if (appSettings.developerMode)
          JoMenu('开发', [
            JoMenuItem(
              '打开新格式世界（地形编辑）…',
              onTap: _openLegacyPreview,
            ),
            JoMenuItem('迁移旧版世界目录…', onTap: _migrateOldDirectory),
            if (!widget.terrainOnly) ...[
              JoMenuItem('打开世界目录…', onTap: () => _runGuarded(state.openRoot)),
              JoMenuItem('导入到世界目录…', onTap: () => _runGuarded(state.importGmap)),
            ],
          ]),
        JoMenu('帮助', [
          JoMenuItem('检查更新…', onTap: _checkForUpdates),
          JoMenuItem('关于', onTap: () => setState(() => _aboutOpen = true)),
        ]),
      ],
    );
  }

  Widget _toolbar(JoPalette p) {
    final segment = state.segment;
    return Container(
      height: 36,
      color: p.surface,
      padding: const EdgeInsets.symmetric(horizontal: JoSpace.s2),
      child: Row(
        children: [
          JoIconAction(
            icon: JoIcons.undo,
            tip: '撤销',
            onTap: !widget.readOnly && state.canUndo ? state.undo : null,
          ),
          JoIconAction(
            icon: JoIcons.redo,
            tip: '重做',
            onTap: !widget.readOnly && state.canRedo ? state.redo : null,
          ),

          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: JoSpace.s2),
            color: p.border,
          ),
          JoIconAction(
            icon: JoIcons.add,
            tip: '新建世界',
            onTap: widget.readOnly || widget.terrainOnly
                ? null
                : () => _runGuarded(() async {
                    _newWorldName = '';
                    _newWorldWidth = 32;
                    _newWorldHeight = 24;
                    setState(() => _newWorldOpen = true);
                  }),
          ),
          JoIconAction(
            icon: JoIcons.file,
            tip: '打开 .gmap',
            onTap: widget.readOnly || widget.terrainOnly ? null : state.openGmap,
          ),
          JoIconAction(
            icon: JoIcons.save,
            tip: '保存',
            onTap: widget.readOnly || state.world == null || !state.dirty
                ? null
                : state.save,
          ),
          JoIconAction(
            icon: JoIcons.check,
            tip: '校验',
            onTap: widget.readOnly || state.world == null ? null : state.validate,
          ),
          const SizedBox(width: JoSpace.s3),
          if (state.world != null)
            Text(
              '${state.world!.name} / ${segment?.spec.id ?? '-'}'
              '${widget.readOnly ? ' · 只读预览' : ''}',
              style: JoTheme.meta(context).copyWith(
                color: widget.readOnly ? p.accent : p.secondary,
              ),
            ),
          const Spacer(),
          if (!widget.readOnly)
            JoSegment<int>(
              key: ValueKey<int>(_panelTab),
              options: switch (_panelTab) {
              0 || 1 || 2 => const [
                  (label: '选择', value: 0),
                  (label: '笔', value: 1),
                  (label: '橡皮', value: 2),
                ],
              3 => const [
                  (label: '选择', value: 0),
                  (label: '新建', value: 1),
                  (label: '橡皮', value: 2),
                ],
              7 => const [
                  (label: '选择', value: 0),
                  (label: '放置', value: 1),
                  (label: '拆除', value: 2),
                ],
              _ => const [
                  (label: '选择', value: 0),
                ],
            },
            value: _currentTool,
            onChanged: (v) => setState(() {
              _toolByTab[_panelTab] = v;
              if (_panelTab == 3 && v == 0 && state.linePortalPick) {
                state.toggleLinePortalPick();
              }
            }),
          ),
          const SizedBox(width: JoSpace.s2),
        ],
      ),
    );
  }

  Widget _leftPanel(JoPalette p, double width) {
    return SizedBox(
      width: width,
      child: ColoredBox(
        color: p.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // —— 世界
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JoSpace.s3,
                JoSpace.s3,
                JoSpace.s3,
                JoSpace.s1,
              ),
              child: Text(
                '世界',
                style: JoTheme.meta(context).copyWith(
                  color: p.secondary,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JoSpace.s2,
                0,
                JoSpace.s2,
                JoSpace.s3,
              ),
              child: !appSettings.developerMode || state.worlds.isEmpty
                  ? Text(
                      state.world?.name ?? '未打开',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 13,
                        color: p.text,
                      ),
                    )
                  : JoDropdown<String>(
                      items: state.worlds
                          .map((w) => (label: w, value: w))
                          .toList(growable: false),
                      value: state.world?.name,
                      placeholder: '选择世界',
                      onChanged: (v) =>
                          _runGuarded(() async => state.openWorld(v)),
                    ),
            ),
            Container(height: 1, color: p.border),

            // —— 层
            SizedBox(
              height: appSettings.layerHeight.clamp(
                60.0,
                (MediaQuery.sizeOf(context).height - 320)
                    .clamp(60.0, 600.0),
              ),
              child: JoListSection(
                title: '层列表',
                child: ListView(
                  children: [
                    for (final int z in state.levels.reversed)
                      JoListRow(
                        title: 'z = $z',
                        subtitle:
                            '${state.world!.segments.where((s) => s.spec.originZ == z).length} 个${(widget.readOnly || widget.terrainOnly) ? '图层' : '段'}',
                        selected: z == state.selectedLevel,
                        onTap: () => state.setLevel(z),
                      ),
                  ],
                ),
              ),
            ),
            JoSplitter(
              palette: p,
              axis: JoSplitterAxis.vertical,
              colors: [p.surface, p.surface],
              width: appSettings.layerHeight,
              minWidth: 60,
              maxWidth: (MediaQuery.sizeOf(context).height - 320)
                  .clamp(60.0, 600.0),
              defaultWidth: 120,
              growsRight: true,
              onResize: appSettings.setLayerHeight,
              onResizeEnd: appSettings.saveLayout,
            ),

            // —— 段
            Expanded(
              child: JoListSection(
                title: (widget.readOnly || widget.terrainOnly) ? '图层' : '段列表',
                actions: (widget.readOnly || widget.terrainOnly)
                    ? const <Widget>[]
                    : [
                        JoButton(
                          text: '新建',
                          bordered: true,
                          onTap: state.world == null
                              ? null
                              : () => setState(() => _newSegOpen = true),
                        ),
                        const SizedBox(width: JoSpace.s1),
                        JoButton(
                          text: '复制',
                          bordered: true,
                          onTap: state.world == null ? null : state.duplicateSegment,
                        ),
                        const SizedBox(width: JoSpace.s1),
                        JoButton(
                          text: '删除',
                          danger: true,
                          onTap: state.world == null ||
                                  state.world!.segments.length <= 1
                              ? null
                              : () => setState(() => _delSegOpen = true),
                        ),
                      ],
                child: ListView.builder(
                  itemCount: state.world == null
                      ? 0
                      : state.world!.segments
                          .where((s) => s.spec.originZ == state.selectedLevel)
                          .length,
                  itemBuilder: (context, index) {
                    final List<Segment> list = state.world!.segments
                        .where((s) => s.spec.originZ == state.selectedLevel)
                        .toList(growable: false);
                    final Segment segment = list[index];
                    final int globalIndex =
                        state.world!.segments.indexOf(segment);
                    return JoListRow(
                      title: segment.spec.id,
                      subtitle: '${segment.width}×${segment.height}',
                      selected: globalIndex == state.selectedSegment,
                      onTap: () => state.selectSegment(globalIndex),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _canvas(JoPalette p) {
    final segment = state.segment;
    final terrain = state.terrain;
    if (segment == null || terrain == null) {
      return Center(
        child: Text(
          '先打开一个世界根目录',
          style: JoTheme.ui(context).copyWith(color: p.secondary),
        ),
      );
    }

    return MapCanvas(
      world: state.world!,
      terrain: terrain,
      selectedSegment: state.selectedSegment,
      level: state.selectedLevel,
      selectedCode: state.selectedCode,
      paintEnabled: !widget.readOnly && _panelTab == 0 && _currentTool != 0,
      onPaint: _currentTool == 2 ? state.eraseWorld : state.paintWorld,
      onStrokeStart: state.beginStroke,
      onStrokeEnd: state.endStroke,
      selectedPlane: state.selectedPlane,
      linePortalMode: !widget.readOnly && (!widget.terrainOnly || widget.allowPortals) && _panelTab == 3 && _currentTool == 1,
      portalEraseMode: !widget.readOnly && (!widget.terrainOnly || widget.allowPortals) && _panelTab == 3 && _currentTool == 2,
      onPortalEraseCell: state.eraseLinePortalWorld,
      fitEpoch: _fitEpoch,
      selection: state.selection,
      onSelectionChanged: state.setSelection,
      onMoveSelection: (dc, dr) {
        final current = state.selection;
        if (current == null) return;
        state.moveRegion(current, dc, dr);
      },
      onViewChanged: (scale, fitScale, fit) {
        if ((scale - _zoomScale).abs() > 0.001 ||
            (fitScale - _fitScale).abs() > 0.001 ||
            fit != _fit) {
          setState(() {
            _zoomScale = scale;
            _fitScale = fitScale;
            _fit = fit;
          });
        }
      },
      onLinePortalCell: (int c, int r) {
        if (!state.linePortalPick) state.toggleLinePortalPick();
        state.pickLinePortalWorld(c, r);
      },
      selectedLinePortal: state.selectedLinePortal,
      linePickStart: state.linePickStart,
      placedProps: state.placedProps,
      propTypes: state.propTypes,
      propMode: !widget.readOnly && (!widget.terrainOnly || widget.allowEntities) && _panelTab == 1 && _currentTool != 0,
      onPropCell: _currentTool == 2 ? state.erasePropWorld : state.placePropWorld,
      placedObjects: state.placedObjects,
      objectMode: !widget.readOnly && (!widget.terrainOnly || widget.allowEntities) && _panelTab == 2 && _currentTool != 0,
      onObjectCell: _currentTool == 2 ? state.eraseObjectWorld : state.placeObjectWorld,
      worldStartCol: state.worldStartCol,
      worldStartRow: state.worldStartRow,
      startPickMode: !widget.readOnly && !widget.terrainOnly && state.startPick,
      onStartCell: state.setStartWorld,
      solids: state.solids,
      solidMode: !widget.readOnly && (widget.allowCollision || !widget.terrainOnly) && state.solidPick,
      onSolidCell: state.pickSolidWorld,
      solidDraft: state.solidDraft,
      solidSelectMode: !widget.readOnly && (widget.allowCollision || !widget.terrainOnly) && _panelTab == 5 && !state.solidPick,
      onSolidSelectCell: state.selectSolidWorld,
      selectedSolid: state.selectedSolid,
      padMode: !widget.readOnly && (!widget.terrainOnly || widget.allowPortals) && _panelTab == 7 && _currentTool != 0,
      onPadCell: _currentTool == 2 ? state.removePadWorld : state.placePadWorld,
      pickMode: !widget.readOnly && !widget.terrainOnly && state.pickPlane,
      onPickCell: state.pickPlaneWorld,
    );
  }

  Widget _rightPanel(JoPalette p, double width) {
    return SizedBox(
      width: width,
      child: ColoredBox(
        color: p.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(JoSpace.s3),
              child: JoSegment<int>(
                options: <({String label, int value})>[
                  (label: '地形', value: 0),
                  if (!widget.terrainOnly) ...<({String label, int value})>[
                    (label: '道具', value: 1),
                    (label: '对象', value: 2),
                    (label: '传送门', value: 3),
                    (label: '传送格', value: 7),
                    if (!widget.readOnly) (label: '段', value: 4),
                    (label: '碰撞', value: 5),
                    (label: '世界', value: 6),
                  ] else if (widget.allowEntities) ...<({String label, int value})>[
                    (label: '道具', value: 1),
                    (label: '对象', value: 2),
                    if (widget.allowPortals) ...<({String label, int value})>[
                      (label: '传送门', value: 3),
                      (label: '传送格', value: 7),
                    ],
                    if (widget.allowCollision) (label: '碰撞', value: 5),
                  ],
                ],
                value: _panelTab,
                onChanged: (v) {
                  setState(() {
                    if (state.linePortalPick) state.toggleLinePortalPick();
                    _panelTab = v;
                  });
                  if (v == 3 && state.selectedPlane < 0 && state.planes.isNotEmpty) {
                    state.selectPlane(0);
                  }
                },
              ),
            ),
            Container(height: 1, color: p.border),
            Expanded(
              child: switch (_panelTab) {
                0 => _terrainList(p),
                1 => _propPanel(p),
                2 => _objectPanel(p),
                3 => _portalPanel(p),
                7 => _padPanel(p),
                4 => _segmentPanel(p),
                5 => _solidPanel(p),
                _ => _worldPanel(p),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _terrainList(JoPalette p) {
    final terrain = state.terrain;
    if (terrain == null) return const SizedBox();
    return ListView(
      children: terrain.types.map((t) {
        return JoListRow(
          title: '${t.code}  ${t.name}',
          subtitle:
              'block:${t.block ? '是' : '否'}  speed:${t.speed}  dmg:${t.damage}',
          selected: t.code == state.selectedCode,
          leading: Container(width: 14, height: 14, color: Color(t.color)),
          onTap: () => state.selectCode(t.code),
        );
      }).toList(),
    );
  }

  Widget _propPanel(JoPalette p) {
    if (state.propTypes.isEmpty) {
      return Center(
        child: Text(
          '没有道具表',
          style: JoTheme.meta(context).copyWith(color: p.secondary),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(JoSpace.s3),
          child: Text(
            '选一个道具，然后在画布上点格子放置；再点同一格删除。',
            style: JoTheme.meta(context).copyWith(color: p.secondary),
          ),
        ),
        Container(height: 1, color: p.border),
        Expanded(
          child: ListView(
            children: state.propTypes.map((t) {
              final selected = t.id == state.selectedPropId;
              return JoListRow(
                title: '${t.id}  ${t.name}',
                subtitle:
                    '${t.sprite}  ${t.width}×${t.height}${t.block ? '  阻挡' : ''}',
                selected: selected,
                leading: Container(
                  width: 14,
                  height: 14,
                  color: selected ? p.accent : p.secondary,
                ),
                onTap: () => state.selectProp(t.id),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _solidPanel(JoPalette p) {
    if (state.world == null) {
      return Center(
        child: Text(
          '先打开一个世界',
          style: JoTheme.meta(context).copyWith(color: p.secondary),
        ),
      );
    }
    final solids = state.solids;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(JoSpace.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  JoButton(
                    text: state.solidPick ? '点顶点中…' : '新建碰撞',
                    bordered: true,
                    color: state.solidPick ? p.accent : null,
                    onTap: state.toggleSolidPick,
                  ),
                  const SizedBox(width: JoSpace.s2),
                  JoButton(
                    text: '完成',
                    bordered: true,
                    onTap: state.solidPick && state.solidDraft.length >= 3
                        ? state.finishSolid
                        : null,
                  ),
                  const SizedBox(width: JoSpace.s2),
                  JoButton(
                    text: '取消',
                    onTap: state.solidPick ? state.cancelSolid : null,
                  ),
                ],
              ),
              if (state.solidPick) ...[
                const SizedBox(height: JoSpace.s1),
                Text(
                  '已点 ${state.solidDraft.length} 个点；点回第一个点或按“完成”闭合。凹多边形会自动拆成三角形。',
                  style: JoTheme.meta(context).copyWith(color: p.secondary),
                ),
              ],
            ],
          ),
        ),
        Container(height: 1, color: p.border),
        Expanded(
          child: solids.isEmpty
              ? Center(
                  child: Text(
                    '没有碰撞',
                    style: JoTheme.meta(context).copyWith(color: p.secondary),
                  ),
                )
              : ListView.builder(
                  itemCount: solids.length,
                  itemBuilder: (context, index) {
                    return JoListRow(
                      title: '碰撞 ${index + 1}',
                      subtitle: solids[index].label,
                      selected: index == state.selectedSolid,
                      onTap: () => state.selectSolid(index),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _worldPanel(JoPalette p) {
    final w = state.world;
    if (w == null) {
      return Center(
        child: Text(
          '先打开一个世界',
          style: JoTheme.meta(context).copyWith(color: p.secondary),
        ),
      );
    }
    final col = state.worldStartCol;
    final row = state.worldStartRow;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(JoSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(p, '名称'),
          Text(
            w.name,
            style: JoTheme.ui(context).copyWith(fontSize: 13, color: p.text),
          ),
          const SizedBox(height: JoSpace.s3),
          _label(p, '起点（世界坐标）'),
          Text(
            col == null || row == null ? '未设置' : 'col $col, row $row',
            style: JoTheme.meta(context).copyWith(color: p.text),
          ),
          const SizedBox(height: JoSpace.s2),
          JoButton(
            text: state.startPick ? '在画布上点…' : '在画布上点',
            bordered: true,
            color: state.startPick ? p.accent : null,
            onTap: state.toggleStartPick,
          ),
          const SizedBox(height: JoSpace.s2),
          Text(
            '点一下画布上的格子，换算成世界坐标写入 world.json。',
            style: JoTheme.meta(context).copyWith(color: p.secondary),
          ),
          const SizedBox(height: JoSpace.s4),
          _label(p, '段'),
          Text(
            '${w.segments.length} 个',
            style: JoTheme.meta(context).copyWith(color: p.text),
          ),
        ],
      ),
    );
  }

  Widget _padPanel(JoPalette p) {
    if (state.world == null) {
      return Center(
        child: Text(
          '先打开一个世界',
          style: JoTheme.meta(context).copyWith(color: p.secondary),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(JoSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
    const SizedBox(height: JoSpace.s4),
    _label(p, '传送格'),
    Text(
      '用顶部工具栏的“放置/拆除”在画布上操作传送格。',
      style: JoTheme.meta(context).copyWith(color: p.secondary),
    ),
    const SizedBox(height: JoSpace.s2),
    if (state.pads.isEmpty)
      Padding(
        padding: const EdgeInsets.only(top: JoSpace.s2),
        child: Text(
          '还没有传送格',
          style: JoTheme.meta(context).copyWith(color: p.secondary),
        ),
      )
    else
      for (int i = 0; i < state.pads.length; i++)
        JoListRow(
          title: state.pads[i].label,
          selected: i == state.selectedPad,
          onTap: () => setState(() => state.selectedPad = i),
        ),
    const SizedBox(height: JoSpace.s4),
    _label(p, '连线'),
    if (state.pads.length < 2)
      Text(
        '至少两个传送格才能连线',
        style: JoTheme.meta(context).copyWith(color: p.secondary),
      )
    else ...[
      JoDropdown<String>(
        items: [
          for (final portal in state.pads)
            (label: portal.id, value: portal.id),
        ],
        value: _linkFrom,
        placeholder: '起点',
        onChanged: (v) => setState(() => _linkFrom = v),
      ),
      const SizedBox(height: JoSpace.s1),
      JoDropdown<String>(
        items: [
          for (final portal in state.pads)
            (label: portal.id, value: portal.id),
        ],
        value: _linkTo,
        placeholder: '终点',
        onChanged: (v) => setState(() => _linkTo = v),
      ),
      const SizedBox(height: JoSpace.s1),
      JoToggle(
        on: _linkBidirectional,
        onLabel: '双向',
        offLabel: '单向',
        onChanged: (v) => setState(() => _linkBidirectional = v),
      ),
      const SizedBox(height: JoSpace.s1),
      JoButton(
        text: '添加连线',
        bordered: true,
        onTap: _linkFrom == null || _linkTo == null
            ? null
            : () {
                state.addPadLink(
                  _linkFrom!,
                  _linkTo!,
                  bidirectional: _linkBidirectional,
                );
                setState(() {});
              },
      ),
    ],
    for (int i = 0; i < state.padLinks.length; i++)
      JoListRow(
        title: state.padLinks[i].label,
        selected: i == state.selectedPadLink,
        onTap: () => setState(() => state.selectedPadLink = i),
      ),
    if (state.padLinks.isNotEmpty)
      Align(
        alignment: Alignment.centerLeft,
        child: JoButton(
          text: '删除连线',
          danger: true,
          onTap: state.selectedPadLink < 0
              ? null
              : () => state.removePadLink(state.selectedPadLink),
        ),
      ),
        ],
      ),
    );
  }

  Widget _objectPanel(JoPalette p) {
    if (state.objectTypes.isEmpty) {
      return Center(
        child: Text(
          '没有对象表',
          style: JoTheme.meta(context).copyWith(color: p.secondary),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(JoSpace.s3),
          child: Text(
            '选一个对象，然后在画布上点格子放置；再点同一格删除。',
            style: JoTheme.meta(context).copyWith(color: p.secondary),
          ),
        ),
        Container(height: 1, color: p.border),
        Expanded(
          child: ListView(
            children: state.objectTypes.map((t) {
              return JoListRow(
                title: '${t.id}  ${t.name}',
                selected: t.id == state.selectedObjectId,
                leading: Container(
                  width: 10,
                  height: 10,
                  color: const Color(0xFF7FB069),
                ),
                onTap: () => state.selectObject(t.id),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _portalPanel(JoPalette p) {
    final portals = state.linePortals;
    final LinePortal? selectedPortal =
        state.selectedLinePortal >= 0 && state.selectedLinePortal < portals.length
            ? portals[state.selectedLinePortal]
            : null;
    final String sourceRef = selectedPortal == null
        ? ''
        : '${state.segment!.spec.id}/${selectedPortal.id}';
    final List<({String segment, LinePortal portal})> linkTargets = [
      for (final e in state.allLinePortals)
        if ('${e.segment}/${e.portal.id}' != sourceRef &&
            selectedPortal != null &&
            e.portal.dir == selectedPortal.dir &&
            e.portal.length == selectedPortal.length)
          e,
    ];
    final List<({PortalLink link, int index})> myLinks = [
      for (int i = 0; i < state.portalLinks.length; i++)
        if (selectedPortal != null &&
            (state.portalLinks[i].from == sourceRef ||
                state.portalLinks[i].to == sourceRef))
          (link: state.portalLinks[i], index: i),
    ];

    if (state.world == null) {
      return Center(
        child: Text('先打开一个世界',
            style: JoTheme.meta(context).copyWith(color: p.secondary)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: appSettings.portalListHeight.clamp(
            120.0,
            (MediaQuery.sizeOf(context).height - 240)
                .clamp(120.0, 700.0),
          ),
          child: JoListSection(
            title: '传送门列表',
            child: portals.isEmpty
                ? Center(
                    child: Text(
                      '这一段还没有传送门',
                      style: JoTheme.meta(context).copyWith(color: p.secondary),
                    ),
                  )
                : ListView.builder(
                    itemCount: portals.length,
                    itemBuilder: (context, index) {
                      final portal = portals[index];
                      return JoListRow(
                        title: portal.label,
                        subtitle: '段内坐标',
                        selected: index == state.selectedLinePortal,
                        onTap: () => setState(() {
                          state.selectedLinePortal = index;
                          _portalNameCtrl.text = portal.id;
                        }),
                      );
                    },
                  ),
          ),
        ),
        JoSplitter(
          palette: p,
          axis: JoSplitterAxis.vertical,
          colors: [p.surface, p.surface],
          width: appSettings.portalListHeight,
          minWidth: 120,
          maxWidth: (MediaQuery.sizeOf(context).height - 240)
              .clamp(120.0, 700.0),
          defaultWidth: 240,
          growsRight: true,
          onResize: appSettings.setPortalListHeight,
          onResizeEnd: appSettings.saveLayout,
        ),
        Expanded(
          child: selectedPortal == null
              ? Center(
                  child: Text(
                    '选中一条传送门后编辑属性',
                    style: JoTheme.meta(context).copyWith(color: p.secondary),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(JoSpace.s3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label(p, '方向'),
                      JoSegment<String>(
                        options: const [
                          (label: '水平', value: 'right'),
                          (label: '竖直', value: 'down'),
                        ],
                        value: selectedPortal.dir,
                        onChanged: (v) => state.updateLinePortal(
                          state.selectedLinePortal,
                          dir: v,
                        ),
                      ),
                      const SizedBox(height: JoSpace.s2),
                      _label(p, '名称'),
                      Row(
                        children: [
                          Expanded(
                            child: JoTextInput(
                              controller: _portalNameCtrl,
                              placeholder: '回车或应用',
                              inputFormatters: [
                                TextInputFormatter.withFunction(
                                    (oldValue, newValue) {
                                  if (newValue.composing.isValid &&
                                      !newValue.composing.isCollapsed) {
                                    return oldValue;
                                  }
                                  return newValue;
                                }),
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[A-Za-z0-9_-]'),
                                ),
                              ],
                              onSubmitted: (v) {
                                state.renameLinePortal(
                                  state.selectedLinePortal,
                                  v,
                                );
                                setState(() {});
                              },
                            ),
                          ),
                          const SizedBox(width: JoSpace.s2),
                          JoButton(
                            text: '应用',
                            bordered: true,
                            onTap: () {
                              state.renameLinePortal(
                                state.selectedLinePortal,
                                _portalNameCtrl.text,
                              );
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                      _numRow(
                        p,
                        '起点 x',
                        selectedPortal.x,
                        0,
                        state.segment!.width,
                        (v) =>
                            state.updateLinePortal(state.selectedLinePortal, x: v),
                      ),
                      _numRow(
                        p,
                        '起点 y',
                        selectedPortal.y,
                        0,
                        state.segment!.height,
                        (v) =>
                            state.updateLinePortal(state.selectedLinePortal, y: v),
                      ),
                      _numRow(
                        p,
                        '长度',
                        selectedPortal.length,
                        1,
                        selectedPortal.horizontal
                            ? state.segment!.width
                            : state.segment!.height,
                        (v) => state.updateLinePortal(
                          state.selectedLinePortal,
                          length: v,
                        ),
                      ),
                      const SizedBox(height: JoSpace.s4),
                      _label(p, '连接'),
                      Text(
                        '源：$sourceRef',
                        style: JoTheme.meta(context).copyWith(color: p.text),
                      ),
                      const SizedBox(height: JoSpace.s1),
                      JoSegment<String>(
                        options: selectedPortal.horizontal
                            ? const [
                                (label: 'A 面（左）', value: 'A'),
                                (label: 'B 面（右）', value: 'B'),
                                (label: '双面', value: 'both'),
                              ]
                            : const [
                                (label: 'A 面（上）', value: 'A'),
                                (label: 'B 面（下）', value: 'B'),
                                (label: '双面', value: 'both'),
                              ],
                        value: _portalLinkFace,
                        onChanged: (v) => setState(() => _portalLinkFace = v),
                      ),
                      const SizedBox(height: JoSpace.s1),
                      JoDropdown<String>(
                        items: [
                          for (final e in linkTargets)
                            (
                              label: '${e.segment}/${e.portal.id}',
                              value: '${e.segment}/${e.portal.id}',
                            ),
                        ],
                        value: _portalLinkTo,
                        placeholder:
                            linkTargets.isEmpty ? '没有符合条件的终点' : '终点',
                        onChanged: (v) => setState(() => _portalLinkTo = v),
                      ),
                      const SizedBox(height: JoSpace.s1),
                      Row(
                        children: [
                          JoButton(
                            text: '添加连接',
                            bordered: true,
                            onTap: _portalLinkTo == null
                                ? null
                                : () {
                                    state.addPortalLink(
                                      sourceRef,
                                      _portalLinkTo!,
                                      face: _portalLinkFace,
                                    );
                                    setState(() {});
                                  },
                          ),
                          const SizedBox(width: JoSpace.s2),
                          JoButton(
                            text: '删除连接',
                            danger: true,
                            onTap: myLinks.any(
                                    (e) => e.index == _selectedPortalLink)
                                ? () => setState(() {
                                      state.removePortalLink(_selectedPortalLink);
                                      _selectedPortalLink = -1;
                                    })
                                : null,
                          ),
                        ],
                      ),
                      for (final e in myLinks)
                        JoListRow(
                          title: e.link.label,
                          selected: e.index == _selectedPortalLink,
                          onTap: () =>
                              setState(() => _selectedPortalLink = e.index),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _segmentPanel(JoPalette p) {
    final segment = state.segment;
    if (segment == null) {
      return Center(
        child: Text(
          '先打开一个世界',
          style: JoTheme.meta(context).copyWith(color: p.secondary),
        ),
      );
    }
    final spec = segment.spec;
    final index = state.selectedSegment;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(JoSpace.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _numRow(p, 'origin z', spec.originZ, -16, 16,
              (v) => state.updateSegmentSpec(spec, originZ: v)),
          const SizedBox(height: JoSpace.s3),
          _label(p, '名称'),
          JoTextInput(
            key: ValueKey('seg-name-$index'),
            initial: spec.id,
            onChanged: (v) => state.renameSegment(index, v),
          ),
          const SizedBox(height: JoSpace.s3),
          _label(p, '文件'),
          Text(
            spec.file,
            style: JoTheme.meta(context).copyWith(color: p.secondary),
          ),
          const SizedBox(height: JoSpace.s2),
          JoButton(
            text: '文件随 id 重命名',
            bordered: true,
            onTap: state.renameSegmentFile,
          ),
          const SizedBox(height: JoSpace.s3),
          _numRow(p, '原点 col', spec.originCol, -512, 512,
              (v) => state.updateSegmentSpec(spec, originCol: v)),
          _numRow(p, '原点 row', spec.originRow, -512, 512,
              (v) => state.updateSegmentSpec(spec, originRow: v)),
          const SizedBox(height: JoSpace.s2),
          _label(p, '重复'),
          JoSegment<String>(
            options: const [
              (label: '不重复', value: ''),
              (label: 'x', value: 'x'),
              (label: 'y', value: 'y'),
              (label: 'xy', value: 'xy'),
            ],
            value: spec.repeat,
            onChanged: (v) => state.updateSegmentSpec(spec, repeat: v),
          ),
          const SizedBox(height: JoSpace.s3),
          _numRow(p, '重复次数（0 为无限）', spec.repeatCount, 0, 999,
              (v) => state.updateSegmentSpec(spec, repeatCount: v)),
        ],
      ),
    );
  }

  Widget _label(JoPalette p, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s1),
      child: Text(
        text,
        style: JoTheme.meta(context).copyWith(color: p.secondary),
      ),
    );
  }

  Widget _numRow(
    JoPalette p,
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: JoTheme.ui(context).copyWith(fontSize: 13, color: p.text),
            ),
          ),
          JoButton(
            text: '−',
            bordered: true,
            onTap: value <= min
                ? null
                : () => onChanged(value - 1),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: JoTheme.meta(context).copyWith(color: p.text),
            ),
          ),
          JoButton(
            text: '+',
            bordered: true,
            onTap: value >= max
                ? null
                : () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    final errors = state.errors;
    final segment = state.segment;
    return JoStatusBar(
      left: errors.isEmpty
          ? (state.notice ?? '就绪')
          : '${errors.length} 个问题：${errors.first}',
      error: errors.isNotEmpty,
      right: segment == null
          ? null
          : '${_fit ? '自适应' : '${(_zoomScale / _fitScale * 100).round()}%'}'
              '  ${segment.width}×${segment.height} 格',
    );
  }

  Widget _prefsOverlay(JoPalette p) {
    final Size screen = MediaQuery.sizeOf(context);
    final double width = (screen.width * 0.72).clamp(520.0, 980.0);
    final double height = (screen.height * 0.72).clamp(360.0, 720.0);

    Widget page;
    switch (_prefsTab) {
      case 0:
        page = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label(p, '主题'),
            JoSegment<bool>(
              options: const [
                (label: '暗 · 机器', value: true),
                (label: '明 · 纸', value: false),
              ],
              value: appSettings.dark,
              onChanged: appSettings.setDark,
            ),
          ],
        );
        break;
      case 1:
        page = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '开发者模式',
                    style: JoTheme.ui(context).copyWith(fontSize: 13, color: p.text),
                  ),
                ),
                JoToggle(
                  on: appSettings.developerMode,
                  onChanged: appSettings.setDeveloperMode,
                ),
              ],
            ),
            const SizedBox(height: JoSpace.s2),
            Text(
              '开启后显示打开世界目录、导入到世界目录等入口。',
              style: JoTheme.meta(context).copyWith(color: p.secondary),
            ),
          ],
        );
        break;
      default:
        page = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in const [
              ('save', '保存'),
              ('undo', '撤销'),
              ('redo', '重做'),
              ('fit', '适应窗口'),
              ('delete', '删除'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: JoSpace.s2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.$2,
                        style: JoTheme.ui(context)
                            .copyWith(fontSize: 13, color: p.text),
                      ),
                    ),
                    JoKeyField(
                      spec: appSettings.bindings[entry.$1] ?? '',
                      onChanged: (v) => appSettings.setBinding(entry.$1, v),
                    ),
                  ],
                ),
              ),
          ],
        );
    }

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: SizedBox(
              width: width,
              height: height,
              child: Container(
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        JoSpace.s5, JoSpace.s4, JoSpace.s5, JoSpace.s3),
                      child: Text(
                        '首选项',
                        style: JoTheme.ui(context).copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: p.text,
                        ),
                      ),
                    ),
                    Container(height: 1, color: p.border),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 170,
                            child: ColoredBox(
                              color: p.bg,
                              child: ListView(
                                padding: const EdgeInsets.symmetric(
                                  vertical: JoSpace.s2),
                                children: [
                                  JoListRow(
                                    title: '外观',
                                    selected: _prefsTab == 0,
                                    onTap: () => setState(() => _prefsTab = 0),
                                  ),
                                  JoListRow(
                                    title: '开发者',
                                    selected: _prefsTab == 1,
                                    onTap: () => setState(() => _prefsTab = 1),
                                  ),
                                  JoListRow(
                                    title: '快捷键',
                                    selected: _prefsTab == 2,
                                    onTap: () => setState(() => _prefsTab = 2),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Container(width: 1, color: p.border),
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(JoSpace.s5),
                              child: page,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(height: 1, color: p.border),
                    Padding(
                      padding: const EdgeInsets.all(JoSpace.s3),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: JoButton(
                          text: '关闭',
                          bordered: true,
                          onTap: () => setState(() => _prefsOpen = false),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _saveGuardOverlay(JoPalette p) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 440,
                padding: const EdgeInsets.all(JoSpace.s5),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '有未保存的改动',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Text(
                      '继续之前要保存吗？',
                      style: JoTheme.meta(context).copyWith(color: p.text),
                    ),
                    const SizedBox(height: JoSpace.s4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        JoButton(
                          text: '取消',
                          onTap: () => setState(() => _saveGuardOpen = false),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '不保存',
                          danger: true,
                          onTap: () {
                            final action = _pendingAction;
                            _pendingAction = null;
                            setState(() => _saveGuardOpen = false);
                            action?.call();
                          },
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '保存并继续',
                          bordered: true,
                          onTap: () async {
                            await state.save();
                            if (state.dirty) return;
                            final action = _pendingAction;
                            _pendingAction = null;
                            setState(() => _saveGuardOpen = false);
                            action?.call();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _historyOverlay(JoPalette p) {
    final labels = state.undoHistory;
    final total = labels.length;

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 460,
                height: 420,
                padding: const EdgeInsets.all(JoSpace.s5),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '历史记录',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Expanded(
                      child: ListView(
                        children: [
                          JoListRow(
                            title: '当前状态',
                            selected: true,
                            onTap: () {},
                          ),
                          for (int i = 0; i < total; i++)
                            JoListRow(
                              title: labels[i],
                              subtitle: '点击回到这一步之前',
                              onTap: () {
                                state.undoTo(total - 1 - i);
                                setState(() => _historyOpen = false);
                              },
                            ),
                          if (total == 0)
                            Padding(
                              padding: const EdgeInsets.all(JoSpace.s3),
                              child: Text(
                                '还没有可撤销的操作',
                                style: JoTheme.meta(context)
                                    .copyWith(color: p.secondary),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Align(
                      alignment: Alignment.centerRight,
                      child: JoButton(
                        text: '关闭',
                        bordered: true,
                        onTap: () => setState(() => _historyOpen = false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _closePrompt(JoPalette p) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 420,
                padding: const EdgeInsets.all(JoSpace.s5),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '有未保存的改动',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Text(
                      '关闭前要保存吗？',
                      style: JoTheme.meta(context).copyWith(color: p.text),
                    ),
                    const SizedBox(height: JoSpace.s4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        JoButton(
                          text: '取消',
                          onTap: () =>
                              setState(() => _closePromptOpen = false),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '不保存',
                          danger: true,
                          onTap: _closeWindow,
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '保存并退出',
                          bordered: true,
                          onTap: () async {
                            await state.save();
                            if (!state.dirty) {
                              _closeWindow();
                            } else {
                              setState(() => _closePromptOpen = false);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _modal(Widget child) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: GestureDetector(onTap: () {}, child: child),
          ),
        ),
      ),
    );
  }

  Widget _newWorldOverlay(JoPalette p) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 360,
                padding: const EdgeInsets.all(JoSpace.s5),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '新建世界',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    JoTextInput(
                      initial: '',
                      placeholder: '世界名称',
                      onChanged: (v) => _newWorldName = v,
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Row(
                      children: [
                        Expanded(
                          child: JoTextInput(
                            initial: '$_newWorldWidth',
                            placeholder: '宽（格）',
                            onChanged: (v) =>
                                _newWorldWidth = int.tryParse(v) ?? 32,
                          ),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        Expanded(
                          child: JoTextInput(
                            initial: '$_newWorldHeight',
                            placeholder: '高（格）',
                            onChanged: (v) =>
                                _newWorldHeight = int.tryParse(v) ?? 24,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: JoSpace.s4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        JoButton(
                          text: '取消',
                          onTap: () => setState(() => _newWorldOpen = false),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '创建',
                          bordered: true,
                          onTap: () {
                            final name = _newWorldName.trim().isEmpty
                                ? '未命名世界'
                                : _newWorldName.trim();
                            setState(() => _newWorldOpen = false);
                            if (widget.terrainOnly) {
                              _createNewFormatWorld(
                                name,
                                _newWorldWidth,
                                _newWorldHeight,
                              );
                            } else {
                              state.newWorld(
                                name,
                                width: _newWorldWidth,
                                height: _newWorldHeight,
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _aboutOverlay(JoPalette p) {
    final String info = [
      'Gloomyabyss Map Editor',
      '版本 $kAppVersion',
      '界面库 JO-DraftUI',
      '字体 Noto Sans SC / Noto Serif SC / Noto Sans Mono',
      '图标 Remix Icon',
      '平台 ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    ].join('\n');

    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 460,
                padding: const EdgeInsets.all(JoSpace.s5),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '关于',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Text(
                      'Gloomyabyss Map Editor',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 14,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s1),
                    Text(
                      '版本 $kAppVersion',
                      style: JoTheme.meta(context).copyWith(color: p.secondary),
                    ),
                    const SizedBox(height: JoSpace.s4),
                    Container(height: 1, color: p.border),
                    const SizedBox(height: JoSpace.s3),
                    _aboutRow(p, '界面库', 'JO-DraftUI（Apache 2.0）'),
                    _aboutRow(p, '字体', 'Noto Sans SC / Serif SC / Mono（SIL OFL 1.1）'),
                    _aboutRow(p, '图标', 'Remix Icon（Remix Icon License 1.0）'),
                    _aboutRow(
                      p,
                      '平台',
                      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
                    ),
                    const SizedBox(height: JoSpace.s4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        JoButton(
                          text: '复制信息',
                          onTap: () async {
                            await Clipboard.setData(ClipboardData(text: info));
                            state.setNotice('已复制版本信息');
                          },
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '项目主页',
                          bordered: true,
                          onTap: () => _openUrl(kProjectUrl),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '第三方许可',
                          bordered: true,
                          onTap: () => setState(() => _licensesOpen = true),
                        ),
                        const SizedBox(width: JoSpace.s2),
                        JoButton(
                          text: '确定',
                          bordered: true,
                          onTap: () => setState(() => _aboutOpen = false),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _licensesOverlay(JoPalette p) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: const Color(0x99000000),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 560,
                height: 460,
                padding: const EdgeInsets.all(JoSpace.s5),
                decoration: BoxDecoration(
                  color: p.surface,
                  border: JoShape.border(p.border),
                  borderRadius: JoShape.br,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '第三方许可',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Expanded(
                      child: FutureBuilder<String>(
                        future: rootBundle.loadString('THIRD-PARTY-NOTICES.md'),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) {
                            return Text(
                              '读取中…',
                              style: JoTheme.meta(context)
                                  .copyWith(color: p.secondary),
                            );
                          }
                          return SingleChildScrollView(
                            child: JoMarkdown(
                              data: snapshot.data!,
                              style: JoTheme.meta(context)
                                  .copyWith(color: p.text),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Align(
                      alignment: Alignment.centerRight,
                      child: JoButton(
                        text: '关闭',
                        bordered: true,
                        onTap: () => setState(() => _licensesOpen = false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _aboutRow(JoPalette p, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: JoSpace.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: JoTheme.meta(context).copyWith(color: p.secondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: JoTheme.meta(context).copyWith(color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}
