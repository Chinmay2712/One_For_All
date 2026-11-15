import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../core/media.dart';
import '../core/store.dart';
import 'develop_renderer.dart';
import 'develop_settings.dart';

/// One photo in the library together with its edit recipe.
class PhotoDoc {
  final String id;
  final String path;
  String name;
  DevelopSettings settings;
  int updated;

  PhotoDoc({required this.id, required this.path, required this.name, DevelopSettings? settings, int? updated})
      : settings = settings ?? DevelopSettings(),
        updated = updated ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() =>
      {'id': id, 'path': path, 'name': name, 'settings': settings.toJson(), 'updated': updated};

  static PhotoDoc fromJson(Map<String, dynamic> j) => PhotoDoc(
        id: j['id'] as String,
        path: j['path'] as String,
        name: j['name'] as String? ?? 'Photo',
        settings: DevelopSettings.fromJson(Map<String, dynamic>.from(j['settings'] as Map? ?? {})),
        updated: (j['updated'] as num?)?.toInt(),
      );
}

class PhotoLibrary {
  static const _key = 'photos';

  /// Rendered thumbnails for this session (also written to disk on mobile).
  static final Map<String, Uint8List> thumbs = {};

  static List<PhotoDoc> all() {
    final docs = <PhotoDoc>[];
    for (final j in Store.readList(_key)) {
      try {
        final d = PhotoDoc.fromJson(j);
        // Blob URLs from a previous web session no longer resolve.
        if (kIsWeb && d.path.startsWith('blob:') && !thumbs.containsKey(d.id)) continue;
        docs.add(d);
      } catch (_) {}
    }
    return docs;
  }

  static Future<void> save(PhotoDoc doc) {
    doc.updated = DateTime.now().millisecondsSinceEpoch;
    return Store.upsert(_key, doc.toJson());
  }

  static Future<void> delete(String id) async {
    thumbs.remove(id);
    await Store.remove(_key, id);
    if (!kIsWeb) {
      final f = File(await _thumbPath(id));
      if (f.existsSync()) f.deleteSync();
    }
  }

  static Future<String> _thumbPath(String id) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/thumbs');
    if (!d.existsSync()) d.createSync(recursive: true);
    return '${d.path}/$id.png';
  }

  static Future<void> storeThumb(String id, ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    final bytes = data.buffer.asUint8List();
    thumbs[id] = bytes;
    if (!kIsWeb) await File(await _thumbPath(id)).writeAsBytes(bytes);
  }

  static Future<Uint8List?> loadThumb(PhotoDoc doc) async {
    final cached = thumbs[doc.id];
    if (cached != null) return cached;
    if (!kIsWeb) {
      final f = File(await _thumbPath(doc.id));
      if (f.existsSync()) return thumbs[doc.id] = await f.readAsBytes();
    }
    try {
      final image = await Media.load(doc.path, maxEdge: 360);
      await DevelopRenderer.init();
      final out = await DevelopRenderer.renderFinal(image, doc.settings, maxEdge: 360);
      await storeThumb(doc.id, out);
      return thumbs[doc.id];
    } catch (_) {
      return null;
    }
  }
}

class ExportOptions {
  final bool jpeg;
  final int quality;
  final int maxEdge;
  const ExportOptions({this.jpeg = true, this.quality = 92, this.maxEdge = 8192});
  String get ext => jpeg ? 'jpg' : 'png';
}

Uint8List _encodeJpg((Uint8List, int, int, int) a) {
  final image = img.Image.fromBytes(width: a.$2, height: a.$3, bytes: a.$1.buffer, numChannels: 4);
  return img.encodeJpg(image, quality: a.$4);
}

class PhotoExport {
  static Future<Uint8List> encode(ui.Image image, ExportOptions o) async {
    if (!o.jpeg) {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return compute(_encodeJpg, (data!.buffer.asUint8List(), image.width, image.height, o.quality));
  }

  /// Full-resolution render of [path] with [settings], encoded per [o].
  static Future<Uint8List> renderFile(String path, DevelopSettings settings, ExportOptions o) async {
    await DevelopRenderer.init();
    final source = await Media.load(path);
    final out = await DevelopRenderer.renderFinal(source, settings, maxEdge: o.maxEdge);
    final bytes = await encode(out, o);
    out.dispose();
    return bytes;
  }
}
