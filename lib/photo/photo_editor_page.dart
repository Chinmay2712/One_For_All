import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../core/media.dart';
import '../core/save.dart';
import '../core/widgets.dart';
import 'ai_segment.dart';
import 'curve_editor.dart';
import 'develop_renderer.dart';
import 'develop_settings.dart';
import 'photo_canvas.dart';
import 'photo_library.dart';
import 'presets.dart';

enum _Tool { presets, crop, light, color, mix, grading, curve, effects, detail, masks, heal, ai }

/// Copied look, shared between photos (copy / paste settings, batch edit).
class PhotoClipboard {
  static DevelopSettings? look;
}

class PhotoEditorPage extends StatefulWidget {
  final PhotoDoc doc;
  const PhotoEditorPage({super.key, required this.doc});

  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  ui.Image? _image;
  DevelopAssets? _assets;
  DevelopAssets? _plainAssets;
  late DevelopSettings _s;
  late ui.FragmentShader _shader;
  String? _error;

  final _history = <String>[];
  int _hi = -1;

  _Tool _tool = _Tool.light;
  bool _compare = false;
  bool _showHist = true;
  Histogram? _hist;
  Timer? _histTimer;
  Timer? _saveTimer;

  int _mask = -1;
  bool _overlay = true;
  double _brush = 0.06;
  bool _erase = false;
  List<ui.Image?> _subjects = [];

  int _spot = -1;
  double _spotR = 0.03;
  bool _healBusy = false;
  bool _healPending = false;

  int _band = 0;
  String _zone = 'gs';
  String _presetGroup = 'Colour';
  final _presetThumbs = <String, ui.Image>{};
  bool _thumbsStarted = false;
  int _lutGen = 0;

  @override
  void initState() {
    super.initState();
    _s = widget.doc.settings.copy();
    _load();
  }

  @override
  void dispose() {
    _histTimer?.cancel();
    _saveTimer?.cancel();
    _persist();
    super.dispose();
  }

  String _step = 'Starting';
  final _clock = Stopwatch()..start();

  /// Runs one loading step, showing its name on screen and turning a hang
  /// into a visible error instead of an endless spinner.
  Future<T> _stage<T>(String name, Future<T> Function() run) async {
    if (mounted) setState(() => _step = name);
    try {
      return await run().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw 'Stuck for 30s at: $name';
    } finally {
      debugPrint('OFA load: $name done at ${_clock.elapsedMilliseconds}ms');
    }
  }

