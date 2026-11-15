import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app_theme.dart';
import '../core/media.dart';
import 'engine.dart';
import 'fx_preview.dart';
import 'models.dart';
import 'text_render.dart';

/// What is selected in the editor.
class Sel {
  final String kind; // main | overlay | text | audio
  final String id;
  const Sel(this.kind, this.id);
  @override
  bool operator ==(Object other) => other is Sel && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

ui.Image? _sampleImage;

/// Call once at start-up so sample-photo clips can draw synchronously.
Future<void> warmSampleImage() async => _sampleImage ??= await Media.samplePhoto();

Widget mediaImage(String path, {BoxFit fit = BoxFit.fill}) {
  if (path.startsWith('sample://')) return RawImage(image: _sampleImage, fit: fit);
  if (kIsWeb) return Image.network(path, fit: fit, gaplessPlayback: true);
  return Image.file(File(path), fit: fit, gaplessPlayback: true);
}

class _Box {
  final Offset centre;
  final Size size;
  final double angle;
  const _Box(this.centre, this.size, this.angle);

  bool contains(Offset p) {
    final d = p - centre;
    final c = math.cos(-angle), s = math.sin(-angle);
    final q = Offset(d.dx * c - d.dy * s, d.dx * s + d.dy * c);
    return q.dx.abs() <= size.width / 2 + 6 && q.dy.abs() <= size.height / 2 + 6;
  }
}

/// Live composite of the project at the engine's playhead.
class VideoPreview extends StatefulWidget {
  final VideoEngine engine;
  final Sel? selection;
  final ValueChanged<Sel?> onSelect;
  final VoidCallback onTransformLive;
  final VoidCallback onTransformEnd;

  const VideoPreview({
    super.key,
    required this.engine,
    required this.selection,
    required this.onSelect,
    required this.onTransformLive,
    required this.onTransformEnd,
  });

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  Pose? _startPose;
  Offset _moved = Offset.zero;
  bool _changed = false;

  VideoEngine get engine => widget.engine;
  Project get pr => engine.project;

  // ------------------------------------------------------------ geometry

  Size _clipBase(Clip c, double cw, double ch) {
    final k = math.min(cw / c.srcW, ch / c.srcH);
    return Size(c.srcW * k, c.srcH * k);
  }

  _Box _box(Pose p, Size base, double cw, double ch) => _Box(
        Offset(cw / 2 + p.x * cw, ch / 2 + p.y * ch),
        base * p.scale,
        p.rotation * math.pi / 180,
      );

  /// The selected visual layer, its timeline start and its base size.
  (Layer, double, Size)? _selected(double cw, double ch) {
    final sel = widget.selection;
    if (sel == null) return null;
    switch (sel.kind) {
      case 'main':
        final i = pr.main.indexWhere((c) => c.id == sel.id);
        if (i < 0) return null;
        return (pr.main[i], pr.mainStart(i), _clipBase(pr.main[i], cw, ch));
      case 'overlay':
        final i = pr.overlays.indexWhere((c) => c.id == sel.id);
        if (i < 0) return null;
        return (pr.overlays[i], pr.overlays[i].start, _clipBase(pr.overlays[i], cw, ch));
      case 'text':
        final i = pr.texts.indexWhere((c) => c.id == sel.id);
        if (i < 0) return null;
        return (pr.texts[i], pr.texts[i].start, TextRender.measure(pr.texts[i], cw, ch));
    }
    return null;
  }

  double _local(Layer l, double start) => (engine.position - start).clamp(0.0, l.duration);

  bool _visible(Layer l, double start) =>
      engine.position >= start - 1e-6 && engine.position <= start + l.duration + 1e-6;

  // ------------------------------------------------------------ gestures

  void _tap(Offset p, double cw, double ch) {
    for (final t in pr.texts.reversed) {
      if (!_visible(t, t.start)) continue;
      if (_box(t.poseAt(_local(t, t.start)), TextRender.measure(t, cw, ch), cw, ch).contains(p)) {
        widget.onSelect(Sel('text', t.id));
        return;
      }
    }
    for (final c in pr.overlays.reversed) {
      if (!_visible(c, c.start)) continue;
      if (_box(c.poseAt(_local(c, c.start)), _clipBase(c, cw, ch), cw, ch).contains(p)) {
        widget.onSelect(Sel('overlay', c.id));
        return;
      }
    }
    final i = pr.mainIndexAt(engine.position);
    widget.onSelect(i >= 0 ? Sel('main', pr.main[i].id) : null);
  }

