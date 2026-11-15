import 'dart:convert';
import 'dart:math' as math;

import '../core/store.dart';
import 'effects.dart';

enum ClipKind { video, image }

double _d(dynamic v, [double def = 0]) => (v as num?)?.toDouble() ?? def;

/// A keyframe on a layer. [t] is seconds from the layer's start.
class Keyframe {
  double t, x, y, scale, rotation;
  Keyframe(this.t, this.x, this.y, this.scale, this.rotation);
  Map<String, dynamic> toJson() => {'t': t, 'x': x, 'y': y, 's': scale, 'r': rotation};
  static Keyframe fromJson(Map j) => Keyframe(_d(j['t']), _d(j['x']), _d(j['y']), _d(j['s'], 1), _d(j['r']));
}

/// Where a layer sits at one instant.
class Pose {
  double x, y, scale, rotation, alpha;
  Pose(this.x, this.y, this.scale, this.rotation, this.alpha);
}

const kAnimations = {
  'none': 'None',
  'fade': 'Fade',
  'slideUp': 'Slide up',
  'slideDown': 'Slide down',
  'slideLeft': 'Slide left',
  'slideRight': 'Slide right',
  'zoom': 'Zoom',
};

/// Anything placed on the canvas: transform, keyframes and in/out animation.
///
/// [x] and [y] are offsets from the canvas centre as fractions of the canvas
/// width and height. [rotation] is in degrees.
abstract class Layer {
  String id = Store.newId();
  double x = 0, y = 0, scale = 1, rotation = 0, opacity = 1;
  List<Keyframe> keys = [];
  String animIn = 'none', animOut = 'none';
  double animDur = 0.5;

  double get duration;

  double get animLen => math.min(animDur, duration / 2);

  /// Pose from static values and keyframes, ignoring in/out animation.
  Pose basePose(double lt) {
    final p = Pose(x, y, scale, rotation, opacity);
    if (keys.isEmpty) return p;
    final ks = [...keys]..sort((a, b) => a.t.compareTo(b.t));
    if (lt <= ks.first.t) {
      final k = ks.first;
      return Pose(k.x, k.y, k.scale, k.rotation, opacity);
    }
    if (lt >= ks.last.t) {
      final k = ks.last;
      return Pose(k.x, k.y, k.scale, k.rotation, opacity);
    }
    for (var i = 0; i < ks.length - 1; i++) {
      final a = ks[i], b = ks[i + 1];
      if (lt >= a.t && lt <= b.t) {
        final f = (lt - a.t) / math.max(b.t - a.t, 1e-6);
        return Pose(
          a.x + (b.x - a.x) * f,
          a.y + (b.y - a.y) * f,
          a.scale + (b.scale - a.scale) * f,
          a.rotation + (b.rotation - a.rotation) * f,
          opacity,
        );
      }
    }
    return p;
  }

  /// Full pose at local time [lt] (seconds from the layer's start).
  Pose poseAt(double lt) {
    final p = basePose(lt);
    final d = animLen;
    if (d <= 0) return p;
    if (animIn != 'none' && lt < d) _animate(p, animIn, 1 - lt / d);
    if (animOut != 'none' && lt > duration - d) _animate(p, animOut, (lt - (duration - d)) / d);
    return p;
  }

  /// [k] runs 1 → 0 on the way in and 0 → 1 on the way out.
  static void _animate(Pose p, String kind, double k) {
    k = k.clamp(0.0, 1.0);
    switch (kind) {
      case 'fade':
        p.alpha *= 1 - k;
      case 'slideUp':
        p.y += 0.25 * k;
        p.alpha *= 1 - k;
      case 'slideDown':
        p.y -= 0.25 * k;
        p.alpha *= 1 - k;
      case 'slideLeft':
        p.x += 0.35 * k;
        p.alpha *= 1 - k;
      case 'slideRight':
        p.x -= 0.35 * k;
        p.alpha *= 1 - k;
      case 'zoom':
        p.scale *= 1 - 0.6 * k;
        p.alpha *= 1 - k;
    }
  }

  /// Times (local) between which the pose is treated as linear on export.
  List<double> breakpoints() {
    final d = animLen;
    final pts = <double>{0, duration};
    if (animIn != 'none' && d > 0) pts.add(d);
    if (animOut != 'none' && d > 0) pts.add(duration - d);
    for (final k in keys) {
      if (k.t > 0 && k.t < duration) pts.add(k.t);
    }
    return pts.toList()..sort();
  }

