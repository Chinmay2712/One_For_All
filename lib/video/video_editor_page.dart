import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../app_theme.dart';
import '../core/save.dart';
import '../core/widgets.dart';
import 'clip_factory.dart';
import 'engine.dart';
import 'exporter.dart';
import 'ff.dart';
import 'ffmpeg_builder.dart' show atempoChain;
import 'models.dart';
import 'preview.dart';
import 'timeline.dart';

const _swatches = [
  0xFFFFFFFF, 0xFF000000, 0xFFFFD60A, 0xFFFF8C1A, 0xFFE5383B, 0xFFFF5DA2,
  0xFF9D4EDD, 0xFF3B82F6, 0xFF2EC4C4, 0xFF3FB950, 0xFF9097A3,
];

class VideoEditorPage extends StatefulWidget {
  final Project project;
  const VideoEditorPage({super.key, required this.project});

  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> with SingleTickerProviderStateMixin {
  late Project pr;
  late VideoEngine engine;
  Sel? sel;
  double pps = 60;
  final _history = <String>[];
  int _hi = -1;

  @override
  void initState() {
    super.initState();
    pr = widget.project;
    engine = VideoEngine(pr, this);
    _push();
    warmSampleImage().then((_) {
      if (mounted) setState(() {});
    });
    for (final t in pr.texts) {
      _loadFont(t.font);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => engine.refresh());
  }

  @override
  void dispose() {
    ProjectStore.save(pr);
    engine.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ state flow

  void _live() {
    engine.refresh();
    setState(() {});
  }

  void _commit() {
    _push();
    ProjectStore.save(pr);
    _live();
  }

  void _push() {
    final snap = jsonEncode(pr.toJson());
    if (_hi >= 0 && _history[_hi] == snap) return;
    _history.removeRange(_hi + 1, _history.length);
    _history.add(snap);
    if (_history.length > 80) _history.removeAt(0);
    _hi = _history.length - 1;
  }

  void _restore(int i) {
    _hi = i;
    final next = Project.fromJson(jsonDecode(_history[i]) as Map);
    pr
      ..name = next.name
      ..aspectW = next.aspectW
      ..aspectH = next.aspectH
      ..background = next.background
      ..main = next.main
      ..overlays = next.overlays
      ..texts = next.texts
      ..audios = next.audios;
    if (sel != null && _layerOf(sel!) == null && _selAudio == null) sel = null;
    ProjectStore.save(pr);
    _live();
  }

  void _loadFont(String font) {
    try {
      GoogleFonts.getFont(font);
      GoogleFonts.pendingFonts().then((_) {
        if (mounted) setState(() {});
      });
    } catch (_) {}
  }

  // ------------------------------------------------------------ selection

  Layer? _layerOf(Sel s) => switch (s.kind) {
        'main' => pr.main.where((c) => c.id == s.id).firstOrNull,
        'overlay' => pr.overlays.where((c) => c.id == s.id).firstOrNull,
        'text' => pr.texts.where((c) => c.id == s.id).firstOrNull,
        _ => null,
      };

  Clip? get _selClip => sel == null || (sel!.kind != 'main' && sel!.kind != 'overlay') ? null : _layerOf(sel!) as Clip?;
  TextItem? get _selText => sel?.kind == 'text' ? _layerOf(sel!) as TextItem? : null;
  AudioItem? get _selAudio => sel?.kind == 'audio' ? pr.audios.where((a) => a.id == sel!.id).firstOrNull : null;

  double _startOf(Layer l) {
    if (l is TextItem) return l.start;
    final c = l as Clip;
    final i = pr.main.indexOf(c);
    return i >= 0 ? pr.mainStart(i) : c.start;
  }

  /// Playhead position inside [l], or null when the playhead is outside it.
  double? _localIn(Layer l, {double margin = 0}) {
    final lt = engine.position - _startOf(l);
    return lt > margin && lt < l.duration - margin ? lt : null;
  }

  // ------------------------------------------------------------ adding

  Future<void> _addMedia({bool overlay = false}) async {
    engine.pause();
    final clips = await withProgress(context, 'Importing', (_) => ClipFactory.pick());
    if (clips == null || clips.isEmpty) return;
    _insertClips(clips, overlay: overlay);
  }

  Future<void> _addSample({bool overlay = false}) async {
    _insertClips([await ClipFactory.sample()], overlay: overlay);
  }

  void _insertClips(List<Clip> clips, {required bool overlay}) {
    if (overlay) {
      var at = engine.position;
      for (final c in clips) {
        c
          ..start = at
          ..scale = 0.45
          ..x = 0.22
          ..y = -0.22;
        pr.overlays.add(c);
        at += 0.3;
      }
      sel = Sel('overlay', clips.last.id);
    } else {
      // Insert after the clip under the playhead, or at the end.
      final i = pr.mainIndexAt(engine.position);
      pr.main.insertAll(i < 0 ? pr.main.length : i + 1, clips);
      sel = Sel('main', clips.first.id);
    }
    _commit();
  }

  Future<void> _addAudio() async {
    engine.pause();
    try {
      final a = await ClipFactory.pickAudio(engine.position);
      if (a == null) return;
      pr.audios.add(a);
      sel = Sel('audio', a.id);
      _commit();
    } catch (e) {
      if (mounted) toast(context, 'Could not add that audio file');
    }
  }

  Future<void> _addText() async {
    engine.pause();
    final text = await promptText(context, 'Add text', hint: 'Type something');
    if (text == null || text.isEmpty) return;
    // Start at the playhead, unless that leaves less than a second of video.
    final total = pr.duration;
    final start = total <= 0 ? 0.0 : (total - engine.position >= 1 ? engine.position : math.max(0.0, total - 3));
    final t = TextItem(text: text, start: start, duration: total <= 0 ? 3 : math.min(3.0, total - start));
    if (start != engine.position) engine.seek(start);
    pr.texts.add(t);
    _loadFont(t.font);
    sel = Sel('text', t.id);
    _commit();
  }

  // ------------------------------------------------------------ editing

  void _split() {
    final s = sel;
    if (s == null) return;
    if (s.kind == 'audio') {
      final a = _selAudio!;
      final lt = engine.position - a.start;
      if (lt <= 0.1 || lt >= a.duration - 0.1) return toast(context, 'Move the playhead inside the clip to split');
      final b = a.copy()
        ..inPoint = a.inPoint + lt
        ..start = a.start + lt
        ..fadeIn = 0;
      a
        ..outPoint = a.inPoint + lt
        ..fadeOut = 0;
      pr.audios.add(b);
      return _commit();
    }
    final layer = _layerOf(s);
    if (layer == null) return;
    final lt = _localIn(layer, margin: 0.1);
    if (lt == null) return toast(context, 'Move the playhead inside the clip to split');
    // Keyframes: the second half keeps those after the cut, shifted.
    List<Keyframe> tail() => [
          for (final k in layer.keys)
            if (k.t >= lt) Keyframe(k.t - lt, k.x, k.y, k.scale, k.rotation),
        ];
    if (layer is TextItem) {
      final b = layer.copy()
        ..start = layer.start + lt
        ..duration = layer.duration - lt
        ..animIn = 'none'
        ..keys = tail();
      layer
        ..duration = lt
        ..animOut = 'none'
        ..keys.removeWhere((k) => k.t > lt);
      pr.texts.add(b);
    } else if (layer is Clip) {
      final b = layer.copy()
        ..animIn = 'none'
        ..fadeIn = 0
        ..keys = tail();
      if (layer.isImage) {
        b
          ..outPoint = layer.outPoint - lt
          ..srcDuration = layer.outPoint - lt;
        layer
          ..outPoint = lt
          ..srcDuration = lt;
      } else {
        b.inPoint = layer.inPoint + lt * layer.speed;
        layer.outPoint = b.inPoint;
      }
      layer
        ..animOut = 'none'
        ..fadeOut = 0
        ..transition = 'none'
        ..keys.removeWhere((k) => k.t > lt);
      final i = pr.main.indexOf(layer);
      if (i >= 0) {
        pr.main.insert(i + 1, b);
      } else {
        b.start = layer.start + lt;
        pr.overlays.add(b);
      }
    }
    _commit();
  }

  void _delete() {
    final s = sel;
    if (s == null) return;
    pr.main.removeWhere((c) => c.id == s.id);
    pr.overlays.removeWhere((c) => c.id == s.id);
    pr.texts.removeWhere((c) => c.id == s.id);
    pr.audios.removeWhere((c) => c.id == s.id);
    engine.forget(s.id);
    sel = null;
    _commit();
  }

  void _duplicate() {
    final s = sel;
    if (s == null) return;
    switch (s.kind) {
      case 'main':
        final c = _selClip!;
        final b = c.copy();
        pr.main.insert(pr.main.indexOf(c) + 1, b);
        sel = Sel('main', b.id);
      case 'overlay':
        final c = _selClip!;
        final b = c.copy()..start = c.start + c.duration;
        pr.overlays.add(b);
        sel = Sel('overlay', b.id);
      case 'text':
        final t = _selText!;
        final b = t.copy()..start = t.start + t.duration;
        pr.texts.add(b);
        sel = Sel('text', b.id);
      case 'audio':
        final a = _selAudio!;
        final b = a.copy()..start = a.start + a.duration;
        pr.audios.add(b);
        sel = Sel('audio', b.id);
    }
    _commit();
  }

  void _move(int dir) {
    final c = _selClip;
    if (c == null) return;
    final i = pr.main.indexOf(c);
    final j = i + dir;
    if (i < 0 || j < 0 || j >= pr.main.length) return;
    pr.main
      ..removeAt(i)
      ..insert(j, c);
    engine.seek(pr.mainStart(j));
    _commit();
  }

  void _toggleKeyframe() {
    final layer = sel == null ? null : _layerOf(sel!);
    if (layer == null) return;
    final lt = (engine.position - _startOf(layer)).clamp(0.0, layer.duration);
    final existing = layer.keyNear(lt);
    if (existing != null) {
      // Keep the look when the last keyframe goes away.
      if (layer.keys.length == 1) {
        layer
          ..x = existing.x
          ..y = existing.y
          ..scale = existing.scale
          ..rotation = existing.rotation;
      }
      layer.keys.remove(existing);
    } else {
      layer.setKeyframe(lt);
    }
    _commit();
  }

  // ------------------------------------------------------------ ffmpeg tools

  Future<bool> _needFfmpeg() async {
    if (FF.available) return true;
    toast(context, 'This tool runs on Android and iOS devices');
    return false;
  }

  Future<void> _reverse() async {
    final c = _selClip;
    if (c == null || c.isImage || !await _needFfmpeg()) return;
    final len = c.outPoint - c.inPoint;
    if (len > 30) {
      if (mounted) toast(context, 'Trim the clip to 30 seconds or less to reverse it');
      return;
    }
    final out = await FF.workFile('mp4');
    if (!mounted) return;
    final ok = await withProgress<bool>(context, 'Reversing', (p) {
      return FF.run([
        '-y', '-ss', '${c.inPoint}', '-t', '$len', '-i', c.path,
        '-vf', 'reverse',
        if (c.hasAudio) ...['-af', 'areverse'],
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', out,
      ], onTime: (t) => p.value = (t / len).clamp(0.0, 1.0));
    });
    if (ok != true) {
      if (mounted) toast(context, 'Could not reverse this clip');
      return;
    }
    engine.forget(c.id);
    c
      ..path = out
      ..srcDuration = len
      ..inPoint = 0
      ..outPoint = len
      ..thumb = await FF.thumbnail(out);
    _commit();
  }

  Future<void> _freeze() async {
    final c = _selClip;
    if (c == null || c.isImage || !pr.main.contains(c) || !await _needFfmpeg()) return;
    final lt = _localIn(c, margin: 0.1);
    if (lt == null) {
      if (mounted) toast(context, 'Move the playhead inside the clip to freeze a frame');
      return;
    }
    final out = await FF.workFile('png');
    if (!mounted) return;
    final ok = await withProgress<bool>(context, 'Grabbing frame',
        (_) => FF.run(['-y', '-ss', '${c.inPoint + lt * c.speed}', '-i', c.path, '-frames:v', '1', out]));
    if (ok != true || !File(out).existsSync()) {
      if (mounted) toast(context, 'Could not grab that frame');
      return;
    }
    _split();
    final i = pr.main.indexOf(c);
    final still = Clip(kind: ClipKind.image, path: out, name: 'Freeze', srcDuration: 2, srcW: c.srcW, srcH: c.srcH)
      ..scale = c.scale
      ..x = c.x
      ..y = c.y
      ..rotation = c.rotation
      ..filter = c.filter
      ..filterAmount = c.filterAmount
      ..adjust = Map.of(c.adjust);
    pr.main.insert(i + 1, still);
    sel = Sel('main', still.id);
    _commit();
  }

  Future<void> _extractAudio() async {
    final c = _selClip;
    if (c == null || !c.hasAudio || !await _needFfmpeg()) return;
    final len = c.outPoint - c.inPoint;
    final out = await FF.workFile('m4a');
    if (!mounted) return;
    final ok = await withProgress<bool>(context, 'Extracting audio', (_) {
      final chain = atempoChain(c.speed);
      final tempo = chain.isEmpty ? <String>[] : ['-af', chain.join(',')];
      return FF.run(['-y', '-ss', '${c.inPoint}', '-t', '$len', '-i', c.path, '-vn', ...tempo, '-c:a', 'aac', '-b:a', '192k', out]);
    });
    if (ok != true) {
      if (mounted) toast(context, 'Could not extract the audio');
      return;
    }
    final a = AudioItem(path: out, name: '${c.name} audio', srcDuration: c.duration, start: _startOf(c))
      ..volume = c.volume;
    pr.audios.add(a);
    c.muted = true;
    _commit();
  }

  // ------------------------------------------------------------ sheets

  /// Opens a bottom sheet whose controls edit the project live; closing it
  /// records one undo step.
  Future<void> _sheet(String title, List<Widget> Function(StateSetter refresh) body) async {
    engine.pause();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      barrierColor: Colors.black26,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        void refresh(VoidCallback fn) {
          fn();
          setSheet(() {});
          _live();
        }

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 12 + MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                  IconButton(icon: const Icon(Icons.check, color: AppColors.accent), onPressed: () => Navigator.pop(ctx)),
                ]),
                ...body(refresh),
              ]),
            ),
          ),
        );
      }),
    );
    if (mounted) _commit();
  }

  Widget _wrapPills<T>(Iterable<T> items, String Function(T) label, bool Function(T) selected, void Function(T) onTap) =>
      Wrap(runSpacing: 8, children: [
        for (final it in items) Pill(label: label(it), selected: selected(it), onTap: () => onTap(it)),
      ]);

  void _speedSheet() {
    final c = _selClip;
    if (c == null || c.isImage) return;
    _sheet('Speed', (set) => [
          ParamSlider(
            label: 'Speed',
            // Logarithmic so slow motion gets as much travel as fast.
            value: math.log(c.speed) / math.ln2,
            min: -3,
            max: 3,
            decimals: 2,
            onChanged: (v) => set(() => c.speed = double.parse(math.pow(2, v).toStringAsFixed(2))),
          ),
          Text('${c.speed.toStringAsFixed(2)}x  ·  ${c.duration.toStringAsFixed(1)}s on the timeline',
              style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 10),
          _wrapPills<double>(const [0.25, 0.5, 1, 1.5, 2, 4, 8], (v) => '${v}x', (v) => c.speed == v, (v) => set(() => c.speed = v)),
        ]);
  }

  void _volumeSheet() {
    final c = _selClip;
    final a = _selAudio;
    if (c == null && a == null) return;
    _sheet('Volume', (set) => [
          ParamSlider(
            label: 'Volume',
            value: (c?.volume ?? a!.volume) * 100,
            min: 0,
            max: 200,
            def: 100,
            onChanged: (v) => set(() => c != null ? c.volume = v / 100 : a!.volume = v / 100),
          ),
          ParamSlider(
            label: 'Fade in',
            value: c?.fadeIn ?? a!.fadeIn,
            min: 0,
            max: 5,
            decimals: 1,
            onChanged: (v) => set(() => c != null ? c.fadeIn = v : a!.fadeIn = v),
          ),
          ParamSlider(
            label: 'Fade out',
            value: c?.fadeOut ?? a!.fadeOut,
            min: 0,
            max: 5,
            decimals: 1,
            onChanged: (v) => set(() => c != null ? c.fadeOut = v : a!.fadeOut = v),
          ),
          if (c != null)
            Row(children: [
              Pill(label: c.muted ? 'Muted' : 'Mute clip', selected: c.muted, onTap: () => set(() => c.muted = !c.muted)),
            ]),
          const Text('Above 100% is applied on export; the preview tops out at 100%.',
              style: TextStyle(fontSize: 11.5, color: AppColors.textDim)),
        ]);
  }

  void _filterSheet() {
    final c = _selClip;
    if (c == null) return;
    _sheet('Filters', (set) => [
          _wrapPills<String>(kVideoFilters.keys, (k) => k == 'none' ? 'None' : k, (k) => c.filter == k, (k) => set(() => c.filter = k)),
          const SizedBox(height: 6),
          ParamSlider(
            label: 'Strength',
            value: c.filterAmount * 100,
            min: 0,
            max: 100,
            def: 100,
            onChanged: (v) => set(() => c.filterAmount = v / 100),
          ),
          TextButton(
            onPressed: () => set(() {
              for (final o in pr.main) {
                o
                  ..filter = c.filter
                  ..filterAmount = c.filterAmount;
              }
            }),
            child: const Text('Apply to all clips'),
          ),
        ]);
  }

  void _adjustSheet() {
    final c = _selClip;
    if (c == null) return;
    _sheet('Adjust', (set) => [
          for (final a in kVideoAdjust)
            ParamSlider(
              label: a.$2,
              value: c.adjust[a.$1] ?? 0,
              min: a.$1 == 'fade' ? 0 : -100,
              max: 100,
              onChanged: (v) => set(() => c.adjust[a.$1] = v.roundToDouble()),
            ),
          TextButton(onPressed: () => set(() => c.adjust.clear()), child: const Text('Reset')),
        ]);
  }

  void _transformSheet() {
    final layer = sel == null ? null : _layerOf(sel!);
    if (layer == null) return;
    final c = layer is Clip ? layer : null;
    double lt() => (engine.position - _startOf(layer)).clamp(0.0, layer.duration);
    _sheet('Transform', (set) {
      final p = layer.basePose(lt());
      return [
        ParamSlider(
          label: 'Scale',
          value: p.scale * 100,
          min: 5,
          max: 400,
          def: 100,
          onChanged: (v) => set(() => layer.applyTransform(lt(), ns: v / 100)),
        ),
        ParamSlider(
          label: 'Rotation',
          value: p.rotation,
          min: -180,
          max: 180,
          onChanged: (v) => set(() => layer.applyTransform(lt(), nr: v.roundToDouble())),
        ),
        ParamSlider(
          label: 'Opacity',
          value: layer.opacity * 100,
          min: 0,
          max: 100,
          def: 100,
          onChanged: (v) => set(() => layer.opacity = v / 100),
        ),
        if (c != null)
          ParamSlider(label: 'Blur', value: c.blur, min: 0, max: 100, onChanged: (v) => set(() => c.blur = v.roundToDouble())),
        Row(children: [
          if (c != null) ...[
            Pill(
              label: 'Fill',
              selected: false,
              onTap: () => set(() {
                final src = c.srcW / c.srcH;
                layer.applyTransform(lt(), nx: 0, ny: 0, ns: math.max(pr.aspect / src, src / pr.aspect), nr: 0);
              }),
            ),
            Pill(label: 'Fit', selected: false, onTap: () => set(() => layer.applyTransform(lt(), nx: 0, ny: 0, ns: 1, nr: 0))),
            Pill(label: 'Mirror', selected: c.flipH, onTap: () => set(() => c.flipH = !c.flipH)),
          ],
          Pill(label: 'Centre', selected: false, onTap: () => set(() => layer.applyTransform(lt(), nx: 0, ny: 0))),
        ]),
        if (layer.keys.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('This layer has keyframes: changes are stored at the playhead.',
                style: TextStyle(fontSize: 11.5, color: AppColors.textDim)),
          ),
      ];
    });
  }

  void _animationSheet() {
    final layer = sel == null ? null : _layerOf(sel!);
    if (layer == null) return;
    _sheet('Animation', (set) => [
          const Text('In', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 6),
          _wrapPills<String>(kAnimations.keys, (k) => kAnimations[k]!, (k) => layer.animIn == k, (k) => set(() => layer.animIn = k)),
          const SizedBox(height: 10),
          const Text('Out', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 6),
          _wrapPills<String>(kAnimations.keys, (k) => kAnimations[k]!, (k) => layer.animOut == k, (k) => set(() => layer.animOut = k)),
          ParamSlider(
            label: 'Duration',
            value: layer.animDur,
            min: 0.1,
            max: 2,
            def: 0.5,
            decimals: 1,
            onChanged: (v) => set(() => layer.animDur = v),
          ),
        ]);
  }

  void _transitionSheet(int i) {
    final c = pr.main[i];
    setState(() => sel = null);
    engine.seek(pr.mainStart(i + 1));
    _sheet('Transition', (set) => [
          _wrapPills<String>(kTransitions.keys, (k) => kTransitions[k]!, (k) => c.transition == k, (k) {
            set(() => c.transition = k);
            // Show it: rewind a moment and play through the join.
            engine.seek(math.max(0, pr.mainStart(i + 1) - 0.8));
            engine.play();
          }),
          ParamSlider(
            label: 'Duration',
            value: c.transitionDur,
            min: 0.2,
            max: 2,
            def: 0.6,
            decimals: 1,
            onChanged: (v) => set(() => c.transitionDur = v),
          ),
          TextButton(
            onPressed: () => set(() {
              for (final o in pr.main) {
                o
                  ..transition = c.transition
                  ..transitionDur = c.transitionDur;
              }
            }),
            child: const Text('Apply to all joins'),
          ),
        ]);
  }

  void _canvasSheet() {
    _sheet('Canvas', (set) => [
          const Text('Aspect ratio', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 6),
          _wrapPills<String>(kAspects.keys, (k) => k, (k) => pr.aspectW == kAspects[k]![0] && pr.aspectH == kAspects[k]![1], (k) {
            set(() {
              pr.aspectW = kAspects[k]![0];
              pr.aspectH = kAspects[k]![1];
            });
          }),
          const SizedBox(height: 12),
          const Text('Background', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 6),
          _swatchRow(pr.background, (v) => set(() => pr.background = v)),
        ]);
  }

  Widget _swatchRow(int current, ValueChanged<int> onPick, {bool allowNone = false}) => Wrap(spacing: 8, runSpacing: 8, children: [
        if (allowNone)
          GestureDetector(
            onTap: () => onPick(0),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: (current >> 24) == 0 ? AppColors.accent : AppColors.line, width: 2),
              ),
              child: const Icon(Icons.block, size: 16, color: AppColors.textDim),
            ),
          ),
        for (final c in _swatches)
          GestureDetector(
            onTap: () => onPick(c),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Color(c),
                shape: BoxShape.circle,
                border: Border.all(color: (current | 0xFF000000) == c && (current >> 24) != 0 ? AppColors.accent : AppColors.line, width: 2),
              ),
            ),
          ),
      ]);

  Future<void> _editText() async {
    final t = _selText;
    if (t == null) return;
    final text = await promptText(context, 'Edit text', initial: t.text);
    if (text == null || text.isEmpty) return;
    t.text = text;
    _commit();
  }

  void _styleSheet() {
    final t = _selText;
    if (t == null) return;
    _sheet('Text style', (set) => [
          SizedBox(
            height: 36,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final f in kFonts)
                Pill(
                  label: f,
                  selected: t.font == f,
                  onTap: () {
                    set(() => t.font = f);
                    _loadFont(f);
                  },
                ),
            ]),
          ),
          ParamSlider(label: 'Size', value: t.size * 100, min: 2, max: 25, def: 6, decimals: 1, onChanged: (v) => set(() => t.size = v / 100)),
          ParamSlider(label: 'Outline', value: t.strokeWidth, min: 0, max: 10, decimals: 1, onChanged: (v) => set(() => t.strokeWidth = v)),
          Row(children: [
            Pill(label: 'Bold', selected: t.bold, onTap: () => set(() => t.bold = !t.bold)),
            Pill(label: 'Italic', selected: t.italic, onTap: () => set(() => t.italic = !t.italic)),
            Pill(label: 'Shadow', selected: t.shadow, onTap: () => set(() => t.shadow = !t.shadow)),
            for (final a in const [(0, Icons.format_align_left), (1, Icons.format_align_center), (2, Icons.format_align_right)])
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(a.$2, size: 18, color: t.align == a.$1 ? AppColors.accent : AppColors.text),
                onPressed: () => set(() => t.align = a.$1),
              ),
          ]),
          const SizedBox(height: 4),
          const Text('Text colour', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 6),
          _swatchRow(t.color, (v) => set(() => t.color = v)),
          const SizedBox(height: 10),
          const Text('Outline colour', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 6),
          _swatchRow(t.stroke, (v) => set(() => t.stroke = v)),
          const SizedBox(height: 10),
          const Text('Background', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
          const SizedBox(height: 6),
          _swatchRow(t.background, (v) => set(() => t.background = v == 0 ? 0 : (v & 0x00FFFFFF) | 0xCC000000), allowNone: true),
        ]);
  }

  Future<void> _captions() async {
    engine.pause();
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.subtitles_outlined, color: AppColors.accent),
            title: const Text('Type captions'),
            subtitle: const Text('One line per caption, spread evenly from the playhead to the end.'),
            onTap: () => Navigator.pop(ctx, 'type'),
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined, color: AppColors.accent),
            title: const Text('Import .srt subtitles'),
            subtitle: const Text('Timed captions from a subtitle file.'),
            onTap: () => Navigator.pop(ctx, 'srt'),
          ),
          if (pr.texts.any((t) => t.caption))
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined, color: AppColors.danger),
              title: const Text('Remove all captions'),
              onTap: () => Navigator.pop(ctx, 'clear'),
            ),
        ]),
      ),
    );
    if (!mounted || act == null) return;
    if (act == 'clear') {
      pr.texts.removeWhere((t) => t.caption);
      sel = null;
      return _commit();
    }
    var items = <TextItem>[];
    if (act == 'type') {
      final text = await promptText(context, 'Captions', hint: 'One caption per line');
      if (text == null || text.isEmpty) return;
      final from = engine.position;
      final to = pr.duration > from + 0.5 ? pr.duration : from + 3.0 * text.split('\n').length;
      items = spreadCaptions(text, from, to);
    } else {
      final file = await FilePicker.pickFile(type: FileType.any);
      if (file == null) return;
      items = parseSrt(utf8.decode(await file.xFile.readAsBytes(), allowMalformed: true));
      if (items.isEmpty && mounted) return toast(context, 'No captions found in that file');
    }
    pr.texts.addAll(items);
    _commit();
  }

  Future<void> _rename() async {
    final name = await promptText(context, 'Project name', initial: pr.name);
    if (name == null || name.isEmpty) return;
    pr.name = name;
    _commit();
  }

  // ------------------------------------------------------------ export

  Future<void> _export() async {
    engine.pause();
    if (pr.duration <= 0) return toast(context, 'Add a clip first');
    var res = 1080, fps = 30, quality = 1;
    final go = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Export video', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              const Text('Resolution', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              const SizedBox(height: 6),
              Row(children: [
                for (final r in const [(480, '480p'), (720, '720p'), (1080, '1080p'), (2160, '4K')])
                  Pill(label: r.$2, selected: res == r.$1, onTap: () => setSheet(() => res = r.$1)),
              ]),
              const SizedBox(height: 10),
              const Text('Frame rate', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              const SizedBox(height: 6),
              Row(children: [
                for (final f in const [24, 25, 30, 50, 60])
                  Pill(label: '$f', selected: fps == f, onTap: () => setSheet(() => fps = f)),
              ]),
              const SizedBox(height: 10),
              const Text('Quality', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              const SizedBox(height: 6),
              Row(children: [
                for (final q in const [(0, 'Smaller file'), (1, 'Balanced'), (2, 'Best')])
                  Pill(label: q.$2, selected: quality == q.$1, onTap: () => setSheet(() => quality = q.$1)),
              ]),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('Export  ·  ${formatTime(pr.duration)}'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    if (go != true || !mounted) return;
    if (!FF.available) {
      return toast(context, 'Video export runs on Android and iOS devices');
    }
    final path = await withProgress<String?>(
      context,
      'Exporting',
      (p) => VideoExporter.export(
        pr,
        VideoExportOptions(resolution: res, fps: fps, quality: quality),
        onProgress: (f) => p.value = f,
      ),
    );
    if (!mounted) return;
    if (path == null) {
      final tail = FF.lastLog.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Export failed', style: TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Text(tail.skip(math.max(0, tail.length - 8)).join('\n'), style: const TextStyle(fontSize: 11.5)),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
      return;
    }
    String msg;
    try {
      msg = await Saver.saveVideo(path);
    } catch (e) {
      msg = 'Exported, but could not save to the gallery: $e';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 6),
      // Snack bars with an action stay up by default; this one covers the toolbar.
      persist: false,
      action: SnackBarAction(label: 'Share', onPressed: () => Saver.shareFile(path)),
    ));
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: GestureDetector(
          onTap: _rename,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(pr.name, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            const Icon(Icons.edit, size: 13, color: AppColors.textDim),
          ]),
        ),
        actions: [
          IconButton(tooltip: 'Undo', icon: const Icon(Icons.undo, size: 20), onPressed: _hi > 0 ? () => _restore(_hi - 1) : null),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo, size: 20),
            onPressed: _hi < _history.length - 1 ? () => _restore(_hi + 1) : null,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10, left: 4),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 34),
              ),
              onPressed: _export,
              child: const Text('Export'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(children: [
          Expanded(
            flex: 11,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: VideoPreview(
                engine: engine,
                selection: sel,
                onSelect: (s) => setState(() => sel = s),
                onTransformLive: () => setState(() {}),
                onTransformEnd: _commit,
              ),
            ),
          ),
          _transport(),
          Expanded(
            flex: 8,
            child: Container(
              color: AppColors.surface,
              child: TimelineView(
                engine: engine,
                selection: sel,
                pps: pps,
                onSelect: (s) => setState(() => sel = s),
                onLive: _live,
                onCommit: _commit,
                onTransitionTap: _transitionSheet,
              ),
            ),
          ),
          _toolbar(),
        ]),
      ),
    );
  }

  Widget _transport() {
    final layer = sel == null ? null : _layerOf(sel!);
    return AnimatedBuilder(
      animation: engine,
      builder: (context, _) {
        final onKey = layer != null && layer.keyNear((engine.position - _startOf(layer)).clamp(0.0, layer.duration)) != null;
        return SizedBox(
          height: 42,
          child: Row(children: [
            const SizedBox(width: 12),
            SizedBox(
              width: 112,
              child: Text(
                '${formatTime(engine.position)} / ${formatTime(engine.duration)}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.textDim, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(engine.playing ? Icons.pause : Icons.play_arrow, size: 28),
              onPressed: engine.toggle,
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Keyframe at playhead',
              visualDensity: VisualDensity.compact,
              icon: Icon(onKey ? Icons.diamond : Icons.diamond_outlined, size: 19, color: layer == null ? AppColors.line : (onKey ? AppColors.accent : AppColors.text)),
              onPressed: layer == null ? null : _toggleKeyframe,
            ),
            IconButton(
              tooltip: 'Zoom out',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.zoom_out, size: 19),
              onPressed: () => setState(() => pps = math.max(8, pps / 1.5)),
            ),
            IconButton(
              tooltip: 'Zoom in',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.zoom_in, size: 19),
              onPressed: () => setState(() => pps = math.min(480, pps * 1.5)),
            ),
            const SizedBox(width: 4),
          ]),
        );
      },
    );
  }

  Widget _toolbar() {
    final clip = _selClip;
    final text = _selText;
    final audio = _selAudio;
    final List<(IconData, String, VoidCallback?)> tools;
    if (clip != null) {
      final isMain = pr.main.contains(clip);
      final video = !clip.isImage;
      tools = [
        (Icons.content_cut, 'Split', _split),
        if (video) (Icons.speed, 'Speed', _speedSheet),
        if (video) (Icons.volume_up_outlined, 'Volume', _volumeSheet),
        (Icons.animation, 'Animation', _animationSheet),
        (Icons.filter_vintage_outlined, 'Filters', _filterSheet),
        (Icons.tune, 'Adjust', _adjustSheet),
        (Icons.open_with, 'Transform', _transformSheet),
        if (video) (Icons.fast_rewind_outlined, 'Reverse', _reverse),
        if (video && isMain) (Icons.ac_unit, 'Freeze', _freeze),
        if (video && clip.hasAudio && !clip.muted) (Icons.graphic_eq, 'Extract audio', _extractAudio),
        if (isMain) (Icons.arrow_back, 'Move left', () => _move(-1)),
        if (isMain) (Icons.arrow_forward, 'Move right', () => _move(1)),
        (Icons.copy, 'Duplicate', _duplicate),
        (Icons.delete_outline, 'Delete', _delete),
      ];
    } else if (text != null) {
      tools = [
        (Icons.edit_outlined, 'Edit', _editText),
        (Icons.text_fields, 'Style', _styleSheet),
        (Icons.animation, 'Animation', _animationSheet),
        (Icons.open_with, 'Transform', _transformSheet),
        (Icons.content_cut, 'Split', _split),
        (Icons.copy, 'Duplicate', _duplicate),
        (Icons.delete_outline, 'Delete', _delete),
      ];
    } else if (audio != null) {
      tools = [
        (Icons.content_cut, 'Split', _split),
        (Icons.volume_up_outlined, 'Volume', _volumeSheet),
        (Icons.copy, 'Duplicate', _duplicate),
        (Icons.delete_outline, 'Delete', _delete),
      ];
    } else {
      tools = [
        (Icons.add_box_outlined, 'Add media', _addMedia),
        (Icons.landscape_outlined, 'Sample clip', _addSample),
        (Icons.music_note_outlined, 'Audio', _addAudio),
        (Icons.title, 'Text', _addText),
        (Icons.picture_in_picture_alt_outlined, 'Overlay', () => _addMedia(overlay: true)),
        (Icons.closed_caption_outlined, 'Captions', _captions),
        (Icons.aspect_ratio, 'Canvas', _canvasSheet),
      ];
    }
    return Container(
      decoration: const BoxDecoration(color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.line))),
      child: Row(children: [
        if (sel != null)
          IconButton(
            tooltip: 'Back to main tools',
            icon: const Icon(Icons.keyboard_arrow_left),
            onPressed: () => setState(() => sel = null),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(children: [
              for (final t in tools)
                ToolButton(
                  icon: t.$1,
                  label: t.$2,
                  onTap: t.$3,
                  color: t.$2 == 'Delete' ? AppColors.danger : null,
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
