import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';

/// Description of one slider-driven parameter.
class ParamSpec {
  final String id;
  final String label;
  final double min;
  final double max;
  final double def;
  const ParamSpec(this.id, this.label, this.min, this.max, [this.def = 0]);
}

const kHslBands = ['Red', 'Orange', 'Yellow', 'Green', 'Aqua', 'Blue', 'Purple', 'Magenta'];
const kHslColors = [
  Color(0xFFE5383B), Color(0xFFFF8C1A), Color(0xFFFFD60A), Color(0xFF3FB950),
  Color(0xFF2EC4C4), Color(0xFF3B82F6), Color(0xFF8B5CF6), Color(0xFFE64CB8),
];

/// Every scalar develop parameter, keyed by id.
class P {
  static const light = [
    ParamSpec('exposure', 'Exposure', -5, 5),
    ParamSpec('contrast', 'Contrast', -100, 100),
    ParamSpec('highlights', 'Highlights', -100, 100),
    ParamSpec('shadows', 'Shadows', -100, 100),
    ParamSpec('whites', 'Whites', -100, 100),
    ParamSpec('blacks', 'Blacks', -100, 100),
  ];
  static const color = [
    ParamSpec('temp', 'Temp', -100, 100),
    ParamSpec('tint', 'Tint', -100, 100),
    ParamSpec('vibrance', 'Vibrance', -100, 100),
    ParamSpec('saturation', 'Saturation', -100, 100),
  ];
  static const effects = [
    ParamSpec('texture', 'Texture', -100, 100),
    ParamSpec('clarity', 'Clarity', -100, 100),
    ParamSpec('dehaze', 'Dehaze', -100, 100),
    ParamSpec('vignette', 'Vignette', -100, 100),
    ParamSpec('vigMid', 'Midpoint', 0, 100, 50),
    ParamSpec('vigFeather', 'Feather', 0, 100, 50),
    ParamSpec('grain', 'Grain', 0, 100),
    ParamSpec('grainSize', 'Grain size', 0, 100, 25),
  ];
  static const detail = [
    ParamSpec('sharpen', 'Sharpening', 0, 100),
    ParamSpec('noise', 'Noise reduction', 0, 100),
  ];
  static const grading = [
    ParamSpec('gsH', 'Shadows hue', 0, 360),
    ParamSpec('gsS', 'Shadows saturation', 0, 100),
    ParamSpec('gsL', 'Shadows luminance', -100, 100),
    ParamSpec('gmH', 'Midtones hue', 0, 360),
    ParamSpec('gmS', 'Midtones saturation', 0, 100),
    ParamSpec('gmL', 'Midtones luminance', -100, 100),
    ParamSpec('ghH', 'Highlights hue', 0, 360),
    ParamSpec('ghS', 'Highlights saturation', 0, 100),
    ParamSpec('ghL', 'Highlights luminance', -100, 100),
    ParamSpec('gBal', 'Balance', -100, 100),
    ParamSpec('gBlend', 'Blending', 0, 100, 50),
  ];
  static const maskAdjust = [
    ParamSpec('exposure', 'Exposure', -4, 4),
    ParamSpec('contrast', 'Contrast', -100, 100),
    ParamSpec('highlights', 'Highlights', -100, 100),
    ParamSpec('shadows', 'Shadows', -100, 100),
    ParamSpec('temp', 'Temp', -100, 100),
    ParamSpec('tint', 'Tint', -100, 100),
    ParamSpec('saturation', 'Saturation', -100, 100),
  ];

  static final List<ParamSpec> hsl = [
    for (var i = 0; i < 8; i++) ...[
      ParamSpec('hue$i', 'Hue', -100, 100),
      ParamSpec('sat$i', 'Saturation', -100, 100),
      ParamSpec('lum$i', 'Luminance', -100, 100),
    ],
  ];

  static final Map<String, ParamSpec> all = {
    for (final s in [...light, ...color, ...effects, ...detail, ...grading, ...hsl]) s.id: s,
  };
}

enum MaskType { linear, radial, brush, subject }

class BrushStroke {
  /// x,y pairs in image-normalised coordinates.
  final List<double> pts;
  /// Radius as a fraction of the image width.
  final double radius;
  final bool erase;
  BrushStroke(this.pts, this.radius, this.erase);

  Map<String, dynamic> toJson() => {
        'p': pts.map((e) => (e * 10000).round() / 10000).toList(),
        'r': radius,
        'e': erase,
      };
  static BrushStroke fromJson(Map<String, dynamic> j) => BrushStroke(
        (j['p'] as List).map((e) => (e as num).toDouble()).toList(),
        (j['r'] as num).toDouble(),
        j['e'] == true,
      );
}

class PhotoMask {
  MaskType type;
  /// linear: x0,y0 (full effect) → x1,y1 (no effect).
  /// radial: cx,cy, rx,ry (radii as fractions of the image width).
  List<double> geo;
  double feather;
  bool invert;
  Map<String, double> adjust;
  List<BrushStroke> strokes;
  /// PNG of an AI-generated mask (white = selected), base64.
  String? subjectPng;