  bool get isAnimated => keys.length > 1 || animIn != 'none' || animOut != 'none';

  void setKeyframe(double lt) {
    final p = basePose(lt);
    keys.removeWhere((k) => (k.t - lt).abs() < 0.04);
    keys.add(Keyframe(lt, p.x, p.y, p.scale, p.rotation));
    keys.sort((a, b) => a.t.compareTo(b.t));
  }

  Keyframe? keyNear(double lt) {
    for (final k in keys) {
      if ((k.t - lt).abs() < 0.04) return k;
    }
    return null;
  }

  /// Writes a transform edit either to the keyframe under the playhead or to
  /// the static values (shifting all keyframes when there are any).
  void applyTransform(double lt, {double? nx, double? ny, double? ns, double? nr}) {
    if (keys.isEmpty) {
      x = nx ?? x;
      y = ny ?? y;
      scale = ns ?? scale;
      rotation = nr ?? rotation;
      return;
    }
    var k = keyNear(lt);
    if (k == null) {
      setKeyframe(lt);
      k = keyNear(lt)!;
    }
    k.x = nx ?? k.x;
    k.y = ny ?? k.y;
    k.scale = ns ?? k.scale;
    k.rotation = nr ?? k.rotation;
  }

  Map<String, dynamic> layerJson() => {
        'id': id,
        'x': x,
        'y': y,
        'scale': scale,
        'rot': rotation,
        'opacity': opacity,
        'keys': keys.map((k) => k.toJson()).toList(),
        'animIn': animIn,
        'animOut': animOut,
        'animDur': animDur,
      };

  void readLayer(Map j) {
    id = j['id'] as String? ?? Store.newId();
    x = _d(j['x']);
    y = _d(j['y']);
    scale = _d(j['scale'], 1);
    rotation = _d(j['rot']);
    opacity = _d(j['opacity'], 1);
    keys = ((j['keys'] as List?) ?? []).map((e) => Keyframe.fromJson(e as Map)).toList();
    animIn = j['animIn'] as String? ?? 'none';
    animOut = j['animOut'] as String? ?? 'none';
    animDur = _d(j['animDur'], 0.5);
  }
}

const kTransitions = {
  'none': 'None',
  'fade': 'Dissolve',
  'fadeblack': 'Dip to black',
  'fadewhite': 'Dip to white',
  'slideleft': 'Slide left',
  'slideright': 'Slide right',
  'slideup': 'Slide up',
  'slidedown': 'Slide down',
  'wipeleft': 'Wipe left',
  'wiperight': 'Wipe right',
  'circleopen': 'Circle open',
};

/// A video or still image on the main track or an overlay track.
class Clip extends Layer {
  ClipKind kind;
  String path;
  String name;
  String? thumb;
  double srcDuration;
  int srcW, srcH;
  bool hasAudio;

  /// Trim range in source seconds. For images, 0..duration.
  double inPoint, outPoint;
  double speed = 1;
  double volume = 1;
  bool muted = false;
  double fadeIn = 0, fadeOut = 0;

  String filter = 'none';
  double filterAmount = 1;
  Map<String, double> adjust = {};
  double blur = 0;
  bool flipH = false;

  /// Resolve-style effects, applied in order (see effects.dart).
  List<ClipFx> effects = [];

  /// Transition into the next main-track clip.
  String transition = 'none';
  double transitionDur = 0.6;

  /// Timeline start (overlay clips only; main clips are sequential).
  double start = 0;

  Clip({
    required this.kind,
    required this.path,
    required this.name,
    required this.srcDuration,
    required this.srcW,
    required this.srcH,
    this.hasAudio = false,
    this.thumb,
    double? inPoint,
    double? outPoint,
  })  : inPoint = inPoint ?? 0,
        outPoint = outPoint ?? srcDuration;

  @override
  double get duration => math.max(0.05, (outPoint - inPoint) / speed);

  bool get isImage => kind == ClipKind.image;
  bool get audible => kind == ClipKind.video && hasAudio && !muted && volume > 0;