  Future<void> _load() async {
    try {
      await _stage('Preparing the editing engine', DevelopRenderer.init);
      _shader = DevelopRenderer.newShader();
      final image = await _stage('Opening the photo', () => Media.load(widget.doc.path, maxEdge: 2048));
      _subjects = await _stage('Reading masks', () => DevelopRenderer.decodeSubjects(_s.masks));
      final assets = await _stage('Setting up the image (${image.width}x${image.height})', () => DevelopRenderer.prepare(image, _s));
      // Probe: a tiny render must contain visible pixels, otherwise the GPU
      // shader is producing nothing on this device and we say so.
      await _stage('Testing the GPU renderer', () async {
        final probe = await DevelopRenderer.render(assets, _s, maxEdge: 16);
        final px = (await probe.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        probe.dispose();
        var seen = 0;
        for (var i = 0; i + 3 < px.length; i += 4) {
          seen += px[i + 3] > 0 ? 1 : 0;
        }
        debugPrint('OFA probe visible pixels: $seen of ${px.length ~/ 4}');
        if (seen == 0) throw 'The GPU shader drew nothing (blank output) on this device';
      });
      if (!mounted) return;
      setState(() {
        _image = image;
        _assets = assets;
        _plainAssets = DevelopAssets(image, DevelopRenderer.identityLut, DevelopRenderer.blackMask);
      });
      _pushHistory();
      _scheduleHist();
    } catch (e, st) {
      if (mounted) setState(() => _error = 'Could not open this photo.\nAt: $_step\n$e\n\n${st.toString().split('\n').take(6).join('\n')}');
    }
  }

  // ------------------------------------------------------------ state flow

  void _live() {
    setState(() {});
    _scheduleHist();
  }

  void _commit() {
    _pushHistory();
    _scheduleHist();
  }

  void _pushHistory() {
    final snap = jsonEncode(_s.toJson());
    if (_hi >= 0 && _history[_hi] == snap) return;
    _history.removeRange(_hi + 1, _history.length);
    _history.add(snap);
    if (_history.length > 60) _history.removeAt(0);
    _hi = _history.length - 1;
    if (mounted) setState(() {});
    // Autosave shortly after each change so a killed app keeps the edit.
    if (_hi > 0) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 800), _persist);
    }
  }

  Future<void> _restore(int index) async {
    _hi = index;
    _s = DevelopSettings.fromJson(jsonDecode(_history[index]) as Map<String, dynamic>);
    _mask = math.min(_mask, _s.masks.length - 1);
    _spot = math.min(_spot, _s.spots.length - 1);
    await _rebuildAll();
  }

  Future<void> _rebuildAll() async {
    _subjects = await DevelopRenderer.decodeSubjects(_s.masks);
    final assets = await DevelopRenderer.prepare(_image!, _s);
    if (!mounted) return;
    setState(() => _assets = assets);
    _scheduleHist();
  }

  void _scheduleHist() {
    if (!_showHist) return;
    _histTimer?.cancel();
    _histTimer = Timer(const Duration(milliseconds: 180), () async {
      final a = _assets;
      if (a == null) return;
      final h = await DevelopRenderer.histogram(a, _s);
      if (mounted) setState(() => _hist = h);
    });
  }

  void _rebuildLut() {
    final gen = ++_lutGen;
    final fut = _s.hasCurve
        ? DevelopRenderer.buildCurveLut(_s.curves)
        : Future.value(DevelopRenderer.identityLut);
    fut.then((lut) {
      if (!mounted || gen != _lutGen) return;
      setState(() => _assets = DevelopAssets(_assets!.base, lut, _assets!.mask));
      _scheduleHist();
    });
  }

  void _rebuildMaskTexture() {
    final a = _assets!;
    final image = _image!;
    while (_subjects.length < _s.masks.length) {
      _subjects.add(null);
    }
    final tex = _s.masks.any((m) => m.usesTexture)
        ? DevelopRenderer.buildMaskTexture(
            Size(image.width.toDouble(), image.height.toDouble()), _s.masks, _subjects)
        : DevelopRenderer.blackMask;
    _assets = DevelopAssets(a.base, a.lut, tex);
  }

  Future<void> _rebuildHealing() async {
    if (_healBusy) {
      _healPending = true;
      return;
    }
    _healBusy = true;
    do {
      _healPending = false;
      final base = await DevelopRenderer.applyHealing(_image!, _s.spots);
      if (!mounted) return;
      setState(() => _assets = DevelopAssets(base, _assets!.lut, _assets!.mask));
    } while (_healPending);
    _healBusy = false;
    _scheduleHist();
  }

  void _canvasLive(String what) {
    if (what == 'stroke') _rebuildMaskTexture();
    if (what == 'spots') _rebuildHealing();
    _live();
  }

  Future<void> _persist() async {
    final doc = widget.doc..settings = _s.copy();
    await PhotoLibrary.save(doc);
    final a = _assets;
    if (a != null) {
      final thumb = await DevelopRenderer.render(a, _s, maxEdge: 360);
      await PhotoLibrary.storeThumb(doc.id, thumb);
    }
  }

  void _set(String id, double v) {
    _s[id] = v;
    _s.presetName = null;
    _live();
  }

  // ------------------------------------------------------------ actions

  Future<void> _auto() async {
    final h = await DevelopRenderer.histogram(_plainAssets!, _s.geometryOnly());
    var total = 0.0;
    for (final v in h.l) {
      total += v;
    }
    double pct(double p) {
      var acc = 0.0;
      for (var i = 0; i < h.l.length; i++) {
        acc += h.l[i];
        if (acc >= total * p) return i / (h.l.length - 1);
      }
      return 1;
    }

    final lo = pct(0.02), mid = pct(0.5), hi = pct(0.98);
    _s['exposure'] = (math.log(0.46 / math.max(mid, 0.05)) / math.ln2 * 0.6).clamp(-1.2, 1.2);
    _s['blacks'] = (-(lo - 0.03) * 150).clamp(-40.0, 30.0).roundToDouble();
    _s['whites'] = ((0.95 - hi) * 150).clamp(-30.0, 45.0).roundToDouble();
    _s['contrast'] = 8;
    _s['highlights'] = hi > 0.9 ? -22 : -6;
    _s['shadows'] = lo < 0.08 ? 20 : 8;
    _s['vibrance'] = 12;
    _s.presetName = null;
    _live();
    _commit();
  }

  void _applyPreset(Preset p) {
    p.applyTo(_s);
    _rebuildLut();
    _live();
    _commit();
  }

  Future<void> _savePreset() async {
    final name = await promptText(context, 'Save preset', hint: 'Preset name');
    if (name == null || name.isEmpty) return;
    await UserPresets.save(Preset.fromSettings(name, _s));
    _thumbsStarted = false;
    if (mounted) {
      setState(() => _presetGroup = 'Yours');
      toast(context, 'Preset "$name" saved');
      _ensurePresetThumbs();
    }
  }

  Future<void> _importPreset() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    final bytes = await file.xFile.readAsBytes();
    final p = await UserPresets.importJson(utf8.decode(bytes, allowMalformed: true));
    if (!mounted) return;
    if (p == null) {
      toast(context, 'That file is not a preset');
      return;
    }
    _thumbsStarted = false;
    setState(() => _presetGroup = 'Yours');
    _ensurePresetThumbs();
    toast(context, 'Imported "${p.name}"');
  }

  Future<void> _presetMenu(Preset p) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.ios_share), title: const Text('Share preset file'), onTap: () => Navigator.pop(ctx, 'share')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete preset'), onTap: () => Navigator.pop(ctx, 'delete')),
        ]),
      ),
    );
    if (act == 'share') {
      final safe = p.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      await Saver.shareBytes(Uint8List.fromList(utf8.encode(UserPresets.exportJson(p))), '$safe.preset.json');
    } else if (act == 'delete') {
      await UserPresets.delete(p.id!);
      if (mounted) setState(() {});
    }
  }

  Future<void> _ensurePresetThumbs() async {
    if (_thumbsStarted || _image == null) return;
    _thumbsStarted = true;
    final small = await DevelopRenderer.renderFinal(_image!, DevelopSettings(), maxEdge: 220);
    for (final p in [...kBuiltInPresets, ...UserPresets.all()]) {
      final key = p.id ?? p.name;
      if (_presetThumbs.containsKey(key)) continue;
      final s = _s.geometryOnly();
      p.applyTo(s);
      final img = await DevelopRenderer.renderFinal(small, s, maxEdge: 220);
      if (!mounted) return;
      setState(() => _presetThumbs[key] = img);
    }
  }

  void _addMask(MaskType type) {
    if (_s.masks.length >= kMaxMasks) {
      toast(context, 'Up to $kMaxMasks masks per photo');
      return;
    }
    final ar = _image!.width / _image!.height;
    _s.masks.add(PhotoMask(
      type: type,
      geo: type == MaskType.radial ? [0.5, 0.5, 0.28, 0.28 / math.max(ar, 1) * math.min(ar, 1)] : [0.5, 0.2, 0.5, 0.6],
      adjust: {'exposure': type == MaskType.brush ? 0.6 : -0.8},
    ));
    _subjects.add(null);
    _mask = _s.masks.length - 1;
    _rebuildMaskTexture();
    _live();
    _commit();
  }

  Future<void> _addSubjectMask() async {
    if (!AiSegmenter.supported) {
      toast(context, 'Person selection runs on Android and iOS devices');
      return;
    }
    if (_s.masks.length >= kMaxMasks) {
      toast(context, 'Up to $kMaxMasks masks per photo');
      return;
    }
    final mask = await withProgress(context, 'Finding the person', (_) => AiSegmenter.personMask(widget.doc.path));
    if (!mounted) return;
    if (mask == null) {
      toast(context, 'No person found in this photo');
      return;
    }
    final png = await AiSegmenter.encodeMask(mask);
    _s.masks.add(PhotoMask(type: MaskType.subject, subjectPng: png, adjust: {'exposure': 0.5}));
    _subjects = await DevelopRenderer.decodeSubjects(_s.masks);
    _mask = _s.masks.length - 1;
    _rebuildMaskTexture();
    setState(() => _tool = _Tool.masks);
    _commit();
  }

  Future<void> _removeBackground() async {
    if (!AiSegmenter.supported) {
      toast(context, 'Background removal runs on Android and iOS devices');
      return;
    }
    final msg = await withProgress<String?>(context, 'Removing background', (_) async {
      final mask = await AiSegmenter.personMask(widget.doc.path);
      if (mask == null) return null;
      final full = await Media.load(widget.doc.path);
      final developed = await DevelopRenderer.renderFinal(full, _s.copy()..crop = const Rect.fromLTRB(0, 0, 1, 1)..turns = 0..flipH = false..flipV = false..straighten = 0);
      final png = await AiSegmenter.cutOut(developed, mask);
      return Saver.saveImage(png, 'cutout_${DateTime.now().millisecondsSinceEpoch}.png');
    });
    if (mounted) toast(context, msg ?? 'No person found in this photo');
  }

  void _rotate(int dir) {
    if (dir > 0) {
      _s.turns = (_s.turns + 1) % 4;
      _s.crop = Geo.rotateCropCw(_s.crop);
    } else {
      _s.turns = (_s.turns + 3) % 4;
      for (var i = 0; i < 3; i++) {
        _s.crop = Geo.rotateCropCw(_s.crop);
      }
    }
    if (_s.aspect != null) _s.aspect = 1 / _s.aspect!;
    _live();
    _commit();
  }

  void _flip(bool horizontal) {
    // Flip what the user sees: after a quarter turn the image axes are swapped.
    final imageH = horizontal != _s.turns.isOdd;
    if (imageH) {
      _s.flipH = !_s.flipH;
    } else {
      _s.flipV = !_s.flipV;
    }
    _s.crop = horizontal ? Geo.flipCropH(_s.crop) : Geo.flipCropV(_s.crop);
    _s.straighten = -_s.straighten;
    _live();
    _commit();
  }

  void _setAspect(double? ratio) {
    _s.aspect = ratio;
    if (ratio != null) {
      final f = Geo.oriented(Size(_image!.width.toDouble(), _image!.height.toDouble()), _s.turns);
      final an = ratio * f.height / f.width; // width/height in normalised units
      var w = 1.0, h = 1.0 / an;
      if (h > 1) {
        h = 1;
        w = an;
      }
      _s.crop = Rect.fromCenter(center: const Offset(0.5, 0.5), width: w, height: h);
    }
    _live();
    _commit();
  }

  Future<void> _export() async {
    final o = await showExportSheet(context);
    if (o == null || !mounted) return;
    try {
      final msg = await withProgress(context, 'Exporting', (_) async {
        final bytes = await PhotoExport.renderFile(widget.doc.path, _s, o);
        return Saver.saveImage(bytes, 'OFA_${DateTime.now().millisecondsSinceEpoch}.${o.ext}');
      });
      if (mounted && msg != null) toast(context, msg);
    } catch (e) {
      if (mounted) toast(context, 'Export failed: $e');
    }
  }

  void _menu(String action) {
    switch (action) {
      case 'copy':
        PhotoClipboard.look = _s.copy();
        toast(context, 'Settings copied');
      case 'paste':
        final look = PhotoClipboard.look;
        if (look == null) {
          toast(context, 'Nothing copied yet');
          return;
        }
        _s.applyLook(look);
        _rebuildLut();
        _live();
        _commit();
      case 'preset':
        _savePreset();
      case 'reset':
        _s = DevelopSettings();
        _mask = -1;
        _spot = -1;
        _rebuildAll();
        _commit();
    }
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(appBar: AppBar(), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))));
    }
    final ready = _assets != null;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Text(widget.doc.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Undo',
            icon: const Icon(Icons.undo, size: 20),
            onPressed: ready && _hi > 0 ? () => _restore(_hi - 1) : null,
          ),
          IconButton(
            tooltip: 'Redo',
            icon: const Icon(Icons.redo, size: 20),
            onPressed: ready && _hi < _history.length - 1 ? () => _restore(_hi + 1) : null,
          ),
          GestureDetector(
            onTapDown: (_) => setState(() => _compare = true),
            onTapUp: (_) => setState(() => _compare = false),
            onTapCancel: () => setState(() => _compare = false),
            child: Tooltip(
              message: 'Hold to see the original',
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(Icons.compare, size: 20, color: _compare ? AppColors.accent : AppColors.text),
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: _menu,
            color: AppColors.surfaceHi,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy', child: Text('Copy settings')),
              PopupMenuItem(value: 'paste', child: Text('Paste settings')),
              PopupMenuItem(value: 'preset', child: Text('Save as preset')),
              PopupMenuItem(value: 'reset', child: Text('Reset all edits')),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 34),
              ),
              onPressed: ready ? _export : null,
              child: const Text('Export'),
            ),
          ),
        ],
      ),
      body: !ready
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: AppColors.accent),
                const SizedBox(height: 16),
                Text(_step, style: const TextStyle(color: AppColors.textDim)),
              ]),
            )
          : SafeArea(
              top: false,
              child: Column(children: [
                Expanded(child: _canvasArea()),
                Container(
                  color: AppColors.surface,
                  constraints: const BoxConstraints(maxHeight: 236),
                  width: double.infinity,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                    child: _panel(),
                  ),
                ),
                _toolBar(),
              ]),
            ),
    );
  }

  Widget _canvasArea() {
    final mode = _compare
        ? CanvasMode.view
        : switch (_tool) {
            _Tool.crop => CanvasMode.crop,
            _Tool.masks => _mask >= 0 ? CanvasMode.mask : CanvasMode.view,
            _Tool.heal => CanvasMode.heal,
            _ => CanvasMode.view,
          };
    return Stack(children: [
      Positioned.fill(
        child: PhotoCanvas(
          assets: _compare ? _plainAssets! : _assets!,
          settings: _compare ? _s.geometryOnly() : _s,
          shader: _shader,
          mode: mode,
          maskIndex: _mask,
          showMaskOverlay: _overlay,
          brushRadius: _brush,
          brushErase: _erase,
          spotIndex: _spot,
          spotRadius: _spotR,
          onLive: _canvasLive,
          onCommit: (_) => _commit(),
          onSelectSpot: (i) => setState(() => _spot = i),
        ),
      ),
      Positioned(
        top: 8,
        right: 8,
        child: GestureDetector(
          onTap: () {
            setState(() => _showHist = !_showHist);
            _scheduleHist();
          },
          child: _showHist
              ? HistogramView(data: _hist)
              : Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(6)),
                  child: const Icon(Icons.bar_chart, size: 18, color: AppColors.textDim),
                ),
        ),
      ),
      if (_compare)
        const Positioned(
          top: 10,
          left: 10,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color(0xB0000000), borderRadius: BorderRadius.all(Radius.circular(4))),
            child: Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Text('Original', style: TextStyle(fontSize: 12))),
          ),
        ),
    ]);
  }

  Widget _toolBar() {
    const tools = [
      (_Tool.presets, Icons.auto_awesome_motion, 'Presets'),
      (_Tool.crop, Icons.crop_rotate, 'Crop'),
      (_Tool.light, Icons.wb_sunny_outlined, 'Light'),
      (_Tool.color, Icons.thermostat, 'Colour'),
      (_Tool.mix, Icons.palette_outlined, 'Mix'),
      (_Tool.grading, Icons.gradient, 'Grading'),
      (_Tool.curve, Icons.show_chart, 'Curve'),
      (_Tool.effects, Icons.blur_on, 'Effects'),
      (_Tool.detail, Icons.details, 'Detail'),
      (_Tool.masks, Icons.filter_tilt_shift, 'Masking'),
      (_Tool.heal, Icons.healing, 'Heal'),
      (_Tool.ai, Icons.auto_fix_high, 'AI'),
    ];
    return Container(
      decoration: const BoxDecoration(color: AppColors.bg, border: Border(top: BorderSide(color: AppColors.line))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(children: [
          for (final t in tools)
            ToolButton(
              icon: t.$2,
              label: t.$3,
              selected: _tool == t.$1,
              onTap: () {
                setState(() => _tool = t.$1);
                if (t.$1 == _Tool.presets) _ensurePresetThumbs();
              },
            ),
        ]),
      ),
    );
  }

  Widget _sliders(List<ParamSpec> specs, {Map<String, List<Color>> tracks = const {}}) => Column(children: [
        for (final p in specs)
          ParamSlider(
            label: p.label,
            value: _s[p.id],
            min: p.min,
            max: p.max,
            def: p.def,
            decimals: p.id == 'exposure' ? 2 : 0,
            track: tracks[p.id],
            onChanged: (v) => _set(p.id, v),
            onChangeEnd: _commit,
          ),
      ]);

  Widget _panel() {
    switch (_tool) {
      case _Tool.light:
        return Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _auto,
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Auto'),
            ),
          ),
          _sliders(P.light),
        ]);
      case _Tool.color:
        return Column(children: [
          Row(children: [
            Pill(label: 'Colour', selected: !_s.bw, onTap: () => _toggleBw(false)),
            Pill(label: 'B&W', selected: _s.bw, onTap: () => _toggleBw(true)),
          ]),
          _sliders(P.color, tracks: const {
            'temp': [Color(0xFF3B82F6), Color(0xFFFFD60A)],
            'tint': [Color(0xFF3FB950), Color(0xFFE64CB8)],
          }),
        ]);
      case _Tool.effects:
        return _sliders(P.effects);
      case _Tool.detail:
        return _sliders(P.detail);
      case _Tool.mix:
        return _mixPanel();
      case _Tool.grading:
        return _gradingPanel();
      case _Tool.curve:
        return SizedBox(
          height: 210,
          child: CurveEditor(
            settings: _s,
            onChanged: () {
              _s.presetName = null;
              _rebuildLut();
            },
            onCommit: _commit,
          ),
        );
      case _Tool.presets:
        return _presetPanel();
      case _Tool.crop:
        return _cropPanel();
      case _Tool.masks:
        return _maskPanel();
      case _Tool.heal:
        return _healPanel();
      case _Tool.ai:
        return _aiPanel();
    }
  }

  void _toggleBw(bool on) {
    _s.bw = on;
    _s.presetName = null;
    _live();
    _commit();
  }

  Widget _mixPanel() => Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          for (var i = 0; i < 8; i++)
            GestureDetector(
              onTap: () => setState(() => _band = i),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: kHslColors[i],
                  shape: BoxShape.circle,
                  border: Border.all(color: _band == i ? Colors.white : Colors.transparent, width: 2.5),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 4),
        Text(kHslBands[_band], style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
        _sliders([
          ParamSpec('hue$_band', 'Hue', -100, 100),
          ParamSpec('sat$_band', 'Saturation', -100, 100),
          ParamSpec('lum$_band', 'Luminance', -100, 100),
        ]),
      ]);

  Widget _gradingPanel() {
    const zones = {'gs': 'Shadows', 'gm': 'Midtones', 'gh': 'Highlights'};
    const rainbow = [
      Color(0xFFFF0000), Color(0xFFFFFF00), Color(0xFF00FF00), Color(0xFF00FFFF),
      Color(0xFF0000FF), Color(0xFFFF00FF), Color(0xFFFF0000),
    ];
    return Column(children: [
      Row(children: [
        for (final z in zones.entries)
          Pill(label: z.value, selected: _zone == z.key, onTap: () => setState(() => _zone = z.key)),
      ]),
      _sliders([
        ParamSpec('${_zone}H', 'Hue', 0, 360),
        ParamSpec('${_zone}S', 'Saturation', 0, 100),
        ParamSpec('${_zone}L', 'Luminance', -100, 100),
        const ParamSpec('gBlend', 'Blending', 0, 100, 50),
        const ParamSpec('gBal', 'Balance', -100, 100),
      ], tracks: {'${_zone}H': rainbow}),
    ]);
  }

  Widget _presetPanel() {
    final user = UserPresets.all();
    final list = _presetGroup == 'Yours' ? user : kBuiltInPresets.where((p) => p.group == _presetGroup).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final g in kPresetGroups)
            Pill(label: g, selected: _presetGroup == g, onTap: () => setState(() => _presetGroup = g)),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 112,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          if (_presetGroup == 'Yours') ...[
            _presetAction(Icons.add, 'Save current', _savePreset),
            _presetAction(Icons.file_download_outlined, 'Import', _importPreset),
          ],
          for (final p in list)
            GestureDetector(
              onTap: () => _applyPreset(p),
              onLongPress: p.id == null ? null : () => _presetMenu(p),
              child: Container(
                width: 84,
                margin: const EdgeInsets.only(right: 8),
                child: Column(children: [
                  Container(
                    width: 84,
                    height: 84,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceHi,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _s.presetName == p.name ? AppColors.accent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: _presetThumbs[p.id ?? p.name] == null
                        ? null
                        : RawImage(image: _presetThumbs[p.id ?? p.name], fit: BoxFit.cover),
                  ),
                  const SizedBox(height: 5),
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                ]),
              ),
            ),
          if (_presetGroup == 'Yours' && user.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(left: 8),
                child: Text('Your saved presets appear here.\nLong-press one to share or delete it.',
                    style: TextStyle(fontSize: 12, color: AppColors.textDim)),
              ),
            ),
        ]),
      ),
    ]);
  }

  Widget _presetAction(IconData icon, String label, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 84,
          margin: const EdgeInsets.only(right: 8),
          child: Column(children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.line),
              ),
              child: Icon(icon, color: AppColors.accent),
            ),
            const SizedBox(height: 5),
            Text(label, style: const TextStyle(fontSize: 11)),
          ]),
        ),
      );

  Widget _cropPanel() {
    final image = Size(_image!.width.toDouble(), _image!.height.toDouble());
    final f = Geo.oriented(image, _s.turns);
    final ratios = <(String, double?)>[
      ('Free', null),
      ('Original', f.width / f.height),
      ('1:1', 1),
      ('4:5', 4 / 5),
      ('5:4', 5 / 4),
      ('3:4', 3 / 4),
      ('4:3', 4 / 3),
      ('2:3', 2 / 3),
      ('3:2', 3 / 2),
      ('9:16', 9 / 16),
      ('16:9', 16 / 9),
    ];
    return Column(children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final r in ratios)
            Pill(
              label: r.$1,
              selected: r.$2 == null ? _s.aspect == null : (_s.aspect != null && (_s.aspect! - r.$2!).abs() < 0.001),
              onTap: () => _setAspect(r.$2),
            ),
        ]),
      ),
      ParamSlider(
        label: 'Straighten',
        value: _s.straighten,
        min: -45,
        max: 45,
        decimals: 1,
        onChanged: (v) {
          _s.straighten = v;
          _live();
        },
        onChangeEnd: _commit,
      ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        ToolButton(icon: Icons.rotate_left, label: 'Rotate left', onTap: () => _rotate(-1)),
        ToolButton(icon: Icons.rotate_right, label: 'Rotate right', onTap: () => _rotate(1)),
        ToolButton(icon: Icons.flip, label: 'Flip H', onTap: () => _flip(true)),
        ToolButton(icon: Icons.flip_camera_android_outlined, label: 'Flip V', onTap: () => _flip(false)),
        ToolButton(
          icon: Icons.restart_alt,
          label: 'Reset',
          onTap: () {
            _s
              ..turns = 0
              ..flipH = false
              ..flipV = false
              ..straighten = 0
              ..aspect = null
              ..crop = const Rect.fromLTRB(0, 0, 1, 1);
            _live();
            _commit();
          },
        ),
      ]),
    ]);
  }

  Widget _maskPanel() {
    final m = _mask >= 0 && _mask < _s.masks.length ? _s.masks[_mask] : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (var i = 0; i < _s.masks.length; i++)
            Pill(
              label: '${i + 1} · ${_s.masks[i].title}',
              selected: _mask == i,
              onTap: () => setState(() => _mask = i),
            ),
          PopupMenuButton<String>(
            color: AppColors.surfaceHi,
            onSelected: (v) {
              if (v == 'subject') {
                _addSubjectMask();
              } else {
                _addMask(MaskType.values.firstWhere((t) => t.name == v));
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'linear', child: Text('Linear gradient')),
              PopupMenuItem(value: 'radial', child: Text('Radial gradient')),
              PopupMenuItem(value: 'brush', child: Text('Brush')),
              PopupMenuItem(value: 'subject', child: Text('Select person (AI)')),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(border: Border.all(color: AppColors.accent), borderRadius: BorderRadius.circular(16)),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add, size: 14, color: AppColors.accent),
                SizedBox(width: 4),
                Text('Add mask', style: TextStyle(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ]),
      ),
      if (m == null)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 18),
          child: Text('Add a mask to edit just part of the photo.', style: TextStyle(fontSize: 12, color: AppColors.textDim)),
        )
      else ...[
        const SizedBox(height: 6),
        Row(children: [
          Pill(label: 'Overlay', selected: _overlay, onTap: () => setState(() => _overlay = !_overlay)),
          Pill(
            label: 'Invert',
            selected: m.invert,
            onTap: () {
              m.invert = !m.invert;
              _live();
              _commit();
            },
          ),
          if (m.usesTexture) Pill(label: 'Erase', selected: _erase, onTap: () => setState(() => _erase = !_erase)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.danger),
            onPressed: () {
              _s.masks.removeAt(_mask);
              if (_mask < _subjects.length) _subjects.removeAt(_mask);
              _mask = _s.masks.isEmpty ? -1 : math.max(0, _mask - 1);
              _rebuildMaskTexture();
              _live();
              _commit();
            },
          ),
        ]),
        if (m.usesTexture)
          ParamSlider(
            label: 'Brush size',
            value: _brush * 100,
            min: 1,
            max: 25,
            def: 6,
            onChanged: (v) => setState(() => _brush = v / 100),
          )
        else if (m.type == MaskType.radial)
          ParamSlider(
            label: 'Feather',
            value: m.feather * 100,
            min: 0,
            max: 100,
            def: 50,
            onChanged: (v) {
              m.feather = v / 100;
              _live();
            },
            onChangeEnd: _commit,
          ),
        for (final p in P.maskAdjust)
          ParamSlider(
            label: p.label,
            value: m.adj(p.id),
            min: p.min,
            max: p.max,
            decimals: p.id == 'exposure' ? 2 : 0,
            onChanged: (v) {
              m.adjust[p.id] = v;
              _live();
            },
            onChangeEnd: _commit,
          ),
      ],
    ]);
  }

  Widget _healPanel() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Tap a blemish to cover it. Drag the second circle to choose where it copies from.',
            style: TextStyle(fontSize: 12, color: AppColors.textDim)),
        ParamSlider(
          label: 'Size',
          value: (_spot >= 0 && _spot < _s.spots.length ? _s.spots[_spot].r : _spotR) * 100,
          min: 0.5,
          max: 15,
          def: 3,
          decimals: 1,
          onChanged: (v) {
            _spotR = v / 100;
            if (_spot >= 0 && _spot < _s.spots.length) {
              _s.spots[_spot].r = _spotR;
              _rebuildHealing();
            }
            setState(() {});
          },
          onChangeEnd: _commit,
        ),
        if (_spot >= 0 && _spot < _s.spots.length)
          ParamSlider(
            label: 'Feather',
            value: _s.spots[_spot].feather * 100,
            min: 0,
            max: 100,
            def: 50,
            onChanged: (v) {
              _s.spots[_spot].feather = v / 100;
              _rebuildHealing();
              setState(() {});
            },
            onChangeEnd: _commit,
          ),
        Row(children: [
          TextButton.icon(
            onPressed: _spot >= 0 && _spot < _s.spots.length
                ? () {
                    _s.spots.removeAt(_spot);
                    _spot = -1;
                    _rebuildHealing();
                    _commit();
                  }
                : null,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete spot'),
          ),
          TextButton(
            onPressed: _s.spots.isEmpty
                ? null
                : () {
                    _s.spots.clear();
                    _spot = -1;
                    _rebuildHealing();
                    _commit();
                  },
            child: const Text('Clear all'),
          ),
        ]),
      ]);

  Widget _aiPanel() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _aiRow(Icons.auto_fix_high, 'Auto enhance', 'Balances exposure, contrast and colour from the histogram.', _auto),
        _aiRow(Icons.person_search_outlined, 'Select person', 'Builds a mask around people so you can edit them separately.', _addSubjectMask),
        _aiRow(Icons.layers_clear_outlined, 'Remove background', 'Saves a transparent PNG cut-out of the person.', _removeBackground),
        if (!AiSegmenter.supported)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Person detection runs on the phone itself (Android / iOS), not in this preview.',
                style: TextStyle(fontSize: 11.5, color: AppColors.textDim)),
          ),
      ]);

  Widget _aiRow(IconData icon, String title, String sub, VoidCallback onTap) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: AppColors.accent),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(sub, style: const TextStyle(fontSize: 11.5, color: AppColors.textDim)),
        onTap: onTap,
      );
}

/// Bottom sheet asking for file type, quality and size.
Future<ExportOptions?> showExportSheet(BuildContext context, {String action = 'Export'}) {
  var jpeg = true;
  var quality = 92.0;
  var maxEdge = 8192;
  return showModalBottomSheet<ExportOptions>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Export', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(children: [
              Pill(label: 'JPEG', selected: jpeg, onTap: () => setSheet(() => jpeg = true)),
              Pill(label: 'PNG', selected: !jpeg, onTap: () => setSheet(() => jpeg = false)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              for (final e in const [('Full size', 8192), ('4K', 3840), ('2048 px', 2048), ('1080 px', 1080)])
                Pill(label: e.$1, selected: maxEdge == e.$2, onTap: () => setSheet(() => maxEdge = e.$2)),
            ]),
            if (jpeg)
              ParamSlider(
                label: 'Quality',
                value: quality,
                min: 40,
                max: 100,
                def: 92,
                onChanged: (v) => setSheet(() => quality = v),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
                onPressed: () => Navigator.pop(ctx, ExportOptions(jpeg: jpeg, quality: quality.round(), maxEdge: maxEdge)),
                child: Text(action),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
}
