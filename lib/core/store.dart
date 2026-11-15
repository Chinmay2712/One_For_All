import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Small JSON key/value store used for the library, projects and presets.
class Store {
  static late SharedPreferences _prefs;
  static final _rng = Random();

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rng.nextInt(1 << 20).toRadixString(36)}';

  static List<Map<String, dynamic>> readList(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> writeList(String key, List<Map<String, dynamic>> items) =>
      _prefs.setString(key, jsonEncode(items));

  static Map<String, dynamic>? readMap(String key) {
    final raw = _prefs.getString(key);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeMap(String key, Map<String, dynamic> value) =>
      _prefs.setString(key, jsonEncode(value));

  /// Inserts or replaces the item with the same `id` and moves it to the front.
  static Future<void> upsert(String key, Map<String, dynamic> item) async {
    final items = readList(key)..removeWhere((e) => e['id'] == item['id']);
    items.insert(0, item);
    await writeList(key, items);
  }

  static Future<void> remove(String key, String id) async {
    final items = readList(key)..removeWhere((e) => e['id'] == id);
    await writeList(key, items);
  }
}
