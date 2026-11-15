import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'develop_settings.dart';

/// Everything the shader needs besides the settings themselves.
class DevelopAssets {
  /// Source image with healing spots already applied.
  final ui.Image base;
  final ui.Image lut;
  /// One greyscale texture per mask slot (painted strokes / AI selection).
  final List<ui.Image> mask;
  const DevelopAssets(this.base, this.lut, this.mask);
}

class Histogram {
  static const bins = 96;
  final Float32List r = Float32List(bins);
  final Float32List g = Float32List(bins);
  final Float32List b = Float32List(bins);
  final Float32List l = Float32List(bins);
}

/// Drives `shaders/develop.frag`.
class DevelopRenderer {
  static late ui.FragmentProgram _program;
  static late ui.Image identityLut;
  static late ui.Image _black;
  static List<ui.Image> get blackMask => List.filled(kMaxMasks, _black);
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;
    _program = await ui.FragmentProgram.fromAsset('shaders/develop.frag');
    identityLut = await buildCurveLut(DevelopSettings().curves);
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..color = Colors.black);
    _black = await rec.endRecording().toImage(2, 2);
    _ready = true;
  }

  static ui.FragmentShader newShader() => _program.fragmentShader();

  // ------------------------------------------------------------ tone curve

  /// Monotone cubic interpolation through [pts], sampled at [n] positions.
  static Float32List sampleCurve(List<List<double>> pts, [int n = 256]) {
    final p = [...pts]..sort((a, b) => a[0].compareTo(b[0]));
    final out = Float32List(n);
    final k = p.length;
    if (k == 0) {
      for (var i = 0; i < n; i++) {
        out[i] = i / (n - 1);
      }
      return out;
    }
    if (k == 1) {
      out.fillRange(0, n, p[0][1]);
      return out;
    }
    final d = List<double>.filled(k - 1, 0);
    final m = List<double>.filled(k, 0);
    for (var i = 0; i < k - 1; i++) {
      final dx = math.max(p[i + 1][0] - p[i][0], 1e-4);
      d[i] = (p[i + 1][1] - p[i][1]) / dx;
    }
    m[0] = d[0];
    m[k - 1] = d[k - 2];
    for (var i = 1; i < k - 1; i++) {
      m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
    }
    for (var i = 0; i < k - 1; i++) {
      if (d[i] == 0) {
        m[i] = 0;
        m[i + 1] = 0;
      } else {
        final a = m[i] / d[i], b = m[i + 1] / d[i];
        final s = a * a + b * b;
        if (s > 9) {
          final t = 3 / math.sqrt(s);
          m[i] = t * a * d[i];
          m[i + 1] = t * b * d[i];
        }
      }
    }
    var seg = 0;
    for (var j = 0; j < n; j++) {
      final x = j / (n - 1);
      double y;
      if (x <= p[0][0]) {
        y = p[0][1];
      } else if (x >= p[k - 1][0]) {
        y = p[k - 1][1];
      } else {
        while (seg < k - 2 && x > p[seg + 1][0]) {
          seg++;
        }
        final h = math.max(p[seg + 1][0] - p[seg][0], 1e-4);
        final t = (x - p[seg][0]) / h;
        final t2 = t * t, t3 = t2 * t;
        y = (2 * t3 - 3 * t2 + 1) * p[seg][1] +
            (t3 - 2 * t2 + t) * h * m[seg] +
            (-2 * t3 + 3 * t2) * p[seg + 1][1] +
            (t3 - t2) * h * m[seg + 1];
      }
      out[j] = y.clamp(0.0, 1.0);
    }
    return out;
  }

  static Future<ui.Image> buildCurveLut(Map<String, List<List<double>>> curves) {
    final master = sampleCurve(curves['rgb']!);
    final chans = [sampleCurve(curves['r']!), sampleCurve(curves['g']!), sampleCurve(curves['b']!)];
    final bytes = Uint8List(256 * 4);
    for (var i = 0; i < 256; i++) {
      for (var c = 0; c < 3; c++) {
        final v = chans[c][i];
        final idx = (v * 255).round().clamp(0, 255);
        bytes[i * 4 + c] = (master[idx] * 255).round().clamp(0, 255);
      }
      bytes[i * 4 + 3] = 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(bytes, 256, 1, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  // ------------------------------------------------------------ masks

  static Future<List<ui.Image?>> decodeSubjects(List<PhotoMask> masks) async {
    final out = <ui.Image?>[];
    for (final m in masks) {
      if (m.type == MaskType.subject && m.subjectPng != null) {
        final codec = await ui.instantiateImageCodec(base64Decode(m.subjectPng!));
        out.add((await codec.getNextFrame()).image);
      } else {
        out.add(null);
      }
    }
    return out;
  }

  /// Rasterises painted and AI masks: one greyscale image per mask slot,
  /// white = selected. Plain source-over drawing only, which every backend
  /// supports.
  static List<ui.Image> buildMaskTexture(Size image, List<PhotoMask> masks, List<ui.Image?> subjects) {
    final f = 768 / math.max(image.width, image.height);
    final tw = math.max(2, (image.width * f).round());
    final th = math.max(2, (image.height * f).round());
    final full = Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble());
    final out = <ui.Image>[];
    for (var i = 0; i < kMaxMasks; i++) {
      final m = i < masks.length ? masks[i] : null;
      if (m == null || !m.usesTexture) {
        out.add(_black);
        continue;
      }
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawRect(full, Paint()..color = Colors.black);
      final subject = i < subjects.length ? subjects[i] : null;
      if (subject != null) {
        c.drawImageRect(
          subject,
          Rect.fromLTWH(0, 0, subject.width.toDouble(), subject.height.toDouble()),
          full,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
      final strokes = m.strokes.where((s) => s.pts.length >= 2).toList();
      if (strokes.isNotEmpty) {
        // Strokes are drawn crisp, in order, then feathered together by one
        // layer blur. (Per-path blur mask filters drop all but the first path
        // on Impeller/GLES, and stamped blurred circles harden the edges.)
        final avgR = strokes.fold<double>(0, (a, s) => a + s.radius) / strokes.length * tw;
        final sigma = math.max(0.5, avgR * 0.35);
        c.saveLayer(full, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma));
        for (final s in strokes) {
          final r = s.radius * tw;
          final color = s.erase ? Colors.black : Colors.white;
          if (s.pts.length < 4) {
            c.drawCircle(Offset(s.pts[0] * tw, s.pts[1] * th), r, Paint()..color = color);
            continue;
          }
          final path = Path()..moveTo(s.pts[0] * tw, s.pts[1] * th);
          for (var k = 2; k + 1 < s.pts.length; k += 2) {
            path.lineTo(s.pts[k] * tw, s.pts[k + 1] * th);
          }
          c.drawPath(
            path,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = r * 2
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
        }
        c.restore();
      }
      final pic = rec.endRecording();
      out.add(pic.toImageSync(tw, th));
      pic.dispose();
    }
    return out;
  }

  // ------------------------------------------------------------ healing

  /// Clones each spot's source patch over its destination with a feathered edge.
  static Future<ui.Image> applyHealing(ui.Image src, List<HealSpot> spots) async {
    if (spots.isEmpty) return src;
    final w = src.width.toDouble(), h = src.height.toDouble();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(src, Offset.zero, Paint());
    for (final s in spots) {
      final r = s.r * w;
      final dst = Rect.fromCircle(center: Offset(s.dx * w, s.dy * h), radius: r);
      final from = Rect.fromCircle(center: Offset(s.sx * w, s.sy * h), radius: r);
      c.saveLayer(dst, Paint());
      c.drawImageRect(src, from, dst, Paint()..filterQuality = FilterQuality.medium);
      c.drawRect(
        dst,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = RadialGradient(
            colors: const [Colors.white, Colors.white, Color(0x00FFFFFF)],
            stops: [0, (1 - s.feather * 0.9).clamp(0.05, 0.98), 1],
          ).createShader(dst),
      );
      c.restore();
    }
    final pic = rec.endRecording();
    final img = await pic.toImage(src.width, src.height);
    pic.dispose();
    return img;
  }

  static Future<DevelopAssets> prepare(ui.Image image, DevelopSettings s) async {
    final base = await applyHealing(image, s.spots);
    final lut = s.hasCurve ? await buildCurveLut(s.curves) : identityLut;
    var mask = blackMask;
    if (s.masks.any((m) => m.usesTexture)) {
      mask = buildMaskTexture(
        Size(image.width.toDouble(), image.height.toDouble()),
        s.masks,
        await decodeSubjects(s.masks),
      );
    }
    return DevelopAssets(base, lut, mask);
  }

  // ------------------------------------------------------------ drawing

  /// Draws the developed image on `Rect(0, 0, image.width, image.height)` of
  /// [canvas]. The caller applies geometry (see [Geo]).
  static void paint(
    Canvas canvas,
    ui.FragmentShader sh,
    DevelopAssets a,
    DevelopSettings s, {
    int showMask = 0,
  }) {
    final w = a.base.width.toDouble(), h = a.base.height.toDouble();
    final size = Size(w, h);
    var i = 0;
    void f(double x) => sh.setFloat(i++, x);

    f(w);
    f(h);
    // Vignette follows the crop: find the crop centre/extent in image uv.
    final frame = Geo.oriented(size, s.turns);
    final inv = Matrix4.inverted(Geo.imageToFrame(size, s));
    final centre = MatrixUtils.transformPoint(
      inv,
      Offset(s.crop.center.dx * frame.width, s.crop.center.dy * frame.height),
    );
    final k = Geo.coverScale(frame, s.straighten);
    var hw = s.crop.width * frame.width / 2 / k, hh = s.crop.height * frame.height / 2 / k;
    if (s.turns.isOdd) {
      final t = hw;
      hw = hh;
      hh = t;
    }
    f(centre.dx / w);
    f(centre.dy / h);
    f(math.max(hw / w, 1e-3));
    f(math.max(hh / h, 1e-3));

    f(s['exposure']);
    for (final id in const ['contrast', 'highlights', 'shadows', 'whites', 'blacks', 'temp', 'tint',
      'vibrance', 'saturation', 'texture', 'clarity', 'dehaze', 'sharpen', 'noise', 'vignette',
      'vigMid', 'vigFeather', 'grain', 'grainSize']) {
      f(s[id] / 100);
    }
    f(s.hasCurve ? 1 : 0);
    f(s.hasHsl ? 1 : 0);
    f(s.bw ? 1 : 0);
    for (var b = 0; b < 8; b++) {
      f(s['hue$b'] / 100);
      f(s['sat$b'] / 100);
      f(s['lum$b'] / 100);
    }
    for (final z in const ['gs', 'gm', 'gh']) {
      f(s['${z}H'] / 360);
      f(s['${z}S'] / 100);
      f(s['${z}L'] / 100);
    }
    f(s['gBal'] / 100);
    f(s['gBlend'] / 100);
    for (var m = 0; m < kMaxMasks; m++) {
      if (m < s.masks.length) {
        final mk = s.masks[m];
        for (var g = 0; g < 4; g++) {
          f(g < mk.geo.length ? mk.geo[g] : 0);
        }
        f(switch (mk.type) { MaskType.linear => 1, MaskType.radial => 2, _ => 3 });
        f(mk.feather);
        f(mk.invert ? 1 : 0);
        f(m.toDouble());
        f(mk.adj('exposure'));
        f(mk.adj('contrast') / 100);
        f(mk.adj('highlights') / 100);
        f(mk.adj('shadows') / 100);
        f(mk.adj('temp') / 100);
        f(mk.adj('tint') / 100);
        f(mk.adj('saturation') / 100);
        f(0);
      } else {
        for (var z = 0; z < 16; z++) {
          f(0);
        }
      }
    }
    f(showMask.toDouble());

    sh.setImageSampler(0, a.base, filterQuality: FilterQuality.low);
    sh.setImageSampler(1, a.lut, filterQuality: FilterQuality.low);
    for (var m = 0; m < kMaxMasks; m++) {
      sh.setImageSampler(2 + m, a.mask[m], filterQuality: FilterQuality.low);
    }
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..shader = sh);
  }

  /// Renders the cropped, developed result to an image. [maxEdge] caps the
  /// long edge of the output.
  static Future<ui.Image> render(DevelopAssets a, DevelopSettings s, {int? maxEdge}) async {
    final size = Size(a.base.width.toDouble(), a.base.height.toDouble());
    final out = Geo.outputSize(size, s);
    var k = 1.0;
    if (maxEdge != null) k = math.min(1.0, maxEdge / math.max(out.width, out.height));
    final ow = math.max(1, (out.width * k).round()), oh = math.max(1, (out.height * k).round());
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.scale(ow / out.width, oh / out.height);
    c.clipRect(Rect.fromLTWH(0, 0, out.width, out.height));
    c.transform(Geo.imageToOutput(size, s).storage);
    final sh = newShader();
    paint(c, sh, a, s);
    final pic = rec.endRecording();
    final img = await pic.toImage(ow, oh);
    pic.dispose();
    sh.dispose();
    return img;
  }

  /// One-call render used by export, batch and thumbnails.
  static Future<ui.Image> renderFinal(ui.Image image, DevelopSettings s, {int? maxEdge}) async {
    final assets = await prepare(image, s);
    return render(assets, s, maxEdge: maxEdge);
  }

  static Future<Histogram> histogram(DevelopAssets a, DevelopSettings s) async {
    final img = await render(a, s, maxEdge: 160);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    final hist = Histogram();
    if (data == null) return hist;
    final bytes = data.buffer.asUint8List();
    const n = Histogram.bins;
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
      hist.r[r * n >> 8]++;
      hist.g[g * n >> 8]++;
      hist.b[b * n >> 8]++;
      hist.l[((r * 54 + g * 183 + b * 19) >> 8) * n >> 8]++;
    }
    var peak = 1.0;
    for (final ch in [hist.r, hist.g, hist.b, hist.l]) {
      // Ignore the clipped end bins when scaling so they do not flatten the rest.
      for (var i = 1; i < n - 1; i++) {
        peak = math.max(peak, ch[i]);
      }
    }
    for (final ch in [hist.r, hist.g, hist.b, hist.l]) {
      for (var i = 0; i < n; i++) {
        ch[i] = math.min(1.0, ch[i] / peak);
      }
    }
    return hist;
  }
}
