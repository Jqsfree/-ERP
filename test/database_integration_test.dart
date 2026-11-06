import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/domain/models.dart';

void main() {
  late Directory temporary;
  late String path;
  late AppDatabase db;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('kaibao-db-test-');
    path = p.join(temporary.path, 'sales.db');
    db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path,
      clock: () => DateTime(2026, 11, 6, 10));
  });

  tearDown(() async {
    await db.close();
    await temporary.delete(recursive: true);
  });

  Future<Customer> addCustomer() async {
    await db.addCustomer(const Customer(name: '客户A', phone: '13900001111',
      address: '门店地址', openingBalanceCents: 3000));
    return (await db.customers()).single;
  }

  SaleLine sampleLine({int? productId}) => SaleLine(
    productId: productId, code: 'KB56-34', specification: '示例',
    lengthMilli: 37000, widthMilli: 2800, unitPriceCents: 1399);

  test('真实数据库写入、查询、关闭重开：客户、产品、销售与收款仍存在', () async {
    final customer = await addCustomer();
    await db.addProduct(const Product(code: 'KB56-34', unitPriceCents: 1399));
    final product = (await db.products()).single;
    final saleId = await db.createSale(customer: customer,
      lines: [sampleLine(productId: product.id)],
      discountCents: 36, initialReceivedCents: 50000, note: '测试订单');
    final before = await db.saleById(saleId);
    expect(before, isNotNull);
    expect(before!.number, 'XS202611060001');
    expect(before.payableCents, 144900);
    expect(before.currentDueCents, 94900);
    expect(before.priorDueCents, 3000);
    expect(await db.customerOutstanding(customer.id!), 97900);
    expect(await db.integrityOk(), isTrue);

    await db.close();
    final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: path);
    try {
      expect((await reopened.customers()).single.name, '客户A');
      expect((await reopened.products()).single.code, 'KB56-34');
      final after = (await reopened.sales()).single;
      expect(after.lines.single.totalCents, 144936);
      expect(after.receivedCents, 50000);
      expect(after.currentDueCents, 94900);
      expect(await reopened.integrityOk(), isTrue);
    } finally {
      await reopened.close();
    }
  });

  test('事务回滚：产品外键失效时销售、明细与收款均不落库', () async {
    final customer = await addCustomer();
    await expectLater(
      db.createSale(customer: customer, lines: [sampleLine(productId: 999999)],
        discountCents: 0, initialReceivedCents: 100),
      throwsA(isA<Exception>()));
    expect(await db.sales(), isEmpty);
    expect(await db.customerOutstanding(customer.id!), 3000);
    expect(await db.integrityOk(), isTrue);
  });

  test('收款超额拒绝且余额不变；合法部分收款仍持久化', () async {
    final customer = await addCustomer();
    final id = await db.createSale(customer: customer, lines: [sampleLine()],
      discountCents: 36, initialReceivedCents: 0);
    final sale = (await db.saleById(id))!;
    await expectLater(db.addPayment(sale, 144901), throwsArgumentError);
    expect((await db.saleById(id))!.receivedCents, 0);
    await db.addPayment(sale, 50000, method: '微信');
    await db.addPayment(sale, 94900, method: '现金');
    await expectLater(db.addPayment(sale, 1), throwsArgumentError);
    final loaded = (await db.saleById(id))!;
    expect(loaded.receivedCents, 144900);
    expect(loaded.currentDueCents, 0);
    expect(await db.customerOutstanding(customer.id!), 3000);
  });

  test('并发开单编号必须唯一，且所有明细可读取', () async {
    final customer = await addCustomer();
    final ids = await Future.wait(List.generate(6, (_) => db.createSale(
      customer: customer, lines: [sampleLine()],
      discountCents: 0, initialReceivedCents: 0)));
    expect(ids.toSet().length, 6);
    final sales = await db.sales();
    expect(sales, hasLength(6));
    expect(sales.map((s) => s.number).toSet().length, 6);
    expect(sales.every((s) => s.lines.length == 1), isTrue);
  });

  test('草稿持久化，不属于财务账；正式开单成功后原子清除', () async {
    const payload = '{"customerId":1,"length":"37","width":"2.8"}';
    await db.saveDraft(payload);
    expect(await db.loadDraft(), payload);
    await db.close();
    final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: path, clock: () => DateTime(2026, 11, 6));
    try {
      expect(await reopened.loadDraft(), payload);
      expect(await reopened.sales(), isEmpty);
      final customer = await addCustomerThrough(reopened);
      await reopened.createSale(customer: customer, lines: [sampleLine()],
        discountCents: 0, initialReceivedCents: 0);
      expect(await reopened.loadDraft(), isNull);
    } finally {
      await reopened.close();
    }
  });

  test('数据库 v1 -> v2 迁移保留客户且增加草稿表', () async {
    await db.close();
    final legacy = await databaseFactoryFfi.openDatabase(path,
      options: OpenDatabaseOptions(version: 1,
        onCreate: (raw, version) async {
          await raw.execute('''CREATE TABLE customers (
            id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE,
            phone TEXT NOT NULL DEFAULT '', address TEXT NOT NULL DEFAULT '',
            opening_balance_cents INTEGER NOT NULL DEFAULT 0)''');
          await raw.insert('customers', {
            'name': '旧客户', 'phone': '', 'address': '',
            'opening_balance_cents': 12500,
          });
        }));
    await legacy.close();
    final upgraded = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: path);
    try {
      expect((await upgraded.customers()).single.name, '旧客户');
      expect((await upgraded.db).getVersion(), completion(AppDatabase.schemaVersion));
      await upgraded.saveDraft('{"text":"迁移完成"}');
      expect(await upgraded.loadDraft(), contains('迁移完成'));
    } finally {
      await upgraded.close();
    }
  });
}

Future<Customer> addCustomerThrough(AppDatabase db) async {
  await db.addCustomer(const Customer(name: '客户B'));
  return (await db.customers()).single;
}
