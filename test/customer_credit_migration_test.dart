import 'legacy_refund_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/customer_credit_ledger.dart';
import 'package:kaibao_sales/data/sale_credit_schema.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final fail in [false, true]) {
    test('v8→v9 ${fail ? '迁移失败不破坏原数据和版本' : '保留历史修订、收款、旧余额并恢复旧备份'}', () async {
      final temp = await Directory.systemTemp.createTemp('kaibao-credit-migration-');
      final path = p.join(temp.path, 'old.db');
      var db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
      try {
        await db.addCustomer(const Customer(name: '旧客户'));
        await db.createSale(customer: (await db.customers()).single, lines: const [
          SaleLine(code: 'X', lengthMilli: 20000, widthMilli: 1000, unitPriceCents: 1000)],
          discountCents: 0, initialReceivedCents: 20000);
        final sale = (await db.saleById(1))!;
        await db.reviseSale(saleId: 1, expectedRevision: 0, requestKey: 'old-credit-revision',
          customerId: 1, date: '2026-11-08', lines: [SaleLine(id: sale.lines.single.id,
            code: 'X', lengthMilli: 10000, widthMilli: 1000, unitPriceCents: 1000)], discountCents: 0, note: '旧版修改');
        final raw = await db.db;
        await raw.transaction((tx) => CustomerCreditLedger.post(tx, customerId: 1,
          saleId: 1, requestKey: 'old-credit-ledger-fixture', deltaCents: 500,
          reason: '模拟旧版既有余额，非新业务入账', createdAt: DateTime(2026, 11, 7)));
        await SaleCreditSchema.adoptLegacyEntries(raw);
        final archive = jsonDecode(await db.exportSnapshotJson()) as Map<String,dynamic>;
        removeRefundArchiveTables(archive);
        archive['schemaVersion'] = 8;
        final tables = archive['tables'] as Map;
        for (final name in ['payment_requests', ...SaleCreditSchema.columns.keys]) { tables.remove(name); }
        for (final row in tables['sale_revisions'] as List) {
          final s = jsonDecode((row as Map)['snapshot'] as String) as Map;
          for (final key in ['creditCutoff','creditAppliedCents','transferredCents']) { s.remove(key); }
          row['snapshot'] = jsonEncode(s);
          await raw.update('sale_revisions', {'snapshot': row['snapshot']}, where: 'id=?', whereArgs: [row['id']]);
        }
        for (final name in ['payment_requests', ...SaleCreditSchema.columns.keys.toList().reversed]) { await raw.execute('DROP TABLE $name'); }
        await removeRefundDatabaseTables(raw); await raw.setVersion(8);
        final originalSales = await raw.query('sales');
        final originalPayments = await raw.query('payments');
        final originalRevisions = await raw.query('sale_revisions');
        if (fail) await raw.execute('CREATE TABLE sale_creation_requests (marker TEXT)');
        await db.close();
        db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
        if (fail) {
          await expectLater(db.db, throwsA(isA<DatabaseException>()));
          final check = await databaseFactoryFfi.openDatabase(path);
          try {
            expect(await check.getVersion(), 8);
            expect(await check.query('sales'), originalSales);
            expect(await check.query('payments'), originalPayments);
            expect(await check.query('sale_revisions'), originalRevisions);
            expect(await CustomerCreditLedger.balance(check, 1), 500);
            expect(await check.rawQuery("SELECT name FROM sqlite_master WHERE name='sale_credit_events'"), isEmpty);
            expect(await check.rawQuery('PRAGMA integrity_check'), [{'integrity_check':'ok'}]);
          } finally { await check.close(); }
          // A failed open is now retryable; close must remain safe and read-only.
          await expectLater(db.db, throwsA(isA<DatabaseException>()));
          await db.close();
        } else {
          final upgraded = await db.db;
          expect(await upgraded.getVersion(), AppDatabase.schemaVersion);
          expect(await upgraded.query('sales'), originalSales);
          expect(await upgraded.query('payments'), originalPayments);
          expect(await upgraded.query('sale_revisions'), originalRevisions);
          expect((await db.customerCreditAccount(1)).balanceCents, 500);
          expect((await db.saleRevisions(1)).length, 2);
          expect((await upgraded.query('sale_credit_events')).single['kind'], 'legacy');
          final restored = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: p.join(temp.path, 'restore.db'));
          try {
            await restored.restoreSnapshotJson(jsonEncode(archive));
            expect((await restored.customerCreditAccount(1)).balanceCents, 500);
            expect((await restored.pendingSaleRefunds(1)).single.amountCents, 10000);
            expect((await restored.saleById(1))!.creditAppliedCents, 0);
            await restored.transferSaleRefundToCredit(saleId: 1, expectedRevision: 1,
              customerId: 1, epoch: 0, amountCents: 10000, requestKey: 'old-restore-transfer');
            final consumer = await restored.createSaleWithCredit(customer: (await restored.customers()).single,
              lines: const [SaleLine(code: 'X', lengthMilli: 10000, widthMilli: 1000, unitPriceCents: 1000)],
              discountCents: 0, initialReceivedCents: 2000, requestKey: 'old-restore-new-sale');
            expect((await restored.saleById(consumer))!.creditAppliedCents, 8000);
            expect((await restored.customerCreditAccount(1)).balanceCents, 2500);
            await restored.exportSnapshotJson();
          } finally { await restored.close(); }
        }
      } finally { await db.close(); await temp.delete(recursive: true); }
    });
  }
}
