import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:jo_draftui/jo_draftui.dart';

import '../models/obj.dart';
import '../models/prop.dart';
import '../models/solid.dart';
import '../models/terrain.dart';
import '../models/world.dart';

class MapCanvas extends StatefulWidget {
  const MapCanvas({
    super.key,
    required this.segment,
    required this.terrain,
    required this.selectedCode,
    required this.onPaint,
    required this.onStrokeStart,
    required this.onStrokeEnd,
    this.highlight,
    this.pickMode = false,
    this.onPickCell,
    this.placedProps = const <PlacedProp>[],
    this.propTypes = const <PropType>[],
    this.propMode = false,
    this.onPropCell,
    this.placedObjects = const <PlacedObject>[],
    this.objectMode = false,
    this.onObjectCell,
    this.worldStartCol,
    this.worldStartRow,
    this.startPickMode = false,
    this.onStartCell,
    this.solids = const <SolidShape>[],
    this.solidMode = false,
    this.onSolidCell,
    this.solidDraft = const <(int, int)>[],
    this.solidSelectMode = false,
    this.onSolidSelectCell,
    this.selectedSolid = -1,
    this.padMode = false,
    this.onPadCell,
  });

  final Segment segment;
  final TerrainSet terrain;
  final String selectedCode;
  final void Function(int col, int row) onPaint;
  final VoidCallback onStrokeStart;
  final VoidCallback onStrokeEnd;

  /// 高亮的传送门平面（画布上用强调色画出来）。
  final PortalPlane? highlight;

  /// 拾取模式：点击只回报格子坐标，不画地形。
  final bool pickMode;
  final void Function(int col, int row)? onPickCell;

  /// 已放下的道具与类型表，用于画在格子上。
  final List<PlacedProp> placedProps;
  final List<PropType> propTypes;

  /// 道具模式：点击只回报格子，由外部放置/删除道具。
  final bool propMode;
  final void Function(int col, int row)? onPropCell;

  final List<PlacedObject> placedObjects;
  final bool objectMode;
  final void Function(int col, int row)? onObjectCell;

  final int? worldStartCol;
  final int? worldStartRow;
  final bool startPickMode;
  final void Function(int col, int row)? onStartCell;

  final List<SolidShape> solids;
  final bool solidMode;
  final void Function(int col, int row)? onSolidCell;
  final List<(int, int)> solidDraft;
  final bool solidSelectMode;
  final void Function(int col, int row)? onSolidSelectCell;
  final int selectedSolid;
  final bool padMode;
  final void Function(int col, int row)? onPadCell;

  @override
  State<MapCanvas> createState() => _MapCanvasState();
}

class _MapCanvasState extends State<MapCanvas> {
  static const double _minScale = 4;
  static const double _maxScale = 64;

  double? _scale;
  Offset _pan = Offset.zero;
  bool _fit = true;

  Size _viewport = Size.zero;
  bool _stroking = false;
  bool _panning = false;
  Offset _lastPointer = Offset.zero;
  (int, int)? _hoverCell;

