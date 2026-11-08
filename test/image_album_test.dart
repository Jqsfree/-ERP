import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/services/image_album.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('kaibao/image_album');
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  test('分页相册返回部分结果，重试仅发送未保存页', () async {
    final calls = <List<int>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final indices = List<int>.from((call.arguments as Map)['indices'] as List);
      calls.add(indices);
      return {'saved': calls.length == 1 ? [0] : indices, 'error': calls.length == 1 ? '空间不足' : null};
    });
    final pages = [Uint8List.fromList([1]), Uint8List.fromList([2])];
    final first = await ImageAlbum.save(pages, 'XS-v0');
    expect(first.saved, [0]);
    expect(first.error, '空间不足');
    final second = await ImageAlbum.save(pages, 'XS-v0', indices: [1]);
    expect(second.saved, [1]);
    expect(calls, [[0, 1], [1]]);
  });
  test('权限拒绝或无保存回执时不得报成功', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'permission'));
    await expectLater(ImageAlbum.save([Uint8List(1)], 'XS'), throwsA(isA<PlatformException>()));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => null);
    await expectLater(ImageAlbum.save([Uint8List(1)], 'XS'), throwsStateError);
  });
}
