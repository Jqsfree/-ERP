import 'package:sqflite/sqflite.dart';
import '../domain/safe_int.dart';

class RefundLedger {
  static Future<int> net(DatabaseExecutor tx, int saleId, int epoch) async {
    final rows = await tx.query(
      'sale_refund_events',
      where: 'sale_id=? AND customer_epoch=?',
      whereArgs: [saleId, epoch],
      orderBy: 'id',
    );
    return netAt(rows, saleId, epoch, 9223372036854775807);
  }

  static int netAt(
    List<Map<String, Object?>> rows,
    int saleId,
    int epoch,
    int cutoff,
  ) {
    var total = 0;
    for (final r in rows) {
      if (r['sale_id'] == saleId &&
          r['customer_epoch'] == epoch &&
          (r['id'] as int) <= cutoff) {
        total = SafeInt.add(
          total,
          (r['kind'] == 'refund' ? 1 : -1) * (r['amount_cents'] as int),
        );
      }
    }
    return total;
  }

  static Future<int> cutoff(DatabaseExecutor tx, int saleId) async =>
      (await tx.rawQuery(
            'SELECT COALESCE(MAX(id),0) AS n FROM sale_refund_events WHERE sale_id=?',
            [saleId],
          )).single['n']
          as int;
}
