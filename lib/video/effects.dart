import 'dart:math' as math;

/// One adjustable value of an effect.
class FxParam {
  final String key, label;
  final double min, max, def;
  final int decimals;
  const FxParam(this.key, this.label, this.min, this.max, this.def, [this.decimals = 0]);
}

/// Sizes an effect needs to turn its sliders into pixel values.
class FxEnv {
  /// Layer raster size in pixels.
  final int w, h;

  /// Pixels per canvas-height unit for this layer (canvas height * raster).
  final double unit;
  const FxEnv(this.w, this.h, this.unit);
}

/// Work done on a copy of the picture and blended back over the original
/// (glow, halation, mirror ...). [pre] runs on the main picture first,
/// [branch] only on the copy, and [combine] joins `[main][copy]`.
class FxBranch {
  final List<String> pre, branch;
  final String combine;
  const FxBranch(this.branch, this.combine, {this.pre = const []});
}

class FxDef {
  final String id, label, category;
  final List<FxParam> params;

  /// Builds the FFmpeg steps; each is a filter string or an [FxBranch].
  final List<Object> Function(Map<String, double> v, FxEnv e) build;

  /// Whether the editor preview can approximate it (export is always exact).
  final bool preview;
  const FxDef(this.id, this.label, this.category, this.params, this.build, {this.preview = false});

  Map<String, double> defaults() => {for (final p in params) p.key: p.def};
}

/// An effect applied to a clip.
class ClipFx {
  String type;
  Map<String, double> v;
  ClipFx(this.type, this.v);

  factory ClipFx.of(String type) => ClipFx(type, kEffects[type]?.defaults() ?? {});

  FxDef? get def => kEffects[type];
  double get(String k) => v[k] ?? def?.params.firstWhere((p) => p.key == k).def ?? 0;

  Map<String, dynamic> toJson() => {'t': type, 'v': v};
  static ClipFx? fromJson(Map j) {
    final t = j['t'] as String?;
    if (t == null || !kEffects.containsKey(t)) return null;
    final base = kEffects[t]!.defaults();
    (j['v'] as Map? ?? {}).forEach((k, x) {
      if (base.containsKey(k) && x is num) base[k as String] = x.toDouble();
    });
    return ClipFx(t, base);
  }
}

