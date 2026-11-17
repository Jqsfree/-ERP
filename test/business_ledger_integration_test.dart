import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/services/backup_codec.dart';
import 'package:kaibao_sales/services/sales_csv.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One business ledger, with independent fixed integer expectations in fen
/// and millionths of a square metre. Never derive expected cash/stock from
/// the same production calculator that is under test.
void main() {
  setUpAll(sqfliteFfiInit);

  test('P2 integrated ledger: purchase, sales, revisions, cash, credit, stock, reopening and restore', () async {
    final temp = await Directory.systemTemp.createTemp('kaibao-phase2-');
    final sourcePath = p.join(temp.path, 'source.db');
    var now = DateTime(2026, 11, 17, 10);
    AppDatabase open(String path) => AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: path, clock: () => now,
    );
    var db = open(sourcePath);
    const day1 = '2026-11-17';
    const day2 = '2026-11-18';

    Future<int> stock() async => (await db.stockBalances()).single.areaMicro;
    Future<Sale> sale(int id) async => (await db.saleById(id))!;

    try {
      await db.addCustomer(const Customer(name: 'A'));
      await db.addCustomer(const Customer(name: 'B'));
      final customers = await db.customers();
      final a = customers.singleWhere((c) => c.name == 'A');
      final b = customers.singleWhere((c) => c.name == 'B');
      await db.addProduct(const Product(code: 'FAB', unitPriceCents: 1000));
      final product = (await db.products()).single;
      await db.addSupplier(const Supplier(name: 'Supplier'));
      final supplier = (await db.suppliers()).single;
      final wh = await db.addWarehouse(code: 'MAIN', name: 'Main');
      SaleLine line(int mm, {int? id}) => SaleLine(
        id: id, productId: product.id, code: product.code,
        lengthMilli: mm, widthMilli: 1000, unitPriceCents: 1000,
      );

      // Procurement is a commitment; only receipt creates stock, not cash.
      final po = await db.createPurchaseOrder(supplierId: supplier.id!, lines: [
        PurchaseLine(productId: product.id!, code: product.code,
          lengthMilli: 30000, widthMilli: 1000, unitCostCents: 500),
      ]);
      expect((await db.purchaseOrderById(po))!.totalCents, 15000);
      expect(await db.stockMovements(), isEmpty);
      final purchaseLine = (await db.receivableLines(po)).single;
      Future<int> receipt() => db.postPurchaseReceipt(
        purchaseOrderId: po, requestKey: 'phase2-receipt-001',
        lines: [ReceiptInputLine(purchaseLineId: purchaseLine.lineId,
          warehouseId: wh, lengthMilli: 30000, batchCode: 'LOT-A')],
      );
      final receiptId = await receipt();
      expect(await receipt(), receiptId);
      expect(await stock(), 30000000);
      expect((await db.dayStatement(day1)).expectedNetCents, 0);

      // A pays 200.00 by WeChat; the order itself cannot move stock.
      Future<int> createOriginal() => db.createSaleWithCredit(
        customer: a, lines: [line(20000)], discountCents: 0,
        initialReceivedCents: 20000, initialPaymentMethod: '微信',
        requestKey: 'phase2-opening-A-001',
      );
      final id = await createOriginal();
      expect(await createOriginal(), id);
      var current = await sale(id);
      final originalLineId = current.lines.single.id!;
      expect(current.payableCents, 20000);
      expect(current.currentDueCents, 0);
      expect(await stock(), 30000000);
      expect((await db.dayStatement(day1)).expectedNetByMethod['微信'], 20000);
      Future<int> dispatch() => db.postSaleDispatch(
        saleId: id, requestKey: 'phase2-dispatch-001',
        lines: [DispatchInputLine(saleLineId: originalLineId,
          warehouseId: wh, batchCode: 'LOT-A', lengthMilli: 15000)],
      );
      final dispatchId = await dispatch();
      expect(await dispatch(), dispatchId);
      expect(await stock(), 15000000);

      Future<int> revise(int version, Customer customer, int mm, String key) =>
        db.reviseSale(saleId: id, expectedRevision: version, requestKey: key,
          customerId: customer.id!, date: day1, lines: [line(mm, id: originalLineId)],
          discountCents: 0, note: 'Business revision');
      expect(await revise(0, a, 10000, 'phase2-revise-001'), 1);
      expect((await db.pendingSaleRefunds(id)).single.amountCents, 10000);
      expect((await db.pendingSaleReturns(id)).single.lengthMilli, 5000);
      expect(await stock(), 15000000);

      Future<int> refund(int amount, int revision, String key) async {
        final request = await db.prepareSaleRefund(saleId: id,
          expectedRevision: revision, customerId: a.id!, epoch: 0,
          amountCents: amount, method: '微信', requestKey: key);
        return db.postRefundRequest(request.key);
      }
      final mistakenRefund = await refund(3000, 1, 'phase2-refund-001');
      expect(await db.postRefundRequest('phase2-refund-001'), mistakenRefund);
      final reverse = await db.prepareRefundReversal(originalEventId: mistakenRefund,
        reason: 'Mistaken registration, funds verified', fundsRecoveredOrMistake: true,
        requestKey: 'phase2-reversal-001');
      final reverseId = await db.postRefundRequest(reverse.key);
      expect(await db.postRefundRequest(reverse.key), reverseId);
      expect((await db.pendingSaleRefunds(id)).single.amountCents, 10000);
      await refund(4000, 1, 'phase2-refund-002');
      Future<int> transfer() => db.transferSaleRefundToCredit(
        saleId: id, expectedRevision: 1, customerId: a.id!, epoch: 0,
        amountCents: 6000, requestKey: 'phase2-credit-001',
      );
      final creditId = await transfer();
      expect(await transfer(), creditId);
      expect(await db.pendingSaleRefunds(id), isEmpty);
      expect((await db.customerCreditAccount(a.id!)).balanceCents, 6000);
      expect(await stock(), 15000000);

      // Switch customer and reduce goods to 8m. A's cash must remain A's.
      expect(await revise(1, b, 8000, 'phase2-revise-002'), 2);
      expect(await revise(1, b, 8000, 'phase2-revise-002'), 2);
      current = await sale(id);
      expect(current.customerId, b.id);
      expect(current.receivedCents, 0);
      expect(current.currentDueCents, 8000);
      final pending = (await db.pendingSaleRefunds(id)).single;
      expect(pending.customerId, a.id);
      expect(pending.epoch, 0);
      expect(pending.amountCents, 10000);
      expect((await db.pendingSaleReturns(id)).single.lengthMilli, 7000);
      await expectLater(refund(10001, 2, 'phase2-overrefund-001'), throwsStateError);
      await refund(10000, 2, 'phase2-refund-003');
      expect(await db.pendingSaleRefunds(id), isEmpty);
      await db.addPayment(current, 8000, method: '现金', requestKey: 'phase2-payment-B-001');
      await db.addPayment(current, 8000, method: '现金', requestKey: 'phase2-payment-B-001');
      expect((await sale(id)).currentDueCents, 0);
      expect(await db.customerOutstanding(b.id!), 0);

      // The cash operations above do not affect stock. Only physical return does.
      expect(await stock(), 15000000);
      final dispatchedLine = (await db.returnableLines(dispatchId)).single;
      Future<int> returnGoods() => db.postSaleReturn(
        dispatchId: dispatchId, requestKey: 'phase2-return-001',
        lines: [ReturnInputLine(dispatchLineId: dispatchedLine.lineId, lengthMilli: 7000)],
      );
      final returnId = await returnGoods();
      expect(await returnGoods(), returnId);
      expect(await db.pendingSaleReturns(id), isEmpty);
      expect(await stock(), 22000000);
      final movements = await db.stockMovements();
      expect(movements, hasLength(3));
      expect(movements.fold<int>(0, (sum, event) => sum + event.deltaAreaMicro), 22000000);

      // A uses credit on a new 90.00 sale, plus 10.00 from Alipay.
      final consumer = await db.createSaleWithCredit(customer: a, lines: [line(9000)],
        discountCents: 0, initialReceivedCents: 1000, initialPaymentMethod: '支付宝',
        requestKey: 'phase2-consumer-001');
      final consumerSale = await sale(consumer);
      expect(consumerSale.creditAppliedCents, 6000);
      expect(consumerSale.currentDueCents, 2000);
      expect((await db.customerCreditAccount(a.id!)).balanceCents, 0);
      expect(await db.customerOutstanding(a.id!), 2000);
      expect(await stock(), 22000000);

      // Independent reconciliation, cents:
      // WeChat 20000 - 3000 + 3000 - 4000 - 10000 = 6000.
      // Cash 8000; Alipay 1000. Credit transfer is not a cash event.
      final firstDay = await db.dayStatement(day1);
      expect(firstDay.salesReceiptsCents, 29000);
      expect(firstDay.salesRefundsCents, 17000);
      expect(firstDay.refundReversalsCents, 3000);
      expect(firstDay.expectedNetCents, 15000);
      const day1Channels = {'微信': 6000, '支付宝': 1000, '现金': 8000, '银行转账': 0, '其他': 0};
      expect(firstDay.expectedNetByMethod, day1Channels);
      await db.closeDay(day: day1, actualNetByMethod: day1Channels, requestKey: 'phase2-day-close-001');
      await expectLater(db.addPayment(consumerSale, 2000, method: '银行转账',
        requestKey: 'phase2-after-close-001'), throwsStateError);
      expect((await sale(consumer)).currentDueCents, 2000);

      await db.close();
      now = DateTime(2026, 11, 18, 10);
      db = open(sourcePath);
      final reopenedConsumer = await sale(consumer);
      expect(reopenedConsumer.currentDueCents, 2000);
      expect(await stock(), 22000000);
      await db.addPayment(reopenedConsumer, 2000, method: '银行转账', requestKey: 'phase2-next-day-001');
      await db.addPayment(reopenedConsumer, 2000, method: '银行转账', requestKey: 'phase2-next-day-001');
      expect((await sale(consumer)).currentDueCents, 0);
      expect(await db.customerOutstanding(a.id!), 0);
      expect(await db.customerOutstanding(b.id!), 0);
      expect((await db.dayStatement(day1)).expectedNetByMethod, day1Channels);
      final secondDay = await db.dayStatement(day2);
      expect(secondDay.expectedNetCents, 2000);
      expect(secondDay.expectedNetByMethod['银行转账'], 2000);
      await db.closeDay(day: day2, actualNetByMethod: secondDay.expectedNetByMethod,
        requestKey: 'phase2-day-close-002');
      final history = await db.saleRevisions(id);
      expect(history.map((r) => r.sale.revision), [2, 1, 0]);
      expect(history.map((r) => r.sale.payableCents), [8000, 10000, 20000]);
      expect(history.map((r) => r.sale.customerId), [b.id, a.id, a.id]);
      expect(history.last.sale.receivedCents, 20000);
      expect(await db.saleRefundEvents(id), hasLength(4));
      expect(await db.checkDataIntegrity(), isEmpty);
      expect(await db.integrityOk(), isTrue);
      expect(await (await db.db).rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(SalesCsvExporter.generate([await sale(id), await sale(consumer)]).orders,
        contains('净实际退款'));

      // Real encrypted file, restore to independent empty database, close and reopen,
      // then compare every persisted table and replay the same financial balances.
      final plain = await db.exportSnapshotJson();
      final tampered = jsonDecode(plain) as Map;
      final requests = (tampered['tables'] as Map)['sale_creation_requests'] as List;
      final opening = requests.cast<Map>().singleWhere((r) => r['sale_id'] == id);
      final payload = jsonDecode(opening['payload'] as String) as Map;
      payload['initialPaymentMethod'] = '现金';
      opening['payload'] = jsonEncode(payload);
      expect(() => BackupSnapshot.parse(jsonEncode(tampered)), throwsFormatException,
        reason: 'First receipt channel must match its persisted opening request');
      final file = File(p.join(temp.path, 'business.kberp'));
      const password = 'phase2-fixture-password-2026';
      await file.writeAsBytes(await BackupCodec.encrypt(plain, password), flush: true);
      final clear = await BackupCodec.decrypt(await file.readAsBytes(), password);
      final targetPath = p.join(temp.path, 'restored.db');
      final target = open(targetPath);
      try {
        await target.restoreSnapshotJson(clear);
        await target.close();
        expect((jsonDecode(await target.exportSnapshotJson()) as Map)['tables'],
          (jsonDecode(plain) as Map)['tables']);
        expect((await target.stockBalances()).single.areaMicro, 22000000);
        expect((await target.dayStatement(day1)).expectedNetByMethod, day1Channels);
        expect((await target.dayStatement(day2)).expectedNetCents, 2000);
        expect((await target.saleById(id))!.currentDueCents, 0);
        expect(await target.customerOutstanding(a.id!), 0);
        expect(await target.customerOutstanding(b.id!), 0);
        expect(await target.checkDataIntegrity(), isEmpty);
        expect(await (await target.db).rawQuery('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        await target.close();
      }
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });

  test('Zero opening receipt preserves valid selected channel without creating cash', () async {
    final temp = await Directory.systemTemp.createTemp('kaibao-phase2-zero-');
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'source.db'),
      clock: () => DateTime(2026, 11, 17, 10));
    try {
      await db.addCustomer(const Customer(name: 'A'));
      final customer = (await db.customers()).single;
      const lines = [SaleLine(code: 'X', lengthMilli: 1000,
        widthMilli: 1000, unitPriceCents: 1000)];
      Future<int> create() => db.createSaleWithCredit(customer: customer,
        lines: lines, discountCents: 0, initialReceivedCents: 0,
        initialPaymentMethod: '支付宝', requestKey: 'phase2-zero-receipt-001');
      final id = await create();
      expect(await create(), id);
      expect((await (await db.db).query('payments')), isEmpty);
      expect((await db.dayStatement('2026-11-17')).expectedNetCents, 0);
      expect((await db.saleById(id))!.currentDueCents, 1000);
      final plain = await db.exportSnapshotJson();
      await db.verifySnapshotJson(plain);
      final bad = jsonDecode(plain) as Map;
      final row = ((bad['tables'] as Map)['sale_creation_requests'] as List).single as Map;
      final payload = jsonDecode(row['payload'] as String) as Map;
      payload['initialPaymentMethod'] = 'invalid-channel';
      row['payload'] = jsonEncode(payload);
      expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
}
