import 'dart:typed_data';

class BoundedBytes {
  /// Metadata is only an early rejection hint; enforce the bound on the stream.
  static Future<Uint8List> read(Stream<List<int>> Function() open,
      {required int limit, int? reportedLength}) async {
    if (limit <= 0) throw ArgumentError('读取上限无效');
    if (reportedLength != null && (reportedLength < 0 || reportedLength > limit)) {
      throw const FormatException('备份文件大小超过限制');
    }
    final output = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in open()) {
      if (chunk.length > limit - count) throw const FormatException('备份文件大小超过限制');
      count += chunk.length;
      output.add(chunk);
    }
    if (count == 0) throw const FormatException('备份文件为空');
    return output.takeBytes();
  }
}
