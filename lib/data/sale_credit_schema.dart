import 'dart:convert';
import 'package:sqflite/sqflite.dart';

/// Additive v9: classify every existing ledger row without guessing its cash
/// source, and require a source event for new transfer/allocation/release rows.
class SaleCreditSchema {
  static const columns = <String,List<String>>{
    'sale_credit_events': ['id', 'ledger_entry_id', 'sale_id', 'customer_id',
      'customer_epoch', 'sale_version', 'kind', 'amount_cents', 'request_key', 'payload', 'created_at'],
    'sale_creation_requests': ['id', 'sale_id', 'request_key', 'payload', 'created_at'],
  };

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE sale_credit_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ledger_entry_id INTEGER NOT NULL UNIQUE REFERENCES customer_credit_entries(id),
      sale_id INTEGER NOT NULL REFERENCES sales(id),
      customer_id INTEGER NOT NULL REFERENCES customers(id),
      customer_epoch INTEGER NOT NULL CHECK(customer_epoch >= 0),
      sale_version INTEGER NOT NULL CHECK(sale_version >= 0),
      kind TEXT NOT NULL CHECK(kind IN ('legacy','transfer','apply','release')),
      amount_cents INTEGER NOT NULL CHECK(amount_cents > 0),
      request_key TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, created_at TEXT NOT NULL
    )''');
    await db.execute('CREATE INDEX idx_sale_credit_epoch ON sale_credit_events(sale_id,customer_epoch,kind)');
    await db.execute('''CREATE TABLE sale_creation_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      sale_id INTEGER NOT NULL UNIQUE REFERENCES sales(id),
      request_key TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, created_at TEXT NOT NULL
    )''');
    await adoptLegacyEntries(db);
  }

  /// Used only by migration and legacy-data fixtures; never exposed as an
  /// application command. It does not grant credit or alter any ledger amount.
  static Future<void> adoptLegacyEntries(DatabaseExecutor db) async {
    final entries = await db.rawQuery('''SELECT e.* FROM customer_credit_entries e
      WHERE NOT EXISTS(SELECT 1 FROM sale_credit_events c WHERE c.ledger_entry_id=e.id) ORDER BY e.id''');
    for (final e in entries) {
      await db.insert('sale_credit_events', legacyEvent(e, e['id'] as int)..remove('id'));
    }
  }

  static Map<String,Object?> legacyEvent(Map<String,Object?> e, int id) => {
    'id': id, 'ledger_entry_id': e['id'], 'sale_id': e['sale_id'],
    'customer_id': e['customer_id'], 'customer_epoch': 0, 'sale_version': 0,
    'kind': 'legacy', 'amount_cents': (e['delta_cents'] as int).abs(),
    'request_key': e['request_key'], 'payload': jsonEncode({'legacyEntryId': e['id']}),
    'created_at': e['created_at'],
  };
}
