import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/refund_repository.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/refund_page.dart';

class LostRefundResponse extends RefundRepository {
  LostRefundResponse(super.db, super.clock);
  bool lose = true;
  @override
  Future<int> postRefundRequest(String key) async {
    final result = await super.postRefundRequest(key);
    if (lose) {
      lose = false;
      throw StateError('模拟入账后响应丢失');
    }
    return result;
  }
}

void main() {
  testWidgets('退款UI：校验、响应丢失保留输入、重试不重复、冲销需确认及原因', (tester) async {
    sqfliteFfiInit();
    tester.view.physicalSize = const Size(411, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('refund-ui-'),
        ))!;
    final db = AppDatabase.forTesting(
      factory: databaseFactoryFfi,
      databasePath: '${dir.path}/db',
      clock: () => DateTime(2026, 11, 8, 10),
    );
    Future<void> settle() async {
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (!tester.binding.hasScheduledFrame &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty) {
          return;
        }
      }
      fail('退款UI未完成加载');
    }

    Future<void> tap(String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.tap(find.text(text));
      await settle();
    }

    try {
      final sid =
          (await tester.runAsync(() async {
            await db.addCustomer(const Customer(name: '退款客户'));
            final id = await db.createSale(
              customer: (await db.customers()).single,
              lines: const [
                SaleLine(
                  code: 'X',
                  lengthMilli: 1000,
                  widthMilli: 1000,
                  unitPriceCents: 20000,
                ),
              ],
              discountCents: 0,
              initialReceivedCents: 20000,
            );
            final sale = (await db.saleById(id))!;
            await db.reviseSale(
              saleId: id,
              expectedRevision: 0,
              requestKey: 'refund-widget-revision',
              customerId: 1,
              date: '2026-11-08',
              lines: [
                SaleLine(
                  id: sale.lines.single.id,
                  code: 'X',
                  lengthMilli: 1000,
                  widthMilli: 1000,
                  unitPriceCents: 10000,
                ),
              ],
              discountCents: 0,
              note: '减价',
            );
            return id;
          }))!;
      final store = LostRefundResponse(
        (await tester.runAsync(() => db.db))!,
        () => DateTime(2026, 11, 8, 10),
      );
      await tester.pumpWidget(
        MaterialApp(home: RefundPage(saleId: sid, store: store, sales: db)),
      );
      await settle();
      await tap('登记已实际退款');
      final amount = find.widgetWithText(TextFormField, '已实际退款金额（元，必填）');
      await tester.enterText(amount, '100.01');
      await tap('确认登记实际退款');
      expect(find.text('金额须大于0且不超过可处理金额'), findsOneWidget);
      await tester.enterText(amount, '30.00');
      await tap('确认登记实际退款');
      expect(find.text('请确认资金已经实际退给客户'), findsOneWidget);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await settle();
      await tap('确认登记实际退款');
      expect(find.textContaining('模拟入账后响应丢失'), findsOneWidget);
      expect(find.text('30.00'), findsOneWidget);
      expect(
        (await tester.runAsync(() => db.saleRefundEvents(sid)))!.length,
        1,
      );
      await tap('原请求重试');
      expect(find.text('最近请求：退款 · 已入账'), findsOneWidget);
      expect(
        (await tester.runAsync(() => db.saleRefundEvents(sid)))!.length,
        1,
      );
      await tester.scrollUntilVisible(
        find.text('冲销误登记退款'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tap('冲销误登记退款');
      await tap('确认冲销退款');
      expect(find.text('请填写冲销原因'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '误登记，核对款项已收回');
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await settle();
      await tap('确认冲销退款');
      expect(
        (await tester.runAsync(() => db.saleRefundEvents(sid)))!.length,
        2,
      );
      expect((await tester.runAsync(() => db.saleById(sid)))!.refundedCents, 0);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
    }
  });
}
