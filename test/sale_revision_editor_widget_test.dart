import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/database_scope.dart';
import 'package:kaibao_sales/ui/pages.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('真实DB+UI：加行提价增量、删行、连续改单、重复点击与保存失败重试', (tester) async {
    debugPrint('REV_EDITOR_STAGE 00: test started');
    sqfliteFfiInit();
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('kaibao-revision-editor-')))!;
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: p.join(temp.path, 'book.db'));
    Future<void> settle() async {
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
        if (!tester.binding.hasScheduledFrame && find.byType(CircularProgressIndicator).evaluate().isEmpty &&
            find.text('当前欠款查询中…').evaluate().isEmpty && find.text('余额读取中…').evaluate().isEmpty &&
            find.text('待退款读取中…').evaluate().isEmpty && find.text('待退货读取中…').evaluate().isEmpty) { return; }
      }
      fail('SQLite editor did not settle');
    }
    try {
      final sale = (await tester.runAsync(() async {
        await db.addCustomer(const Customer(name: 'A'));
        await db.addCustomer(const Customer(name: 'B'));
        final id = await db.createSale(customer: (await db.customers()).firstWhere((c) => c.name == 'A'),
          lines: List.generate(2, (_) => const SaleLine(code: 'X', lengthMilli: 1000,
            widthMilli: 2000, unitPriceCents: 1000)), discountCents: 0, initialReceivedCents: 1000);
        return db.saleById(id);
      }))!;
      debugPrint('REV_EDITOR_STAGE 01: fixtures created');
      await tester.pumpWidget(DatabaseScope(database: db,
        child: MaterialApp(home: SaleDetailPage(sale: sale))));
      await settle();
      debugPrint('REV_EDITOR_STAGE 02: initial sale detail ready');
      await tester.scrollUntilVisible(find.text('更多操作'), 250, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('更多操作'));
      await settle();
      await tester.tap(find.text('修改已确认销售单'));
      await settle();
      debugPrint('REV_EDITOR_STAGE 03: first editor ready');
      await tester.enterText(find.widgetWithText(TextFormField, '米数 *').first, '2');
      await tester.enterText(find.widgetWithText(TextFormField, '单价（元/㎡）*').first, '12');
      await tester.tap(find.text('新增一行产品'));
      await settle();
      await tester.enterText(find.widgetWithText(TextFormField, '产品型号 *').last, 'Y');
      await tester.enterText(find.widgetWithText(TextFormField, '米数 *').last, '1');
      await tester.enterText(find.widgetWithText(TextFormField, '单价（元/㎡）*').last, '1');
      final save = find.text('核对并保存修改');
      await tester.tap(save);
      // The second pointer event is intentionally blocked by the saving overlay.
      await tester.tap(save, warnIfMissed: false);
      await settle();
      debugPrint('REV_EDITOR_STAGE 04: first confirmation ready');
      expect(find.text('确认修改销售单'), findsOneWidget);
      expect(find.textContaining('金额差额 ¥30.80'), findsOneWidget);
      await tester.tap(find.text('确认保存修改'));
      await settle();
      debugPrint('REV_EDITOR_STAGE 05: first revision saved');
      expect(find.text('版本 1（当前有效）'), findsOneWidget);
      final first = (await tester.runAsync(() => db.saleById(sale.id)))!;
      expect(first.payableCents, 7080);
      expect(first.lines.length, 3);
      expect(first.lines[0].id, sale.lines[0].id);
      expect(first.receivedCents, 1000);
      await tester.scrollUntilVisible(find.text('更多操作'), 250, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('更多操作'));
      await settle();
      await tester.tap(find.text('修改已确认销售单'));
      await settle();
      debugPrint('REV_EDITOR_STAGE 06: second editor ready');
      await tester.tap(find.byTooltip('删除本行').first);
      await settle();
      await tester.tap(find.byType(DropdownButtonFormField<int>).first);
      await settle();
      await tester.tap(find.text('B').last);
      await settle();
      debugPrint('REV_EDITOR_STAGE 07: second editor modified');
      final before = await tester.runAsync(() async {
        final snapshot = (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
        await (await db.db).execute('''CREATE TRIGGER fail_editor_revision BEFORE INSERT ON sale_revisions
          WHEN NEW.version=2 BEGIN SELECT RAISE(ABORT, 'editor failure'); END''');
        return snapshot;
      });
      await tester.tap(find.text('核对并保存修改'));
      await settle();
      debugPrint('REV_EDITOR_STAGE 08: second confirmation ready');
      expect(find.textContaining('原客户已收待退 ¥10.00'), findsOneWidget);
      expect(find.textContaining('新客户应收 ¥22.80'), findsOneWidget);
      await tester.tap(find.text('确认保存修改'));
      await settle();
      debugPrint('REV_EDITOR_STAGE 09: injected failure handled');
      expect(find.text('操作未完成'), findsOneWidget);
      expect(await tester.runAsync(() async => (jsonDecode(await db.exportSnapshotJson()) as Map)['tables']), before);
      await tester.tap(find.text('知道了'));
      await settle();
      expect(find.text('修改销售单 · 版本 1'), findsOneWidget);
      await tester.runAsync(() async => (await db.db).execute('DROP TRIGGER fail_editor_revision'));
      await tester.tap(find.text('核对并保存修改'));
      await settle();
      await tester.tap(find.text('确认保存修改'));
      await settle();
      debugPrint('REV_EDITOR_STAGE 10: retried successfully');
      expect(find.text('版本 2（当前有效）'), findsOneWidget);
      final second = (await tester.runAsync(() => db.saleById(sale.id)))!;
      expect(second.payableCents, 2280);
      expect(second.customerId, 2);
      expect(second.receivedCents, 0);
      expect((await tester.runAsync(() => db.pendingSaleRefunds(sale.id)))!.single.amountCents, 1000);
      expect(second.lines.map((l) => l.id), [sale.lines[1].id, first.lines.last.id]);
      expect((await tester.runAsync(() => db.saleRevisions(sale.id)))!.map((r) => r.sale.revision), [2, 1, 0]);
      expect(tester.takeException(), isNull);
    } finally {
      debugPrint('REV_EDITOR_STAGE 99: cleanup');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async { await db.close(); await temp.delete(recursive: true); });
    }
  });
}
