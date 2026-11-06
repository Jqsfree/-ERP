import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/main.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  testWidgets('真实界面：客户输入 -> 产品输入 -> 销售单 -> SQLite -> 详情输出',
      (tester) async {
    final dir = await Directory.systemTemp.createTemp('kaibao-widget-');
    final db = AppDatabase.forTesting(factory: databaseFactoryFfiNoIsolate,
      databasePath: p.join(dir.path, 'ui.db'),
      clock: () => DateTime(2026, 11, 6));
    try {
      await tester.pumpWidget(KaibaoApp(database: db));
      await tester.pumpAndSettle();

      await tester.tap(find.text('客户'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增客户'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, '客户名称 *'), '客户A');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      expect((await db.customers()).single.name, '客户A');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('产品'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增产品'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, '产品型号 *'), 'KB56-34');
      await tester.enterText(find.widgetWithText(TextFormField, '默认单价（元/平方米）*'), '13.99');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      expect((await db.products()).single.unitPriceCents, 1399);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('销售'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('客户A').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('KB56-34').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '37');
      await tester.enterText(find.widgetWithText(TextFormField, '优惠金额（元）'), '0.36');
      await tester.enterText(find.widgetWithText(TextFormField, '开单已收款（元）'), '500');
      await tester.ensureVisible(find.text('确认销售并保存'));
      await tester.tap(find.text('确认销售并保存'));
      await tester.pumpAndSettle();

      final sales = await db.sales();
      expect(sales, hasLength(1));
      expect(sales.single.number, 'XS202611060001');
      expect(sales.single.payableCents, 144900);
      expect(sales.single.receivedCents, 50000);
      expect(sales.single.lines.single.areaText, '103.6');
      expect(find.text('NO.XS202611060001'), findsOneWidget);
      expect(find.text('¥1449.00'), findsWidgets);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