  void _scaleStart(double cw, double ch) {
    final s = _selected(cw, ch);
    _startPose = s == null || !_visible(s.$1, s.$2) ? null : s.$1.basePose(_local(s.$1, s.$2));
    _moved = Offset.zero;
    _changed = false;
  }

  void _scaleUpdate(ScaleUpdateDetails d, double cw, double ch) {
    final s = _selected(cw, ch);
    final p0 = _startPose;
    if (s == null || p0 == null) return;
    _moved += d.focalPointDelta;
    var nx = p0.x + _moved.dx / cw, ny = p0.y + _moved.dy / ch;
    // Snap to the centre lines.
    if (nx.abs() < 0.012) nx = 0;
    if (ny.abs() < 0.012) ny = 0;
    var rot = p0.rotation + d.rotation * 180 / math.pi;
    if (rot.abs() < 2.0) rot = 0;
    s.$1.applyTransform(
      _local(s.$1, s.$2),
      nx: nx,
      ny: ny,
      ns: (p0.scale * d.scale).clamp(0.05, 12.0),
      nr: rot,
    );
    _changed = true;
    widget.onTransformLive();
  }

  // ------------------------------------------------------------ layers

  Widget _clipLayer(Clip c, double lt, double cw, double ch) {
    final p = c.poseAt(lt.clamp(0.0, c.duration));
    final b = _box(p, _clipBase(c, cw, ch), cw, ch);
    final ctrl = engine.controllerFor(c.id);
    Widget make({bool primary = false}) => c.isImage
        ? mediaImage(c.path)
        : ctrl != null
            ? VideoPlayer(ctrl, key: primary ? ValueKey('vp-${c.id}') : null)
            : const ColoredBox(color: Colors.black);
    Widget flip(Widget x) => c.flipH ? Transform.flip(flipX: true, child: x) : x;
    var w = flip(make(primary: true));
    w = applyFxPreview(c.effects, w, () => flip(make()), ch);
    final cm = clipColor(c);
    if (!cm.isIdentity) w = ColorFiltered(colorFilter: ColorFilter.matrix(cm.toFlutter()), child: w);
    if (c.blur > 0) {
      final s = c.blur / 100 * 0.03 * ch;
      w = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.decal), child: w);
    }
    if (p.alpha < 0.999) w = Opacity(opacity: p.alpha.clamp(0.0, 1.0), child: w);
    return Positioned(
      key: ValueKey('layer-${c.id}'),
      left: b.centre.dx - b.size.width / 2,
      top: b.centre.dy - b.size.height / 2,
      width: b.size.width,
      height: b.size.height,
      child: Transform.rotate(angle: b.angle, child: w),
    );
  }

  /// A main clip composed over the project background, filling the canvas.
  Widget _frame(Clip c, double lt, double cw, double ch) => SizedBox(
        width: cw,
        height: ch,
        child: ClipRect(
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: Color(pr.background))),
            _clipLayer(c, lt, cw, ch),
          ]),
        ),
      );

  List<Widget> _mainLayers(double cw, double ch) {
    final pos = engine.position;
    final i = pr.mainIndexAt(pos);
    if (i < 0) return const [];
    final start = pr.mainStart(i);
    final tr = pr.transitionAfter(i - 1);
    final incoming = _frame(pr.main[i], pos - start, cw, ch);
    if (i == 0 || tr <= 0 || pos >= start + tr) return [incoming];

    final prev = pr.main[i - 1];
    final outgoing = _frame(prev, pos - pr.mainStart(i - 1), cw, ch);
    final p = ((pos - start) / tr).clamp(0.0, 1.0);
    Widget shift(Widget w, double dx, double dy) => Transform.translate(offset: Offset(dx, dy), child: w);
    Widget dip(Color colour) => p < 0.5
        ? Stack(children: [outgoing, Positioned.fill(child: ColoredBox(color: colour.withValues(alpha: p * 2)))])
        : Stack(children: [incoming, Positioned.fill(child: ColoredBox(color: colour.withValues(alpha: (1 - p) * 2)))]);

    switch (prev.transition) {
      case 'fadeblack':
        return [dip(Colors.black)];
      case 'fadewhite':
        return [dip(Colors.white)];
      case 'slideleft':
        return [shift(outgoing, -p * cw, 0), shift(incoming, (1 - p) * cw, 0)];
      case 'slideright':
        return [shift(outgoing, p * cw, 0), shift(incoming, -(1 - p) * cw, 0)];
      case 'slideup':
        return [shift(outgoing, 0, -p * ch), shift(incoming, 0, (1 - p) * ch)];
      case 'slidedown':
        return [shift(outgoing, 0, p * ch), shift(incoming, 0, -(1 - p) * ch)];
      case 'wipeleft':
        return [outgoing, ClipRect(clipper: _RectClipper(Rect.fromLTRB(cw * (1 - p), 0, cw, ch)), child: incoming)];
      case 'wiperight':
        return [outgoing, ClipRect(clipper: _RectClipper(Rect.fromLTRB(0, 0, cw * p, ch)), child: incoming)];
      case 'circleopen':
        final r = p * math.sqrt(cw * cw + ch * ch) / 2;
        return [
          outgoing,
          ClipOval(clipper: _RectClipper(Rect.fromCircle(center: Offset(cw / 2, ch / 2), radius: r)), child: incoming),
        ];
      default:
        return [outgoing, Opacity(opacity: p, child: incoming)];
    }
  }

  Widget _textLayer(TextItem t, double cw, double ch) {
    final p = t.poseAt(_local(t, t.start));
    final base = TextRender.measure(t, cw, ch);
    final b = _box(p, base, cw, ch);
    return Positioned(
      key: ValueKey('layer-${t.id}'),
      left: b.centre.dx - b.size.width / 2,
      top: b.centre.dy - b.size.height / 2,
      width: b.size.width,
      height: b.size.height,
      child: Transform.rotate(
        angle: b.angle,
        child: Opacity(
          opacity: p.alpha.clamp(0.0, 1.0),
          child: FittedBox(
            fit: BoxFit.fill,
            child: CustomPaint(size: base, painter: TextLayerPainter(t, cw, ch)),
          ),
        ),
      ),
    );
  }

  Widget _selectionOutline(double cw, double ch) {
    final s = _selected(cw, ch);
    if (s == null || !_visible(s.$1, s.$2)) return const SizedBox.shrink();
    final b = _box(s.$1.poseAt(_local(s.$1, s.$2)), s.$3, cw, ch);
    return Positioned(
      left: b.centre.dx - b.size.width / 2,
      top: b.centre.dy - b.size.height / 2,
      width: b.size.width,
      height: b.size.height,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: b.angle,
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: AppColors.accent, width: 1.5)),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      var cw = box.maxWidth, ch = cw / pr.aspect;
      if (ch > box.maxHeight) {
        ch = box.maxHeight;
        cw = ch * pr.aspect;
      }
      return Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _tap(d.localPosition, cw, ch),
          onScaleStart: (_) => _scaleStart(cw, ch),
          onScaleUpdate: (d) => _scaleUpdate(d, cw, ch),
          onScaleEnd: (_) {
            if (_changed) widget.onTransformEnd();
            _startPose = null;
          },
          child: SizedBox(
            width: cw,
            height: ch,
            child: ClipRect(
              child: AnimatedBuilder(
                animation: engine,
                builder: (context, _) => Stack(children: [
                  Positioned.fill(child: ColoredBox(color: Color(pr.background))),
                  ..._mainLayers(cw, ch),
                  for (final c in pr.overlays)
                    if (_visible(c, c.start)) _clipLayer(c, engine.position - c.start, cw, ch),
                  for (final t in pr.texts)
                    if (_visible(t, t.start)) _textLayer(t, cw, ch),
                  _selectionOutline(cw, ch),
                ]),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _RectClipper extends CustomClipper<Rect> {
  final Rect rect;
  const _RectClipper(this.rect);
  @override
  Rect getClip(Size size) => rect;
  @override
  bool shouldReclip(_RectClipper old) => old.rect != rect;
}
