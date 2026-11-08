import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/main.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/domain/models.dart';

class EasyStore extends Fake implements SalesStore {
  String? draft;
  @override Future<List<Customer>> customers() async => [const Customer(id: 1, name: '长名称客户用于验证大字体显示和页面布局')];
  @override Future<List<Product>> products() async => [];
  @override Future<String?> loadDraft() async => draft;
  @override Future<void> saveDraft(String value) async { draft = value; }
  @override Future<void> deleteDraft() async { draft = null; }
}
class CatalogStore extends EasyStore {
  @override Future<List<Product>> products() async => [const Product(id: 1, code: 'A', unitPriceCents: 100)];
}
void main() {
  testWidgets('选库存A后手改B解除关联，草稿恢复不会扣A库存', (tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final store = CatalogStore();
    await tester.pumpWidget(KaibaoApp(database: store)); await tester.pumpAndSettle();
    await tester.tap(find.text('快速开单')); await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>).first); await tester.pumpAndSettle();
    await tester.tap(find.text('长名称客户用于验证大字体显示和页面布局').last); await tester.pumpAndSettle();
    await tester.tap(find.text('下一步')); await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>)); await tester.pumpAndSettle();
    await tester.tap(find.text('A').last); await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '产品型号 *'), 'B'); await tester.pumpAndSettle();
    expect(find.textContaining('手填商品：未关联库存'), findsOneWidget);
    await tester.tap(find.text('返回')); await tester.pumpAndSettle();
    final draft = jsonDecode(store.draft!) as Map;
    expect((draft['lines'] as List).single['productId'], isNull);
    await tester.tap(find.text('快速开单')); await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(find.textContaining('手填商品：未关联库存'), findsOneWidget);
  });
  testWidgets('三步开单：逐步校验、返回保留和草稿恢复步骤', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = EasyStore();
    await tester.pumpWidget(KaibaoApp(database: store));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速开单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('请选择客户'), findsOneWidget);
    await tester.tap(find.text('搜索客户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '长名称');
    await tester.pumpAndSettle();
    await tester.tap(find.text('长名称客户用于验证大字体显示和页面布局').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '产品型号 *'), 'X');
    await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '0');
    await tester.enterText(find.widgetWithText(TextFormField, '单价（元/㎡）*'), '10');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('米数必须大于0'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '2');
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('确认开单并保存图片'), findsOneWidget);
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('X'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('快速开单'));
    await tester.pumpAndSettle();
    expect(find.text('第 2 步，共3步 · 填商品'), findsOneWidget);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets('360dp字体$scale：三页导航和开单退出保存草稿', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = EasyStore();
      await tester.pumpWidget(KaibaoApp(database: store));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('快速开单'));
      await tester.tap(find.text('快速开单'));
      await tester.pumpAndSettle();
      expect(find.text('下一步'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(store.draft, isNotNull);
      await tester.tap(find.text('业务'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
