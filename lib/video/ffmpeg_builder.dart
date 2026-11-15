import 'dart:math' as math;

import 'models.dart';

/// Output settings for an export.
class ExportSpec {
  final int width, height, fps;
  final String encoder; // libx264 | h264_mediacodec | h264_videotoolbox | mpeg4
  final int quality; // 0 (smallest) .. 2 (best)
  final String outPath;
  /// Text id → rendered PNG path, and the raster scale baked into it.
  final Map<String, String> textPngs;
  final Map<String, double> textRaster;
  const ExportSpec({
    required this.width,
    required this.height,
    required this.fps,
    required this.encoder,
    required this.outPath,
    this.quality = 1,
    this.textPngs = const {},
    this.textRaster = const {},
  });
}

class FfmpegCommand {
  final List<String> args;
  final String filterGraph;
  final double duration;
  const FfmpegCommand(this.args, this.filterGraph, this.duration);
}

String _n(double v) {
  if (v.abs() < 5e-5) return '0';
  final s = v.toStringAsFixed(4);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

int _even(double v) => math.max(2, (v / 2).round() * 2);

/// Largest scale a layer reaches; its raster is prepared at this scale.
double rasterScale(Layer l) {
  var m = 0.01;
  for (final t in l.breakpoints()) {
    m = math.max(m, l.poseAt(t).scale);
  }
  return m;
}

/// A piecewise-linear ffmpeg expression of `(t - start)` through the layer's
/// breakpoints, or a plain number when the value never changes.
String _expr(Layer l, double start, double Function(Pose) pick) {
  final bp = l.breakpoints();
  final vals = [for (final t in bp) pick(l.poseAt(t))];
  if (vals.every((v) => (v - vals.first).abs() < 1e-5)) return _n(vals.first);
  final T = start == 0 ? 't' : '(t-${_n(start)})';
  var e = _n(vals.last);
  for (var i = bp.length - 2; i >= 0; i--) {
    final span = math.max(bp[i + 1] - bp[i], 1e-4);
    final seg = '${_n(vals[i])}+${_n((vals[i + 1] - vals[i]) / span)}*($T-${_n(bp[i])})';
    e = 'if(lt($T,${_n(bp[i + 1])}),$seg,$e)';
  }
  return e;
}

String _hex(int argb) => '0x${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// atempo accepts 0.5..2 per instance on older builds, so chain as needed.
List<String> atempoChain(double speed) {
  final out = <String>[];
  var s = speed;
  while (s > 2.0 + 1e-6) {
    out.add('atempo=2.0');
    s /= 2;
  }
  while (s < 0.5 - 1e-6) {
    out.add('atempo=0.5');
    s /= 0.5;
  }
  if ((s - 1).abs() > 1e-3) out.add('atempo=${_n(s)}');
  return out;
}

/// Builds the complete ffmpeg invocation that renders [p].
///
/// The preview (see `preview.dart`) and this graph follow the same rules:
/// every main clip is composed over the background at canvas size, joined to
/// the next with `xfade` or a cut, then overlays and text are stacked on top.
FfmpegCommand buildExport(Project p, ExportSpec s) {
  final w = s.width.toDouble(), h = s.height.toDouble();
  final total = math.max(p.duration, 0.1);
  final inputs = <String>[];
  var inputCount = 0;
  final f = <String>[];
  final audio = <String>[];
  var label = 0;
  String next(String prefix) => '$prefix${label++}';

  int addClipInput(Clip c) {
    if (c.isImage) {
      inputs.addAll(['-loop', '1', '-framerate', '${s.fps}', '-t', _n(c.duration + 0.1), '-i', c.path]);
    } else {
      inputs.addAll(['-ss', _n(c.inPoint), '-t', _n(c.outPoint - c.inPoint), '-i', c.path]);
    }
    return inputCount++;
  }

  /// Filters that turn a clip's raw video into an RGBA layer raster.
  String clipChain(Clip c, double start, double raster) {
    final k = math.min(w / c.srcW, h / c.srcH);
    final parts = <String>[
      'setpts=(PTS-STARTPTS)${c.isImage || c.speed == 1 ? '' : '/${_n(c.speed)}'}${start == 0 ? '' : '+${_n(start)}/TB'}',
      'fps=${s.fps}',
      'scale=${_even(c.srcW * k * raster)}:${_even(c.srcH * k * raster)}',
      'format=rgba',
    ];
    if (c.flipH) parts.add('hflip');
    final cm = clipColor(c);
    if (!cm.isIdentity || c.opacity < 0.999) {
      final m = cm.m, o = cm.o;
      parts.add('colorchannelmixer='
          'rr=${_n(m[0])}:rg=${_n(m[1])}:rb=${_n(m[2])}:ra=${_n(o[0])}:'
          'gr=${_n(m[3])}:gg=${_n(m[4])}:gb=${_n(m[5])}:ga=${_n(o[1])}:'
          'br=${_n(m[6])}:bg=${_n(m[7])}:bb=${_n(m[8])}:ba=${_n(o[2])}:'
          'aa=${_n(c.opacity.clamp(0.0, 1.0))}');
    }
    if (c.blur > 0) parts.add('gblur=sigma=${_n(c.blur / 100 * 0.03 * h * raster)}');
    return parts.join(',');
  }

  /// Animated rotation / scale / fades shared by clips and text.
  List<String> poseFilters(Layer l, double start, double raster) {
    final parts = <String>[];
    final d = l.animLen;
    if (l.animIn != 'none' && d > 0) parts.add('fade=t=in:st=${_n(start)}:d=${_n(d)}:alpha=1');
    if (l.animOut != 'none' && d > 0) {
      parts.add('fade=t=out:st=${_n(start + l.duration - d)}:d=${_n(d)}:alpha=1');
    }
    final rot = _expr(l, start, (q) => q.rotation * math.pi / 180);
    if (rot != '0') parts.add("rotate=a='$rot':ow='hypot(iw,ih)':oh=ow:c=none");
    final sc = _expr(l, start, (q) => q.scale / raster);
    if (double.tryParse(sc) == null) {
      parts.add("scale=w='max(2,iw*($sc))':h='max(2,ih*($sc))':eval=frame");
    } else if ((double.parse(sc) - 1).abs() > 1e-3) {
      parts.add('scale=w=iw*$sc:h=ih*$sc');
    }
    return parts;
  }

  String overlay(String base, String layer, Layer l, double start, String out) {
    final x = _expr(l, start, (q) => w / 2 + q.x * w);
    final y = _expr(l, start, (q) => h / 2 + q.y * h);
    return "[$base][$layer]overlay=x='$x-w/2':y='$y-h/2':eof_action=pass:"
        "enable='between(t,${_n(start)},${_n(start + l.duration)})'[$out]";
  }

  void clipAudio(Clip c, int input, double start, double fadeIn, double fadeOut) {
    if (!c.audible) return;
    final parts = <String>['asetpts=PTS-STARTPTS', ...atempoChain(c.speed), 'aresample=44100', 'aformat=channel_layouts=stereo'];
    if ((c.volume - 1).abs() > 1e-3) parts.add('volume=${_n(c.volume)}');
    if (fadeIn > 0) parts.add('afade=t=in:st=0:d=${_n(fadeIn)}');
    if (fadeOut > 0) parts.add('afade=t=out:st=${_n(math.max(0, c.duration - fadeOut))}:d=${_n(fadeOut)}');
    if (start > 0) parts.add('adelay=${(start * 1000).round()}:all=1');
    final out = next('a');
    f.add('[$input:a]${parts.join(',')}[$out]');
    audio.add(out);
  }

  // ---- Main track.
  var acc = '';
  var accDur = 0.0;
  if (p.main.isEmpty) {
    acc = next('v');
    f.add('color=c=${_hex(p.background)}:s=${s.width}x${s.height}:r=${s.fps}:d=${_n(total)},format=yuv420p[$acc]');
  }
  for (var i = 0; i < p.main.length; i++) {
    final c = p.main[i];
    final input = addClipInput(c);
    final raster = rasterScale(c);
    final layer = next('l'), bg = next('b'), placed = next('p'), frame = next('v');
    f.add('[$input:v]${[clipChain(c, 0, raster), ...poseFilters(c, 0, raster)].join(',')}[$layer]');
    f.add('color=c=${_hex(p.background)}:s=${s.width}x${s.height}:r=${s.fps}:d=${_n(c.duration)}[$bg]');
    f.add(overlay(bg, layer, c, 0, placed));
    f.add('[$placed]fps=${s.fps},format=yuv420p,setsar=1,settb=AVTB[$frame]');
    clipAudio(c, input, p.mainStart(i), math.max(c.fadeIn, p.transitionAfter(i - 1)),
        math.max(c.fadeOut, p.transitionAfter(i)));
    if (i == 0) {
      acc = frame;
      accDur = c.duration;
      continue;
    }
    final tr = p.transitionAfter(i - 1);
    final joined = next('x');
    if (tr > 0) {
      f.add('[$acc][$frame]xfade=transition=${p.main[i - 1].transition}:duration=${_n(tr)}:'
          'offset=${_n(accDur - tr)},settb=AVTB[$joined]');
      accDur += c.duration - tr;
    } else {
      f.add('[$acc][$frame]concat=n=2:v=1:a=0,fps=${s.fps},settb=AVTB[$joined]');
      accDur += c.duration;
    }
    acc = joined;
  }

  // ---- Overlay clips.
  for (final c in p.overlays) {
    final input = addClipInput(c);
    final raster = rasterScale(c);
    final layer = next('l'), out = next('o');
    f.add('[$input:v]${[clipChain(c, c.start, raster), ...poseFilters(c, c.start, raster)].join(',')}[$layer]');
    f.add(overlay(acc, layer, c, c.start, out));
    clipAudio(c, input, c.start, c.fadeIn, c.fadeOut);
    acc = out;
  }

  // ---- Text.
  for (final t in p.texts) {
    final png = s.textPngs[t.id];
    if (png == null) continue;
    final raster = s.textRaster[t.id] ?? 1;
    inputs.addAll(['-loop', '1', '-framerate', '${s.fps}', '-t', _n(t.duration + 0.1), '-i', png]);
    final input = inputCount++;
    final layer = next('l'), out = next('o');
    final parts = <String>['format=rgba', 'setpts=PTS-STARTPTS+${_n(t.start)}/TB'];
    if (t.opacity < 0.999) parts.add('colorchannelmixer=aa=${_n(t.opacity.clamp(0.0, 1.0))}');
    parts.addAll(poseFilters(t, t.start, raster));
    f.add('[$input:v]${parts.join(',')}[$layer]');
    f.add(overlay(acc, layer, t, t.start, out));
    acc = out;
  }
  f.add('[$acc]format=yuv420p[vout]');

  // ---- Audio tracks.
  for (final a in p.audios) {
    inputs.addAll(['-ss', _n(a.inPoint), '-t', _n(a.duration), '-i', a.path]);
    final input = inputCount++;
    final parts = <String>['asetpts=PTS-STARTPTS', 'aresample=44100', 'aformat=channel_layouts=stereo'];
    if ((a.volume - 1).abs() > 1e-3) parts.add('volume=${_n(a.volume)}');
    if (a.fadeIn > 0) parts.add('afade=t=in:st=0:d=${_n(a.fadeIn)}');
    if (a.fadeOut > 0) parts.add('afade=t=out:st=${_n(math.max(0, a.duration - a.fadeOut))}:d=${_n(a.fadeOut)}');
    if (a.start > 0) parts.add('adelay=${(a.start * 1000).round()}:all=1');
    final out = next('a');
    f.add('[$input:a]${parts.join(',')}[$out]');
    audio.add(out);
  }
  final silence = next('a');
  f.add('anullsrc=r=44100:cl=stereo,atrim=0:${_n(total)}[$silence]');
  if (audio.isEmpty) {
    f.add('[$silence]anull[aout]');
  } else {
    f.add('[$silence]${audio.map((a) => '[$a]').join()}'
        'amix=inputs=${audio.length + 1}:normalize=0:dropout_transition=0,atrim=0:${_n(total)}[aout]');
  }

  final graph = f.join(';');
  final codec = switch (s.encoder) {
    'libx264' => ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', const ['26', '21', '17'][s.quality]],
    'mpeg4' => ['-c:v', 'mpeg4', '-q:v', const ['7', '4', '2'][s.quality]],
    _ => [
        '-c:v',
        s.encoder,
        '-b:v',
        '${(s.width * s.height * s.fps * const [0.07, 0.12, 0.2][s.quality] / 1000).round()}k',
      ],
  };
  final args = <String>[
    '-y',
    ...inputs,
    '-filter_complex', graph,
    '-map', '[vout]',
    '-map', '[aout]',
    ...codec,
    '-pix_fmt', 'yuv420p',
    '-r', '${s.fps}',
    '-c:a', 'aac',
    '-b:a', '192k',
    '-t', _n(total),
    '-movflags', '+faststart',
    s.outPath,
  ];
  return FfmpegCommand(args, graph, total);
}
