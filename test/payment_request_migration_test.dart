import 'legacy_refund_fixture.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final fail in [false, true]) {
    test('v9→v10 ${fail ? '失败回滚保留原库' : '历史交易保留、旧快照恢复及新请求持久保存'}', () async {
      final dir = await Directory.systemTemp.createTemp('payment-migration-');
      final path = '${dir.path}/old.db';
      final db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
      try {
        await db.addCustomer(const Customer(name: 'C'));
        final id = await db.createSale(customer: (await db.customers()).single, lines: const [SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 1000, unitPriceCents: 10000)], discountCents: 0, initialReceivedCents: 1000);
        final raw = await db.db;
        final headers = await raw.query('sales'); final payments = await raw.query('payments');
        final archive = jsonDecode(await db.exportSnapshotJson()) as Map;
        removeRefundArchiveTables(archive);
        archive['schemaVersion'] = 9; (archive['tables'] as Map).remove('payment_requests');
        await raw.execute('DROP TABLE payment_requests'); await removeRefundDatabaseTables(raw); await raw.setVersion(9);
        if (fail) await raw.execute('CREATE TABLE payment_requests (marker TEXT)');
        await db.close();
        if (fail) {
          await expectLater(db.db, throwsA(isA<Exception>()));
          final untouched = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(readOnly: true));
          try {
            expect(await untouched.getVersion(), 9); expect(await untouched.query('sales'), headers); expect(await untouched.query('payments'), payments);
          } finally { await untouched.close(); }
        } else {
          final upgraded = await db.db;
          expect(await upgraded.getVersion(), AppDatabase.schemaVersion); expect(await upgraded.query('sales'), headers); expect(await upgraded.query('payments'), payments);
          expect(await upgraded.query('payment_requests'), isEmpty);
          final target = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: '${dir.path}/restored');
          try {
            await target.restoreSnapshotJson(jsonEncode(archive));
            expect((await target.saleById(id))!.receivedCents, 1000);
            await target.addPayment((await target.saleById(id))!, 2000, requestKey: 'migrated-payment-01');
            final snapshot = await target.exportSnapshotJson();
            final bad = jsonDecode(snapshot) as Map;
            (((bad['tables'] as Map)['payment_requests'] as List).single as Map)['amount_cents'] = 3000;
            final empty = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: '${dir.path}/empty');
            try {
              await expectLater(empty.restoreSnapshotJson(jsonEncode(bad)), throwsFormatException);
              expect(await (await empty.db).query('customers'), isEmpty);
            } finally { await empty.close(); }
          } finally { await target.close(); }
        }
      } finally {
        try { await db.close(); } catch (_) { /* intentionally failed opening future */ }
        await dir.delete(recursive: true);
      }
    });
  }
}
