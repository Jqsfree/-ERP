import 'package:sqflite/sqflite.dart';
import '../domain/customer_credit.dart';
import '../domain/models.dart';

/// Append-only customer credit. Call posting operations inside the same
/// transaction as the originating sale revision; never post cash here.
class CustomerCreditLedger {
  static Future<CustomerCreditAccount> account(Transaction tx, int customerId) async {
    final customers = await tx.query('customers', where: 'id=?', whereArgs: [customerId]);
    if (customers.isEmpty) throw StateError('客户不存在');
    final rows = await tx.rawQuery('''SELECT e.*, s.number AS sale_number
      FROM customer_credit_entries e JOIN sales s ON s.id=e.sale_id
      WHERE e.customer_id=? ORDER BY e.id''', [customerId]);
    var running = BigInt.zero;
    final max = BigInt.from(9223372036854775807);
    final entries = <CustomerCreditEntry>[];
    for (final row in rows) {
      running += BigInt.from(row['delta_cents'] as int);
      if (running.isNegative || running > max) throw StateError('余额流水透支或超出范围，请核查数据');
      entries.add(CustomerCreditEntry(id: row['id'] as int, saleId: row['sale_id'] as int,
        saleNumber: row['sale_number'] as String, deltaCents: row['delta_cents'] as int,
        balanceAfterCents: running.toInt(), reason: row['reason'] as String,
        createdAt: row['created_at'] as String));
    }
    return CustomerCreditAccount(customer: Customer.fromMap(customers.single),
      balanceCents: running.toInt(), entries: entries.reversed.toList());
  }

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE customer_credit_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      customer_id INTEGER NOT NULL REFERENCES customers(id),
      sale_id INTEGER NOT NULL REFERENCES sales(id),
      request_key TEXT NOT NULL UNIQUE,
      delta_cents INTEGER NOT NULL CHECK(delta_cents != 0),
      reason TEXT NOT NULL,
      created_at TEXT NOT NULL
    )''');
    await db.execute('CREATE INDEX idx_credit_customer ON customer_credit_entries(customer_id)');
  }

  static Future<int> balance(DatabaseExecutor tx, int customerId) async {
    final rows = await tx.rawQuery('''SELECT COALESCE(SUM(delta_cents), 0) AS balance
      FROM customer_credit_entries WHERE customer_id=?''', [customerId]);
    return rows.single['balance'] as int;
  }

  static Future<int> post(Transaction tx, {required int customerId,
    required int saleId, required String requestKey, required int deltaCents,
    required String reason, required DateTime createdAt}) async {
    final key = requestKey.trim();
    final explanation = reason.trim();
    if (customerId <= 0 || saleId <= 0 || deltaCents == 0 ||
        key.length < 12 || key.length > 128 || explanation.isEmpty) {
      throw ArgumentError('余额流水参数无效');
    }
    final existing = await tx.query('customer_credit_entries',
      where: 'request_key=?', whereArgs: [key]);
    if (existing.isNotEmpty) {
      final row = existing.single;
      if (row['customer_id'] != customerId || row['sale_id'] != saleId ||
          row['delta_cents'] != deltaCents || row['reason'] != explanation) {
        throw StateError('相同请求标识的余额业务内容不一致');
      }
      return row['id'] as int;
    }
    final current = await balance(tx, customerId);
    final next = BigInt.from(current) + BigInt.from(deltaCents);
    if (next.isNegative || next > BigInt.from(9223372036854775807)) {
      throw StateError('客户余额不足或超过可表示范围');
    }
    return tx.insert('customer_credit_entries', {
      'customer_id': customerId, 'sale_id': saleId, 'request_key': key,
      'delta_cents': deltaCents, 'reason': explanation,
      'created_at': createdAt.toIso8601String(),
    });
  }
}
