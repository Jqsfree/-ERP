import 'package:sqflite/sqflite.dart';

/// v6 adds an auditable non-sales cashbook and immutable daily reconciliation.
/// Does not touch old sales, payments, inventory or receivables tables.
class FinanceSchema {
  FinanceSchema._();

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE cash_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      number TEXT NOT NULL UNIQUE,
      business_date TEXT NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('income', 'expense', 'reversal')),
      direction INTEGER NOT NULL CHECK(direction IN (-1, 1)),
      method TEXT NOT NULL,
      category TEXT NOT NULL,
      amount_cents INTEGER NOT NULL CHECK(amount_cents > 0),
      original_entry_id INTEGER UNIQUE REFERENCES cash_entries(id),
      request_key TEXT NOT NULL UNIQUE,
      payload TEXT NOT NULL,
      note TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      CHECK((kind = 'reversal' AND original_entry_id IS NOT NULL)
        OR (kind != 'reversal' AND original_entry_id IS NULL)),
      CHECK((kind != 'income' OR direction = 1)
        AND (kind != 'expense' OR direction = -1))
    )''');
    await db.execute('''CREATE TABLE day_closures (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      business_date TEXT NOT NULL UNIQUE,
      request_key TEXT NOT NULL UNIQUE,
      expected_json TEXT NOT NULL,
      actual_json TEXT NOT NULL,
      variance_reason TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )''');
    await db.execute('CREATE INDEX idx_cash_date_method ON cash_entries(business_date, method)');
    await db.execute('CREATE INDEX idx_payments_created_at ON payments(created_at)');
  }
}
