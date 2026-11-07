import 'package:sqflite/sqflite.dart';

/// v4 is additive: no existing order, payment, supplier or customer is changed.
class InventorySchema {
  const InventorySchema._();

  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE warehouses (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      code TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0, 1))
    )''');
    await db.execute('''CREATE TABLE purchase_receipts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      number TEXT NOT NULL UNIQUE,
      purchase_order_id INTEGER NOT NULL REFERENCES purchase_orders(id),
      request_key TEXT NOT NULL UNIQUE,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL,
      note TEXT NOT NULL DEFAULT ''
    )''');
    await db.execute('''CREATE TABLE purchase_receipt_lines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      receipt_id INTEGER NOT NULL REFERENCES purchase_receipts(id),
      purchase_line_id INTEGER NOT NULL REFERENCES purchase_lines(id),
      warehouse_id INTEGER NOT NULL REFERENCES warehouses(id),
      batch_code TEXT NOT NULL DEFAULT '',
      length_milli INTEGER NOT NULL CHECK(length_milli > 0),
      width_milli INTEGER NOT NULL CHECK(width_milli > 0),
      area_micro INTEGER NOT NULL CHECK(area_micro > 0),
      UNIQUE(receipt_id, purchase_line_id)
    )''');
    await db.execute('''CREATE TABLE stock_movements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      receipt_line_id INTEGER NOT NULL UNIQUE REFERENCES purchase_receipt_lines(id),
      product_id INTEGER NOT NULL REFERENCES products(id),
      warehouse_id INTEGER NOT NULL REFERENCES warehouses(id),
      batch_code TEXT NOT NULL DEFAULT '',
      delta_area_micro INTEGER NOT NULL CHECK(delta_area_micro > 0),
      created_at TEXT NOT NULL
    )''');
    await db.execute('CREATE INDEX idx_receipts_order ON purchase_receipts(purchase_order_id)');
    await db.execute('CREATE INDEX idx_receipt_lines_po_line ON purchase_receipt_lines(purchase_line_id)');
    await db.execute('CREATE INDEX idx_movements_stock ON stock_movements(product_id, warehouse_id, batch_code)');
  }
}
