import 'legacy_refund_fixture.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/customer_credit_ledger.dart';
import 'package:kaibao_sales/data/sale_credit_schema.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/services/backup_codec.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory temp;
  late AppDatabase source;
  late String path;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('kaibao-release-storage-');
    path = p.join(temp.path, 'source.db');
    source = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: path, clock: () => DateTime(2026, 11, 7, 10));
    await source.addCustomer(const Customer(name: '迁移客户', openingBalanceCents: 300));
    await source.addProduct(const Product(code: 'MIG-1', unitPriceCents: 1000));
    final product = (await source.products()).single;
    await source.createSale(customer: (await source.customers()).single,
      lines: [SaleLine(productId: product.id, code: product.code,
        lengthMilli: 1000, widthMilli: 2000, unitPriceCents: 1000)],
      discountCents: 0, initialReceivedCents: 500);
  });
  tearDown(() async {
    await source.close();
    await temp.delete(recursive: true);
  });

  // v7 is additive: removing its only table reconstructs the v6 schema.
  // This is an isolated fixture, not a historical device database.
  Future<void> asV6({bool conflict = false}) async {
    final raw = await source.db;
    for (final table in ['payment_requests', 'sale_creation_requests', 'sale_credit_events',
        'sale_dispatch_contexts', 'sale_payment_contexts',
        'sale_line_origins', 'sale_revisions']) {
      await raw.execute('DROP TABLE $table');
    }
    await raw.execute('DROP TABLE customer_credit_entries');
    if (conflict) {
      await raw.execute('CREATE TABLE customer_credit_entries (marker TEXT)');
      await raw.insert('customer_credit_entries', {'marker': 'must survive'});
    }
    await removeRefundDatabaseTables(raw); await raw.setVersion(6);
    await source.close();
  }

  test('v6→当前版 保留销售、收款及客户欠款并创建余额表', () async {
    final before = jsonDecode(await source.exportSnapshotJson()) as Map<String, dynamic>;
    await asV6();
    final upgraded = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
    try {
      final after = jsonDecode(await upgraded.exportSnapshotJson()) as Map<String, dynamic>;
      expect(after['tables'], before['tables']);
      expect(await (await upgraded.db).getVersion(), AppDatabase.schemaVersion);
      expect(await upgraded.customerOutstanding(1), 1800);
      expect(await upgraded.integrityOk(), isTrue);
    } finally {
      await upgraded.close();
    }
  });

  test('余额流水经加密备份、空库恢复和重启后逐表一致', () async {
    final raw = await source.db;
    await raw.transaction((tx) async {
      for (final entry in [('storage-credit-001', 800), ('storage-debit-0001', -300)]) {
        await CustomerCreditLedger.post(tx, customerId: 1, saleId: 1,
          requestKey: entry.$1, deltaCents: entry.$2,
          reason: '存储测试夹具，非真实退款', createdAt: DateTime(2026, 11, 7, 11));
      }
    });
    await SaleCreditSchema.adoptLegacyEntries(raw);
    final plain = await source.exportSnapshotJson();
    final encrypted = await BackupCodec.encrypt(plain, 'storage-test-password-2026');
    final targetPath = p.join(temp.path, 'restored.db');
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
    try {
      await target.restoreSnapshotJson(await BackupCodec.decrypt(encrypted, 'storage-test-password-2026'));
    } finally {
      await target.close();
    }
    final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
    try {
      expect((jsonDecode(await reopened.exportSnapshotJson()) as Map)['tables'],
        (jsonDecode(plain) as Map)['tables']);
      expect(await CustomerCreditLedger.balance(await reopened.db, 1), 500);
      expect(await reopened.customerOutstanding(1), 1800);
      expect(await reopened.integrityOk(), isTrue);
    } finally {
      await reopened.close();
    }
  });

  test('迁移遇到冲突失败后版本、销售及收款仍保留', () async {
    final raw = await source.db;
    final sales = await raw.query('sales');
    final payments = await raw.query('payments');
    await asV6(conflict: true);
    final failing = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
    await expectLater(failing.db, throwsA(isA<DatabaseException>()));
    // A rejected opening future cannot be closed through AppDatabase.close.
    final check = await databaseFactoryFfi.openDatabase(path);
    try {
      expect(await check.getVersion(), 6);
      expect(await check.query('sales'), sales);
      expect(await check.query('payments'), payments);
      expect((await check.query('customer_credit_entries')).single['marker'], 'must survive');
      expect(await check.rawQuery('PRAGMA integrity_check'), [{'integrity_check': 'ok'}]);
    } finally {
      await check.close();
    }
  });
}
