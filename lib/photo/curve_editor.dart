import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../core/widgets.dart';
import 'develop_renderer.dart';
import 'develop_settings.dart';

/// Point-curve editor: tap to add a point, drag to move, double-tap to remove.
class CurveEditor extends StatefulWidget {
  final DevelopSettings settings;
  final VoidCallback onChanged;
  final VoidCallback onCommit;
  const CurveEditor({super.key, required this.settings, required this.onChanged, required this.onCommit});

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor> {
  String _ch = 'rgb';
  int _active = -1;
  static const _colors = {
    'rgb': Colors.white,
    'r': Color(0xFFFF5D5D),
    'g': Color(0xFF4ADE80),
    'b': Color(0xFF60A5FA),
  };

  List<List<double>> get _pts => widget.settings.curves[_ch]!;

  Offset _norm(Offset local, Size size) => Offset(
        (local.dx / size.width).clamp(0.0, 1.0),
        (1 - local.dy / size.height).clamp(0.0, 1.0),
      );

  int _hit(Offset n, Size size) {
    var best = -1;
    var bestD = 28.0;
    for (var i = 0; i < _pts.length; i++) {
      final d = Offset((_pts[i][0] - n.dx) * size.width, (_pts[i][1] - n.dy) * size.height).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _start(Offset local, Size size) {
    final n = _norm(local, size);
    var i = _hit(n, size);
    if (i < 0 && _pts.length < 10) {
      _pts.add([n.dx, n.dy]);
      _pts.sort((a, b) => a[0].compareTo(b[0]));
      i = _pts.indexWhere((p) => p[0] == n.dx && p[1] == n.dy);
    }
    _active = i;
    setState(() {});
    widget.onChanged();
  }

  void _drag(Offset local, Size size) {
    if (_active < 0) return;
    final n = _norm(local, size);
    final p = _pts[_active];
    // End points keep their place in the order; inner points stay between neighbours.
    final lo = _active == 0 ? 0.0 : _pts[_active - 1][0] + 0.02;
    final hi = _active == _pts.length - 1 ? 1.0 : _pts[_active + 1][0] - 0.02;
    p[0] = n.dx.clamp(lo, hi < lo ? lo : hi);
    p[1] = n.dy;
    setState(() {});
    widget.onChanged();
  }

  void _remove(Offset local, Size size) {
    final i = _hit(_norm(local, size), size);
    if (i <= 0 || i >= _pts.length - 1) return;
    _pts.removeAt(i);
    _active = -1;
    setState(() {});
    widget.onChanged();
    widget.onCommit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(children: [
        for (final c in kCurveChannels)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Pill(
              label: c.toUpperCase(),
              selected: _ch == c,
              onTap: () => setState(() {
                _ch = c;
                _active = -1;
              }),
            ),
          ),
        const Spacer(),
        TextButton(
          onPressed: () {
            widget.settings.curves[_ch] = [[0, 0], [1, 1]];
            setState(() => _active = -1);
            widget.onChanged();
            widget.onCommit();
          },
          child: Text('Reset ${_ch.toUpperCase()}', style: const TextStyle(fontSize: 12)),
        ),
      ]),
      const SizedBox(height: 6),
      Expanded(
        child: Center(
          child: AspectRatio(
            aspectRatio: 1.25,
            child: LayoutBuilder(builder: (context, box) {
              final size = box.biggest;
              return GestureDetector(
                onPanDown: (d) => _start(d.localPosition, size),
                onPanUpdate: (d) => _drag(d.localPosition, size),
                onPanEnd: (_) => widget.onCommit(),
                onPanCancel: () => widget.onCommit(),
                onDoubleTapDown: (d) => _remove(d.localPosition, size),
                onDoubleTap: () {},
                child: CustomPaint(
                  size: size,
                  painter: _CurvePainter(_pts, _colors[_ch]!, _active),
                ),
              );
            }),
          ),
        ),
      ),
    ]);
  }
}

class _CurvePainter extends CustomPainter {
  final List<List<double>> pts;
  final Color color;
  final int active;
  _CurvePainter(this.pts, this.color, this.active);

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), Paint()..color = AppColors.bg);
    final grid = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(Offset(size.width * i / 4, 0), Offset(size.width * i / 4, size.height), grid);
      canvas.drawLine(Offset(0, size.height * i / 4), Offset(size.width, size.height * i / 4), grid);
    }
    canvas.drawLine(Offset(0, size.height), Offset(size.width, 0), grid);
    final samples = DevelopRenderer.sampleCurve(pts, 96);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final p = Offset(i / (samples.length - 1) * size.width, (1 - samples[i]) * size.height);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    for (var i = 0; i < pts.length; i++) {
      final p = Offset(pts[i][0] * size.width, (1 - pts[i][1]) * size.height);
      canvas.drawCircle(p, 6, Paint()..color = i == active ? AppColors.accent : color);
      canvas.drawCircle(
        p,
        6,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) => true;
}

class HistogramView extends StatelessWidget {
  final Histogram? data;
  const HistogramView({super.key, required this.data});

  @override
  Widget build(BuildContext context) => Container(
        width: 132,
        height: 70,
        decoration: BoxDecoration(
          color: const Color(0xB0000000),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.line),
        ),
        child: data == null ? null : CustomPaint(painter: _HistPainter(data!)),
      );
}

class _HistPainter extends CustomPainter {
  final Histogram h;
  _HistPainter(this.h);

  @override
  void paint(Canvas canvas, Size size) {
    void draw(List<double> v, Color c) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i < v.length; i++) {
        path.lineTo(i / (v.length - 1) * size.width, size.height - v[i] * (size.height - 4));
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = c
          ..blendMode = BlendMode.plus,
      );
    }

    canvas.saveLayer(Offset.zero & size, Paint());
    draw(h.r, const Color(0xA0E23B3B));
    draw(h.g, const Color(0xA03BB95A));
    draw(h.b, const Color(0xA03B7BE2));
    canvas.restore();
    final outline = Path();
    for (var i = 0; i < h.l.length; i++) {
      final p = Offset(i / (h.l.length - 1) * size.width, size.height - h.l[i] * (size.height - 4));
      i == 0 ? outline.moveTo(p.dx, p.dy) : outline.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      outline,
      Paint()
        ..color = Colors.white70
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_HistPainter old) => old.h != h;
}
