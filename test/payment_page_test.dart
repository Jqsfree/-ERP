import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/application/sales_store.dart';
import 'package:kaibao_sales/application/payment_request_store.dart';
import 'package:kaibao_sales/domain/payment_request.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/ui/payment_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class LostReplyStore extends Fake implements SalesStore, PaymentRequestStore {
  LostReplyStore(this.db);
  final AppDatabase db;
  bool lost = false;
  bool failNextLookup = false;
  @override Future<Sale?> saleById(int id) => db.saleById(id);
  @override Future<PaymentRequest?> latestPaymentRequest(int id) async {
    if (failNextLookup) { failNextLookup = false; throw StateError('lookup lost'); }
    return db.latestPaymentRequest(id);
  }
  @override Future<PaymentRequest> preparePayment(Sale sale, int amount, {required String requestKey, required String method}) => db.preparePayment(sale, amount, requestKey: requestKey, method: method);
  @override Future<void> cancelPaymentRequest(String key) => db.cancelPaymentRequest(key);
  @override Future<void> addPayment(Sale sale, int amount, {required String requestKey, String method = '其他'}) async {
    await db.addPayment(sale, amount, requestKey: requestKey, method: method);
    if (!lost) { lost = true; failNextLookup = true; throw StateError('simulated lost response after commit'); }
  }
}

void main() {
  testWidgets('收款提交后响应丢失、页面与数据库重开先恢复已入账状态，不自动再扣', (tester) async {
    sqfliteFfiInit();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('payment-lost-')))!;
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: '${dir.path}/book.db');
    final store = LostReplyStore(db);
    Future<void> settle() async {
      await tester.pump();
      for (var i=0; i<80; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    try {
      final sale = (await tester.runAsync(() async {
        await db.addCustomer(const Customer(name: 'C'));
        final id = await db.createSale(customer: (await db.customers()).single, lines: const [SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 1000, unitPriceCents: 10000)], discountCents: 0, initialReceivedCents: 0);
        return db.saleById(id);
      }))!;
      await tester.pumpWidget(MaterialApp(home: PaymentPage(sale: sale, store: store))); await settle();
      await tester.enterText(find.byType(TextFormField), '20');
      await tester.tap(find.text('核对收款')); await settle();
      await tester.tap(find.text('确认收款')); await settle();
      expect((await tester.runAsync(() => db.saleById(sale.id)))!.receivedCents, 2000);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(db.close);
      await tester.pumpWidget(MaterialApp(home: PaymentPage(sale: sale, store: store))); await settle();
      expect(find.textContaining('上次收款已入账'), findsOneWidget);
      expect(find.text('核对收款'), findsNothing);
      expect(find.text('登记另一笔收款'), findsOneWidget);
      expect((await tester.runAsync(() => db.saleById(sale.id)))!.receivedCents, 2000);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async { await db.close(); await dir.delete(recursive: true); });
    }
  });

  testWidgets('真实SQLite收款：校验、确认取消、事务失败保留、重试只入账一次', (tester) async {
    sqfliteFfiInit();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('payment-ui-')))!;
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: '${dir.path}/book.db');
    Future<void> settle() async {
      await tester.pump();
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    try {
      final sale = (await tester.runAsync(() async {
        await db.addCustomer(const Customer(name: '收款客户'));
        final id = await db.createSale(customer: (await db.customers()).single,
          lines: const [SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 1000, unitPriceCents: 10000)],
          discountCents: 0, initialReceivedCents: 0);
        return db.saleById(id);
      }))!;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => Scaffold(body: TextButton(
        onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => PaymentPage(sale: sale, store: db))), child: const Text('打开'))))));
      await tester.tap(find.text('打开')); await settle();
      await tester.enterText(find.byType(TextFormField), '101');
      await tester.tap(find.text('核对收款')); await settle();
      expect(find.text('不能超过本单剩余未收'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), '20');
      await tester.tap(find.text('核对收款')); await settle();
      expect(find.textContaining('登记后未收：¥80.00'), findsOneWidget);
      await tester.tap(find.text('返回修改')); await settle();
      expect((await tester.runAsync(() => db.saleById(sale.id)))!.receivedCents, 0);
      await tester.runAsync(() async => (await db.db).execute("CREATE TRIGGER fail_payment_ui BEFORE INSERT ON payments BEGIN SELECT RAISE(ABORT, 'failure'); END"));
      await tester.tap(find.text('核对收款')); await settle();
      await tester.tap(find.text('确认收款')); await settle();
      expect(find.textContaining('输入已保留'), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
      expect((await tester.runAsync(() => db.saleById(sale.id)))!.receivedCents, 0);
      await tester.runAsync(() async => (await db.db).execute('DROP TRIGGER fail_payment_ui'));
      await tester.tap(find.text('核对收款')); await settle();
      await tester.tap(find.text('确认收款')); await settle();
      expect((await tester.runAsync(() => db.saleById(sale.id)))!.receivedCents, 2000);
      expect(find.text('打开'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async { await db.close(); await dir.delete(recursive: true); });
    }
  });
}
