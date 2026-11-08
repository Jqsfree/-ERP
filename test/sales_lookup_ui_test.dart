import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/database_scope.dart';
import 'package:kaibao_sales/ui/pages.dart';

class LookupStore extends Fake implements SalesStore {
  @override Future<List<Sale>> sales() async => [const Sale(id: 1, number: 'XS202611080001', date: '2026-11-08', customerId: 1,
    customerName: '很长的客户名称用于验证查单页面的大字和换行显示', customerPhone: '13800000000', customerAddress: '',
    subtotalCents: 5600, discountCents: 0, priorDueCents: 0, receivedCents: 2000, status: 'confirmed', note: '', lines: [])];
}
void main() {
  testWidgets('360dp/200%：查单换行、电话搜索、未匹配提示和清空', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(DatabaseScope(database: LookupStore(), child: const MaterialApp(home: SalesPage())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), '13800000000'); await tester.pumpAndSettle();
    expect(find.text('共 1 单'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'missing'); await tester.pumpAndSettle();
    expect(find.text('没有找到匹配单据，请修改或清空搜索。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('清空搜索')); await tester.pumpAndSettle();
    expect(find.text('共 1 单'), findsOneWidget);
  });
}
