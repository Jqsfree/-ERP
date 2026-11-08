import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/ui/database_scope.dart';
import 'package:kaibao_sales/ui/pages.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final paid in [0, 10000, 20000]) {
    for (final shipped in [0, 6000, 10000]) {
      testWidgets('真实DB+UI：收款$paid/出库$shipped改单、历史只读及待办展示', (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('kaibao-revision-widget-')))!;
        final db = AppDatabase.forTesting(factory: databaseFactoryFfi,
          databasePath: p.join(temp.path, 'book.db'));
        try {
          final sale = await tester.runAsync(() async {
            await db.addCustomer(const Customer(name: 'A'));
            await db.addProduct(const Product(code: 'X', unitPriceCents: 1000));
            await db.addProduct(const Product(code: 'Y', unitPriceCents: 1000));
            await db.addSupplier(const Supplier(name: 'S'));
            final wh = await db.addWarehouse(code: 'W', name: '仓库');
            final po = await db.createPurchaseOrder(supplierId: 1, lines: const [
              PurchaseLine(productId: 1, code: 'X', lengthMilli: 20000, widthMilli: 2000, unitCostCents: 500)]);
            await db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'widget-revision-stock',
              lines: [ReceiptInputLine(purchaseLineId: (await db.receivableLines(po)).single.lineId,
                warehouseId: wh, lengthMilli: 20000)]);
            final id = await db.createSale(customer: (await db.customers()).single,
              lines: const [SaleLine(productId: 1, code: 'X', lengthMilli: 10000,
                widthMilli: 2000, unitPriceCents: 1000)], discountCents: 0, initialReceivedCents: paid);
            if (shipped > 0) {
              await db.postSaleDispatch(saleId: id, requestKey: 'widget-revision-ship',
                lines: [DispatchInputLine(saleLineId: (await db.saleById(id))!.lines.single.id!,
                  warehouseId: wh, lengthMilli: shipped)]);
            }
            await db.saveDraft('{"schema":1,"sentinel":"unrelated draft"}');
            return (await db.saleById(id))!;
          });
          Future<void> settle() async {
            // Let actual SQLite worker I/O finish outside Flutter's fake clock.
            await tester.pump();
            for (var i = 0; i < 100; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
              await tester.pump(const Duration(milliseconds: 100));
              if (!tester.binding.hasScheduledFrame &&
                  find.byType(CircularProgressIndicator).evaluate().isEmpty) {
                return;
              }
            }
            fail('SQLite UI did not settle');
          }
          await tester.pumpWidget(DatabaseScope(database: db,
            child: MaterialApp(home: SaleDetailPage(sale: sale!))));
          await settle();

          await tester.scrollUntilVisible(find.text('更多操作'), 250, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('更多操作'));
      await settle();
      await tester.tap(find.text('修改已确认销售单'));
          await settle();
          expect(find.text('修改销售单 · 版本 0'), findsOneWidget);
          expect(find.text('开单已收款（元）'), findsNothing);
          await tester.enterText(find.widgetWithText(TextFormField, '销售日期（YYYY-MM-DD）'), '2026-11-06');
          await tester.enterText(find.widgetWithText(TextFormField, '米数 *'), '5');
          final replaceProduct = paid == 10000 && shipped == 10000;
          final replaceWidth = paid == 20000 && shipped == 10000;
          if (replaceProduct) {
            await tester.tap(find.byType(DropdownButtonFormField<int>).last);
            await settle();
            await tester.tap(find.text('Y').last);
            await settle();
          }
          if (replaceWidth) {
            await tester.enterText(find.widgetWithText(TextFormField, '门幅 *'), '3');
          }
          await tester.scrollUntilVisible(find.text('核对并保存修改'), 350,
            scrollable: find.byType(Scrollable).first);
          expect(find.textContaining('已收款：¥${paid == 0 ? '0.00' : paid == 10000 ? '100.00' : '200.00'}'), findsOneWidget);
          await tester.tap(find.text('核对并保存修改'));
          await settle();
          expect(find.text('确认修改销售单'), findsOneWidget);
          expect(find.textContaining('金额差额 ¥${replaceWidth ? '-50.00' : '-100.00'}'), findsOneWidget);
          await tester.tap(find.text('确认保存修改'));
          await settle();
          expect(find.text('版本 1（当前有效）'), findsOneWidget);
          if (paid == 20000) expect(find.textContaining('待退款：A'), findsOneWidget);
          if (shipped > 5000) expect(find.textContaining('待退货：X'), findsOneWidget);
          final current = await tester.runAsync(() => db.saleById(sale.id));
          expect(current!.revision, 1);
          expect(current.payableCents, replaceWidth ? 15000 : 10000);
          expect(current.receivedCents, paid);
          if (replaceWidth || replaceProduct) {
            expect(current.lines.single.id, isNot(sale.lines.single.id));
            final pending = await tester.runAsync(() => db.pendingSaleReturns(sale.id));
            expect(pending!.single.lengthMilli, shipped);
          }
          expect(current.date, '2026-11-06');
          expect(await tester.runAsync(db.loadDraft), contains('unrelated draft'));
          await tester.scrollUntilVisible(find.text('更多操作'), 250, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('更多操作'));
      await settle();
      await tester.ensureVisible(find.text('查看历史版本'));
          await tester.tap(find.text('查看历史版本'));
          await settle();
          await tester.tap(find.text('版本 0 · A · ¥200.00'));
          await settle();
          expect(find.text('版本 0（历史快照，只读）'), findsOneWidget);
          expect(find.text('修改已确认销售单'), findsNothing);
          expect(find.text('登记后续收款'), findsNothing);
          expect(find.text('¥200.00'), findsWidgets);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await db.close();
            await temp.delete(recursive: true);
          });
        }
      });
    }
  }
}
