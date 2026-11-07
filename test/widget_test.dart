import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/main.dart';

void main() {
  testWidgets('首页展示九项业务入口，包含真实的费用收支与日结功能', (tester) async {
    await tester.pumpWidget(const KaibaoApp());
    expect(find.text('凯堡软装 · 开单管理'), findsOneWidget);
    expect(find.text('销售'), findsOneWidget);
    expect(find.text('采购'), findsOneWidget);
    expect(find.text('客户'), findsOneWidget);
    expect(find.text('供应商'), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    await tester.scrollUntilVisible(find.text('费用收支'), 220,
      scrollable: find.byType(Scrollable).first);
    expect(find.text('费用收支'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('日结对账'), 220,
      scrollable: find.byType(Scrollable).first);
    expect(find.text('日结对账'), findsOneWidget);
  });

  testWidgets('新增客户表单可以输入客户资料', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const KaibaoApp());
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
