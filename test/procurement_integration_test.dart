import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/domain/procurement.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;
  late AppDatabase store;
  late String path;

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kaibao-po-');
    path = p.join(dir.path, 'db.sqlite');
    store = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: path, clock: () => DateTime(2026, 11, 7, 11));
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  Future<(Supplier, Product)> seed() async {
    await store.addSupplier(const Supplier(name: '上海供应商', phone: '1234'));
    await store.addProduct(const Product(
      code: 'FB-01', specification: '棉布', unitPriceCents: 2000));
    return ((await store.suppliers()).single, (await store.products()).single);
  }

  PurchaseLine line(Product product, {int length = 37000, int cost = 1000}) =>
      PurchaseLine(productId: product.id!, code: '忽略这个客户端名称',
        lengthMilli: length, widthMilli: 2800, unitCostCents: cost);

  test('供应商可新增、修改、停用、重新打开；不允许重名', () async {
    await store.addSupplier(const Supplier(name: '布料厂A'));
    final supplier = (await store.suppliers()).single;
    expect(supplier.active, isTrue);
    await store.updateSupplier(Supplier(
      id: supplier.id, name: '布料厂A', phone: '18611112222',
      note: '测试备注', active: false));
    expect(await store.suppliers(includeInactive: false), isEmpty);
    await expectLater(store.addSupplier(const Supplier(name: '布料厂A')),
      throwsA(isA<Exception>()));
    await store.close();
    final reopened = AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: path);
    try {
      final actual = (await reopened.suppliers()).single;
      expect(actual.phone, '18611112222');
      expect(actual.note, '测试备注');
      expect(actual.active, isFalse);
      expect(await reopened.integrityOk(), isTrue);
    } finally {
      await reopened.close();
    }
  });

  test('采购订单多行计算、服务端产品快照、历史持久化；不改变销售和库存', () async {
    final (supplier, product) = await seed();
    final id = await store.createPurchaseOrder(
      supplierId: supplier.id!,
      lines: [line(product), line(product, length: 1000, cost: 2000)],
      note: '订单报价');
    final order = (await store.purchaseOrderById(id))!;
    expect(order.number, 'CG202611070001');
    expect(order.lines, hasLength(2));
    expect(order.lines.first.code, 'FB-01');
    expect(order.lines.first.specification, '棉布');
    expect(order.lines.first.amountCents, 103600);
    expect(order.totalCents, 109200);
    expect(order.status, 'ordered');
    expect(await store.sales(), isEmpty);

    await store.close();
    final reopened = AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: path);
    try {
      expect((await reopened.purchaseOrders()).single.totalCents, 109200);
      expect((await reopened.purchaseOrders()).single.lines, hasLength(2));
      expect(await reopened.integrityOk(), isTrue);
    } finally {
      await reopened.close();
    }
  });

  test('非法采购回滚、停用供应商不可采购、取消保留历史', () async {
    final (supplier, product) = await seed();
    await expectLater(store.createPurchaseOrder(
      supplierId: supplier.id!, lines: [line(product),
        const PurchaseLine(productId: 999999, code: 'BAD',
          lengthMilli: 1000, widthMilli: 2000, unitCostCents: 1000)]),
      throwsArgumentError);
    expect(await store.purchaseOrders(), isEmpty);

    await store.updateSupplier(Supplier(
      id: supplier.id, name: supplier.name, active: false));
    await expectLater(store.createPurchaseOrder(
      supplierId: supplier.id!, lines: [line(product)]), throwsStateError);
    await store.updateSupplier(Supplier(
      id: supplier.id, name: supplier.name, active: true));
    final id = await store.createPurchaseOrder(
      supplierId: supplier.id!, lines: [line(product)]);
    await store.cancelPurchaseOrder(id);
    await store.cancelPurchaseOrder(id);
    expect((await store.purchaseOrderById(id))!.status, 'cancelled');
    expect((await store.purchaseOrderById(id))!.lines, hasLength(1));
    expect(await store.integrityOk(), isTrue);
  });

  test('并发开单单号唯一；备份 v3 加密前快照恢复金额不变', () async {
    final (supplier, product) = await seed();
    final ids = await Future.wait(List.generate(6, (_) =>
      store.createPurchaseOrder(
        supplierId: supplier.id!, lines: [line(product)])));
    expect(ids.toSet(), hasLength(6));
    final orders = await store.purchaseOrders();
    expect(orders.map((o) => o.number).toSet(), hasLength(6));

    final snapshot = await store.exportSnapshotJson();
    final parsed = BackupSnapshot.parse(snapshot);
    expect(parsed.counts['suppliers'], 1);
    expect(parsed.counts['purchase_orders'], 6);
    expect(parsed.counts['purchase_lines'], 6);

    final restored = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(dir.path, 'restored.sqlite'));
    try {
      await restored.restoreSnapshotJson(snapshot);
      expect((await restored.purchaseOrders()).map((o) => o.totalCents).toList(),
        orders.map((o) => o.totalCents).toList());
      expect(await restored.integrityOk(), isTrue);
    } finally {
      await restored.close();
    }

    final corrupted = jsonDecode(snapshot) as Map<String, dynamic>;
    final tables = corrupted['tables'] as Map<String, dynamic>;
    ((tables['purchase_lines'] as List).first as Map<String, dynamic>)['amount_cents'] = 1;
    expect(() => BackupSnapshot.parse(jsonEncode(corrupted)), throwsFormatException);
  });

  test('既有 v2 数据库迁移到 v3 不丢客户和产品', () async {
    await store.close();
    final old = await databaseFactoryFfi.openDatabase(path,
      options: OpenDatabaseOptions(version: 2, onCreate: (db, _) async {
        await db.execute('''CREATE TABLE customers (
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE,
          phone TEXT NOT NULL DEFAULT '', address TEXT NOT NULL DEFAULT '',
          opening_balance_cents INTEGER NOT NULL DEFAULT 0)''');
        await db.execute('''CREATE TABLE products (
          id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL UNIQUE,
          specification TEXT NOT NULL DEFAULT '',
          unit_price_cents INTEGER NOT NULL CHECK(unit_price_cents >= 0))''');
        await db.execute('''CREATE TABLE sales (
          id INTEGER PRIMARY KEY AUTOINCREMENT, number TEXT NOT NULL UNIQUE,
          date TEXT NOT NULL, customer_id INTEGER NOT NULL REFERENCES customers(id),
          customer_name_snapshot TEXT NOT NULL, customer_phone_snapshot TEXT NOT NULL,
          customer_address_snapshot TEXT NOT NULL, subtotal_cents INTEGER NOT NULL,
          discount_cents INTEGER NOT NULL, prior_due_snapshot INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'confirmed', note TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE sale_lines (
          id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL REFERENCES sales(id),
          product_id INTEGER REFERENCES products(id), code_snapshot TEXT NOT NULL,
          spec_snapshot TEXT NOT NULL DEFAULT '', length_milli INTEGER NOT NULL,
          width_milli INTEGER NOT NULL, unit_price_cents INTEGER NOT NULL,
          amount_cents INTEGER NOT NULL, note TEXT NOT NULL DEFAULT '')''');
        await db.execute('''CREATE TABLE payments (
          id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL REFERENCES sales(id),
          amount_cents INTEGER NOT NULL, method TEXT NOT NULL DEFAULT '其他',
          remark TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE sale_drafts (
          id INTEGER PRIMARY KEY CHECK(id = 1),
          payload TEXT NOT NULL, updated_at TEXT NOT NULL)''');
        await db.insert('customers', {'name': 'v2 客户'});
        await db.insert('products', {'code': 'v2-ITEM', 'unit_price_cents': 1500});
      }));
    await old.close();
    final upgraded = AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: path);
    try {
      expect((await upgraded.db).getVersion(), completion(AppDatabase.schemaVersion));
      expect((await upgraded.customers()).single.name, 'v2 客户');
      expect((await upgraded.products()).single.code, 'v2-ITEM');
      expect(await upgraded.suppliers(), isEmpty);
      await upgraded.addSupplier(const Supplier(name: '新供应商'));
      expect((await upgraded.suppliers()).single.name, '新供应商');
      expect(await upgraded.integrityOk(), isTrue);
    } finally {
      await upgraded.close();
    }
  });

  test('旧版 v2 逻辑备份恢复到 v3 时采购表为空，原有记录保留', () async {
    await store.addCustomer(const Customer(name: '保留客户'));
    final newBackup = jsonDecode(await store.exportSnapshotJson()) as Map<String, dynamic>;
    newBackup['schemaVersion'] = 2;
    final tables = newBackup['tables'] as Map<String, dynamic>;
    tables.remove('suppliers');
    tables.remove('purchase_orders');
    tables.remove('purchase_lines');
    for (final table in ['sale_dispatches', 'sale_dispatch_lines',
        'sale_returns', 'sale_return_lines',
        'cash_entries', 'day_closures']) { tables.remove(table); }
    for (final name in ['warehouses', 'purchase_receipts',
        'purchase_receipt_lines', 'stock_movements']) {
      tables.remove(name);
    }
    final oldBackup = jsonEncode(newBackup);
    final parsed = BackupSnapshot.parse(oldBackup);
    expect(parsed.counts['suppliers'], 0);
    final recovered = AppDatabase.forTesting(
      factory: databaseFactoryFfi, databasePath: p.join(dir.path, 'older.sqlite'));
    try {
      await recovered.restoreSnapshotJson(oldBackup);
      expect((await recovered.customers()).single.name, '保留客户');
      expect(await recovered.purchaseOrders(), isEmpty);
      expect(await recovered.integrityOk(), isTrue);
    } finally {
      await recovered.close();
    }
  });
}
