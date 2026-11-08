import 'package:flutter/services.dart';

class ImageAlbumResult {
  const ImageAlbumResult(this.saved, this.error);
  final List<int> saved;
  final String? error;
}
class ImageAlbum {
  static const _channel = MethodChannel('kaibao/image_album');
  static Future<ImageAlbumResult> save(List<Uint8List> pages, String name, {List<int>? indices}) async {
    final selected = indices ?? List.generate(pages.length, (i) => i);
    final result = await _channel.invokeMapMethod<String, dynamic>('save',
      {'pages': selected.map((i) => pages[i]).toList(), 'name': name, 'indices': selected});
    if (result == null) throw StateError('相册未返回保存结果');
    return ImageAlbumResult(List<int>.from(result['saved'] as List), result['error'] as String?);
  }
}
