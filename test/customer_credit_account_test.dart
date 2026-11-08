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
  test('真实SQLite：余额页流水逐笔余额、客户隔离、重启及备份恢复一致', () async {
    final temp = await Directory.systemTemp.createTemp('kaibao-credit-account-');
    final path = p.join(temp.path, 'source.db');
    var db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
    try {
      await db.addCustomer(const Customer(name: 'A', openingBalanceCents: 300));
      await db.addCustomer(const Customer(name: 'B'));
      final sid = await db.createSale(customer: (await db.customers()).first,
        lines: const [SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 2000, unitPriceCents: 1000)],
        discountCents: 0, initialReceivedCents: 1000);
      expect((await db.customerCreditAccount(1)).balanceCents, 0);
      final raw = await db.db;
      await raw.transaction((tx) async {
        // Storage fixtures only; no claim of an implemented refund transfer.
        for (final row in [(1, 'account-credit-fixture-01', 8000),
                          (2, 'account-other-fixture-01', 4000),
                          (1, 'account-debit-fixture-001', -3000)]) {
          await CustomerCreditLedger.post(tx, customerId: row.$1,
            saleId: sid, requestKey: row.$2, deltaCents: row.$3,
            reason: '账户存储测试夹具', createdAt: DateTime(2026, 11, 7, 12));
        }
      });
      await SaleCreditSchema.adoptLegacyEntries(raw);
      final before = (jsonDecode(await db.exportSnapshotJson()) as Map)['tables'];
      final account = await db.customerCreditAccount(1);
      expect(account.customer.name, 'A');
      expect(account.balanceCents, await CustomerCreditLedger.balance(raw, 1));
      expect(account.balanceCents, 5000);
      expect(account.entries.map((e) => e.deltaCents), [-3000, 8000]);
      expect(account.entries.map((e) => e.balanceAfterCents), [5000, 8000]);
      expect(account.entries.map((e) => e.saleId).toSet(), {sid});
      expect(account.entries.map((e) => e.saleNumber).toSet(), {(await db.saleById(sid))!.number});
      expect((await db.customerCreditAccount(2)).balanceCents, 4000);
      expect(await db.customerOutstanding(1), 1300);
      expect(() => account.entries.clear(), throwsUnsupportedError);
      await expectLater(db.customerCreditAccount(999), throwsStateError);
      expect((jsonDecode(await db.exportSnapshotJson()) as Map)['tables'], before);
      final plain = await db.exportSnapshotJson();
      await db.close();
      db = AppDatabase.forTesting(factory: databaseFactoryFfi, databasePath: path);
      expect((await db.customerCreditAccount(1)).balanceCents, 5000);
      final target = AppDatabase.forTesting(factory: databaseFactoryFfi,
        databasePath: p.join(temp.path, 'restored.db'));
      try {
        await target.restoreSnapshotJson(plain);
        final restored = await target.customerCreditAccount(1);
        expect(restored.balanceCents, 5000);
        expect(restored.entries.map((e) => e.balanceAfterCents), [5000, 8000]);
        expect((jsonDecode(await target.exportSnapshotJson()) as Map)['tables'], before);
      } finally { await target.close(); }
    } finally { await db.close(); await temp.delete(recursive: true); }
  });
}