  Map<String, dynamic> toJson() => {
        ...layerJson(),
        'kind': kind.name,
        'path': path,
        'name': name,
        'thumb': thumb,
        'srcDur': srcDuration,
        'w': srcW,
        'h': srcH,
        'hasAudio': hasAudio,
        'in': inPoint,
        'out': outPoint,
        'speed': speed,
        'volume': volume,
        'muted': muted,
        'fadeIn': fadeIn,
        'fadeOut': fadeOut,
        'filter': filter,
        'filterAmount': filterAmount,
        'adjust': adjust,
        'blur': blur,
        'flipH': flipH,
        'effects': [for (final e in effects) e.toJson()],
        'transition': transition,
        'transitionDur': transitionDur,
        'start': start,
      };

  static Clip fromJson(Map j) {
    final c = Clip(
      kind: j['kind'] == 'image' ? ClipKind.image : ClipKind.video,
      path: j['path'] as String,
      name: j['name'] as String? ?? 'Clip',
      srcDuration: _d(j['srcDur'], 3),
      srcW: (j['w'] as num?)?.toInt() ?? 1080,
      srcH: (j['h'] as num?)?.toInt() ?? 1920,
      hasAudio: j['hasAudio'] == true,
      thumb: j['thumb'] as String?,
      inPoint: _d(j['in']),
      outPoint: _d(j['out'], 3),
    )..readLayer(j);
    c
      ..speed = _d(j['speed'], 1)
      ..volume = _d(j['volume'], 1)
      ..muted = j['muted'] == true
      ..fadeIn = _d(j['fadeIn'])
      ..fadeOut = _d(j['fadeOut'])
      ..filter = j['filter'] as String? ?? 'none'
      ..filterAmount = _d(j['filterAmount'], 1)
      ..adjust = (j['adjust'] as Map? ?? {}).map((k, v) => MapEntry(k as String, _d(v)))
      ..blur = _d(j['blur'])
      ..flipH = j['flipH'] == true
      ..effects = [
        for (final e in (j['effects'] as List? ?? []))
          if (e is Map) ?ClipFx.fromJson(e),
      ]
      ..transition = j['transition'] as String? ?? 'none'
      ..transitionDur = _d(j['transitionDur'], 0.6)
      ..start = _d(j['start']);
    return c;
  }

  Clip copy() => fromJson(jsonDecode(jsonEncode(toJson())) as Map)..id = Store.newId();
}

const kFonts = ['Inter', 'Bebas Neue', 'Playfair Display', 'Pacifico', 'Oswald', 'Caveat', 'Roboto Mono', 'Anton', 'Lobster', 'Montserrat'];

class TextItem extends Layer {
  String text;
  double start;
  double _duration;
  String font = 'Inter';
  /// Font size as a fraction of the canvas height.
  double size = 0.06;
  int color = 0xFFFFFFFF;
  int background = 0x00000000;
  int stroke = 0xFF000000;
  double strokeWidth = 0;
  bool shadow = true;
  bool bold = true;
  bool italic = false;
  int align = 1; // 0 left, 1 centre, 2 right
  bool caption = false;

  TextItem({required this.text, required this.start, double duration = 3}) : _duration = duration;

  @override
  double get duration => _duration;
  set duration(double v) => _duration = math.max(0.1, v);

  Map<String, dynamic> toJson() => {
        ...layerJson(),
        'text': text,
        'start': start,
        'dur': _duration,
        'font': font,
        'size': size,
        'color': color,
        'bg': background,
        'stroke': stroke,
        'strokeW': strokeWidth,
        'shadow': shadow,
        'bold': bold,
        'italic': italic,
        'align': align,
        'caption': caption,
      };

  static TextItem fromJson(Map j) {
    final t = TextItem(text: j['text'] as String? ?? '', start: _d(j['start']), duration: _d(j['dur'], 3))
      ..readLayer(j);
    t
      ..font = j['font'] as String? ?? 'Inter'
      ..size = _d(j['size'], 0.06)
      ..color = (j['color'] as num?)?.toInt() ?? 0xFFFFFFFF
      ..background = (j['bg'] as num?)?.toInt() ?? 0
      ..stroke = (j['stroke'] as num?)?.toInt() ?? 0xFF000000
      ..strokeWidth = _d(j['strokeW'])
      ..shadow = j['shadow'] != false
      ..bold = j['bold'] != false
      ..italic = j['italic'] == true
      ..align = (j['align'] as num?)?.toInt() ?? 1
      ..caption = j['caption'] == true;
    return t;
  }

