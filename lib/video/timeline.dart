import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui show Clip;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import 'engine.dart';
import 'models.dart';
import 'preview.dart';

String formatTime(double s) {
  final m = s ~/ 60;
  final sec = s - m * 60;
  return '${m.toString().padLeft(2, '0')}:${sec.toStringAsFixed(1).padLeft(4, '0')}';
}

/// Multi-track timeline with a fixed centre playhead. Scrolling scrubs.
class TimelineView extends StatefulWidget {
  final VideoEngine engine;
  final Sel? selection;
  final double pps; // pixels per second
  final ValueChanged<Sel?> onSelect;
  final VoidCallback onLive;
  final VoidCallback onCommit;
  final ValueChanged<int> onTransitionTap;

  const TimelineView({
    super.key,
    required this.engine,
    required this.selection,
    required this.pps,
    required this.onSelect,
    required this.onLive,
    required this.onCommit,
    required this.onTransitionTap,
  });

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _Lane<T> {
  final T item;
  final int lane;
  const _Lane(this.item, this.lane);
}

class _TimelineViewState extends State<TimelineView> {
  final _scroll = ScrollController();
  bool _userScrolling = false;
  bool _jumping = false;

  static const _ruler = 20.0, _small = 30.0, _mainH = 56.0, _gap = 4.0;

  VideoEngine get engine => widget.engine;
  Project get pr => engine.project;
  double get pps => widget.pps;

