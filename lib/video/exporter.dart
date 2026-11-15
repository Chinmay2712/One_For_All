import 'dart:io';
import 'dart:math' as math;

import '../core/media.dart';
import 'ff.dart';
import 'ffmpeg_builder.dart';
import 'models.dart';
import 'text_render.dart';

class VideoExportOptions {
  /// Length of the short side in pixels (480, 720, 1080, 2160).
  final int resolution;
  final int fps;
  final int quality;
  const VideoExportOptions({this.resolution = 1080, this.fps = 30, this.quality = 1});
}

class VideoExporter {
  /// Renders [p] to an MP4 and returns its path, or null on failure
  /// (details in [FF.lastLog]).
  static Future<String?> export(
    Project p,
    VideoExportOptions o, {
    void Function(double fraction)? onProgress,
  }) async {
    if (!FF.available) return null;
    int even(double v) => math.max(2, (v / 2).round() * 2);
    final landscape = p.aspect >= 1;
    final w = even(landscape ? o.resolution * p.aspect : o.resolution.toDouble());
    final h = even(landscape ? o.resolution.toDouble() : o.resolution / p.aspect);

    final pngs = <String, String>{};
    final rasters = <String, double>{};
    for (final t in p.texts) {
      if (t.text.trim().isEmpty) continue;
      final raster = rasterScale(t);
      final path = await FF.workFile('png');
      await TextRender.writePng(t, w.toDouble(), h.toDouble(), raster, path);
      pngs[t.id] = path;
      rasters[t.id] = raster;
    }

    final out = '${await Media.workDir()}/OFA_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final encoders = [
      'libx264',
      Platform.isIOS ? 'h264_videotoolbox' : 'h264_mediacodec',
      'mpeg4',
    ];
    String? result;
    for (final enc in encoders) {
      final cmd = buildExport(
        p,
        ExportSpec(
          width: w,
          height: h,
          fps: o.fps,
          encoder: enc,
          quality: o.quality,
          outPath: out,
          textPngs: pngs,
          textRaster: rasters,
        ),
      );
      final ok = await FF.run(cmd.args, onTime: (t) => onProgress?.call((t / cmd.duration).clamp(0.0, 1.0)));
      if (ok && File(out).existsSync() && File(out).lengthSync() > 1000) {
        result = out;
        break;
      }
      // Only fall through to the next encoder when this one is unavailable.
      if (!FF.lastLog.contains('Unknown encoder') && !FF.lastLog.contains('Encoder not found') && enc == 'libx264') {
        // A graph error will fail the same way with any encoder; still try the
        // hardware encoder once in case the failure was encoder specific.
      }
    }
    for (final f in pngs.values) {
      try {
        File(f).deleteSync();
      } catch (_) {}
    }
    return result;
  }
}
