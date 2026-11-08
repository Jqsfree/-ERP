import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/main.dart';

void main() {
  testWidgets('首页只保留开单和找单，业务及设置分区', (tester) async {
    await tester.pumpWidget(const KaibaoApp());
    expect(find.text('快速开单'), findsOneWidget);
    expect(find.text('找单／保存图片'), findsOneWidget);
    expect(find.text('采购'), findsNothing);
    await tester.tap(find.text('业务'));
    await tester.pumpAndSettle();
    expect(find.text('客户与商品'), findsOneWidget);
    expect(find.text('客户'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('数据备份与恢复'), findsOneWidget);
  });

  testWidgets('新增客户表单可以输入客户资料', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const KaibaoApp());
    await tester.tap(find.text('业务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('客户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增客户'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '测试客户');
    await tester.enterText(find.byType(TextField).at(1), '13800000000');
    await tester.pumpAndSettle();

    expect(find.text('测试客户'), findsOneWidget);
    expect(find.text('13800000000'), findsOneWidget);
  });
}
