import 'refund_ledger.dart';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'customer_credit_ledger.dart';

class SaleCreditAmounts {
  const SaleCreditAmounts({this.applied = 0, this.transferred = 0});
  final int applied;
  final int transferred;
}

class SaleCreditLedger {
  static Future<SaleCreditAmounts> amounts(DatabaseExecutor tx, int saleId, int epoch) async {
    final rows = await tx.rawQuery('''SELECT
      COALESCE(SUM(CASE kind WHEN 'apply' THEN amount_cents WHEN 'release' THEN -amount_cents ELSE 0 END),0) AS applied,
      COALESCE(SUM(CASE WHEN kind='transfer' THEN amount_cents ELSE 0 END),0) AS transferred
      FROM sale_credit_events WHERE sale_id=? AND customer_epoch=?''', [saleId, epoch]);
    return SaleCreditAmounts(applied: rows.single['applied'] as int,
      transferred: rows.single['transferred'] as int);
  }

  static Future<int> post(Transaction tx, {required int saleId, required int customerId,
    required int epoch, required int version, required String kind, required int amount,
    required String key, required String payload, required DateTime now}) async {
    if (!['transfer','apply','release'].contains(kind) || amount <= 0) {
      throw ArgumentError('余额业务类型或金额无效');
    }
    final prior = await tx.query('sale_credit_events', where: 'request_key=?', whereArgs: [key]);
    if (prior.isNotEmpty) {
      if (prior.single['payload'] != payload) throw StateError('相同请求标识的余额业务内容不同');
      return prior.single['id'] as int;
    }
    final collision = await tx.query('customer_credit_entries', where: 'request_key=?', whereArgs: [key]);
    if (collision.isNotEmpty) throw StateError('请求标识已被既有余额流水使用');
    final reason = {'transfer': '应退款转入余额', 'apply': '开单余额抵扣', 'release': '改单释放余额抵扣'}[kind]!;
    final ledgerId = await CustomerCreditLedger.post(tx, customerId: customerId,
      saleId: saleId, requestKey: key, deltaCents: kind == 'apply' ? -amount : amount,
      reason: reason, createdAt: now);
    return tx.insert('sale_credit_events', {'ledger_entry_id': ledgerId,
      'sale_id': saleId, 'customer_id': customerId, 'customer_epoch': epoch,
      'sale_version': version, 'kind': kind, 'amount_cents': amount,
      'request_key': key, 'payload': payload, 'refund_cutoff': await RefundLedger.cutoff(tx, saleId),
      'created_at': now.toIso8601String()});
  }

  static String allocationPayload({required int saleId, required int customerId,
    required int epoch, required int version, required String kind, required int amount}) =>
    jsonEncode({'saleId': saleId, 'customerId': customerId, 'epoch': epoch,
      'version': version, 'kind': kind, 'amountCents': amount});
}
