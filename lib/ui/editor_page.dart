import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import '../config.dart';
import '../models/world.dart';
import '../state/editor_state.dart';
import 'map_canvas.dart';
import 'segment_dialogs.dart';

class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final state = EditorState();
  bool _aboutOpen = false;
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

  static const MethodChannel _windowChannel = MethodChannel('jodraft/window');

  @override
  void initState() {
    super.initState();
    _windowChannel.setMethodCallHandler(_onWindowCall);
  }

  @override
  void dispose() {
    _windowChannel.setMethodCallHandler(null);
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

  @override
  Widget build(BuildContext context) {
    final p = JoTheme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([state, appSettings]),
      builder: (context, _) {
        return Focus(
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
                    child: Row(
                      children: [
                        _leftPanel(p),
                        Container(width: 1, color: p.border),
                        Expanded(child: _canvas(p)),
                        Container(width: 1, color: p.border),
                        _rightPanel(p),
                      ],
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed) return KeyEventResult.ignored;

    final key = event.logicalKey;

    // Ctrl+S 始终归编辑器，输入框里也能保存
    if (key == LogicalKeyboardKey.keyS) {
      if (state.world != null) state.save();
      return KeyEventResult.handled;
    }

    // 撤销/重做在输入框聚焦时让给输入框自己
    if (JoTextField.isEditing) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.keyZ) {
      if (keyboard.isShiftPressed) {
        state.redo();
      } else {
        state.undo();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyY) {
      state.redo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _menuBar() {
    return JoMenuBar(
      menus: [
        JoMenu('文件', [
          JoMenuItem(
            '新建世界…',
            onTap: () => _runGuarded(() async {
              _newWorldName = '';
              _newWorldWidth = 32;
              _newWorldHeight = 24;
              setState(() => _newWorldOpen = true);
            }),
          ),
          JoMenuItem('打开 .gmap…', onTap: () => _runGuarded(state.openGmap)),
          if (appSettings.developerMode) ...[
            JoMenuItem('打开世界目录…', onTap: () => _runGuarded(state.openRoot)),
            JoMenuItem('导入到世界目录…', onTap: () => _runGuarded(state.importGmap)),
          ],
          const JoMenuItem('', divider: true),
          JoMenuItem(
            '保存',
            onTap: state.world == null || !state.dirty ? null : state.save,
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
          JoMenuItem('历史记录…', onTap: () => setState(() => _historyOpen = true)),
          const JoMenuItem('', divider: true),
          JoMenuItem('首选项…', onTap: () => setState(() => _prefsOpen = true)),
        ]),
        JoMenu('视图', [
          JoMenuItem('校验地图', onTap: state.world == null ? null : state.validate),
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
            onTap: state.canUndo ? state.undo : null,
          ),
          JoIconAction(
            icon: JoIcons.redo,
            tip: '重做',
            onTap: state.canRedo ? state.redo : null,
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
            onTap: () => _runGuarded(() async {
              _newWorldName = '';
              _newWorldWidth = 32;
              _newWorldHeight = 24;
              setState(() => _newWorldOpen = true);
            }),
          ),
          JoIconAction(
            icon: JoIcons.file,
            tip: '打开 .gmap',
            onTap: state.openGmap,
          ),
          JoIconAction(
            icon: JoIcons.save,
            tip: '保存',
            onTap: state.world == null || !state.dirty ? null : state.save,
          ),
          JoIconAction(
            icon: JoIcons.check,
            tip: '校验',
            onTap: state.world == null ? null : state.validate,
          ),
          const SizedBox(width: JoSpace.s3),
          if (state.world != null)
            Text(
              '${state.world!.name} / ${segment?.spec.id ?? '-'}',
              style: JoTheme.meta(context).copyWith(color: p.secondary),
            ),
        ],
      ),
    );
  }

  Widget _leftPanel(JoPalette p) {
    return SizedBox(
      width: 220,
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
              child: state.worlds.isEmpty
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

            // —— 段
            Padding(
              padding: const EdgeInsets.fromLTRB(
                JoSpace.s3,
                JoSpace.s3,
                JoSpace.s3,
                JoSpace.s1,
              ),
              child: Text(
                '段',
                style: JoTheme.meta(context).copyWith(
                  color: p.secondary,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: JoSpace.s2),
              child: Row(
                children: [
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
              ),
            ),
            const SizedBox(height: JoSpace.s2),
            Container(height: 1, color: p.border),
            Expanded(
              child: ListView.builder(
                itemCount: state.world?.segments.length ?? 0,
                itemBuilder: (context, index) {
                  final segment = state.world!.segments[index];
                  return JoListRow(
                    title: segment.spec.id,
                    subtitle: '${segment.width}×${segment.height}',
                    selected: index == state.selectedSegment,
                    onTap: () => state.selectSegment(index),
                  );
                },
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

    PortalPlane? highlight;
    if (_panelTab == 3 &&
        state.selectedPlane >= 0 &&
        state.selectedPlane < state.planes.length) {
      highlight = state.planes[state.selectedPlane];
    }

    return MapCanvas(
      segment: segment,
      terrain: terrain,
      selectedCode: state.selectedCode,
      onPaint: state.paint,
      onStrokeStart: state.beginStroke,
      onStrokeEnd: state.endStroke,
      highlight: highlight,
      placedProps: state.placedProps,
      propTypes: state.propTypes,
      propMode: _panelTab == 1,
      onPropCell: state.togglePropAt,
      placedObjects: state.placedObjects,
      objectMode: _panelTab == 2,
      onObjectCell: state.toggleObjectAt,
      worldStartCol: state.worldStartCol,
      worldStartRow: state.worldStartRow,
      startPickMode: state.startPick,
      onStartCell: state.setStartFromCell,
      solids: state.solids,
      solidMode: state.solidPick,
      onSolidCell: state.pickSolidCell,
      solidDraft: state.solidDraft,
      pickMode: state.pickPlane,
      onPickCell: state.pickCell,
    );
  }

  Widget _rightPanel(JoPalette p) {
    return SizedBox(
      width: 300,
      child: ColoredBox(
        color: p.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(JoSpace.s3),
              child: JoSegment<int>(
                options: const [
                  (label: '地形', value: 0),
                  (label: '道具', value: 1),
                  (label: '对象', value: 2),
                  (label: '传送', value: 3),
                  (label: '段', value: 4),
                  (label: '碰撞', value: 5),
                  (label: '世界', value: 6),
                ],
                value: _panelTab,
                onChanged: (v) {
                  setState(() => _panelTab = v);
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
    final planes = state.planes;
    if (state.world == null) {
      return Center(
        child: Text('先打开一个世界', style: JoTheme.meta(context).copyWith(color: p.secondary)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: JoSpace.s2,
            vertical: JoSpace.s2,
          ),
          child: Row(
            children: [
              JoButton(text: '新建', bordered: true, onTap: state.addPlane),
              const SizedBox(width: JoSpace.s2),
              JoButton(
                text: '删除',
                danger: true,
                onTap: state.selectedPlane < 0 ? null : state.removePlane,
              ),
              const SizedBox(width: JoSpace.s2),
              JoButton(
                text: state.pickPlane ? '拾取中…' : '画到画布',
                bordered: true,
                color: state.pickPlane ? p.accent : null,
                onTap: state.selectedPlane < 0 ? null : state.togglePick,
              ),
            ],
          ),
        ),
        Container(height: 1, color: p.border),
        Expanded(
          child: planes.isEmpty
              ? Center(
                  child: Text(
                    '没有传送门平面',
                    style: JoTheme.meta(context).copyWith(color: p.secondary),
                  ),
                )
              : ListView.builder(
                  itemCount: planes.length,
                  itemBuilder: (context, index) {
                    final plane = planes[index];
                    return JoListRow(
                      title: '${plane.axis} @ ${plane.at}  ${plane.from}→${plane.to}',
                      subtitle: _planeExitLabel(plane),
                      selected: index == state.selectedPlane,
                      onTap: () => state.selectPlane(index),
                    );
                  },
                ),
        ),
        if (state.selectedPlane >= 0 && state.selectedPlane < planes.length) ...[
          Container(height: 1, color: p.border),
          SizedBox(
            height: 300,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(JoSpace.s3),
              child: _planeEditor(p, planes[state.selectedPlane]),
            ),
          ),
        ],
      ],
    );
  }

  String _planeExitLabel(PortalPlane plane) {
    if (plane.axis == 'x') {
      final x = plane.at + plane.dx;
      final y1 = plane.from + plane.dy;
      final y2 = plane.to + plane.dy;
      return '方向 ${plane.direction}  出口 x=$x  y=$y1→$y2';
    }
    final y = plane.at + plane.dy;
    final x1 = plane.from + plane.dx;
    final x2 = plane.to + plane.dx;
    return '方向 ${plane.direction}  出口 y=$y  x=$x1→$x2';
  }

  Widget _planeEditor(JoPalette p, PortalPlane plane) {
    final segment = state.segment;
    final width = segment?.width ?? 0;
    final height = segment?.height ?? 0;
    final horizontal = plane.axis == 'x';
    final maxAt = horizontal ? width : height;
    final maxTo = horizontal ? height : width;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(p, '轴'),
        JoSegment<String>(
          options: const [
            (label: 'x（竖线）', value: 'x'),
            (label: 'y（横线）', value: 'y'),
          ],
          value: plane.axis,
          onChanged: (v) {
            final maxA = v == 'x' ? width : height;
            final maxB = v == 'x' ? height : width;
            state.updatePlane(
              plane,
              axis: v,
              at: plane.at.clamp(0, maxA).toInt(),
              to: plane.to.clamp(0, maxB).toInt(),
              from: plane.from.clamp(0, maxB).toInt(),
            );
            state.cancelPick();
          },
        ),
        const SizedBox(height: JoSpace.s3),
        _label(p, '方向'),
        JoSegment<String>(
          options: const [
            (label: '+', value: '+'),
            (label: '-', value: '-'),
          ],
          value: plane.direction,
          onChanged: (v) => state.updatePlane(plane, direction: v),
        ),
        const SizedBox(height: JoSpace.s3),
        _numRow(p, '位置 at', plane.at, 0, maxAt,
            (v) => state.updatePlane(plane, at: v)),
        _numRow(p, '起 from', plane.from, 0, maxTo,
            (v) => state.updatePlane(plane, from: v)),
        _numRow(p, '止 to', plane.to, 0, maxTo,
            (v) => state.updatePlane(plane, to: v)),
        const SizedBox(height: JoSpace.s2),
        _label(p, '目标坐标'),
        _numRow(p, 'dx', plane.dx, -64, 64,
            (v) => state.updatePlane(plane, dx: v)),
        _numRow(p, 'dy', plane.dy, -64, 64,
            (v) => state.updatePlane(plane, dy: v)),
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
      right: segment == null ? null : '${segment.width}×${segment.height} 格',
    );
  }

  Widget _prefsOverlay(JoPalette p) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _prefsOpen = false),
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
                      '首选项',
                      style: JoTheme.ui(context).copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                      ),
                    ),
                    const SizedBox(height: JoSpace.s4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '开发者模式',
                            style: JoTheme.ui(context)
                                .copyWith(fontSize: 13, color: p.text),
                          ),
                        ),
                        JoToggle(
                          on: appSettings.developerMode,
                          onChanged: appSettings.setDeveloperMode,
                        ),
                      ],
                    ),
                    const SizedBox(height: JoSpace.s3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '主题',
                            style: JoTheme.ui(context)
                                .copyWith(fontSize: 13, color: p.text),
                          ),
                        ),
                        JoSegment<bool>(
                          options: const [
                            (label: '暗 · 机器', value: true),
                            (label: '明 · 纸', value: false),
                          ],
                          value: appSettings.dark,
                          onChanged: appSettings.setDark,
                        ),
                      ],
                    ),
                    const SizedBox(height: JoSpace.s5),
                    Align(
                      alignment: Alignment.centerRight,
                      child: JoButton(
                        text: '关闭',
                        bordered: true,
                        onTap: () => setState(() => _prefsOpen = false),
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
        onTap: () => setState(() => _saveGuardOpen = false),
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
        onTap: () => setState(() => _historyOpen = false),
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
        onTap: () => setState(() => _closePromptOpen = false),
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
        onTap: () => setState(() {
          _newSegOpen = false;
          _delSegOpen = false;
        }),
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
        onTap: () => setState(() => _newWorldOpen = false),
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
                            state.newWorld(
                              name,
                              width: _newWorldWidth,
                              height: _newWorldHeight,
                            );
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
        onTap: () => setState(() => _aboutOpen = false),
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
        onTap: () => setState(() => _licensesOpen = false),
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
