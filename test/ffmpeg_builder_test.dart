import 'package:flutter_test/flutter_test.dart';
import 'package:one_for_all_studio/video/ffmpeg_builder.dart';
import 'package:one_for_all_studio/video/models.dart';

Clip _video(String path, double dur) =>
    Clip(kind: ClipKind.video, path: path, name: path, srcDuration: dur, srcW: 1920, srcH: 1080, hasAudio: true);

void main() {
  test('two clips with a dissolve, text and music', () {
    final p = Project()
      ..main = [
        _video('a.mp4', 4)..transition = 'fade'..transitionDur = 1,
        _video('b.mp4', 6)..speed = 2,
      ]
      ..texts = [TextItem(text: 'Hi', start: 0.5, duration: 2)..animIn = 'fade']
      ..audios = [AudioItem(path: 'm.mp3', name: 'm', srcDuration: 30)];

    expect(p.duration, closeTo(4 + 3 - 1, 1e-9));
    final cmd = buildExport(
      p,
      const ExportSpec(width: 1080, height: 1920, fps: 30, encoder: 'libx264', outPath: 'out.mp4', textPngs: {}, textRaster: {}),
    );
    final g = cmd.filterGraph;
    expect(g, contains('xfade=transition=fade:duration=1:offset=3'));
    expect(g, contains('atempo=2'));
    expect(g, contains('amix=inputs=4'));
    expect(g, endsWith('[aout]'));
    // Every label that is consumed must be produced exactly once.
    final produced = RegExp(r'\[([a-z]+\d+|vout|aout)\](?=;|$)').allMatches(g).map((m) => m[1]).toList();
    expect(produced.toSet().length, produced.length);
    expect(cmd.args.where((a) => a == '-i').length, 3);
  });

  test('keyframed overlay produces animated expressions', () {
    final o = _video('c.mp4', 5)
      ..start = 1
      ..keys = [Keyframe(0, 0, 0, 0.5, 0), Keyframe(2, 0.2, 0.1, 1, 30)];
    final p = Project()
      ..main = [_video('a.mp4', 5)]
      ..overlays = [o];
    final g = buildExport(
      p,
      const ExportSpec(width: 720, height: 1280, fps: 30, encoder: 'libx264', outPath: 'o.mp4'),
    ).filterGraph;
    expect(g, contains("rotate=a='if(lt((t-1),2)"));
    expect(g, contains('eval=frame'));
    expect(g, contains("enable='between(t,1,6)'"));
  });
}
