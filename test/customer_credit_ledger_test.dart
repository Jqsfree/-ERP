import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kaibao_sales/data/customer_credit_ledger.dart';

void main() {
  test('余额转入、抵扣、重复请求和失败事务保持一致', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    try {
      await db.execute('PRAGMA foreign_keys=ON');
      await db.execute('CREATE TABLE customers (id INTEGER PRIMARY KEY)');
      await db.execute('CREATE TABLE sales (id INTEGER PRIMARY KEY)');
      await db.insert('customers', {'id': 1});
      await db.insert('sales', {'id': 1});
      await CustomerCreditLedger.create(db);
      Future<int> post(String key, int amount) => db.transaction((tx) =>
        CustomerCreditLedger.post(tx, customerId: 1, saleId: 1,
          requestKey: key, deltaCents: amount, reason: '改单结算',
          createdAt: DateTime(2026, 11, 7)));
      final id = await post('credit-transfer-001', 8000);
      expect(await post('credit-transfer-001', 8000), id);
      await expectLater(post('credit-transfer-001', 9000), throwsStateError);
      await post('credit-consume-0001', -3000);
      expect(await CustomerCreditLedger.balance(db, 1), 5000);
      await expectLater(post('credit-consume-0002', -5001), throwsStateError);
      await expectLater(db.transaction((tx) async {
        await CustomerCreditLedger.post(tx, customerId: 1, saleId: 1,
          requestKey: 'credit-rollback-001', deltaCents: -1000,
          reason: '事务回滚', createdAt: DateTime(2026, 11, 7));
        throw StateError('模拟主单保存失败');
      }), throwsStateError);
      expect(await CustomerCreditLedger.balance(db, 1), 5000);
      expect(await db.query('customer_credit_entries'), hasLength(2));
    } finally {
      await db.close();
    }
  });
}
