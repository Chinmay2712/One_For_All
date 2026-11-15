import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const _album = 'One For All Studio';

/// Saving results to the device gallery and sharing them.
class Saver {
  static bool get hasGallery => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<String> tempPath(String name) async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/$name';
  }

  static Future<void> _ensurePermission() async {
    if (!await Gal.hasPermission(toAlbum: true)) {
      await Gal.requestPermission(toAlbum: true);
    }
  }

  /// Saves image bytes. Returns a short message for the user.
  static Future<String> saveImage(Uint8List bytes, String name) async {
    if (!hasGallery) {
      await shareBytes(bytes, name);
      return 'Exported $name';
    }
    final path = await tempPath(name);
    await File(path).writeAsBytes(bytes, flush: true);
    await _ensurePermission();
    await Gal.putImage(path, album: _album);
    return 'Saved to your gallery';
  }

  static Future<String> saveVideo(String path) async {
    await _ensurePermission();
    await Gal.putVideo(path, album: _album);
    return 'Saved to your gallery';
  }

  static Future<void> shareBytes(Uint8List bytes, String name) async {
    final mime = name.endsWith('.png')
        ? 'image/png'
        : name.endsWith('.json')
            ? 'application/json'
            : 'image/jpeg';
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(bytes, name: name, mimeType: mime)],
      fileNameOverrides: [name],
    ));
  }

  static Future<void> shareFile(String path) async {
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
  }
}
