import 'legacy_refund_fixture.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/customer_credit_ledger.dart';
import 'package:kaibao_sales/data/sale_revision_schema.dart';
import 'package:kaibao_sales/data/sale_credit_schema.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/services/backup_codec.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  for (final failMigration in [false, true]) {
    test('v7→v8 ${failMigration ? '中途失败保留旧库且建表回滚' : '保留旧收款/余额，兼容旧备份，改单后加密恢复'}', () async {
      final temp = await Directory.systemTemp.createTemp('kaibao-v7-upgrade-');
      final path = p.join(temp.path, 'legacy.db');
      var source = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
      try {
        await source.addCustomer(const Customer(name: '旧客户'));
        await source.createSale(customer: (await source.customers()).single,
          lines: const [SaleLine(code: 'OLD', lengthMilli: 1000, widthMilli: 2000, unitPriceCents: 1000)],
          discountCents: 0, initialReceivedCents: 1500);
        await (await source.db).transaction((tx) => CustomerCreditLedger.post(tx,
          customerId: 1, saleId: 1, requestKey: 'legacy-credit-fixture-001',
          deltaCents: 500, reason: '迁移存储夹具，非真实退款', createdAt: DateTime(2026, 11, 7)));
        await SaleCreditSchema.adoptLegacyEntries(await source.db);
        // Reconstruct v7 by removing only additive v8 tables. This is a
        // controlled fixture, not a claim of testing a historical device DB.
        final oldArchive = jsonDecode(await source.exportSnapshotJson()) as Map<String,dynamic>;
        removeRefundArchiveTables(oldArchive);
        oldArchive['schemaVersion'] = 7;
        for (final table in ['payment_requests', ...SaleCreditSchema.columns.keys, ...SaleRevisionSchema.columns.keys]) {
          (oldArchive['tables'] as Map).remove(table);
        }
        final raw = await source.db;
        for (final table in ['payment_requests', ...SaleCreditSchema.columns.keys.toList().reversed, ...SaleRevisionSchema.columns.keys.toList().reversed]) {
          await raw.execute('DROP TABLE $table');
        }
        if (failMigration) await raw.execute('CREATE TABLE sale_payment_contexts (marker TEXT)');
        await removeRefundDatabaseTables(raw); await raw.setVersion(7);
        await source.close();
        source = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
        if (failMigration) {
          await expectLater(source.db, throwsA(isA<DatabaseException>()));
          final unchanged = await databaseFactoryFfi.openDatabase(path);
          try {
            expect(await unchanged.getVersion(), 7);
            expect((await unchanged.query('payments')).single['amount_cents'], 1500);
            expect(await CustomerCreditLedger.balance(unchanged, 1), 500);
            expect(await unchanged.rawQuery("SELECT name FROM sqlite_master WHERE name='sale_revisions'"), isEmpty);
            expect(await unchanged.rawQuery("SELECT name FROM sqlite_master WHERE name='sale_line_origins'"), isEmpty);
          } finally { await unchanged.close(); }
          // A failed open is now retryable; close must remain safe and read-only.
          await expectLater(source.db, throwsA(isA<DatabaseException>()));
          await source.close();
        } else {
          expect(await (await source.db).getVersion(), AppDatabase.schemaVersion);
          expect((await source.saleById(1))!.receivedCents, 1500);
          expect(await CustomerCreditLedger.balance(await source.db, 1), 500);
          final restored = AppDatabase.forTesting(factory: databaseFactoryFfi,
            databasePath: p.join(temp.path, 'old-restore.db'));
          try {
            await restored.restoreSnapshotJson(jsonEncode(oldArchive));
            expect((await restored.saleById(1))!.currentDueCents, 500);
            expect(await CustomerCreditLedger.balance(await restored.db, 1), 500);
          } finally { await restored.close(); }
          final sale = (await source.saleById(1))!;
          await source.reviseSale(saleId: 1, expectedRevision: 0,
            requestKey: 'v7-upgrade-revision-001', customerId: 1, date: '2026-11-06',
            lines: [SaleLine(id: sale.lines.single.id, code: 'OLD', lengthMilli: 500,
              widthMilli: 2000, unitPriceCents: 1000)], discountCents: 0, note: '升级后改单');
          final plain = await source.exportSnapshotJson();
          const password = 'v8-revision-restore-password';
          final encrypted = await BackupCodec.encrypt(plain, password);
          final targetPath = p.join(temp.path, 'revised-restore.db');
          final target = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
          try {
            await target.restoreSnapshotJson(await BackupCodec.decrypt(encrypted, password));
          } finally { await target.close(); }
          final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: targetPath);
          try {
            expect((jsonDecode(await reopened.exportSnapshotJson()) as Map)['tables'],
              (jsonDecode(plain) as Map)['tables']);
            expect((await reopened.pendingSaleRefunds(1)).single.amountCents, 500);
            expect(await CustomerCreditLedger.balance(await reopened.db, 1), 500);
            expect((await reopened.saleRevisions(1)).length, 2);
            expect(await reopened.integrityOk(), isTrue);
          } finally { await reopened.close(); }
        }
      } finally {
        await source.close();
        await temp.delete(recursive: true);
      }
    });
  }
}