  PhotoMask({
    required this.type,
    List<double>? geo,
    this.feather = 0.5,
    this.invert = false,
    Map<String, double>? adjust,
    List<BrushStroke>? strokes,
    this.subjectPng,
  })  : geo = geo ?? [0.5, 0.25, 0.5, 0.75],
        adjust = adjust ?? {},
        strokes = strokes ?? [];

  bool get usesTexture => type == MaskType.brush || type == MaskType.subject;

  double adj(String id) => adjust[id] ?? 0;

  String get title => switch (type) {
        MaskType.linear => 'Linear gradient',
        MaskType.radial => 'Radial gradient',
        MaskType.brush => 'Brush',
        MaskType.subject => 'Select person',
      };

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'geo': geo,
        'feather': feather,
        'invert': invert,
        'adjust': adjust,
        'strokes': strokes.map((s) => s.toJson()).toList(),
        if (subjectPng != null) 'subjectPng': subjectPng,
      };

  static PhotoMask fromJson(Map<String, dynamic> j) => PhotoMask(
        type: MaskType.values.firstWhere((t) => t.name == j['type'], orElse: () => MaskType.linear),
        geo: (j['geo'] as List).map((e) => (e as num).toDouble()).toList(),
        feather: (j['feather'] as num?)?.toDouble() ?? 0.5,
        invert: j['invert'] == true,
        adjust: (j['adjust'] as Map?)?.map((k, v) => MapEntry(k as String, (v as num).toDouble())) ?? {},
        strokes: ((j['strokes'] as List?) ?? [])
            .map((e) => BrushStroke.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        subjectPng: j['subjectPng'] as String?,
      );
}

/// A clone/heal spot. All values are image-normalised; [r] is a fraction of
/// the image width.
class HealSpot {
  double dx, dy, sx, sy, r, feather;
  HealSpot(this.dx, this.dy, this.sx, this.sy, this.r, [this.feather = 0.5]);
  Map<String, dynamic> toJson() => {'dx': dx, 'dy': dy, 'sx': sx, 'sy': sy, 'r': r, 'f': feather};
  static HealSpot fromJson(Map<String, dynamic> j) => HealSpot(
        (j['dx'] as num).toDouble(),
        (j['dy'] as num).toDouble(),
        (j['sx'] as num).toDouble(),
        (j['sy'] as num).toDouble(),
        (j['r'] as num).toDouble(),
        (j['f'] as num?)?.toDouble() ?? 0.5,
      );
}

const kCurveChannels = ['rgb', 'r', 'g', 'b'];
const kMaxMasks = 3;

/// The full, non-destructive edit recipe for one photo.
class DevelopSettings {
  final Map<String, double> v = {};
  bool bw = false;

  /// Tone curve control points per channel, each [x, y] in 0..1.
  Map<String, List<List<double>>> curves = {
    for (final c in kCurveChannels) c: [[0, 0], [1, 1]],
  };

  // Geometry.
  int turns = 0;
  bool flipH = false;
  bool flipV = false;
  double straighten = 0;
  /// Crop rectangle in the oriented frame, normalised 0..1.
  Rect crop = const Rect.fromLTRB(0, 0, 1, 1);
  /// Locked aspect ratio (width / height) or null for free.
  double? aspect;

  List<PhotoMask> masks = [];
  List<HealSpot> spots = [];
  String? presetName;

  double operator [](String id) => v[id] ?? P.all[id]!.def;
  void operator []=(String id, double value) => v[id] = value;

  bool get hasCurve => curves.values.any((pts) =>
      pts.length != 2 || pts[0][0] != 0 || pts[0][1] != 0 || pts[1][0] != 1 || pts[1][1] != 1);

  bool get hasHsl => P.hsl.any((s) => this[s.id] != 0);

  bool get hasCrop => crop != const Rect.fromLTRB(0, 0, 1, 1);

  bool get isDefault =>
      jsonEncode(toJson()) == jsonEncode(DevelopSettings().toJson());

  Map<String, dynamic> toJson() => {
        'v': {
          for (final e in v.entries)
            if (e.value != P.all[e.key]?.def) e.key: e.value,
        },
        'bw': bw,
        'curves': curves,
        'turns': turns,
        'flipH': flipH,
        'flipV': flipV,
        'straighten': straighten,
        'crop': [crop.left, crop.top, crop.right, crop.bottom],
        'aspect': aspect,
        'masks': masks.map((m) => m.toJson()).toList(),
        'spots': spots.map((s) => s.toJson()).toList(),
        'preset': presetName,
      };

