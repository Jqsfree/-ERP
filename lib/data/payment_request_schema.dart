import 'package:sqflite/sqflite.dart';
import '../domain/finance.dart';

/// v10: additive durable receipts. Existing payments are never rewritten.
class PaymentRequestSchema {
  static const columns = <String, List<String>>{
    'payment_requests': ['id','request_key','sale_id','expected_revision','amount_cents',
      'method','status','payment_id','created_at','updated_at'],
  };
  static Future<void> create(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE payment_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT, request_key TEXT NOT NULL UNIQUE,
      sale_id INTEGER NOT NULL REFERENCES sales(id), expected_revision INTEGER NOT NULL CHECK(expected_revision>=0),
      amount_cents INTEGER NOT NULL CHECK(amount_cents>0), method TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('pending','posted','cancelled')),
      payment_id INTEGER UNIQUE REFERENCES payments(id), created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      CHECK((status='posted' AND payment_id IS NOT NULL) OR (status!='posted' AND payment_id IS NULL))
    )''');
    await db.execute("CREATE UNIQUE INDEX idx_pending_payment ON payment_requests(sale_id) WHERE status='pending'");
  }
  static void validate(Map<String,List<Map<String,Object?>>> tables) {
    final sales = {for (final s in tables['sales']!) s['id']: s};
    final versions = <Object?, int>{for (final s in tables['sales']!) s['id']: 0};
    for (final r in tables['sale_revisions']!) {
      final v = r['version'];
      if (v is int && v > (versions[r['sale_id']] ?? 0)) versions[r['sale_id']] = v;
    }
    final payments = {for (final p in tables['payments']!) p['id']: p};
    final ids = <Object?>{}, keys = <Object?>{}, posted = <Object?>{}, pending = <Object?>{};
    for (final r in tables['payment_requests']!) {
      final key = r['request_key'];
      final rev = r['expected_revision'];
      final amount = r['amount_cents'];
      if (!ids.add(r['id']) || key is! String || key.length < 12 || key.length > 128 ||
          key != key.trim() || !keys.add(key) || !sales.containsKey(r['sale_id']) ||
          rev is! int || rev < 0 || rev > (versions[r['sale_id']] ?? 0) || amount is! int || amount <= 0 || !FinanceMath.methods.contains(r['method']) ||
          r['created_at'] is! String || DateTime.tryParse(r['created_at'] as String) == null ||
          r['updated_at'] is! String || DateTime.tryParse(r['updated_at'] as String) == null) {
        throw const FormatException('收款请求标识、金额或来源无效');
      }
      final status = r['status'];
      if (status == 'posted') {
        final p = payments[r['payment_id']];
        if (!posted.add(r['payment_id']) || p == null || p['sale_id'] != r['sale_id'] ||
            p['amount_cents'] != amount || p['method'] != r['method']) {
          throw const FormatException('收款请求与实际入账记录不一致');
        }
      } else if (status == 'pending' || status == 'cancelled') {
        if (r['payment_id'] != null || (status == 'pending' && !pending.add(r['sale_id']))) {
          throw const FormatException('待处理收款重复或已关联入账');
        }
      } else { throw const FormatException('收款请求状态无效'); }
    }
  }
}