  @override
  void initState() {
    super.initState();
    engine.addListener(_follow);
    _scroll.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(TimelineView old) {
    super.didUpdateWidget(old);
    if (old.engine != widget.engine) {
      old.engine.removeListener(_follow);
      engine.addListener(_follow);
    }
    if (old.pps != widget.pps) WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
  }

  @override
  void dispose() {
    engine.removeListener(_follow);
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    if (!mounted) return;
    if (_userScrolling || !_scroll.hasClients) {
      setState(() {});
      return;
    }
    final target = engine.position * pps;
    if ((_scroll.offset - target).abs() > 0.5) {
      _jumping = true;
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
      _jumping = false;
    }
    setState(() {});
  }

  void _scrolled() {
    if (_jumping || !_userScrolling) return;
    engine.seek(_scroll.offset / pps);
  }

  List<_Lane<T>> _lanes<T>(List<T> items, double Function(T) start, double Function(T) dur) {
    final sorted = [...items]..sort((a, b) => start(a).compareTo(start(b)));
    final ends = <double>[];
    final out = <_Lane<T>>[];
    for (final it in sorted) {
      var lane = ends.indexWhere((e) => e <= start(it) + 1e-6);
      if (lane < 0) {
        ends.add(0);
        lane = ends.length - 1;
      }
      ends[lane] = start(it) + dur(it);
      out.add(_Lane(it, lane));
    }
    return out;
  }

  int _laneCount(List<_Lane> l) => l.isEmpty ? 0 : l.map((e) => e.lane).reduce(math.max) + 1;

  // ------------------------------------------------------------ trimming

  void _trimClip(Clip c, bool main, int edge, double dx) {
    final dt = dx / pps; // timeline seconds
    if (c.isImage) {
      if (edge < 0) {
        final d = dt.clamp(main ? -600.0 : -c.start, c.outPoint - 0.2);
        c.outPoint = (c.outPoint - d).clamp(0.2, 600.0);
        if (!main) c.start += d;
      } else if (edge > 0) {
        c.outPoint = (c.outPoint + dt).clamp(0.2, 600.0);
      }
    } else {
      final ds = dt * c.speed; // source seconds
      if (edge < 0) {
        final before = c.inPoint;
        c.inPoint = (c.inPoint + ds).clamp(0.0, c.outPoint - 0.1 * c.speed);
        if (!main) c.start = math.max(0, c.start + (c.inPoint - before) / c.speed);
      } else if (edge > 0) {
        c.outPoint = (c.outPoint + ds).clamp(c.inPoint + 0.1 * c.speed, c.srcDuration);
      }
    }
    if (edge == 0 && !main) c.start = math.max(0, c.start + dt);
    c.srcDuration = c.isImage ? c.outPoint : c.srcDuration;
  }

  void _trimText(TextItem t, int edge, double dx) {
    final dt = dx / pps;
    if (edge < 0) {
      final d = dt.clamp(-t.start, t.duration - 0.2);
      t.start += d;
      t.duration = t.duration - d;
    } else if (edge > 0) {
      t.duration = math.max(0.2, t.duration + dt);
    } else {
      t.start = math.max(0, t.start + dt);
    }
  }

  void _trimAudio(AudioItem a, int edge, double dx) {
    final dt = dx / pps;
    if (edge < 0) {
      final before = a.inPoint;
      a.inPoint = (a.inPoint + dt).clamp(0.0, a.outPoint - 0.2);
      a.start = math.max(0, a.start + (a.inPoint - before));
    } else if (edge > 0) {
      a.outPoint = (a.outPoint + dt).clamp(a.inPoint + 0.2, a.srcDuration);
    } else {
      a.start = math.max(0, a.start + dt);
    }
  }

  // ------------------------------------------------------------ tiles

  Widget _tile({
    required Sel sel,
    required double left,
    required double top,
    required double width,
    required double height,
    required Color color,
    required Widget child,
    required void Function(int edge, double dx) onDrag,
    bool movable = true,
    DecorationImage? image,
  }) {
    final selected = widget.selection == sel;
    Widget handle(int edge) => Positioned(
          left: edge < 0 ? 0 : null,
          right: edge > 0 ? 0 : null,
          top: 0,
          bottom: 0,
          width: 18,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) {
              onDrag(edge, d.delta.dx);
              widget.onLive();
            },
            onHorizontalDragEnd: (_) => widget.onCommit(),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.horizontal(
                  left: Radius.circular(edge < 0 ? 5 : 0),
                  right: Radius.circular(edge > 0 ? 5 : 0),
                ),
              ),
              child: const Center(child: SizedBox(width: 2, height: 14, child: ColoredBox(color: Colors.black54))),
            ),
          ),
        );
    return Positioned(
      left: left,
      top: top,
      width: math.max(width, 6),
      height: height,
      child: GestureDetector(
        onTap: () => widget.onSelect(selected ? null : sel),
        onHorizontalDragUpdate: selected && movable
            ? (d) {
                onDrag(0, d.delta.dx);
                widget.onLive();
              }
            : null,
        onHorizontalDragEnd: selected && movable ? (_) => widget.onCommit() : null,
        child: Container(
          clipBehavior: ui.Clip.antiAlias,
          decoration: BoxDecoration(
            color: color,
            image: image,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: selected ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Stack(children: [
            Positioned.fill(child: child),
            if (selected) ...[handle(-1), handle(1)],
          ]),
        ),
      ),
    );
  }

  Widget _label(String text, {IconData? icon, Color color = Colors.white}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ]),
      );

  DecorationImage? _thumb(Clip c) {
    ImageProvider? provider;
    if (!kIsWeb) {
      final path = c.isImage ? c.path : c.thumb;
      if (path != null && !path.startsWith('sample://')) provider = FileImage(File(path));
    } else if (c.isImage && !c.path.startsWith('sample://')) {
      provider = NetworkImage(c.path);
    }
    if (provider == null) return null;
    return DecorationImage(
      image: ResizeImage(provider, height: 112),
      repeat: ImageRepeat.repeatX,
      fit: BoxFit.fitHeight,
      alignment: Alignment.centerLeft,
      colorFilter: const ColorFilter.mode(Color(0x55000000), BlendMode.darken),
    );
  }

  String _clipCaption(Clip c) {
    final parts = <String>[c.name, '${c.duration.toStringAsFixed(1)}s'];
    if (c.speed != 1) parts.add('${c.speed.toStringAsFixed(c.speed < 1 ? 2 : 1)}x');
    return parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final half = box.maxWidth / 2;
      final total = math.max(pr.duration, 0.0);
      final texts = _lanes<TextItem>(pr.texts, (t) => t.start, (t) => t.duration);
      final overlays = _lanes<Clip>(pr.overlays, (c) => c.start, (c) => c.duration);
      final audios = _lanes<AudioItem>(pr.audios, (a) => a.start, (a) => a.duration);
      final textTop = _ruler + _gap;
      final overlayTop = textTop + _laneCount(texts) * (_small + _gap);
      final mainTop = overlayTop + _laneCount(overlays) * (_small + _gap);
      final audioTop = mainTop + _mainH + _gap;
      final height = math.max(audioTop + math.max(1, _laneCount(audios)) * (_small + _gap) + 6, box.maxHeight);
      final contentWidth = total * pps + box.maxWidth;

      final tiles = <Widget>[];
      // Main track.
      for (var i = 0; i < pr.main.length; i++) {
        final c = pr.main[i];
        tiles.add(_tile(
          sel: Sel('main', c.id),
          left: half + pr.mainStart(i) * pps,
          top: mainTop,
          width: c.duration * pps - 1.5,
          height: _mainH,
          color: const Color(0xFF2B4A6B),
          image: _thumb(c),
          movable: false,
          onDrag: (edge, dx) => _trimClip(c, true, edge, dx),
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4, left: 14),
              child: _label(_clipCaption(c), icon: c.isImage ? Icons.image_outlined : (c.audible ? null : Icons.volume_off)),
            ),
          ),
        ));
      }
      for (var i = 0; i < pr.main.length - 1; i++) {
        final on = pr.main[i].transition != 'none';
        tiles.add(Positioned(
          left: half + (pr.mainStart(i + 1) + pr.transitionAfter(i) / 2) * pps - 12,
          top: mainTop + _mainH / 2 - 12,
          width: 24,
          height: 24,
          child: GestureDetector(
            onTap: () => widget.onTransitionTap(i),
            child: Container(
              decoration: BoxDecoration(
                color: on ? AppColors.accent : Colors.white,
                borderRadius: BorderRadius.circular(5),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
              ),
              child: Icon(on ? Icons.auto_awesome : Icons.add, size: 15, color: Colors.black),
            ),
          ),
        ));
      }
      for (final l in overlays) {
        final c = l.item;
        tiles.add(_tile(
          sel: Sel('overlay', c.id),
          left: half + c.start * pps,
          top: overlayTop + l.lane * (_small + _gap),
          width: c.duration * pps,
          height: _small,
          color: const Color(0xFF6A4C93),
          image: _thumb(c),
          onDrag: (edge, dx) => _trimClip(c, false, edge, dx),
          child: _label(c.name, icon: Icons.picture_in_picture_alt_outlined),
        ));
      }
      for (final l in texts) {
        final t = l.item;
        tiles.add(_tile(
          sel: Sel('text', t.id),
          left: half + t.start * pps,
          top: textTop + l.lane * (_small + _gap),
          width: t.duration * pps,
          height: _small,
          color: t.caption ? const Color(0xFF8A5A19) : const Color(0xFFB5542D),
          onDrag: (edge, dx) => _trimText(t, edge, dx),
          child: _label(t.text.replaceAll('\n', ' '), icon: t.caption ? Icons.closed_caption_outlined : Icons.title),
        ));
      }
      for (final l in audios) {
        final a = l.item;
        tiles.add(_tile(
          sel: Sel('audio', a.id),
          left: half + a.start * pps,
          top: audioTop + l.lane * (_small + _gap),
          width: a.duration * pps,
          height: _small,
          color: const Color(0xFF1F7A6C),
          onDrag: (edge, dx) => _trimAudio(a, edge, dx),
          child: _label(a.name, icon: Icons.music_note),
        ));
      }
      // Keyframe markers for the selected layer.
      final sel = widget.selection;
      if (sel != null) {
        Layer? layer;
        double start = 0, top = mainTop, h = _mainH;
        if (sel.kind == 'main') {
          final i = pr.main.indexWhere((c) => c.id == sel.id);
          if (i >= 0) {
            layer = pr.main[i];
            start = pr.mainStart(i);
          }
        } else if (sel.kind == 'overlay') {
          final l = overlays.where((e) => e.item.id == sel.id).firstOrNull;
          if (l != null) {
            layer = l.item;
            start = l.item.start;
            top = overlayTop + l.lane * (_small + _gap);
            h = _small;
          }
        } else if (sel.kind == 'text') {
          final l = texts.where((e) => e.item.id == sel.id).firstOrNull;
          if (l != null) {
            layer = l.item;
            start = l.item.start;
            top = textTop + l.lane * (_small + _gap);
            h = _small;
          }
        }
        if (layer != null) {
          for (final k in layer.keys) {
            tiles.add(Positioned(
              left: half + (start + k.t) * pps - 5,
              top: top + h - 12,
              child: IgnorePointer(
                child: Transform.rotate(
                  angle: math.pi / 4,
                  child: Container(width: 9, height: 9, decoration: BoxDecoration(color: AppColors.accent, border: Border.all(color: Colors.black, width: 1))),
                ),
              ),
            ));
          }
        }
      }

      return Stack(children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.axis != Axis.horizontal) return false;
            if (n is ScrollStartNotification && n.dragDetails != null) {
              _userScrolling = true;
              engine.pause();
            } else if (n is ScrollEndNotification) {
              _userScrolling = false;
            }
            return false;
          },
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => widget.onSelect(null),
                child: SizedBox(
                  width: contentWidth,
                  height: height,
                  child: Stack(children: [
                    Positioned(
                      left: half,
                      top: 0,
                      width: total * pps + 60,
                      height: _ruler,
                      child: CustomPaint(painter: _RulerPainter(pps, total)),
                    ),
                    if (pr.main.isEmpty)
                      Positioned(
                        left: half + 8,
                        top: mainTop,
                        height: _mainH,
                        child: const Center(
                          child: Text('Add clips to start', style: TextStyle(color: AppColors.textDim, fontSize: 12)),
                        ),
                      ),
                    ...tiles,
                  ]),
                ),
              ),
            ),
          ),
        ),
        // Fixed playhead.
        Positioned(
          left: half - 1,
          top: 0,
          bottom: 0,
          width: 2,
          child: const IgnorePointer(child: ColoredBox(color: Colors.white)),
        ),
      ]);
    });
  }
}

class _RulerPainter extends CustomPainter {
  final double pps, total;
  _RulerPainter(this.pps, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    // Choose a label step that keeps labels roughly 70 px apart.
    const steps = [0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0];
    final step = steps.firstWhere((s) => s * pps >= 64, orElse: () => 120);
    final tick = Paint()
      ..color = AppColors.textDim
      ..strokeWidth = 1;
    for (var t = 0.0; t <= total + step; t += step / 2) {
      final x = t * pps;
      final major = ((t / step) - (t / step).round()).abs() < 1e-6;
      canvas.drawLine(Offset(x, major ? 12 : 15), Offset(x, 19), tick);
      if (major) {
        final tp = TextPainter(
          text: TextSpan(
            text: t < 60 ? '${t.toStringAsFixed(step < 1 ? 1 : 0)}s' : formatTime(t),
            style: const TextStyle(fontSize: 9, color: AppColors.textDim),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + 3, 0));
      }
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.pps != pps || old.total != total;
}