  TextItem copy() => fromJson(jsonDecode(jsonEncode(toJson())) as Map)..id = Store.newId();
}

class AudioItem {
  String id = Store.newId();
  String path;
  String name;
  double srcDuration;
  double start;
  double inPoint, outPoint;
  double volume = 1;
  double fadeIn = 0, fadeOut = 0;

  AudioItem({required this.path, required this.name, required this.srcDuration, this.start = 0, double? inPoint, double? outPoint})
      : inPoint = inPoint ?? 0,
        outPoint = outPoint ?? srcDuration;

  double get duration => math.max(0.05, outPoint - inPoint);

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'srcDur': srcDuration,
        'start': start,
        'in': inPoint,
        'out': outPoint,
        'volume': volume,
        'fadeIn': fadeIn,
        'fadeOut': fadeOut,
      };

  static AudioItem fromJson(Map j) => AudioItem(
        path: j['path'] as String,
        name: j['name'] as String? ?? 'Audio',
        srcDuration: _d(j['srcDur'], 10),
        start: _d(j['start']),
        inPoint: _d(j['in']),
        outPoint: _d(j['out'], 10),
      )
        ..id = j['id'] as String? ?? Store.newId()
        ..volume = _d(j['volume'], 1)
        ..fadeIn = _d(j['fadeIn'])
        ..fadeOut = _d(j['fadeOut']);

  AudioItem copy() => fromJson(jsonDecode(jsonEncode(toJson())) as Map)..id = Store.newId();
}

const kAspects = {'9:16': [9, 16], '16:9': [16, 9], '1:1': [1, 1], '4:5': [4, 5], '4:3': [4, 3], '3:4': [3, 4], '21:9': [21, 9]};

class Project {
  String id;
  String name;
  int aspectW, aspectH;
  int background = 0xFF000000;
  List<Clip> main = [];
  List<Clip> overlays = [];
  List<TextItem> texts = [];
  List<AudioItem> audios = [];
  int updated = DateTime.now().millisecondsSinceEpoch;

  Project({String? id, this.name = 'Untitled project', this.aspectW = 9, this.aspectH = 16}) : id = id ?? Store.newId();

  double get aspect => aspectW / aspectH;

  /// Overlap between main clip [i] and the next one.
  double transitionAfter(int i) {
    if (i < 0 || i >= main.length - 1) return 0;
    final c = main[i];
    if (c.transition == 'none') return 0;
    return math.max(0, math.min(c.transitionDur, math.min(c.duration, main[i + 1].duration) * 0.45));
  }

  double mainStart(int i) {
    var t = 0.0;
    for (var k = 0; k < i; k++) {
      t += main[k].duration - transitionAfter(k);
    }
    return t;
  }

  double get mainDuration => main.isEmpty ? 0 : mainStart(main.length - 1) + main.last.duration;

  double get duration {
    var d = mainDuration;
    if (main.isEmpty) {
      for (final o in overlays) {
        d = math.max(d, o.start + o.duration);
      }
      for (final t in texts) {
        d = math.max(d, t.start + t.duration);
      }
      for (final a in audios) {
        d = math.max(d, a.start + a.duration);
      }
    }
    return d;
  }

  /// Index of the main clip that owns time [t] (the incoming clip during a
  /// transition), or -1.
  int mainIndexAt(double t) {
    for (var i = main.length - 1; i >= 0; i--) {
      if (t >= mainStart(i) - 1e-6) return t <= mainStart(i) + main[i].duration + 1e-6 ? i : -1;
    }
    return -1;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'aw': aspectW,
        'ah': aspectH,
        'bg': background,
        'main': main.map((c) => c.toJson()).toList(),
        'overlays': overlays.map((c) => c.toJson()).toList(),
        'texts': texts.map((c) => c.toJson()).toList(),
        'audios': audios.map((c) => c.toJson()).toList(),
        'updated': updated,
      };