  @override
  void didUpdateWidget(covariant MapCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segment != widget.segment) {
      _fit = true;
      _pan = Offset.zero;
    }
  }

  double _fitScale(Size viewport) {
    final w = widget.segment.width;
    final h = widget.segment.height;
    if (w == 0 || h == 0) return 16;
    final fit = math.min(viewport.width / w, viewport.height / h);
    return fit.clamp(2.0, 32.0);
  }

  double get _effectiveScale => _fit ? _fitScale(_viewport) : (_scale ?? 16);

  Offset get _baseOffset {
    final scale = _effectiveScale;
    return Offset(
      (_viewport.width - widget.segment.width * scale) / 2,
      (_viewport.height - widget.segment.height * scale) / 2,
    );
  }

  Offset get _offset => _baseOffset + _pan;

  (int, int) _cellAt(Offset local) {
    final scale = _effectiveScale;
    final offset = _offset;
    return (
      ((local.dx - offset.dx) / scale).floor(),
      ((local.dy - offset.dy) / scale).floor(),
    );
  }

  (int, int) _cornerAt(Offset local) {
    final double sc = _effectiveScale;
    final Offset off = _offset;
    return (
      ((local.dx - off.dx) / sc).round(),
      ((local.dy - off.dy) / sc).round(),
    );
  }

  void _paintAt(Offset local) {
    final (col, row) = _cellAt(local);
    widget.onPaint(col, row);
  }

  void _zoom(PointerScrollEvent event) {
    final scale = _effectiveScale;
    final pos = event.localPosition;
    final factor = event.scrollDelta.dy < 0 ? 1.12 : 1 / 1.12;
    final next = (scale * factor).clamp(_minScale, _maxScale);
    if (next == scale) return;

    final world = (pos - _offset) / scale;
    final nextBase = Offset(
      (_viewport.width - widget.segment.width * next) / 2,
      (_viewport.height - widget.segment.height * next) / 2,
    );
    setState(() {
      _scale = next;
      _fit = false;
      _pan = pos - world * next - nextBase;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = JoTheme.of(context);
    if (widget.segment.width == 0 || widget.segment.height == 0) {
      return Center(
        child: Text(
          '这个段没有数据',
          style: JoTheme.ui(context).copyWith(color: p.secondary),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = _effectiveScale;
        final offset = _offset;

        return ClipRect(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) _zoom(event);
            },
            onPointerDown: (event) {
              if (event.buttons &
                      (kMiddleMouseButton | kSecondaryMouseButton) !=
                  0) {
                _panning = true;
                _lastPointer = event.localPosition;
                return;
              }
              if (event.buttons & kPrimaryMouseButton != 0) {
                if (widget.pickMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  widget.onPickCell?.call(col, row);
                  return;
                }
                if (widget.propMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  widget.onPropCell?.call(col, row);
                  return;
                }
                if (widget.objectMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  widget.onObjectCell?.call(col, row);
                  return;
                }
                if (widget.startPickMode) {
                  final (col, row) = _cellAt(event.localPosition);
                  widget.onStartCell?.call(col, row);
                  return;
                }
                if (widget.solidMode) {
                  final (int cx, int cy) = _cornerAt(event.localPosition);
                  widget.onSolidCell?.call(cx, cy);
                  return;
                }
                if (widget.solidSelectMode) {
                  final (int cc, int rr) = _cellAt(event.localPosition);
                  widget.onSolidSelectCell?.call(cc, rr);
                  return;
                }
                if (widget.padMode) {
                  final (int cc, int rr) = _cellAt(event.localPosition);
                  widget.onPadCell?.call(cc, rr);
                  return;
                }
                _stroking = true;
                widget.onStrokeStart();
                _paintAt(event.localPosition);
              }
            },
            onPointerMove: (event) {
              if (_panning) {
                final delta = event.localPosition - _lastPointer;
                _lastPointer = event.localPosition;
                setState(() => _pan += delta);
                return;
              }
              if (_stroking) _paintAt(event.localPosition);
            },
            onPointerUp: (event) {
              if (_stroking) {
                _stroking = false;
                widget.onStrokeEnd();
              }
              _panning = false;
            },
            onPointerCancel: (event) {
              if (_stroking) {
                _stroking = false;
                widget.onStrokeEnd();
              }
              _panning = false;
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              onHover: (event) {
                if (!widget.solidMode) return;
                final (int c, int r) = _cornerAt(event.localPosition);
                if (_hoverCell != (c, r)) {
                  setState(() => _hoverCell = (c, r));
                }
              },
              onExit: (_) {
                if (_hoverCell != null) {
                  setState(() => _hoverCell = null);
                }
              },
              child: CustomPaint(
                size: Size.infinite,
                painter: _MapPainter(
                  segment: widget.segment,
                  terrain: widget.terrain,
                  scale: scale,
                  offset: offset,
                  background: p.bg,
                  grid: p.border,
                  border: p.border,
                  accent: p.accent,
                  highlight: widget.highlight,
                  placedProps: widget.placedProps,
                  propTypes: widget.propTypes,
                  placedObjects: widget.placedObjects,
                  worldStartCol: widget.worldStartCol,
                  worldStartRow: widget.worldStartRow,
                  solids: widget.solids,
                  solidDraft: widget.solidDraft,
                  selectedSolid: widget.selectedSolid,
                  solidHoverCell: _hoverCell,
                  accentColor: p.accent,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

void _drawDashed(Canvas canvas, Offset a, Offset b, Color color) {
  final double dx = b.dx - a.dx;
  final double dy = b.dy - a.dy;
  final double len = math.sqrt(dx * dx + dy * dy);
  if (len <= 0) return;

  const double dash = 6;
  const double gap = 4;
  final double ux = dx / len;
  final double uy = dy / len;
  final Paint paint = Paint()
    ..color = color
    ..strokeWidth = 1;

  double t = 0;
  while (t < len) {
    final double end = math.min(t + dash, len);
    canvas.drawLine(
      Offset(a.dx + ux * t, a.dy + uy * t),
      Offset(a.dx + ux * end, a.dy + uy * end),
      paint,
    );
    t = end + gap;
  }
}

const List<Color> _kPropColors = <Color>[
  Color(0xFFD9A441),
  Color(0xFF6FA8DC),
  Color(0xFF7FB069),
  Color(0xFFA98BD6),
  Color(0xFFD96C6C),
];

Color _propColor(int index, Color fallback) =>
    index >= 0 && index < _kPropColors.length ? _kPropColors[index] : fallback;

class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.segment,
    required this.terrain,
    required this.scale,
    required this.offset,
    required this.background,
    required this.grid,
    required this.border,
    required this.accent,
    required this.highlight,
    required this.placedProps,
    required this.propTypes,
    required this.placedObjects,
    required this.worldStartCol,
    required this.worldStartRow,
    required this.solids,
    required this.solidDraft,
    required this.solidHoverCell,
    required this.selectedSolid,
    required this.accentColor,
  });

  final Segment segment;
  final TerrainSet terrain;
  final double scale;
  final Offset offset;
  final Color background;
  final Color grid;
  final Color border;
  final Color accent;
  final PortalPlane? highlight;
  final List<PlacedProp> placedProps;
  final List<PropType> propTypes;
  final List<PlacedObject> placedObjects;
  final int? worldStartCol;
  final int? worldStartRow;
  final List<SolidShape> solids;
  final List<(int, int)> solidDraft;
  final (int, int)? solidHoverCell;
  final int selectedSolid;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);

    canvas.save();
    canvas.translate(offset.dx, offset.dy);

    final paint = Paint();
    for (var row = 0; row < segment.height; row++) {
      for (var col = 0; col < segment.width; col++) {
        final code = segment.charAt(col, row);
        final type = terrain.byCode[code] ?? terrain.fallback;
        paint.color = Color(type.color);
        canvas.drawRect(
          Rect.fromLTWH(col * scale, row * scale, scale, scale),
          paint,
        );
      }
    }

    if (scale >= 6) {
      final gridPaint = Paint()
        ..color = grid
        ..strokeWidth = 1;
      for (var col = 0; col <= segment.width; col++) {
        canvas.drawLine(
          Offset(col * scale + 0.5, 0),
          Offset(col * scale + 0.5, segment.height * scale),
          gridPaint,
        );
      }
      for (var row = 0; row <= segment.height; row++) {
        canvas.drawLine(
          Offset(0, row * scale + 0.5),
          Offset(segment.width * scale, row * scale + 0.5),
          gridPaint,
        );
      }
    }

    for (final PlacedProp prop in placedProps) {
      final int index = propTypes.indexWhere((t) => t.id == prop.id);
      final Color color = _propColor(index < 0 ? 0 : index, accent);
      final Rect rect = Rect.fromLTWH(
        prop.col * scale + 1.5,
        prop.row * scale + 1.5,
        scale - 3,
        scale - 3,
      );
      canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.85));
      canvas.drawRect(
        rect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      if (scale >= 12) {
        final TextPainter tp = TextPainter(
          text: TextSpan(
            text: prop.id.length > 2 ? prop.id.substring(0, 2) : prop.id,
            style: TextStyle(
              color: const Color(0xFF111111),
              fontSize: (scale * 0.4).clamp(7.0, 14.0),
              fontFamily: 'packages/jo_draftui/NotoSansSC',
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          rect.center - Offset(tp.width / 2, tp.height / 2),
        );
      }
    }

    for (final PlacedObject obj in placedObjects) {
      final Offset center = Offset(
        (obj.col + 0.5) * scale,
        (obj.row + 0.5) * scale,
      );
      final double r = (scale - 6).clamp(2.0, 20.0);
      final Path diamond = Path()
        ..moveTo(center.dx, center.dy - r)
        ..lineTo(center.dx + r, center.dy)
        ..lineTo(center.dx, center.dy + r)
        ..lineTo(center.dx - r, center.dy)
        ..close();
      canvas.drawPath(diamond, Paint()..color = const Color(0xFF7FB069).withValues(alpha: 0.9));
      canvas.drawPath(
        diamond,
        Paint()
          ..color = const Color(0xFF3F7A3A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      if (scale >= 14) {
        final TextPainter tp = TextPainter(
          text: TextSpan(
            text: obj.id.length > 2 ? obj.id.substring(0, 2) : obj.id,
            style: TextStyle(
              color: const Color(0xFF111111),
              fontSize: (scale * 0.32).clamp(6.0, 11.0),
              fontFamily: 'packages/jo_draftui/NotoSansSC',
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
      }
    }

    if (solidDraft.isNotEmpty) {
      final Paint draftPaint = Paint()
        ..color = accentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      final Path draftPath = Path();
      for (int i = 0; i < solidDraft.length; i++) {
        final Offset o = Offset(
          solidDraft[i].$1 * scale,
          solidDraft[i].$2 * scale,
        );
        if (i == 0) {
          draftPath.moveTo(o.dx, o.dy);
        } else {
          draftPath.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(draftPath, draftPaint);

      for (final (int px, int py) in solidDraft) {
        final Offset o = Offset(px * scale, py * scale);
        canvas.drawRect(
          Rect.fromCenter(center: o, width: 6, height: 6),
          Paint()..color = accentColor,
        );
      }

      if (solidHoverCell != null) {
        final (int hc, int hr) = solidHoverCell!;
        final Offset hover = Offset(hc * scale, hr * scale);
        final Offset last = Offset(
          solidDraft.last.$1 * scale,
          solidDraft.last.$2 * scale,
        );
        canvas.drawLine(last, hover, draftPaint);
        if (solidDraft.length >= 3) {
          final Offset first = Offset(
            solidDraft.first.$1 * scale,
            solidDraft.first.$2 * scale,
          );
          canvas.drawLine(
            hover,
            first,
            Paint()
              ..color = accentColor.withValues(alpha: 0.4)
              ..strokeWidth = 1,
          );
        }
      }
    }

    for (int si = 0; si < solids.length; si++) {
      final SolidShape solid = solids[si];
      final bool sel = si == selectedSolid;
      final Paint line = Paint()
        ..color = sel ? accentColor : const Color(0xFFD96C6C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = sel ? 3 : 2;
      final Path path = Path();
      for (int i = 0; i < solid.points.length; i++) {
        final (int px, int py) = solid.points[i];
        final Offset o = Offset(px * scale, py * scale);
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      path.close();
      canvas.drawPath(path, line);
    }

    final int? sc = worldStartCol;
    final int? sr = worldStartRow;
    if (sc != null && sr != null) {
      final int lc = sc - segment.spec.originCol;
      final int lr = sr - segment.spec.originRow;
      if (lc >= 0 && lc < segment.width && lr >= 0 && lr < segment.height) {
        final Offset c = Offset((lc + 0.5) * scale, (lr + 0.5) * scale);
        final Paint ring = Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        canvas.drawCircle(c, (scale * 0.32).clamp(4.0, 12.0), ring);
        final double r = (scale * 0.12).clamp(2.0, 5.0);
        canvas.drawLine(c - Offset(r, 0), c + Offset(r, 0), ring);
        canvas.drawLine(c - Offset(0, r), c + Offset(0, r), ring);
      }
    }

    canvas.drawRect(
      Rect.fromLTWH(0, 0, segment.width * scale, segment.height * scale),
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final plane = highlight;
    if (plane != null) {
      final linePaint = Paint()
        ..color = accent
        ..strokeWidth = 2;
      final bool horizontal = plane.axis == 'x';
      final Offset a = horizontal
          ? Offset(plane.at * scale, plane.from * scale)
          : Offset(plane.from * scale, plane.at * scale);
      final Offset b = horizontal
          ? Offset(plane.at * scale, plane.to * scale)
          : Offset(plane.to * scale, plane.at * scale);
      canvas.drawLine(a, b, linePaint);

      // 方向箭头：画在线的中点。
      final Offset mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      final bool positive = plane.direction == '+';
      final double sign = positive ? 1 : -1;
      final Path arrow = Path();
      const double s6 = 6;
      if (horizontal) {
        arrow.moveTo(mid.dx + sign * s6, mid.dy);
        arrow.lineTo(mid.dx - sign * s6, mid.dy - s6);
        arrow.lineTo(mid.dx - sign * s6, mid.dy + s6);
      } else {
        arrow.moveTo(mid.dx, mid.dy + sign * s6);
        arrow.lineTo(mid.dx - s6, mid.dy - sign * s6);
        arrow.lineTo(mid.dx + s6, mid.dy - sign * s6);
      }
      arrow.close();
      canvas.drawPath(arrow, Paint()..color = accent);

      // 出口：目标位置的那条线，虚线画。
      final Offset dstA = horizontal
          ? Offset(
              (plane.at + plane.dx) * scale,
              (plane.from + plane.dy) * scale,
            )
          : Offset(
              (plane.from + plane.dx) * scale,
              (plane.at + plane.dy) * scale,
            );
      final Offset dstB = horizontal
          ? Offset((plane.at + plane.dx) * scale, (plane.to + plane.dy) * scale)
          : Offset(
              (plane.to + plane.dx) * scale,
              (plane.at + plane.dy) * scale,
            );

      _drawDashed(canvas, dstA, dstB, accent.withValues(alpha: 0.55));
      _drawDashed(
        canvas,
        mid,
        Offset((dstA.dx + dstB.dx) / 2, (dstA.dy + dstB.dy) / 2),
        accent.withValues(alpha: 0.25),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MapPainter oldDelegate) => true;
}
