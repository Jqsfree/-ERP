import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'legacy_refund_fixture.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  for (final failure in [false, true]) {
    test(
      'v10→v11 ${failure ? '迁移失败整事务回滚，不改旧款' : '保留历史、空退款表、兼容v10备份及关闭重开'}',
      () async {
        final dir = await Directory.systemTemp.createTemp('refund-migration-');
        final path = '${dir.path}/old.db';
        final db = AppDatabase.forTesting(
          factory: databaseFactoryFfi,
          databasePath: path,
        );
        try {
          await db.addCustomer(const Customer(name: '旧客户'));
          final sid = await db.createSale(
            customer: (await db.customers()).single,
            lines: const [
              SaleLine(
                code: 'X',
                lengthMilli: 1000,
                widthMilli: 1000,
                unitPriceCents: 10000,
              ),
            ],
            discountCents: 0,
            initialReceivedCents: 1000,
          );
          final archive = jsonDecode(await db.exportSnapshotJson()) as Map;
          removeRefundArchiveTables(archive);
          archive['schemaVersion'] = 10;
          final raw = await db.db;
          await removeRefundDatabaseTables(raw);
          await raw.setVersion(10);
          final before = await raw.query('payments');
          if (failure) {
            await raw.execute('CREATE TABLE sale_refund_events (marker TEXT)');
          }
          await db.close();
          if (failure) {
            await expectLater(db.db, throwsA(isA<DatabaseException>()));
            final untouched = await databaseFactoryFfi.openDatabase(
              path,
              options: OpenDatabaseOptions(readOnly: true),
            );
            try {
              expect(await untouched.getVersion(), 10);
              expect(await untouched.query('payments'), before);
              expect(
                (await untouched.rawQuery(
                  'PRAGMA table_info(sale_credit_events)',
                )).any((c) => c['name'] == 'refund_cutoff'),
                isFalse,
              );
              expect(
                (await untouched.rawQuery(
                  "SELECT name FROM sqlite_master WHERE name='refund_requests'",
                )),
                isEmpty,
              );
            } finally {
              await untouched.close();
            }
          } else {
            expect(await (await db.db).getVersion(), 11);
            expect(await (await db.db).query('payments'), before);
            expect(await db.saleRefundEvents(sid), isEmpty);
            expect((await db.saleById(sid))!.refundedCents, 0);
            final target = AppDatabase.forTesting(
              factory: databaseFactoryFfi,
              databasePath: '${dir.path}/restored.db',
            );
            try {
              await target.restoreSnapshotJson(jsonEncode(archive));
              await target.close();
              expect((await target.saleById(sid))!.receivedCents, 1000);
              expect((await target.saleById(sid))!.currentDueCents, 9000);
              BackupSnapshot.parse(await target.exportSnapshotJson());
            } finally {
              await target.close();
            }
          }
        } finally {
          try {
            await db.close();
          } catch (_) {
            /* expected failed opening */
          }
          await dir.delete(recursive: true);
        }
      },
    );
  }
}
