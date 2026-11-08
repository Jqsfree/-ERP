import 'package:sqflite/sqflite.dart';

/// v11 is additive; no historical refunds are inferred.
class RefundSchema {
  static const columns = <String, List<String>>{
    'refund_requests': [
      'id',
      'request_key',
      'sale_id',
      'kind',
      'payload',
      'status',
      'event_id',
      'created_at',
      'updated_at',
    ],
    'sale_refund_events': [
      'id',
      'sale_id',
      'customer_id',
      'customer_epoch',
      'sale_version',
      'kind',
      'amount_cents',
      'method',
      'reason',
      'original_event_id',
      'request_key',
      'payment_cutoff',
      'credit_cutoff',
      'created_at',
    ],
  };
  static Future<void> create(DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE day_closures ADD COLUMN refund_cutoff INTEGER NOT NULL DEFAULT 0 CHECK(refund_cutoff>=0)',
    );
    await db.execute(
      'ALTER TABLE sale_credit_events ADD COLUMN refund_cutoff INTEGER NOT NULL DEFAULT 0 CHECK(refund_cutoff>=0)',
    );
    await db.execute('''CREATE TABLE refund_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT, request_key TEXT NOT NULL UNIQUE,
      sale_id INTEGER NOT NULL REFERENCES sales(id), kind TEXT NOT NULL CHECK(kind IN ('refund','reversal')),
      payload TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('pending','posted','cancelled')),
      event_id INTEGER UNIQUE, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      CHECK((status='posted' AND event_id IS NOT NULL) OR (status!='posted' AND event_id IS NULL))
    )''');
    await db.execute(
      "CREATE UNIQUE INDEX idx_pending_refund ON refund_requests(sale_id) WHERE status='pending'",
    );
    await db.execute('''CREATE TABLE sale_refund_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL REFERENCES sales(id),
      customer_id INTEGER NOT NULL REFERENCES customers(id), customer_epoch INTEGER NOT NULL CHECK(customer_epoch>=0),
      sale_version INTEGER NOT NULL CHECK(sale_version>=0), kind TEXT NOT NULL CHECK(kind IN ('refund','reversal')),
      amount_cents INTEGER NOT NULL CHECK(amount_cents>0), method TEXT NOT NULL, reason TEXT NOT NULL,
      original_event_id INTEGER UNIQUE REFERENCES sale_refund_events(id),
      request_key TEXT NOT NULL UNIQUE REFERENCES refund_requests(request_key),
      payment_cutoff INTEGER NOT NULL CHECK(payment_cutoff>=0), credit_cutoff INTEGER NOT NULL CHECK(credit_cutoff>=0),
      created_at TEXT NOT NULL,
      CHECK((kind='refund' AND original_event_id IS NULL) OR (kind='reversal' AND original_event_id IS NOT NULL))
    )''');
    await db.execute(
      'CREATE INDEX idx_refund_sale_epoch ON sale_refund_events(sale_id,customer_epoch)',
    );
  }
}