  static Project fromJson(Map j) {
    final p = Project(
      id: j['id'] as String?,
      name: j['name'] as String? ?? 'Untitled project',
      aspectW: (j['aw'] as num?)?.toInt() ?? 9,
      aspectH: (j['ah'] as num?)?.toInt() ?? 16,
    );
    p
      ..background = (j['bg'] as num?)?.toInt() ?? 0xFF000000
      ..main = ((j['main'] as List?) ?? []).map((e) => Clip.fromJson(e as Map)).toList()
      ..overlays = ((j['overlays'] as List?) ?? []).map((e) => Clip.fromJson(e as Map)).toList()
      ..texts = ((j['texts'] as List?) ?? []).map((e) => TextItem.fromJson(e as Map)).toList()
      ..audios = ((j['audios'] as List?) ?? []).map((e) => AudioItem.fromJson(e as Map)).toList()
      ..updated = (j['updated'] as num?)?.toInt() ?? 0;
    return p;
  }
}

class ProjectStore {
  static const _key = 'video_projects';

  static List<Project> all() {
    final out = <Project>[];
    for (final j in Store.readList(_key)) {
      try {
        out.add(Project.fromJson(j));
      } catch (_) {}
    }
    return out;
  }

  static Future<void> save(Project p) {
    p.updated = DateTime.now().millisecondsSinceEpoch;
    return Store.upsert(_key, p.toJson());
  }

  static Future<void> delete(String id) => Store.remove(_key, id);
}

// ---------------------------------------------------------------- colour

/// An affine colour transform: out = m · rgb + o (o in 0..1).
class ColorMatrix {
  final List<double> m; // 3x3 row-major
  final List<double> o; // 3
  const ColorMatrix(this.m, this.o);

  static const identity = ColorMatrix([1, 0, 0, 0, 1, 0, 0, 0, 1], [0, 0, 0]);

  bool get isIdentity {
    for (var i = 0; i < 9; i++) {
      if ((m[i] - identity.m[i]).abs() > 1e-4) return false;
    }
    return o.every((v) => v.abs() < 1e-4);
  }

  /// Returns the transform "this, then [next]".
  ColorMatrix then(ColorMatrix next) {
    final r = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        for (var k = 0; k < 3; k++) {
          r[i * 3 + j] += next.m[i * 3 + k] * m[k * 3 + j];
        }
      }
    }
    final off = [
      for (var i = 0; i < 3; i++)
        next.m[i * 3] * o[0] + next.m[i * 3 + 1] * o[1] + next.m[i * 3 + 2] * o[2] + next.o[i],
    ];
    return ColorMatrix(r, off);
  }

  /// 5x4 matrix for Flutter's `ColorFilter.matrix`.
  List<double> toFlutter() => [
        m[0], m[1], m[2], 0, o[0] * 255,
        m[3], m[4], m[5], 0, o[1] * 255,
        m[6], m[7], m[8], 0, o[2] * 255,
        0, 0, 0, 1, 0,
      ];

  static const _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

  static ColorMatrix saturation(double s) => ColorMatrix([
        _lr + (1 - _lr) * s, _lg - _lg * s, _lb - _lb * s,
        _lr - _lr * s, _lg + (1 - _lg) * s, _lb - _lb * s,
        _lr - _lr * s, _lg - _lg * s, _lb + (1 - _lb) * s,
      ], const [0, 0, 0]);

  static ColorMatrix hue(double turns) {
    final a = turns * 2 * math.pi;
    final c = math.cos(a), s = math.sin(a);
    return ColorMatrix([
      _lr + c * (1 - _lr) + s * -_lr, _lg + c * -_lg + s * -_lg, _lb + c * -_lb + s * (1 - _lb),
      _lr + c * -_lr + s * 0.143, _lg + c * (1 - _lg) + s * 0.140, _lb + c * -_lb + s * -0.283,
      _lr + c * -_lr + s * -(1 - _lr), _lg + c * -_lg + s * _lg, _lb + c * (1 - _lb) + s * _lb,
    ], const [0, 0, 0]);
  }

  static ColorMatrix gains(double r, double g, double b) =>
      ColorMatrix([r, 0, 0, 0, g, 0, 0, 0, b], const [0, 0, 0]);

  static ColorMatrix contrast(double c) {
    final k = 1 + c;
    final off = 0.5 * (1 - k);
    return ColorMatrix([k, 0, 0, 0, k, 0, 0, 0, k], [off, off, off]);
  }

  static ColorMatrix offset(double v) => ColorMatrix(identity.m, [v, v, v]);

  static ColorMatrix fade(double f) {
    final k = 1 - 0.28 * f;
    return ColorMatrix([k, 0, 0, 0, k, 0, 0, 0, k], [0.14 * f, 0.14 * f, 0.14 * f]);
  }

  static ColorMatrix sepia(double a) {
    const s = [0.393, 0.769, 0.189, 0.349, 0.686, 0.168, 0.272, 0.534, 0.131];
    return ColorMatrix([
      for (var i = 0; i < 9; i++) identity.m[i] + (s[i] - identity.m[i]) * a,
    ], const [0, 0, 0]);
  }
}

