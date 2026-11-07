import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late String path;
  late AppDatabase db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kaibao-stock-test-');
    path = p.join(temp.path, 'stock.db');
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path,
      clock: () => DateTime(2026, 11, 7, 12));
  });

  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });

  Future<(int, int, int)> seed() async {
    await db.addSupplier(const Supplier(name: '供应商A'));
    await db.addProduct(const Product(code: 'CURTAIN-1', unitPriceCents: 1399));
    final supplier = (await db.suppliers()).single;
    final product = (await db.products()).single;
    final poId = await db.createPurchaseOrder(supplierId: supplier.id!,
      lines: [PurchaseLine(productId: product.id!, code: product.code,
        lengthMilli: 100000, widthMilli: 2800, unitCostCents: 1000)]);
    final warehouseId = await db.addWarehouse(code: 'MAIN', name: '主仓');
    return (poId, (await db.receivableLines(poId)).single.lineId, warehouseId);
  }

  test('采购订单没有库存，分次收货实时生成独立流水，不产生应付或收款', () async {
    final (po, line, wh) = await seed();
    expect(await db.stockMovements(), isEmpty);
    expect(await db.stockBalances(), isEmpty);
    final first = await db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: 'first-receipt-001',
      lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: wh,
        lengthMilli: 30000, batchCode: 'B1')]);
    expect((await db.receivableLines(po)).single.remainingLengthMilli, 70000);
    expect((await db.purchaseReceipts(purchaseOrderId: po)).single.id, first);
    expect((await db.stockBalances()).single.areaMicro, 84000000);
    expect((await db.stockMovements()).single.deltaAreaMicro, 84000000);

    final secondWh = await db.addWarehouse(code: 'SECOND', name: '分仓');
    await db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'second-receipt-002',
      lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: secondWh,
        lengthMilli: 70000, batchCode: 'B2')]);
    expect((await db.receivableLines(po)).single.remainingLengthMilli, 0);
    expect((await db.stockMovements()), hasLength(2));
    final balances = await db.stockBalances();
    expect(balances, hasLength(2));
    expect(balances.fold<int>(0, (sum, b) => sum + b.areaMicro), 280000000);
    expect((await db.purchaseOrderById(po))!.status, 'ordered');
    expect(await db.integrityOk(), isTrue);
  });

  test('同一请求重试永远不重复加库存，内容变更的相同键拒绝', () async {
    final (po, line, wh) = await seed();
    const key = 'idempotency-receipt-01';
    final input = ReceiptInputLine(purchaseLineId: line,
      warehouseId: wh, lengthMilli: 10000);
    final ids = await Future.wait(List.generate(5, (_) => db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: key, lines: [input])));
    expect(ids.toSet(), hasLength(1));
    expect(await db.stockMovements(), hasLength(1));
    expect((await db.stockBalances()).single.areaMicro, 28000000);
    await expectLater(db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: key,
      lines: [ReceiptInputLine(purchaseLineId: line,
        warehouseId: wh, lengthMilli: 9000)]), throwsStateError);

    await db.close();
    final reopened = AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: path);
    try {
      final id = await reopened.postPurchaseReceipt(
        purchaseOrderId: po, requestKey: key, lines: [input]);
      expect(id, ids.first);
      expect(await reopened.stockMovements(), hasLength(1));
    } finally {
      await reopened.close();
    }
  });

  test('并发收货不可超过订单，失败事务不生成孤儿库存', () async {
    final (po, line, wh) = await seed();
    final calls = await Future.wait([
      db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'concurrent-one-001',
        lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: wh,
          lengthMilli: 70000)]).then((_) => true).catchError((Object _) => false),
      db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'concurrent-two-002',
        lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: wh,
          lengthMilli: 70000)]).then((_) => true).catchError((Object _) => false),
    ]);
    expect(calls.where((s) => s), hasLength(1));
    expect(await db.purchaseReceipts(), hasLength(1));
    expect(await db.stockMovements(), hasLength(1));
    expect((await db.receivableLines(po)).single.remainingLengthMilli, 30000);
    await expectLater(db.cancelPurchaseOrder(po), throwsStateError);
    expect(await db.integrityOk(), isTrue);
  });

  test('跨采购单行、失效仓库、超额收货和取消订单均不得入库', () async {
    final (po, line, wh) = await seed();
    await expectLater(db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: 'too-many-meters-001',
      lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: wh,
        lengthMilli: 100001)]), throwsStateError);
    await expectLater(db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: 'wrong-line-identifier',
      lines: [ReceiptInputLine(purchaseLineId: 999999, warehouseId: wh,
        lengthMilli: 1000)]), throwsArgumentError);
    await (await db.db).update('warehouses', {'active': 0},
      where: 'id = ?', whereArgs: [wh]);
    await expectLater(db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: 'disabled-warehouse',
      lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: wh,
        lengthMilli: 1000)]), throwsArgumentError);
    expect(await db.stockMovements(), isEmpty);
    expect(await db.purchaseReceipts(), isEmpty);
    await db.cancelPurchaseOrder(po);
    await expectLater(db.postPurchaseReceipt(
      purchaseOrderId: po, requestKey: 'cancelled-order-001',
      lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: wh,
        lengthMilli: 1000)]), throwsStateError);
  });

  test('v3 旧库升级 v5 保留采购、客户、产品且不伪造库存', () async {
    final (po, _, _) = await seed();
    await db.addCustomer(const Customer(name: 'v3 客户'));
    await db.close();
    final old = await databaseFactoryFfi.openDatabase(path);
    for (final name in ['stock_movements', 'purchase_receipt_lines',
        'purchase_receipts', 'warehouses']) {
      await old.execute('DROP TABLE $name');
    }
    await old.setVersion(3);
    await old.close();
    final upgraded = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: path);
    try {
      expect(await (await upgraded.db).getVersion(), AppDatabase.schemaVersion);
      expect((await upgraded.purchaseOrderById(po))!.lines, hasLength(1));
      expect((await upgraded.customers()).single.name, 'v3 客户');
      expect(await upgraded.warehouses(), isEmpty);
      expect(await upgraded.stockBalances(), isEmpty);
      expect(await upgraded.integrityOk(), isTrue);
    } finally {
      await upgraded.close();
    }
  });

  test('v4 加密备份的基础快照保留真实入库、校验重复/篡改/空库恢复', () async {
    final (po, line, wh) = await seed();
    await db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'backup-receipt-001',
      lines: [ReceiptInputLine(purchaseLineId: line, warehouseId: wh,
        lengthMilli: 30000, batchCode: 'LOT-A')]);
    final snapshot = await db.exportSnapshotJson();
    final parsed = BackupSnapshot.parse(snapshot);
    expect(parsed.counts['stock_movements'], 1);
    expect(parsed.counts['purchase_receipt_lines'], 1);
    final recovered = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'recovered.db'));
    try {
      await recovered.restoreSnapshotJson(snapshot);
      expect((await recovered.stockBalances()).single.areaMicro, 84000000);
      expect((await recovered.stockMovements()).single.batchCode, 'LOT-A');
      expect(await recovered.integrityOk(), isTrue);
      await expectLater(recovered.restoreSnapshotJson(snapshot), throwsStateError);
      expect(await recovered.stockMovements(), hasLength(1));
    } finally { await recovered.close(); }

    final corrupt = jsonDecode(snapshot) as Map<String, dynamic>;
    final tables = corrupt['tables'] as Map<String, dynamic>;
    final record = (tables['stock_movements'] as List).first as Map<String, dynamic>;
    record['delta_area_micro'] = 1;
    expect(() => BackupSnapshot.parse(jsonEncode(corrupt)), throwsFormatException);
  });

  test('历史 v3 备份恢复到 v5，新增库存表保持为空', () async {
    final (po, _, _) = await seed();
    final content = jsonDecode(await db.exportSnapshotJson()) as Map<String, dynamic>;
    content['schemaVersion'] = 3;
    final tables = content['tables'] as Map<String, dynamic>;
    for (final name in ['stock_movements','purchase_receipt_lines',
        'purchase_receipts', 'warehouses']) {
      tables.remove(name);
    }
    for (final name in ['sale_dispatches', 'sale_dispatch_lines',
        'sale_returns', 'sale_return_lines']) { tables.remove(name); }
    final archive = jsonEncode(content);
    expect(BackupSnapshot.parse(archive).counts['warehouses'], 0);
    final restore = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'restore-v3.db'));
    try {
      await restore.restoreSnapshotJson(archive);
      expect((await restore.purchaseOrderById(po))!.lines, hasLength(1));
      expect(await restore.stockBalances(), isEmpty);
      expect(await restore.integrityOk(), isTrue);
    } finally { await restore.close(); }
  });
}
