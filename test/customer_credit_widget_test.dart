import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/customer_credit_ledger.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/database_scope.dart';
import 'package:kaibao_sales/ui/pages.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('真实SQLite+UI：客户列表余额、明细、逐笔余额和刷新', (tester) async {
    sqfliteFfiInit();
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('kaibao-credit-ui-')))!;
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: p.join(temp.path, 'book.db'));
    Future<void> settle() async {
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
        if (!tester.binding.hasScheduledFrame && find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          return;
        }
      }
      fail('Credit UI did not settle');
    }
    try {
      await tester.runAsync(() async {
        await db.addCustomer(const Customer(name: '余额客户A'));
        await db.createSale(customer: (await db.customers()).single,
          lines: const [SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 2000, unitPriceCents: 1000)],
          discountCents: 0, initialReceivedCents: 0);
        await (await db.db).transaction((tx) => CustomerCreditLedger.post(tx,
          customerId: 1, saleId: 1, requestKey: 'credit-ui-fixture-001', deltaCents: 8000,
          reason: '余额展示测试夹具', createdAt: DateTime(2026, 11, 7, 12)));
      });
      await tester.pumpWidget(DatabaseScope(database: db, child: const MaterialApp(home: CustomersPage())));
      await settle();
      expect(find.text('余额 ¥80.00'), findsOneWidget);
      expect(find.text('欠款 ¥20.00'), findsOneWidget);
      await tester.tap(find.text('余额客户A'));
      await settle();
      expect(find.text('客户余额与明细'), findsOneWidget);
      expect(find.text('可用余额 ¥80.00'), findsOneWidget);
      expect(find.textContaining('来源单号 XS'), findsOneWidget);
      expect(find.textContaining('变动后余额 ¥80.00'), findsOneWidget);
      await tester.runAsync(() async => (await db.db).transaction((tx) =>
        CustomerCreditLedger.post(tx, customerId: 1, saleId: 1,
          requestKey: 'credit-ui-fixture-002', deltaCents: -3000,
          reason: '余额扣减测试夹具', createdAt: DateTime(2026, 11, 7, 13))));
      await tester.tap(find.byTooltip('刷新余额'));
      await settle();
      expect(find.text('可用余额 ¥50.00'), findsOneWidget);
      expect(find.textContaining('变动后余额 ¥50.00'), findsOneWidget);
      expect((await tester.runAsync(() => db.customerCreditAccount(1)))!.balanceCents, 5000);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async { await db.close(); await temp.delete(recursive: true); });
    }
  });
}
