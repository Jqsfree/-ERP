import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late String path;
  late AppDatabase db;
  late int saleId, root, warehouse;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kaibao-revision-');
    path = p.join(temp.path, 'book.db');
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path,
      clock: () => DateTime(2026, 11, 7, 12));
    await db.addCustomer(const Customer(name: 'A'));
    await db.addCustomer(const Customer(name: 'B'));
    await db.addProduct(const Product(code: 'X', unitPriceCents: 1000));
    await db.addSupplier(const Supplier(name: 'S'));
    warehouse = await db.addWarehouse(code: 'W', name: '仓库');
    final po = await db.createPurchaseOrder(supplierId: 1, lines: const [
      PurchaseLine(productId: 1, code: 'X', lengthMilli: 100000, widthMilli: 2000, unitCostCents: 500)]);
    await db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'revision-stock-001',
      lines: [ReceiptInputLine(purchaseLineId: (await db.receivableLines(po)).single.lineId,
        warehouseId: warehouse, lengthMilli: 100000)]);
    saleId = await db.createSale(customer: (await db.customers()).firstWhere((c) => c.name == 'A'),
      lines: const [SaleLine(productId: 1, code: 'X', lengthMilli: 10000,
        widthMilli: 2000, unitPriceCents: 1000)], discountCents: 0, initialReceivedCents: 0);
    root = (await db.saleById(saleId))!.lines.single.id!;
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  SaleLine item({int? id, int length = 5000, int price = 1000, int width = 2000,
    int product = 1}) => SaleLine(id: id, productId: product, code: 'X',
      lengthMilli: length, widthMilli: width, unitPriceCents: price);

  Future<int> revise({int version = 0, String key = 'revision-request-001',
    int customer = 1, List<SaleLine>? lines}) => db.reviseSale(saleId: saleId,
      expectedRevision: version, requestKey: key, customerId: customer,
      date: '2026-11-06', lines: lines ?? [item(id: root)], discountCents: 0, note: '修改');

  for (final paid in [0, 10000, 20000]) {
    for (final shipped in [0, 6000, 10000]) {
      test('收款$paid分/出库$shipped毫米：减量不改资金或库存事实，差额与历史可恢复', () async {
        if (paid > 0) await db.addPayment((await db.saleById(saleId))!, paid, requestKey: 'fixture-sale_revision_integration_test-1');
        if (shipped > 0) {
          await db.postSaleDispatch(saleId: saleId, requestKey: 'revision-ship-001',
            lines: [DispatchInputLine(saleLineId: root, warehouseId: warehouse, lengthMilli: shipped)]);
        }
        final raw = await db.db;
        final originalHeaders = await raw.query('sales');
        final originalPayments = await raw.query('payments');
        final originalDispatch = await raw.query('sale_dispatch_lines');
        final stock = (await db.stockBalances()).single.areaMicro;
        expect(await revise(), 1);
        final current = (await db.saleById(saleId))!;
        expect(current.revision, 1);
        expect(current.payableCents, 10000);
        expect(current.receivedCents, paid);
        expect(current.currentDueCents, paid == 0 ? 10000 : 0);
        expect(await db.customerOutstanding(1), current.currentDueCents);
        final refunds = await db.pendingSaleRefunds(saleId);
        expect(refunds.fold<int>(0, (n,r) => n + r.amountCents), paid == 20000 ? 10000 : 0);
        final returns = await db.pendingSaleReturns(saleId);
        expect(returns.fold<int>(0, (n,r) => n + r.lengthMilli), shipped > 5000 ? shipped - 5000 : 0);
        final history = await db.saleRevisions(saleId);
        expect(history.map((r) => r.sale.revision), [1, 0]);
        expect(history.first.amountDeltaCents, -10000);
        expect(history.last.sale.payableCents, 20000);
        expect(await raw.query('sales'), originalHeaders);
        expect(await raw.query('payments'), originalPayments);
        expect(await raw.query('sale_dispatch_lines'), originalDispatch);
        expect((await db.stockBalances()).single.areaMicro, stock);
        final snapshot = await db.exportSnapshotJson();
        BackupSnapshot.parse(snapshot);
        final target = AppDatabase.forTesting(factory: databaseFactoryFfi,
          databasePath: p.join(temp.path, 'restore.db'));
        try {
          await target.restoreSnapshotJson(snapshot);
          expect((jsonDecode(await target.exportSnapshotJson()) as Map)['tables'],
            (jsonDecode(snapshot) as Map)['tables']);
          expect((await target.saleById(saleId))!.payableCents, 10000);
        } finally { await target.close(); }
      });
    }
  }

  test('客户A→B→A：款项不转移，按归属段生成待退款，新客户重新付款', () async {
    await db.addPayment((await db.saleById(saleId))!, 15000, requestKey: 'fixture-sale_revision_integration_test-2');
    await revise(customer: 2);
    expect((await db.saleById(saleId))!.receivedCents, 0);
    expect(await db.customerOutstanding(1), 0);
    expect(await db.customerOutstanding(2), 10000);
    expect((await db.pendingSaleRefunds(saleId)).single.customerId, 1);
    await db.addPayment((await db.saleById(saleId))!, 4000, requestKey: 'fixture-sale_revision_integration_test-3');
    await (await db.db).update('customers', {'name': 'B的新名称'}, where: 'id=2');
    await revise(version: 1, key: 'revision-request-002', customer: 1);
    final sale = (await db.saleById(saleId))!;
    expect(sale.receivedCents, 0);
    expect(sale.currentDueCents, 10000);
    final pending = await db.pendingSaleRefunds(saleId);
    expect(pending.map((r) => r.amountCents), [15000, 4000]);
    expect(pending.map((r) => r.customerId), [1, 2]);
    expect(pending.map((r) => r.customerName), ['A', 'B']);
    expect((await db.dayStatement('2026-11-07')).salesReceiptsCents, 19000);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('换客时上期欠款取新客户快照，历史原客户快照和实际欠款不混账', () async {
    final raw = await db.db;
    await raw.update('customers', {'opening_balance_cents': 300}, where: 'id=1');
    await raw.update('customers', {'opening_balance_cents': 800}, where: 'id=2');
    // Existing sale's prior_due_snapshot stays at its actual creation value 0.
    await db.addPayment((await db.saleById(saleId))!, 1000, requestKey: 'fixture-sale_revision_integration_test-4');
    await revise(customer: 2);
    final sale = (await db.saleById(saleId))!;
    expect(sale.priorDueCents, 800);
    expect(sale.cumulativeDueCents, 10800);
    expect(await db.customerOutstanding(1), 300);
    expect(await db.customerOutstanding(2), 10800);
    expect((await db.saleRevisions(saleId)).last.sale.priorDueCents, 0);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('连续修改、增加商品、删除旧行、数量增加、改价后按当前版本出库收款', () async {
    await revise(lines: [item(id: root, length: 12000, price: 1200), item(length: 1000)]);
    final v1 = (await db.saleById(saleId))!;
    expect(v1.payableCents, 30800);
    await db.addPayment(v1, 25000, requestKey: 'fixture-sale_revision_integration_test-5');
    await db.postSaleDispatch(saleId: saleId, requestKey: 'revision-ship-larger',
      lines: [DispatchInputLine(saleLineId: root, warehouseId: warehouse, lengthMilli: 11000)]);
    await revise(version: 1, key: 'revision-request-002', lines: [v1.lines.last]);
    expect((await db.saleById(saleId))!.payableCents, 2000);
    expect((await db.pendingSaleRefunds(saleId)).single.amountCents, 23000);
    expect((await db.pendingSaleReturns(saleId)).single.lengthMilli, 11000);
    expect((await db.dispatchableLines(saleId)).single.lineId, v1.lines.last.id);
    await expectLater(db.addPayment(v1, 1, requestKey: 'fixture-sale_revision_integration_test-6'), throwsStateError);
    await expectLater(db.postSaleDispatch(saleId: saleId, requestKey: 'revision-deleted-ship',
      lines: [DispatchInputLine(saleLineId: root, warehouseId: warehouse, lengthMilli: 1)]), throwsArgumentError);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('改门幅建立新物理行，旧出库待退，实际退回才增加库存且当前待退减少', () async {
    final dispatch = await db.postSaleDispatch(saleId: saleId, requestKey: 'revision-width-ship',
      lines: [DispatchInputLine(saleLineId: root, warehouseId: warehouse, lengthMilli: 6000)]);
    final before = (await db.stockBalances()).single.areaMicro;
    await revise(lines: [item(id: root, width: 3000)]);
    expect((await db.saleById(saleId))!.lines.single.id, isNot(root));
    expect((await db.pendingSaleReturns(saleId)).single.saleLineId, root);
    expect((await db.stockBalances()).single.areaMicro, before);
    final line = (await db.returnableLines(dispatch)).single;
    await db.postSaleReturn(dispatchId: dispatch, requestKey: 'revision-width-return',
      lines: [ReturnInputLine(dispatchLineId: line.lineId, lengthMilli: 2000)]);
    expect((await db.pendingSaleReturns(saleId)).single.lengthMilli, 4000);
    expect((await db.saleRevisions(saleId)).first.returns.single.lengthMilli, 6000);
    expect((await db.stockBalances()).single.areaMicro, before + 4000000);
    await revise(version: 1, key: 'revision-after-return', lines: (await db.saleById(saleId))!.lines);
    expect((await db.saleRevisions(saleId)).first.returns.single.lengthMilli, 4000);
    BackupSnapshot.parse(await db.exportSnapshotJson());
  });

  test('重复/并发同键只追加一次，旧版本/同键不同内容拒绝，保存中断全部回滚', () async {
    final result = await Future.wait(List.generate(4, (_) => revise()));
    expect(result.toSet(), {1});
    expect((await db.saleRevisions(saleId)).length, 2);
    await expectLater(revise(lines: [item(id: root, price: 1100)]), throwsStateError);
    await expectLater(revise(key: 'revision-stale-request'), throwsStateError);
    final raw = await db.db;
    final before = (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
    await raw.execute('''CREATE TRIGGER fail_revision BEFORE INSERT ON sale_revisions
      WHEN NEW.version=2 BEGIN SELECT RAISE(ABORT, 'injected failure'); END''');
    await expectLater(revise(version: 1, key: 'revision-failure-002',
      lines: [item(id: root), item()]), throwsA(isA<DatabaseException>()));
    expect((jsonDecode(await db.exportSnapshotJson()) as Map)['tables'], before);
    await raw.execute('DROP TRIGGER fail_revision');
    expect(await revise(version: 1, key: 'revision-failure-002'), 2);
    await db.close();
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
    expect((await db.saleById(saleId))!.revision, 2);
    expect(await db.integrityOk(), isTrue);
  });

  test('改单不重写已日结收款，非法外键保存不留下新增行或版本', () async {
    await db.addPayment((await db.saleById(saleId))!, 20000, requestKey: 'fixture-sale_revision_integration_test-7');
    final statement = await db.dayStatement('2026-11-07');
    await db.closeDay(day: '2026-11-07', actualNetByMethod: statement.expectedNetByMethod,
      requestKey: 'revision-day-close-001');
    await revise();
    expect((await db.dayStatement('2026-11-07')).salesReceiptsCents, 20000);
    expect((await db.pendingSaleRefunds(saleId)).single.amountCents, 10000);
    final before = (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
    await expectLater(revise(version: 1, key: 'revision-bad-product',
      lines: [item(product: 999)]), throwsA(isA<DatabaseException>()));
    expect((jsonDecode(await db.exportSnapshotJson()) as Map)['tables'], before);
  });

  test('篡改版本金额、收款归属、待退款和事件边界的备份被拒绝', () async {
    await db.addPayment((await db.saleById(saleId))!, 20000, requestKey: 'fixture-sale_revision_integration_test-8');
    await revise();
    final good = await db.exportSnapshotJson();
    for (final field in ['receivedCents', 'epoch', 'paymentCutoff']) {
      final bad = jsonDecode(good) as Map<String,dynamic>;
      final rows = (bad['tables'] as Map)['sale_revisions'] as List;
      final row = rows.last as Map;
      final snapshot = jsonDecode(row['snapshot'] as String) as Map<String,dynamic>;
      snapshot[field] = 999;
      row['snapshot'] = jsonEncode(snapshot);
      expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
    }
    for (final field in ['refunds', 'subtotal_cents']) {
      final altered = jsonDecode(good) as Map<String,dynamic>;
      final row = ((altered['tables'] as Map)['sale_revisions'] as List).last as Map;
      final snapshot = jsonDecode(row['snapshot'] as String) as Map<String,dynamic>;
      if (field == 'refunds') {
        ((snapshot['refunds'] as List).single as Map)['amountCents'] = 1;
      } else {
        (snapshot['header'] as Map)[field] = 1;
      }
      row['snapshot'] = jsonEncode(snapshot);
      expect(() => BackupSnapshot.parse(jsonEncode(altered)), throwsFormatException);
    }
    final bad = jsonDecode(good) as Map<String,dynamic>;
    (((bad['tables'] as Map)['sale_payment_contexts'] as List).single as Map)['customer_id'] = 2;
    expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
  });

  test('新增出库版本关联被删除或换成错误历史版本时备份拒绝', () async {
    await revise(lines: [item(id: root, length: 12000)]);
    await db.postSaleDispatch(saleId: saleId, requestKey: 'revision-context-ship',
      lines: [DispatchInputLine(saleLineId: root, warehouseId: warehouse, lengthMilli: 11000)]);
    await revise(version: 1, key: 'revision-context-next', lines: [item(id: root, length: 15000)]);
    final good = await db.exportSnapshotJson();
    for (final remove in [true, false]) {
      final bad = jsonDecode(good) as Map<String,dynamic>;
      final rows = (bad['tables'] as Map)['sale_dispatch_contexts'] as List;
      if (remove) { rows.clear(); } else { (rows.single as Map)['version'] = 2; }
      expect(() => BackupSnapshot.parse(jsonEncode(bad)), throwsFormatException);
    }
  });
}