  static DevelopSettings fromJson(Map<String, dynamic> j) {
    final s = DevelopSettings();
    (j['v'] as Map?)?.forEach((k, val) {
      if (P.all.containsKey(k)) s.v[k as String] = (val as num).toDouble();
    });
    s.bw = j['bw'] == true;
    (j['curves'] as Map?)?.forEach((k, pts) {
      if (kCurveChannels.contains(k)) {
        s.curves[k as String] = (pts as List)
            .map((p) => (p as List).map((e) => (e as num).toDouble()).toList())
            .toList();
      }
    });
    s.turns = (j['turns'] as num?)?.toInt() ?? 0;
    s.flipH = j['flipH'] == true;
    s.flipV = j['flipV'] == true;
    s.straighten = (j['straighten'] as num?)?.toDouble() ?? 0;
    final c = j['crop'] as List?;
    if (c != null && c.length == 4) {
      s.crop = Rect.fromLTRB(
        (c[0] as num).toDouble(), (c[1] as num).toDouble(),
        (c[2] as num).toDouble(), (c[3] as num).toDouble(),
      );
    }
    s.aspect = (j['aspect'] as num?)?.toDouble();
    s.masks = ((j['masks'] as List?) ?? [])
        .map((e) => PhotoMask.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    s.spots = ((j['spots'] as List?) ?? [])
        .map((e) => HealSpot.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    s.presetName = j['preset'] as String?;
    return s;
  }

  DevelopSettings copy() =>
      fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);

  /// Same geometry and retouching, no tonal or colour edits ("before" view).
  DevelopSettings geometryOnly() {
    final s = DevelopSettings()
      ..turns = turns
      ..flipH = flipH
      ..flipV = flipV
      ..straighten = straighten
      ..crop = crop
      ..aspect = aspect;
    return s;
  }

  /// Copies the look (tone, colour, effects, curves) from [other], leaving
  /// geometry, masks and healing untouched. Used by presets and paste.
  void applyLook(DevelopSettings other) {
    v
      ..clear()
      ..addAll(other.v);
    bw = other.bw;
    curves = other.copy().curves;
    presetName = other.presetName;
  }

  /// Removes the look entirely: tone, colour, effects, curves and any preset.
  void clearLook() {
    v.clear();
    bw = false;
    curves = {for (final c in kCurveChannels) c: [[0.0, 0.0], [1.0, 1.0]]};
    presetName = null;
  }

  /// Resets tone/colour to defaults then applies a preset's overrides.
  void applyPreset(String name, Map<String, double> values,
      {bool mono = false, Map<String, List<List<double>>>? presetCurves}) {
    v
      ..clear()
      ..addAll(values);
    bw = mono;
    curves = {
      for (final c in kCurveChannels)
        c: (presetCurves?[c] ?? [[0.0, 0.0], [1.0, 1.0]]).map((p) => [...p]).toList(),
    };
    presetName = name;
  }
}

/// Geometry helpers shared by the on-screen canvas and the exporter.
class Geo {
  static Size oriented(Size image, int turns) =>
      turns.isOdd ? Size(image.height, image.width) : image;

  /// Scale needed so the straightened image still covers the frame.
  static double coverScale(Size frame, double degrees) {
    final a = degrees.abs() * math.pi / 180;
    final ar = math.max(frame.width / frame.height, frame.height / frame.width);
    return math.cos(a) + ar * math.sin(a);
  }

  /// Maps image pixels into the oriented, straightened frame (frame pixels).
  static Matrix4 imageToFrame(Size image, DevelopSettings s) {
    final f = oriented(image, s.turns);
    final k = coverScale(f, s.straighten);
    return Matrix4.identity()
      ..translateByDouble(f.width / 2, f.height / 2, 0, 1)
      ..rotateZ(s.straighten * math.pi / 180)
      ..scaleByDouble(k, k, 1, 1)
      ..rotateZ(s.turns * math.pi / 2)
      ..scaleByDouble(s.flipH ? -1 : 1, s.flipV ? -1 : 1, 1, 1)
      ..translateByDouble(-image.width / 2, -image.height / 2, 0, 1);
  }

  static Size outputSize(Size image, DevelopSettings s) {
    final f = oriented(image, s.turns);
    return Size(f.width * s.crop.width, f.height * s.crop.height);
  }

  /// Maps image pixels into the cropped output (output pixels).
  static Matrix4 imageToOutput(Size image, DevelopSettings s) {
    final f = oriented(image, s.turns);
    return Matrix4.identity()
      ..translateByDouble(-s.crop.left * f.width, -s.crop.top * f.height, 0, 1)
      ..multiply(imageToFrame(image, s));
  }

  /// Rotates the crop along with the image by a clockwise quarter turn.
  static Rect rotateCropCw(Rect c) =>
      Rect.fromLTRB(1 - c.bottom, c.left, 1 - c.top, c.right);

  static Rect flipCropH(Rect c) => Rect.fromLTRB(1 - c.right, c.top, 1 - c.left, c.bottom);
  static Rect flipCropV(Rect c) => Rect.fromLTRB(c.left, 1 - c.bottom, c.right, 1 - c.top);
}
