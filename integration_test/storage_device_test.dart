import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:kaibao_sales/domain/inventory.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android 设备 SQLite：写入、关闭、重开、欠款核对和完整性检查', (tester) async {
    // Independent database; must never touch kaibao_sales.db or production data.
    final base = await getDatabasesPath();
    final id = DateTime.now().microsecondsSinceEpoch + Random.secure().nextInt(1000000);
    final filename = p.join(base, 'kaibao_device_integration_$id.db');
    final store = AppDatabase.forTesting(
      databasePath: filename, factory: databaseFactory,
      clock: () => DateTime(2026, 11, 7, 12),
    );
    try {
      await store.addCustomer(const Customer(name: '测试客户-设备', openingBalanceCents: 500));
      await store.addProduct(const Product(code: 'TEST-01', unitPriceCents: 1399));
      final customer = (await store.customers()).single;
      final product = (await store.products()).single;
      await store.saveDraft('{"schema":1,"from":"device-test"}');
      final id = await store.createSale(
        customer: customer,
        lines: [SaleLine(productId: product.id, code: product.code,
          lengthMilli: 37000, widthMilli: 2800, unitPriceCents: product.unitPriceCents)],
        discountCents: 36, initialReceivedCents: 50000);
      expect((await store.saleById(id))!.payableCents, 144900);
      expect(await store.loadDraft(), isNull);
      await store.addSupplier(const Supplier(name: '设备测试供应商'));
      final supplier = (await store.suppliers()).single;
      final purchaseId = await store.createPurchaseOrder(
        supplierId: supplier.id!,
        lines: [PurchaseLine(productId: product.id!, code: product.code,
          lengthMilli: 1000, widthMilli: 2800, unitCostCents: 1000)]);
      expect((await store.purchaseOrderById(purchaseId))!.totalCents, 2800);
      final warehouseId = await store.addWarehouse(
        code: 'ANDROID-MAIN', name: '真机测试仓');
      final purchaseLineId = (await store.receivableLines(purchaseId)).single.lineId;
      final receiptId = await store.postPurchaseReceipt(
        purchaseOrderId: purchaseId, requestKey: 'android-sqlite-receipt-001',
        lines: [ReceiptInputLine(purchaseLineId: purchaseLineId,
          warehouseId: warehouseId, lengthMilli: 500, batchCode: 'T1')]);
      expect(receiptId, greaterThan(0));
      expect((await store.stockBalances()).single.areaMicro, 1400000);
      expect((await store.receivableLines(purchaseId)).single.remainingLengthMilli, 500);
      expect(await store.integrityOk(), isTrue);
      await store.close();

      final reopened = AppDatabase.forTesting(
        databasePath: filename, factory: databaseFactory);
      try {
        final sale = (await reopened.sales()).single;
        expect(sale.number, 'XS202611070001');
        expect(sale.currentDueCents, 94900);
        expect((await reopened.suppliers()).single.name, '设备测试供应商');
        expect((await reopened.purchaseOrders()).single.totalCents, 2800);
        expect((await reopened.stockBalances()).single.areaMicro, 1400000);
        expect((await reopened.stockMovements()).single.batchCode, 'T1');
        expect(await reopened.customerOutstanding(customer.id!), 95400);
        expect(await reopened.integrityOk(), isTrue);
      } finally {
        await reopened.close();
      }
    } finally {
      await store.close();
      await deleteDatabase(filename);
    }
  });
}
