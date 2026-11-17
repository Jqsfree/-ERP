import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:kaibao_sales/domain/fulfillment.dart';
import 'package:kaibao_sales/services/sales_csv.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('Master editing, deactivation, historical snapshots, recovery and versioned return exports', () async {
    final dir = await Directory.systemTemp.createTemp('master-data-flow-');
    final path = '${dir.path}/source.db';
    AppDatabase open(String file) => AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: file,
      clock: () => DateTime(2026, 11, 17, 10));
    final db = open(path);
    try {
      await db.addCustomer(const Customer(name: 'Old A', openingBalanceCents: 500));
      await db.addCustomer(const Customer(name: 'B'));
      await db.addProduct(const Product(code: 'FAB', specification: 'Original spec', unitPriceCents: 1000));
      await db.addSupplier(const Supplier(name: 'S'));
      final a = (await db.customers()).singleWhere((c) => c.name == 'Old A');
      final b = (await db.customers()).singleWhere((c) => c.name == 'B');
      final p = (await db.products()).single;
      final supplier = (await db.suppliers()).single;
      final warehouse = await db.addWarehouse(code: 'MAIN', name: 'Main');
      PurchaseLine purchase() => PurchaseLine(productId: p.id!, code: p.code,
        specification: p.specification, lengthMilli: 10000, widthMilli: 1000, unitCostCents: 500);
      SaleLine line(int length, {int? id}) => SaleLine(id: id, productId: p.id,
        code: p.code, specification: p.specification, lengthMilli: length,
        widthMilli: 1000, unitPriceCents: 1000);
      final po = await db.createPurchaseOrder(supplierId: supplier.id!, lines: [purchase()]);
      final receiptLine = (await db.receivableLines(po)).single;
      await db.postPurchaseReceipt(purchaseOrderId: po, requestKey: 'master-receipt-0001',
        lines: [ReceiptInputLine(purchaseLineId: receiptLine.lineId, warehouseId: warehouse, lengthMilli: 10000)]);
      Future<int> create(Customer c, String key) => db.createSaleWithCredit(customer: c,
        lines: [line(8000)], discountCents: 0, initialReceivedCents: 8000, requestKey: key);
      final sid = await create(a, 'master-sale-first-001');
      final original = (await db.saleById(sid))!;
      final dispatch = await db.postSaleDispatch(saleId: sid, requestKey: 'master-dispatch-001',
        lines: [DispatchInputLine(saleLineId: original.lines.single.id!, warehouseId: warehouse, lengthMilli: 8000)]);

      await db.updateCustomer(Customer(id: a.id, name: 'New A', phone: '123',
        address: 'New address', openingBalanceCents: 500, active: false));
      await db.updateProduct(Product(id: p.id, code: p.code, specification: 'New spec',
        unitPriceCents: 1200, active: false));
      expect((await db.customers()).singleWhere((c) => c.id == a.id).active, isFalse);
      expect((await db.products()).single.active, isFalse);
      expect(await db.customerOutstanding(a.id!), 500);
      await expectLater(db.updateCustomer(Customer(id: a.id, name: 'New A', openingBalanceCents: 999)), throwsStateError);
      await expectLater(db.updateProduct(Product(id: p.id, code: 'CHANGED', unitPriceCents: 1000)), throwsStateError);
      // The original request still resolves before active-state validation.
      expect(await create(a, 'master-sale-first-001'), sid);
      await expectLater(create(a, 'master-sale-disabled-001'), throwsStateError);
      await expectLater(create(b, 'master-sale-disabled-product'), throwsStateError);
      await expectLater(db.createPurchaseOrder(supplierId: supplier.id!, lines: [purchase()]), throwsStateError);
      expect((await db.sales()).length, 1);

      // An existing inactive customer's unchanged product association remains valid.
      expect(await db.reviseSale(saleId: sid, expectedRevision: 0, requestKey: 'master-revision-001',
        customerId: a.id!, date: original.date,
        lines: [line(6000, id: original.lines.single.id)], discountCents: 0, note: 'reduce'), 1);
      expect((await db.saleById(sid))!.customerName, 'Old A');
      expect((await db.saleById(sid))!.lines.single.specification, 'Original spec');
      expect((await db.purchaseOrderById(po))!.lines.single.specification, 'Original spec');
      final returnLine = (await db.returnableLines(dispatch)).single;
      await db.postSaleReturn(dispatchId: dispatch, requestKey: 'master-return-0001',
        lines: [ReturnInputLine(dispatchLineId: returnLine.lineId, lengthMilli: 2000)]);
      final current = (await db.saleById(sid))!;
      expect(current.returnedLengthMilli, 2000);
      expect(current.returnedAreaMicro, 2000000);
      expect(current.refundedCents, 0);
      expect((await db.stockBalances()).single.areaMicro, 4000000);
      final history = await db.saleRevisions(sid);
      expect(history.every((r) => r.sale.returnedLengthMilli == 0), isTrue);
      final csv = SalesCsvExporter.generate([current, history.last.sale]);
      expect(csv.orders, contains('累计实物退货(米)'));
      expect(csv.orders, contains('"2.000","2.000000"'));

      final plain = await db.exportSnapshotJson();
      final target = open('${dir.path}/restored.db');
      try {
        await target.restoreSnapshotJson(plain);
        await target.close();
        expect((await target.customers()).singleWhere((c) => c.id == a.id).active, isFalse);
        expect((await target.products()).single.active, isFalse);
        expect((await target.saleById(sid))!.returnedAreaMicro, 2000000);
        expect((jsonDecode(await target.exportSnapshotJson()) as Map)['tables'],
          (jsonDecode(plain) as Map)['tables']);
      } finally { await target.close(); }

      await db.updateCustomer(Customer(id: a.id, name: 'New A', phone: '123', openingBalanceCents: 500));
      await db.updateProduct(Product(id: p.id, code: p.code, specification: 'New spec', unitPriceCents: 1200));
      final another = await create(a, 'master-sale-restored-001');
      expect((await db.saleById(another))!.customerName, 'New A');
      expect((await db.saleById(sid))!.customerName, 'Old A');
      expect(await db.checkDataIntegrity(), isEmpty);
    } finally { await db.close(); await dir.delete(recursive: true); }
  });

  test('v11 upgrade and v11 snapshot restore add active defaults without changing historical money', () async {
    final dir = await Directory.systemTemp.createTemp('master-v11-');
    final path = '${dir.path}/old.db';
    AppDatabase open(String file) => AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: file);
    final db = open(path);
    try {
      await db.addCustomer(const Customer(name: 'Legacy', openingBalanceCents: 123));
      await db.addProduct(const Product(code: 'X', unitPriceCents: 100));
      final archive = jsonDecode(await db.exportSnapshotJson()) as Map;
      archive['schemaVersion'] = 11;
      final tables = archive['tables'] as Map;
      final raw = await db.db;
      for (final table in ['customers', 'products']) {
        for (final row in tables[table] as List) { (row as Map).remove('active'); }
        await raw.execute('ALTER TABLE $table DROP COLUMN active');
      }
      await raw.setVersion(11);
      await db.close();
      expect(await (await db.db).getVersion(), AppDatabase.schemaVersion);
      expect((await db.customers()).single.active, isTrue);
      expect((await db.products()).single.active, isTrue);
      expect(await db.customerOutstanding(1), 123);
      final target = open('${dir.path}/restore.db');
      try {
        await target.restoreSnapshotJson(jsonEncode(archive));
        expect((await target.customers()).single.active, isTrue);
        expect((await target.products()).single.active, isTrue);
        expect(await target.customerOutstanding(1), 123);
        final invalid = jsonDecode(await target.exportSnapshotJson()) as Map;
        (((invalid['tables'] as Map)['customers'] as List).single as Map)['active'] = 7;
        expect(() => BackupSnapshot.parse(jsonEncode(invalid)), throwsFormatException);
      } finally { await target.close(); }
    } finally { await db.close(); await dir.delete(recursive: true); }
  });
}
