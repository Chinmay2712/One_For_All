import 'dart:convert';

import '../core/store.dart';
import 'develop_settings.dart';

class Preset {
  final String name;
  final String group;
  final Map<String, double> v;
  final bool mono;
  final Map<String, List<List<double>>>? curves;
  final String? id; // set for user presets
  const Preset(this.name, this.group, this.v, {this.mono = false, this.curves, this.id});

  void applyTo(DevelopSettings s) =>
      s.applyPreset(name, v, mono: mono, presetCurves: curves);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'v': v,
        'mono': mono,
        'curves': curves,
      };

  static Preset fromJson(Map<String, dynamic> j) => Preset(
        j['name'] as String? ?? 'Preset',
        'Yours',
        (j['v'] as Map? ?? {}).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        mono: j['mono'] == true,
        curves: (j['curves'] as Map?)?.map((k, pts) => MapEntry(
              k as String,
              (pts as List)
                  .map((p) => (p as List).map((e) => (e as num).toDouble()).toList())
                  .toList(),
            )),
        id: j['id'] as String? ?? Store.newId(),
      );

  /// Captures the look (not geometry, masks or healing) of [s].
  static Preset fromSettings(String name, DevelopSettings s) {
    final c = s.copy();
    return Preset(name, 'Yours', Map.of(c.v), mono: c.bw, curves: c.hasCurve ? c.curves : null, id: Store.newId());
  }
}

const _fadeCurve = {
  'rgb': [[0.0, 0.07], [0.25, 0.24], [0.75, 0.76], [1.0, 0.95]],
};
const _filmCurve = {
  'rgb': [[0.0, 0.04], [0.2, 0.17], [0.5, 0.52], [0.8, 0.85], [1.0, 0.97]],
};
const _punchCurve = {
  'rgb': [[0.0, 0.0], [0.25, 0.2], [0.75, 0.8], [1.0, 1.0]],
};

const kPresetGroups = ['Colour', 'Portrait', 'Landscape', 'Cinematic', 'Film', 'B&W', 'Yours'];