/// Looks for video clips. Values: sat (1 = unchanged) and the rest 0 = unchanged.
const kVideoFilters = <String, Map<String, double>>{
  'none': {},
  'Vivid': {'sat': 1.4, 'contrast': 0.12},
  'Punch': {'sat': 1.2, 'contrast': 0.28, 'bright': -0.03},
  'Warm': {'temp': 0.55, 'sat': 1.1},
  'Sunset': {'temp': 0.8, 'tint': 0.2, 'sat': 1.25, 'contrast': 0.08},
  'Cool': {'temp': -0.55, 'contrast': 0.06},
  'Teal Night': {'temp': -0.4, 'tint': -0.15, 'contrast': 0.18, 'sat': 0.9},
  'Pastel': {'sat': 0.78, 'contrast': -0.16, 'bright': 0.1, 'fade': 0.35},
  'Fade': {'fade': 0.85, 'sat': 0.85},
  'Vintage': {'sepia': 0.45, 'fade': 0.5, 'temp': 0.2, 'contrast': -0.05},
  'Sepia': {'sepia': 1.0, 'contrast': 0.05},
  'Mono': {'sat': 0.0, 'contrast': 0.1},
  'Noir': {'sat': 0.0, 'contrast': 0.4, 'bright': -0.06},
  'Dream': {'hue': 0.03, 'sat': 1.15, 'bright': 0.06, 'fade': 0.25, 'tint': 0.2},
};

const kVideoAdjust = [
  ('brightness', 'Brightness'),
  ('contrast', 'Contrast'),
  ('saturation', 'Saturation'),
  ('temperature', 'Temperature'),
  ('tint', 'Tint'),
  ('hue', 'Hue'),
  ('fade', 'Fade'),
];

/// The combined colour transform for a clip (filter look + manual adjustments).
ColorMatrix clipColor(Clip c) {
  final f = kVideoFilters[c.filter] ?? const {};
  final a = c.filterAmount.clamp(0.0, 1.0);
  double adj(String id) => (c.adjust[id] ?? 0) / 100;
  final sat = (1 + ((f['sat'] ?? 1) - 1) * a) * (1 + adj('saturation'));
  final hue = (f['hue'] ?? 0) * a + adj('hue') * 0.5;
  final temp = (f['temp'] ?? 0) * a + adj('temperature');
  final tint = (f['tint'] ?? 0) * a + adj('tint');
  final con = (f['contrast'] ?? 0) * a + adj('contrast') * 0.6;
  final bri = (f['bright'] ?? 0) * a + adj('brightness') * 0.35;
  final fade = ((f['fade'] ?? 0) * a + math.max(0, adj('fade'))).clamp(0.0, 1.0);
  final sep = (f['sepia'] ?? 0) * a;
  var m = ColorMatrix.identity;
  if (sep != 0) m = m.then(ColorMatrix.sepia(sep));
  if (sat != 1) m = m.then(ColorMatrix.saturation(math.max(0, sat)));
  if (hue != 0) m = m.then(ColorMatrix.hue(hue));
  if (temp != 0 || tint != 0) {
    m = m.then(ColorMatrix.gains(1 + 0.18 * temp + 0.04 * tint, 1 - 0.12 * tint, 1 - 0.18 * temp + 0.04 * tint));
  }
  if (con != 0) m = m.then(ColorMatrix.contrast(con));
  if (bri != 0) m = m.then(ColorMatrix.offset(bri));
  if (fade != 0) m = m.then(ColorMatrix.fade(fade));
  return m;
}