String _n(num v) {
  final s = v.toStringAsFixed(4);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

int _even(num v) {
  final i = v.round();
  return math.max(2, i - i % 2);
}

String _lut(String expr) => "lutrgb=r='$expr':g='$expr':b='$expr'";

/// Bright-areas-only glow, blended back with "screen". [tint] multiplies the
/// glow's colour (white = plain bloom). [threshold] 0 glows the whole picture.
List<Object> _glow(double amount, double size, double threshold, {List<double> tint = const [1, 1, 1], FxEnv? e}) {
  final t = (threshold * 255).clamp(0, 254.0);
  final branch = <String>[
    if (threshold > 0) _lut('clip((val-${_n(t)})*${_n(255 / (255 - t))},0,255)'),
    'gblur=sigma=${_n(math.max(0.5, size / 100 * 0.06 * e!.unit))}',
    if (tint[0] != 1 || tint[1] != 1 || tint[2] != 1)
      'colorchannelmixer=rr=${_n(tint[0])}:gg=${_n(tint[1])}:bb=${_n(tint[2])}',
    'format=rgba',
  ];
  final a = _n(amount.clamp(0.0, 1.0));
  return [
    FxBranch(branch,
        'blend=c0_mode=screen:c1_mode=screen:c2_mode=screen:c0_opacity=$a:c1_opacity=$a:c2_opacity=$a:c3_opacity=0,format=rgba')
  ];
}

const _kernelEmboss = '-2 -1 0 -1 1 1 0 1 2';
const _kernelKeepAlpha = '0 0 0 0 1 0 0 0 0';

/// The effect library. Everything is applied by FFmpeg on export; entries
/// with `preview: true` are also approximated live in the editor.
final Map<String, FxDef> kEffects = {
  for (final d in <FxDef>[
    // ---- Light & glow
    FxDef('halation', 'Halation', 'Light & glow', const [
      FxParam('amount', 'Amount', 0, 100, 60),
      FxParam('size', 'Glow size', 5, 100, 40),
      FxParam('warmth', 'Warmth', 0, 100, 80),
      FxParam('threshold', 'Highlight cut-off', 20, 95, 60),
    ], (v, e) {
      final w = v['warmth']! / 100;
      return _glow(v['amount']! / 100, v['size']!, v['threshold']! / 100, tint: [1, 1 - 0.72 * w, 1 - 0.95 * w], e: e);
    }, preview: true),
    FxDef('bloom', 'Bloom', 'Light & glow', const [
      FxParam('amount', 'Amount', 0, 100, 50),
      FxParam('size', 'Glow size', 5, 100, 35),
      FxParam('threshold', 'Highlight cut-off', 10, 95, 50),
    ], (v, e) => _glow(v['amount']! / 100, v['size']!, v['threshold']! / 100, e: e), preview: true),
    FxDef('dream', 'Soft glow', 'Light & glow', const [
      FxParam('amount', 'Amount', 0, 100, 45),
      FxParam('size', 'Softness', 5, 100, 30),
    ], (v, e) => _glow(v['amount']! / 100, v['size']!, 0, e: e), preview: true),
    FxDef('vignette', 'Vignette', 'Light & glow', const [
      FxParam('amount', 'Amount', 0, 100, 50),
    ], (v, e) => ['vignette=angle=${_n(0.3 + v['amount']! / 100 * 1.1)}'], preview: true),
    FxDef('strobe', 'Strobe', 'Light & glow', const [
      FxParam('rate', 'Flashes per second', 1, 12, 4),
      FxParam('amount', 'Brightness', 10, 100, 50),
    ], (v, e) {
      final p = 1 / v['rate']!;
      return ["eq=brightness='${_n(v['amount']! / 100)}*lt(mod(t,${_n(p)}),${_n(p * 0.15)})':eval=frame"];
    }),

    // ---- Film & texture
    FxDef('grain', 'Film grain', 'Film & texture', const [
      FxParam('amount', 'Amount', 1, 80, 18),
    ], (v, e) => ['noise=alls=${_n(v['amount']!)}:allf=t+u', 'format=rgba']),
    FxDef('vhs', 'VHS', 'Film & texture', const [
      FxParam('amount', 'Amount', 0, 100, 50),
    ], (v, e) {
      final a = v['amount']! / 100;
      final s = math.max(1, (a * 8 * e.unit / 1000).round());
      return [
        'rgbashift=rh=-$s:bh=$s',
        'noise=alls=${_n(6 + 24 * a)}:allf=t',
        'gblur=sigma=${_n(0.4 + 1.2 * a)}:sigmaV=0.3',
        'drawgrid=width=iw*4:height=${_even(e.h / 90)}:thickness=1:color=black@${_n(0.18 + 0.3 * a)}',
        'format=rgba',
      ];
    }),
    FxDef('scanlines', 'CRT scanlines', 'Film & texture', const [
      FxParam('density', 'Line spacing', 2, 24, 6),
      FxParam('amount', 'Darkness', 5, 100, 35),
    ], (v, e) => [
          'drawgrid=width=iw*4:height=${_n(v['density']!)}:thickness=1:color=black@${_n(v['amount']! / 100)}',
          'format=rgba'
        ]),
    FxDef('letterbox', 'Cinema bars', 'Film & texture', const [
      FxParam('size', 'Bar size', 2, 30, 12),
    ], (v, e) {
      final b = _n(v['size']! / 100);
      return [
        'drawbox=x=0:y=0:w=iw:h=ih*$b:color=black:t=fill',
        'drawbox=x=0:y=ih-ih*$b:w=iw:h=ih*$b:color=black:t=fill',
      ];
    }, preview: true),

    // ---- Blur & sharpen
    FxDef('boxblur', 'Soften', 'Blur & sharpen', const [
      FxParam('amount', 'Amount', 1, 100, 25),
    ], (v, e) => ['gblur=sigma=${_n(math.max(0.3, v['amount']! / 100 * 0.025 * e.unit))}'], preview: true),
    FxDef('motionblur', 'Motion blur (horizontal)', 'Blur & sharpen', const [
      FxParam('amount', 'Length', 1, 100, 30),
    ], (v, e) => ['gblur=sigma=${_n(math.max(0.3, v['amount']! / 100 * 0.06 * e.unit))}:sigmaV=0.01'], preview: true),
    FxDef('vblur', 'Motion blur (vertical)', 'Blur & sharpen', const [
      FxParam('amount', 'Length', 1, 100, 30),
    ], (v, e) => ['gblur=sigma=0.01:sigmaV=${_n(math.max(0.3, v['amount']! / 100 * 0.06 * e.unit))}'], preview: true),
    FxDef('echo', 'Echo trail', 'Blur & sharpen', const [
      FxParam('frames', 'Trail frames', 2, 12, 4),
    ], (v, e) => ['tmix=frames=${v['frames']!.round()}', 'format=rgba']),
    FxDef('sharpen', 'Sharpen', 'Blur & sharpen', const [
      FxParam('amount', 'Amount', 0, 300, 100),
    ], (v, e) => ['unsharp=5:5:${_n(v['amount']! / 100)}:5:5:0']),
    FxDef('denoise', 'Noise reduction', 'Blur & sharpen', const [
      FxParam('amount', 'Strength', 1, 20, 4),
    ], (v, e) {
      final s = _n(v['amount']!), t = _n(v['amount']! * 1.5);
      return ['hqdn3d=$s:$s:$t:$t', 'format=rgba'];
    }),
    FxDef('deflicker', 'Deflicker', 'Blur & sharpen', const [
      FxParam('size', 'Smoothing frames', 3, 25, 5),
    ], (v, e) => ['deflicker=size=${v['size']!.round()}:mode=am', 'format=rgba']),

    // ---- Colour looks
    FxDef('invert', 'Invert', 'Colour looks', const [], (v, e) => ['negate=negate_alpha=0'], preview: true),
    FxDef('sepia', 'Sepia', 'Colour looks', const [], (v, e) => [
          'colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131'
        ], preview: true),
    FxDef('posterize', 'Posterize', 'Colour looks', const [
      FxParam('levels', 'Levels', 2, 16, 5),
    ], (v, e) {
      final n = v['levels']!.round();
      return [_lut('min(255,floor(val*$n/256)*255/${n - 1})')];
    }),
    FxDef('solarize', 'Solarize', 'Colour looks', const [
      FxParam('threshold', 'Threshold', 10, 240, 128),
    ], (v, e) => [_lut('if(gt(val,${_n(v['threshold']!)}),255-val,val)')]),
    FxDef('huecycle', 'Hue cycle', 'Colour looks', const [
      FxParam('speed', 'Cycles per second', 0.05, 3, 0.4, 2),
    ], (v, e) => ["hue=h='${_n(v['speed']! * 360)}*t'", 'format=rgba']),

    // ---- Distort
    FxDef('pixelate', 'Pixelate', 'Distort', const [
      FxParam('size', 'Block size', 2, 80, 16),
    ], (v, e) {
      final n = v['size']! * e.unit / 1000;
      return [
        'scale=${_even(e.w / math.max(1, n))}:${_even(e.h / math.max(1, n))}:flags=neighbor',
        'scale=${e.w}:${e.h}:flags=neighbor',
      ];
    }),
    FxDef('rgbsplit', 'RGB split', 'Distort', const [
      FxParam('amount', 'Shift', 1, 40, 8),
    ], (v, e) {
      final s = math.max(1, (v['amount']! * e.unit / 1000)).round();
      return ['rgbashift=rh=-$s:bh=$s'];
    }),
    FxDef('lens', 'Lens distortion', 'Distort', const [
      FxParam('amount', 'Amount (− pinch / + bulge)', -50, 50, 15),
    ], (v, e) {
      final k = _n(-v['amount']! / 100);
      return ['lenscorrection=k1=$k:k2=$k', 'format=rgba'];
    }),
    FxDef('mirrorh', 'Mirror (left to right)', 'Distort', const [], (v, e) => [
          FxBranch(const ['hflip'], 'hstack', pre: ['crop=iw/2:ih:0:0']),
        ]),
    FxDef('mirrorv', 'Mirror (top to bottom)', 'Distort', const [], (v, e) => [
          FxBranch(const ['vflip'], 'vstack', pre: ['crop=iw:ih/2:0:0']),
        ]),
    FxDef('flipv', 'Flip vertical', 'Distort', const [], (v, e) => ['vflip'], preview: true),

    // ---- Stylise
    FxDef('oil', 'Painterly', 'Stylise', const [
      FxParam('radius', 'Brush size', 1, 5, 2),
    ], (v, e) => ['median=radius=${v['radius']!.round()}', 'format=rgba']),
    FxDef('emboss', 'Emboss', 'Stylise', const [], (v, e) => [
          'convolution=0m=\'$_kernelEmboss\':1m=\'$_kernelEmboss\':2m=\'$_kernelEmboss\':3m=\'$_kernelKeepAlpha\':0bias=128:1bias=128:2bias=128',
          'format=rgba',
        ]),
    FxDef('edges', 'Edge detect', 'Stylise', const [
      FxParam('threshold', 'Sensitivity', 5, 90, 30),
    ], (v, e) {
      final hi = _n(v['threshold']! / 100);
      return ['edgedetect=low=${_n(v['threshold']! / 300)}:high=$hi:mode=colormix', 'format=rgba'];
    }),
    FxDef('sketch', 'Pencil sketch', 'Stylise', const [
      FxParam('threshold', 'Sensitivity', 5, 90, 25),
    ], (v, e) {
      final hi = _n(v['threshold']! / 100);
      return ['edgedetect=low=${_n(v['threshold']! / 300)}:high=$hi:mode=wires', 'negate', 'format=rgba'];
    }),

    // ---- Keying
    FxDef('chromakey', 'Green screen', 'Keying', const [
      FxParam('similarity', 'Tolerance', 1, 60, 25),
      FxParam('blend', 'Edge softness', 0, 50, 10),
    ], (v, e) => [
          'chromakey=color=0x00FF00:similarity=${_n(v['similarity']! / 100)}:blend=${_n(v['blend']! / 100)}',
          'format=rgba'
        ]),
    FxDef('bluekey', 'Blue screen', 'Keying', const [
      FxParam('similarity', 'Tolerance', 1, 60, 25),
      FxParam('blend', 'Edge softness', 0, 50, 10),
    ], (v, e) => [
          'chromakey=color=0x0000FF:similarity=${_n(v['similarity']! / 100)}:blend=${_n(v['blend']! / 100)}',
          'format=rgba'
        ]),
    FxDef('lumakey', 'Luma key (remove brights)', 'Keying', const [
      FxParam('threshold', 'Brightness', 5, 100, 90),
      FxParam('tolerance', 'Tolerance', 1, 60, 15),
    ], (v, e) => [
          'lumakey=threshold=${_n(v['threshold']! / 100)}:tolerance=${_n(v['tolerance']! / 100)}:softness=0.05',
          'format=rgba'
        ]),
  ])
    d.id: d,
};

/// The categories in display order.
List<String> get kEffectCategories {
  final seen = <String>[];
  for (final d in kEffects.values) {
    if (!seen.contains(d.category)) seen.add(d.category);
  }
  return seen;
}
