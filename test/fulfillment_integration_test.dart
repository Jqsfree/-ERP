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

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kaibao-fulfillment-');
    path = p.join(temp.path, 'fulfillment.db');
    db = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: path, clock: () => DateTime(2026, 11, 7, 12));
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<(int sale, int saleLine, int wh, int po)> seed({
    int saleLength = 80000, int receivedLength = 100000,
  }) async {
    await db.addSupplier(const Supplier(name: '上游供应商'));
    await db.addProduct(const Product(code: 'FAB-1', specification: '280门幅',
      unitPriceCents: 1399));
    await db.addCustomer(const Customer(name: '客户A', openingBalanceCents: 300));
    final product = (await db.products()).single;
    final supplier = (await db.suppliers()).single;
    final customer = (await db.customers()).single;
    final wh = await db.addWarehouse(code: 'MAIN', name: '主仓');
    final po = await db.createPurchaseOrder(
      supplierId: supplier.id!, lines: [
        PurchaseLine(productId: product.id!, code: product.code,
          lengthMilli: receivedLength, widthMilli: 2800, unitCostCents: 1000),
      ]);
    final poLine = (await db.receivableLines(po)).single;
    await db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: 'purchase-receipt-seed-01',
      lines: [ReceiptInputLine(purchaseLineId: poLine.lineId,
        warehouseId: wh, lengthMilli: receivedLength, batchCode: 'LOT-A')]);
    final sale = await db.createSale(customer: customer, lines: [
      SaleLine(productId: product.id!, code: product.code,
        lengthMilli: saleLength, widthMilli: 2800, unitPriceCents: 1399),
    ], discountCents: 0, initialReceivedCents: 5000);
    return (sale, (await db.dispatchableLines(sale)).single.lineId, wh, po);
  }

  test('销售单不扣库存；两次部分出库、关联实物退货只调整库存', () async {
    final (sale, saleLine, wh, po) = await seed();
    final initial = (await db.stockBalances()).single.areaMicro;
    expect(initial, 280000000);
    final due = (await db.saleById(sale))!.currentDueCents;
    final customerDue = await db.customerOutstanding((await db.customers()).single.id!);
    expect((await db.dispatchableLines(sale)).single.remainingLengthMilli, 80000);
    expect((await db.stockMovements()).single.sourceType, 'purchase_receipt');

    final dispatch = await db.postSaleDispatch(
      saleId: sale, requestKey: 'outbound-first-001',
      lines: [DispatchInputLine(saleLineId: saleLine, warehouseId: wh,
        batchCode: 'LOT-A', lengthMilli: 30000)]);
    expect((await db.dispatchableLines(sale)).single.remainingLengthMilli, 50000);
    expect((await db.stockBalances()).single.areaMicro, 196000000);
    expect((await db.saleDispatches(saleId: sale)).single.id, dispatch);

    final second = await db.postSaleDispatch(
      saleId: sale, requestKey: 'outbound-second-002',
      lines: [DispatchInputLine(saleLineId: saleLine, warehouseId: wh,
        batchCode: 'LOT-A', lengthMilli: 50000)]);
    expect(second, isNot(dispatch));
    expect((await db.stockBalances()).single.areaMicro, 56000000);
    expect((await db.dispatchableLines(sale)).single.remainingLengthMilli, 0);

    final firstLine = (await db.returnableLines(dispatch)).single;
    expect(firstLine.dispatchedLengthMilli, 30000);
    expect(firstLine.remainingLengthMilli, 30000);
    final retId = await db.postSaleReturn(
      dispatchId: dispatch, requestKey: 'customer-return-001',
      lines: [ReturnInputLine(dispatchLineId: firstLine.lineId,
        lengthMilli: 10000)], note: '品质符合重新上架');
    expect((await db.saleReturns(dispatchId: dispatch)).single.id, retId);
    expect((await db.returnableLines(dispatch)).single.remainingLengthMilli, 20000);
    expect((await db.stockBalances()).single.areaMicro, 84000000);
    final events = await db.stockMovements();
    expect(events, hasLength(4));
    expect(events.map((m) => m.sourceType).toSet(),
      {'purchase_receipt', 'sale_dispatch', 'sale_return'});
    expect(events.fold<int>(0, (sum, m) => sum + m.deltaAreaMicro), 84000000);
    expect((await db.saleById(sale))!.currentDueCents, due);
    expect(await db.customerOutstanding((await db.customers()).single.id!), customerDue);
    expect((await db.purchaseOrderById(po))!.status, 'ordered');
    expect(await db.integrityOk(), isTrue);
  });

  test('同一出库请求并发六次只扣一次；修改内容的相同键必须拒绝', () async {
    final (sale, line, wh, _) = await seed();
    final inputs = [DispatchInputLine(
      saleLineId: line, warehouseId: wh, batchCode: 'LOT-A',
      lengthMilli: 20000)];
    final ids = await Future.wait(List.generate(6, (_) =>
      db.postSaleDispatch(saleId: sale, requestKey: 'dispatch-retry-001',
        lines: inputs)));
    expect(ids.toSet(), hasLength(1));
    expect(await db.saleDispatches(saleId: sale), hasLength(1));
    expect((await db.stockBalances()).single.areaMicro, 224000000);
    await expectLater(db.postSaleDispatch(saleId: sale,
      requestKey: 'dispatch-retry-001',
      lines: [DispatchInputLine(saleLineId: line, warehouseId: wh,
        batchCode: 'LOT-A', lengthMilli: 21000)]), throwsStateError);

    await db.close();
    final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
    try {
      expect(await reopened.postSaleDispatch(saleId: sale,
        requestKey: 'dispatch-retry-001', lines: inputs), ids.first);
      expect((await reopened.stockBalances()).single.areaMicro, 224000000);
      expect(await reopened.integrityOk(), isTrue);
    } finally { await reopened.close(); }
  });

  test('不同销售单并发抢同批次库存不得超卖，失败没有孤儿出库', () async {
    final (sale, line, wh, _) = await seed(saleLength: 80000, receivedLength: 100000);
    final product = (await db.products()).single;
    final customer = (await db.customers()).single;
    final otherSale = await db.createSale(customer: customer, lines: [
      SaleLine(productId: product.id, code: product.code,
        lengthMilli: 80000, widthMilli: 2800, unitPriceCents: 1399),
    ], discountCents: 0, initialReceivedCents: 0);
    final otherLine = (await db.dispatchableLines(otherSale)).single.lineId;

    final results = await Future.wait([
      db.postSaleDispatch(saleId: sale, requestKey: 'first-competing-sale',
        lines: [DispatchInputLine(saleLineId: line, warehouseId: wh,
          lengthMilli: 80000, batchCode: 'LOT-A')])
        .then((_) => true).catchError((Object _) => false),
      db.postSaleDispatch(saleId: otherSale, requestKey: 'other-competing-sale',
        lines: [DispatchInputLine(saleLineId: otherLine, warehouseId: wh,
          lengthMilli: 80000, batchCode: 'LOT-A')])
        .then((_) => true).catchError((Object _) => false),
    ]);
    expect(results.where((success) => success), hasLength(1));
    expect(await db.saleDispatches(), hasLength(1));
    expect((await db.stockBalances()).single.areaMicro, 56000000);
    expect(await db.integrityOk(), isTrue);
  });

  test('超量、错批次、跨单出库、无库存产品不得修改原账', () async {
    final (sale, line, wh, _) = await seed();
    await expectLater(db.postSaleDispatch(saleId: sale,
      requestKey: 'too-many-meters-sale',
      lines: [DispatchInputLine(saleLineId: line, warehouseId: wh,
        lengthMilli: 81000, batchCode: 'LOT-A')]), throwsStateError);
    await expectLater(db.postSaleDispatch(saleId: sale,
      requestKey: 'wrong-stock-batch',
      lines: [DispatchInputLine(saleLineId: line, warehouseId: wh,
        lengthMilli: 20000, batchCode: 'UNKNOWN')]), throwsStateError);
    await expectLater(db.postSaleDispatch(saleId: sale,
      requestKey: 'cross-sale-line-id',
      lines: [DispatchInputLine(saleLineId: line + 999, warehouseId: wh,
        lengthMilli: 20000, batchCode: 'LOT-A')]), throwsArgumentError);
    final customer = (await db.customers()).single;
    final noCatalogSale = await db.createSale(customer: customer, lines: const [
      SaleLine(code: 'MANUAL', lengthMilli: 1000, widthMilli: 2800,
        unitPriceCents: 1000),
    ], discountCents: 0, initialReceivedCents: 0);
    final missing = (await db.dispatchableLines(noCatalogSale)).single;
    expect(missing.productId, 0);
    await expectLater(db.postSaleDispatch(saleId: noCatalogSale,
      requestKey: 'unlinked-product-row',
      lines: [DispatchInputLine(saleLineId: missing.lineId,
        warehouseId: wh, batchCode: 'LOT-A', lengthMilli: 1000)]), throwsStateError);
    expect(await db.saleDispatches(), isEmpty);
    expect((await db.stockBalances()).single.areaMicro, 280000000);
  });

  test('退货按原出库行、原仓/批次，不可超退；并发同键只入库一次', () async {
    final (sale, line, wh, _) = await seed();
    final dispatchId = await db.postSaleDispatch(
      saleId: sale, requestKey: 'original-dispatch-key',
      lines: [DispatchInputLine(saleLineId: line, warehouseId: wh,
        lengthMilli: 30000, batchCode: 'LOT-A')]);
    final dispatchLine = (await db.returnableLines(dispatchId)).single.lineId;
    final input = [ReturnInputLine(dispatchLineId: dispatchLine, lengthMilli: 10000)];
    final ids = await Future.wait(List.generate(5, (_) =>
      db.postSaleReturn(dispatchId: dispatchId,
        requestKey: 'return-same-key-001', lines: input)));
    expect(ids.toSet(), hasLength(1));
    expect(await db.saleReturns(), hasLength(1));
    expect((await db.stockBalances()).single.areaMicro, 224000000);

    await expectLater(db.postSaleReturn(dispatchId: dispatchId,
      requestKey: 'return-same-key-001', lines: [
        ReturnInputLine(dispatchLineId: dispatchLine, lengthMilli: 9000),
      ]), throwsStateError);
    await expectLater(db.postSaleReturn(dispatchId: dispatchId,
      requestKey: 'too-much-physical-return', lines: [
        ReturnInputLine(dispatchLineId: dispatchLine, lengthMilli: 21000),
      ]), throwsStateError);
    await expectLater(db.postSaleReturn(dispatchId: dispatchId,
      requestKey: 'not-this-dispatch-line', lines: [
        const ReturnInputLine(dispatchLineId: 99999, lengthMilli: 1000),
      ]), throwsArgumentError);
    expect((await db.stockBalances()).single.areaMicro, 224000000);
    expect(await db.integrityOk(), isTrue);
  });

  test('v4→v5 迁移保留采购库存与销售收款，新增履约为空', () async {
    final (sale, _, _, _) = await seed();
    final oldBalance = (await db.stockBalances()).single.areaMicro;
    final oldDue = (await db.saleById(sale))!.currentDueCents;
    await db.close();
    final old = await databaseFactoryFfi.openDatabase(path);
    await old.execute('DROP TABLE day_closures');
    await old.execute('DROP TABLE cash_entries');
    await old.execute('DROP INDEX idx_payments_created_at');
    await old.execute('DROP VIEW stock_ledger_entries');
    for (final table in ['sale_return_lines','sale_returns',
      'sale_dispatch_lines','sale_dispatches']) {
      await old.execute('DROP TABLE $table');
    }
    await old.setVersion(4);
    await old.close();

    final migrated = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
    try {
      expect(await (await migrated.db).getVersion(), AppDatabase.schemaVersion);
      expect((await migrated.stockBalances()).single.areaMicro, oldBalance);
      expect((await migrated.saleById(sale))!.currentDueCents, oldDue);
      expect(await migrated.saleDispatches(), isEmpty);
      expect(await migrated.saleReturns(), isEmpty);
      expect(await migrated.integrityOk(), isTrue);
    } finally { await migrated.close(); }
  });

  test('v5 出库退货备份恢复、金额独立、篡改拒绝；旧 v4 备份兼容', () async {
    final (sale, line, wh, _) = await seed();
    final dispatchId = await db.postSaleDispatch(
      saleId: sale, requestKey: 'backup-dispatch-001',
      lines: [DispatchInputLine(saleLineId: line, warehouseId: wh,
        batchCode: 'LOT-A', lengthMilli: 30000)]);
    final dl = (await db.returnableLines(dispatchId)).single.lineId;
    await db.postSaleReturn(dispatchId: dispatchId,
      requestKey: 'backup-return-001', lines: [
        ReturnInputLine(dispatchLineId: dl, lengthMilli: 10000),
      ]);
    final json = await db.exportSnapshotJson();
    expect(BackupSnapshot.parse(json).counts['sale_dispatches'], 1);
    expect(BackupSnapshot.parse(json).counts['sale_returns'], 1);
    final recovered = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'backup-restore.db'));
    try {
      await recovered.restoreSnapshotJson(json);
      expect((await recovered.stockBalances()).single.areaMicro, 224000000);
      expect((await recovered.saleDispatches()).single.id, dispatchId);
      expect(await recovered.saleReturns(), hasLength(1));
      expect(await recovered.integrityOk(), isTrue);
      final wrong = jsonDecode(json) as Map<String, dynamic>;
      ((wrong['tables'] as Map<String, dynamic>)['sale_dispatch_lines'] as List)
        .first['area_micro'] = 1;
      expect(() => BackupSnapshot.parse(jsonEncode(wrong)), throwsFormatException);
      await expectLater(recovered.restoreSnapshotJson(json), throwsStateError);
    } finally { await recovered.close(); }

    // Construct the shape of a real v4 archive without any fulfillment data.
    final old = jsonDecode(json) as Map<String, dynamic>;
    old['schemaVersion'] = 4;
    final tables = old['tables'] as Map<String, dynamic>;
    for (final table in ['sale_dispatches','sale_dispatch_lines',
      'sale_returns','sale_return_lines','cash_entries','day_closures']) { tables.remove(table); }
    expect(BackupSnapshot.parse(jsonEncode(old)).counts['sale_returns'], 0);
    final legacy = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'legacy-v4-restore.db'));
    try {
      await legacy.restoreSnapshotJson(jsonEncode(old));
      expect(await legacy.saleDispatches(), isEmpty);
      expect((await legacy.stockBalances()).single.areaMicro, 280000000);
    } finally { await legacy.close(); }
  });
}
