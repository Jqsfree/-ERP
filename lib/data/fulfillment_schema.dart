import 'package:sqflite/sqflite.dart';

/// Additive v5 schema. v4 stock_movements remains an immutable receipt ledger;
/// a unified, read-only view combines receipt, delivery and physical return events.
class FulfillmentSchema {
  const FulfillmentSchema._();

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE sale_dispatches (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      number TEXT NOT NULL UNIQUE,
      sale_id INTEGER NOT NULL REFERENCES sales(id),
      request_key TEXT NOT NULL UNIQUE,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL,
      note TEXT NOT NULL DEFAULT ''
    )''');
    await db.execute('''CREATE TABLE sale_dispatch_lines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      dispatch_id INTEGER NOT NULL REFERENCES sale_dispatches(id),
      sale_line_id INTEGER NOT NULL REFERENCES sale_lines(id),
      product_id INTEGER NOT NULL REFERENCES products(id),
      warehouse_id INTEGER NOT NULL REFERENCES warehouses(id),
      batch_code TEXT NOT NULL DEFAULT '',
      length_milli INTEGER NOT NULL CHECK(length_milli > 0),
      width_milli INTEGER NOT NULL CHECK(width_milli > 0),
      area_micro INTEGER NOT NULL CHECK(area_micro > 0),
      UNIQUE(dispatch_id, sale_line_id)
    )''');
    await db.execute('''CREATE TABLE sale_returns (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      number TEXT NOT NULL UNIQUE,
      dispatch_id INTEGER NOT NULL REFERENCES sale_dispatches(id),
      request_key TEXT NOT NULL UNIQUE,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL,
      note TEXT NOT NULL DEFAULT ''
    )''');
    await db.execute('''CREATE TABLE sale_return_lines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      return_id INTEGER NOT NULL REFERENCES sale_returns(id),
      dispatch_line_id INTEGER NOT NULL REFERENCES sale_dispatch_lines(id),
      product_id INTEGER NOT NULL REFERENCES products(id),
      warehouse_id INTEGER NOT NULL REFERENCES warehouses(id),
      batch_code TEXT NOT NULL DEFAULT '',
      length_milli INTEGER NOT NULL CHECK(length_milli > 0),
      width_milli INTEGER NOT NULL CHECK(width_milli > 0),
      area_micro INTEGER NOT NULL CHECK(area_micro > 0),
      UNIQUE(return_id, dispatch_line_id)
    )''');
    await db.execute('CREATE INDEX idx_dispatch_sale ON sale_dispatches(sale_id)');
    await db.execute('CREATE INDEX idx_dispatch_line_sale_line ON sale_dispatch_lines(sale_line_id)');
    await db.execute('CREATE INDEX idx_return_dispatch ON sale_returns(dispatch_id)');
    await db.execute('CREATE INDEX idx_return_line_source ON sale_return_lines(dispatch_line_id)');
    await db.execute('''CREATE VIEW stock_ledger_entries AS
      SELECT 'purchase_receipt' AS source_type, m.id AS event_id,
        r.number AS document_number, m.product_id, m.warehouse_id,
        m.batch_code, m.delta_area_micro, m.created_at
      FROM stock_movements m
      JOIN purchase_receipt_lines rl ON rl.id=m.receipt_line_id
      JOIN purchase_receipts r ON r.id=rl.receipt_id
      UNION ALL
      SELECT 'sale_dispatch', dl.id, d.number, dl.product_id, dl.warehouse_id,
        dl.batch_code, -dl.area_micro, d.created_at
      FROM sale_dispatch_lines dl JOIN sale_dispatches d ON d.id=dl.dispatch_id
      UNION ALL
      SELECT 'sale_return', rl.id, r.number, rl.product_id, rl.warehouse_id,
        rl.batch_code, rl.area_micro, r.created_at
      FROM sale_return_lines rl JOIN sale_returns r ON r.id=rl.return_id
    ''');
  }
}
