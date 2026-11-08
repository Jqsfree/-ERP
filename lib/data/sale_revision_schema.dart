import 'package:sqflite/sqflite.dart';

/// v8 is additive. Original sale headers, lines, receipts and dispatches survive.
class SaleRevisionSchema {
  static const columns = <String, List<String>>{
    'sale_revisions': ['id', 'sale_id', 'version', 'request_key', 'payload',
      'snapshot', 'amount_delta_cents', 'created_at'],
    'sale_line_origins': ['id', 'sale_line_id', 'sale_id', 'introduced_version'],
    'sale_payment_contexts': ['id', 'payment_id', 'customer_id', 'customer_epoch'],
    'sale_dispatch_contexts': ['id', 'dispatch_id', 'sale_id', 'version'],
  };

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE sale_revisions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_id INTEGER NOT NULL REFERENCES sales(id),
      version INTEGER NOT NULL CHECK(version >= 0),
      request_key TEXT NOT NULL UNIQUE,
      payload TEXT NOT NULL,
      snapshot TEXT NOT NULL,
      amount_delta_cents INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      UNIQUE(sale_id, version)
    )''');
    await db.execute('''CREATE TABLE sale_line_origins (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_line_id INTEGER NOT NULL UNIQUE REFERENCES sale_lines(id),
      sale_id INTEGER NOT NULL REFERENCES sales(id),
      introduced_version INTEGER NOT NULL CHECK(introduced_version > 0),
      FOREIGN KEY(sale_id, introduced_version) REFERENCES sale_revisions(sale_id, version)
    )''');
    await db.execute('''CREATE TABLE sale_payment_contexts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      payment_id INTEGER NOT NULL UNIQUE REFERENCES payments(id),
      customer_id INTEGER NOT NULL REFERENCES customers(id),
      customer_epoch INTEGER NOT NULL CHECK(customer_epoch >= 0)
    )''');
    await db.execute('''CREATE TABLE sale_dispatch_contexts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      dispatch_id INTEGER NOT NULL UNIQUE REFERENCES sale_dispatches(id),
      sale_id INTEGER NOT NULL REFERENCES sales(id),
      version INTEGER NOT NULL CHECK(version > 0),
      FOREIGN KEY(sale_id, version) REFERENCES sale_revisions(sale_id, version)
    )''');
  }
}