const kBuiltInPresets = <Preset>[
  // Colour
  Preset('Natural', 'Colour', {'contrast': 8, 'highlights': -15, 'shadows': 12, 'vibrance': 12, 'clarity': 6}),
  Preset('Vivid', 'Colour', {'contrast': 18, 'highlights': -20, 'shadows': 15, 'vibrance': 32, 'saturation': 6, 'clarity': 12}),
  Preset('Bright & Airy', 'Colour', {'exposure': 0.45, 'contrast': -8, 'highlights': -30, 'shadows': 35, 'whites': 12, 'vibrance': 10, 'temp': 4}),
  Preset('Warm Glow', 'Colour', {'temp': 22, 'tint': 4, 'contrast': 10, 'highlights': -18, 'vibrance': 14, 'ghH': 42, 'ghS': 18}),
  Preset('Cool Breeze', 'Colour', {'temp': -20, 'contrast': 12, 'shadows': 10, 'vibrance': 12, 'gsH': 215, 'gsS': 16}),
  // Portrait
  Preset('Soft Skin', 'Portrait', {'exposure': 0.2, 'contrast': -6, 'highlights': -22, 'shadows': 18, 'texture': -28, 'clarity': -10, 'vibrance': 8, 'sat1': -6, 'lum1': 8}),
  Preset('Golden Hour', 'Portrait', {'temp': 26, 'tint': 6, 'highlights': -28, 'shadows': 20, 'vibrance': 16, 'ghH': 45, 'ghS': 24, 'gsH': 28, 'gsS': 10, 'vignette': -14}),
  Preset('Studio Pop', 'Portrait', {'contrast': 20, 'highlights': -12, 'whites': 10, 'blacks': -12, 'clarity': 10, 'vibrance': 14, 'sharpen': 35}),
  // Landscape
  Preset('Deep Sky', 'Landscape', {'contrast': 14, 'highlights': -45, 'shadows': 28, 'dehaze': 22, 'vibrance': 22, 'sat5': 18, 'lum5': -22, 'sat4': 10, 'clarity': 14}),
  Preset('Lush Green', 'Landscape', {'contrast': 10, 'shadows': 20, 'vibrance': 20, 'hue3': 12, 'sat3': 22, 'lum3': 8, 'sat2': -10, 'clarity': 12}),
  Preset('Autumn', 'Landscape', {'temp': 14, 'contrast': 12, 'hue2': -28, 'sat1': 24, 'sat0': 14, 'hue3': -40, 'sat3': -18, 'vibrance': 12, 'vignette': -12}),
  Preset('HDR Look', 'Landscape', {'contrast': 6, 'highlights': -75, 'shadows': 70, 'whites': 18, 'blacks': -18, 'clarity': 38, 'texture': 18, 'vibrance': 20}),
  // Cinematic
  Preset('Teal & Orange', 'Cinematic', {'contrast': 16, 'highlights': -20, 'shadows': 10, 'gsH': 190, 'gsS': 34, 'ghH': 36, 'ghS': 30, 'gBlend': 70, 'sat1': 16, 'sat4': 14, 'vignette': -16}),
  Preset('Moody', 'Cinematic', {'exposure': -0.35, 'contrast': 22, 'highlights': -40, 'shadows': -8, 'blacks': -14, 'saturation': -22, 'gsH': 220, 'gsS': 18, 'clarity': 14, 'vignette': -28}),
  Preset('Blockbuster', 'Cinematic', {'contrast': 26, 'highlights': -30, 'shadows': 16, 'dehaze': 12, 'vibrance': -8, 'gsH': 200, 'gsS': 24, 'gmH': 40, 'gmS': 10, 'grain': 14, 'vignette': -20}, curves: _punchCurve),
  Preset('Neon Night', 'Cinematic', {'contrast': 20, 'shadows': 22, 'blacks': -20, 'temp': -14, 'tint': 22, 'vibrance': 30, 'gsH': 265, 'gsS': 30, 'ghH': 320, 'ghS': 18}),
  // Film
  Preset('Faded Film', 'Film', {'contrast': -10, 'saturation': -14, 'temp': 6, 'grain': 26, 'vignette': -10}, curves: _fadeCurve),
  Preset('Kodachrome-ish', 'Film', {'contrast': 22, 'highlights': -14, 'vibrance': 20, 'sat0': 12, 'sat5': 14, 'temp': 6, 'grain': 16}, curves: _filmCurve),
  Preset('Vintage 70s', 'Film', {'temp': 20, 'tint': 8, 'contrast': -4, 'saturation': -12, 'gsH': 50, 'gsS': 22, 'ghH': 48, 'ghS': 18, 'grain': 34, 'vignette': -22}, curves: _fadeCurve),
  Preset('Matte', 'Film', {'contrast': 8, 'highlights': -20, 'shadows': 18, 'saturation': -10, 'clarity': 8}, curves: _fadeCurve),
  // Black & white
  Preset('Mono', 'B&W', {'contrast': 12, 'clarity': 8}, mono: true),
  Preset('Noir', 'B&W', {'contrast': 42, 'highlights': -10, 'blacks': -28, 'clarity': 22, 'vignette': -30, 'grain': 20}, mono: true),
  Preset('Silver', 'B&W', {'contrast': 4, 'highlights': -30, 'shadows': 30, 'lum5': -30, 'lum0': 14, 'grain': 12}, mono: true),
  Preset('Sepia', 'B&W', {'contrast': 10, 'gsH': 36, 'gsS': 32, 'gmH': 38, 'gmS': 26, 'ghH': 44, 'ghS': 16, 'vignette': -16}, mono: true),
];

/// User-saved presets, persisted locally and shareable as JSON.
class UserPresets {
  static const _key = 'photo_presets';

  static List<Preset> all() => Store.readList(_key).map(Preset.fromJson).toList();

  static Future<void> save(Preset p) => Store.upsert(_key, p.toJson());

  static Future<void> delete(String id) => Store.remove(_key, id);

  static String exportJson(Preset p) => jsonEncode({'oneForAllPreset': 1, ...p.toJson()});

  static Future<Preset?> importJson(String text) async {
    try {
      final j = Map<String, dynamic>.from(jsonDecode(text) as Map);
      if (j['v'] is! Map) return null;
      j['id'] = Store.newId();
      final p = Preset.fromJson(j);
      await save(p);
      return p;
    } catch (_) {
      return null;
    }
  }
}
