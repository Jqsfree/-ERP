import 'refund_ledger.dart';
import '../domain/safe_int.dart';
import 'product_identity.dart';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../application/sale_revision_store.dart';
import '../domain/finance.dart';
import '../domain/models.dart';
import '../domain/sale_revision.dart';
import 'sale_credit_ledger.dart';
import '../domain/sale_settlement.dart';

/// Versions are append-only snapshots. Original sales/lines are never updated.
/// Epochs isolate receipts when a customer changes, including A -> B -> A.
class SaleRevisionRepository implements SaleRevisionStore {
  SaleRevisionRepository(this.db, this.clock);
  final Database db;
  final DateTime Function() clock;

  static Future<Map<String, Object?>?> currentSnapshot(DatabaseExecutor tx, int id) async {
    final revisions = await tx.query('sale_revisions', where: 'sale_id=?',
      whereArgs: [id], orderBy: 'version DESC', limit: 1);
    if (revisions.isNotEmpty) {
      return Map<String, Object?>.from(jsonDecode(revisions.single['snapshot'] as String) as Map);
    }
    final headers = await tx.query('sales', where: 'id=?', whereArgs: [id]);
    if (headers.isEmpty) return null;
    final lines = await tx.rawQuery('''SELECT sl.* FROM sale_lines sl
      LEFT JOIN sale_line_origins o ON o.sale_line_id=sl.id
      WHERE sl.sale_id=? AND o.id IS NULL ORDER BY sl.id''', [id]);
    return {'header': headers.single, 'lines': lines, 'version': 0, 'epoch': 0};
  }

  static Sale readSale(Map<String, Object?> snapshot, int received,
    {int? creditAppliedCents, int? transferredCents, int? refundedCents,
      int returnedLengthMilli = 0, int returnedAreaMicro = 0}) {
    final h = Map<String, Object?>.from(snapshot['header'] as Map);
    return Sale(revision: snapshot['version'] as int,
      id: h['id'] as int, number: h['number'] as String, date: h['date'] as String,
      customerId: h['customer_id'] as int, customerName: h['customer_name_snapshot'] as String,
      customerPhone: h['customer_phone_snapshot'] as String,
      customerAddress: h['customer_address_snapshot'] as String,
      subtotalCents: h['subtotal_cents'] as int, discountCents: h['discount_cents'] as int,
      priorDueCents: h['prior_due_snapshot'] as int, receivedCents: received,
      creditAppliedCents: creditAppliedCents ?? snapshot['creditAppliedCents'] as int? ?? 0,
      transferredCents: transferredCents ?? snapshot['transferredCents'] as int? ?? 0,
      refundedCents: refundedCents ?? snapshot['refundedCents'] as int? ?? 0,
      returnedLengthMilli: returnedLengthMilli, returnedAreaMicro: returnedAreaMicro,
      status: h['status'] as String, note: h['note'] as String,
      lines: (snapshot['lines'] as List).map((r) => SaleLine.fromMap(
        Map<String, Object?>.from(r as Map))).toList());
  }

  static Future<int> received(DatabaseExecutor tx, int id, int epoch) async {
    final rows = await tx.rawQuery('''SELECT COALESCE(SUM(p.amount_cents),0) AS n
      FROM payments p LEFT JOIN sale_payment_contexts c ON c.payment_id=p.id
      WHERE p.sale_id=? AND COALESCE(c.customer_epoch,0)=?''', [id, epoch]);
    return rows.single['n'] as int;
  }

  static Future<int> customerOutstanding(DatabaseExecutor tx, int customerId) async {
    final customers = await tx.query('customers', where: 'id=?', whereArgs: [customerId]);
    if (customers.isEmpty) throw StateError('客户不存在');
    final sums = await tx.rawQuery('''SELECT COALESCE(SUM(s.subtotal_cents - s.discount_cents -
      COALESCE((SELECT SUM(p.amount_cents) FROM payments p WHERE p.sale_id=s.id),0) -
      COALESCE((SELECT SUM(CASE c.kind WHEN 'apply' THEN c.amount_cents WHEN 'release' THEN -c.amount_cents
        WHEN 'transfer' THEN -c.amount_cents ELSE 0 END) FROM sale_credit_events c
        WHERE c.sale_id=s.id AND c.customer_epoch=0),0)),0) AS due
      FROM sales s WHERE s.customer_id=? AND s.status='confirmed'
      AND NOT EXISTS(SELECT 1 FROM sale_revisions r WHERE r.sale_id=s.id AND r.version>0)''', [customerId]);
    var due = SafeInt.add(customers.single['opening_balance_cents'] as int, sums.single['due'] as int);
    final revisions = await tx.rawQuery('''SELECT r.snapshot FROM sale_revisions r WHERE r.version>0
      AND r.version=(SELECT MAX(x.version) FROM sale_revisions x WHERE x.sale_id=r.sale_id)''');
    for (final row in revisions) {
      final s = Map<String,Object?>.from(jsonDecode(row['snapshot'] as String) as Map);
      final h = s['header'] as Map;
      if (h['customer_id'] == customerId) {
        final credit = await SaleCreditLedger.amounts(tx, h['id'] as int, s['epoch'] as int);
        due = SafeInt.add(due, readSale(s, await received(tx, h['id'] as int, s['epoch'] as int),
          creditAppliedCents: credit.applied, transferredCents: credit.transferred,
          refundedCents: await RefundLedger.net(tx, h['id'] as int, s['epoch'] as int)).currentDueCents);
      }
    }
    return due;
  }

  static Map<String, Object?> lineRow(int saleId, SaleLine line) => {
    'sale_id': saleId, 'product_id': line.productId, 'code_snapshot': line.code,
    'spec_snapshot': line.specification, 'length_milli': line.lengthMilli,
    'width_milli': line.widthMilli, 'unit_price_cents': line.unitPriceCents,
    'amount_cents': line.totalCents, 'note': line.note,
  };

  static List<PendingSaleRefund> readRefunds(Map<String, Object?> snapshot) =>
    ((snapshot['refunds'] as List?) ?? []).map((r) {
      final row = r as Map;
      return PendingSaleRefund(customerId: row['customerId'] as int,
        customerName: row['customerName'] as String, epoch: row['epoch'] as int,
        amountCents: row['amountCents'] as int);
    }).toList();

  static List<PendingSaleReturn> readReturns(Map<String, Object?> snapshot) =>
    ((snapshot['returns'] as List?) ?? []).map((r) {
      final row = r as Map;
      return PendingSaleReturn(saleLineId: row['saleLineId'] as int,
        code: row['code'] as String, widthMilli: row['widthMilli'] as int,
        lengthMilli: row['lengthMilli'] as int);
    }).toList();

  static Future<List<Map<String, Object?>>> refundRows(DatabaseExecutor tx,
    int saleId, Map<String, Object?> snapshot) async {
    final original = (await tx.query('sales', where: 'id=?', whereArgs: [saleId])).single;
    final h = snapshot['header'] as Map;
    final epoch = snapshot['epoch'] as int;
    final names = <int, Object?>{0: original['customer_name_snapshot']};
    final history = await tx.query('sale_revisions', columns: ['snapshot'],
      where: 'sale_id=?', whereArgs: [saleId], orderBy: 'version');
    for (final row in history) {
      final s = jsonDecode(row['snapshot'] as String) as Map;
      names.putIfAbsent(s['epoch'] as int, () => (s['header'] as Map)['customer_name_snapshot']);
    }
    names[epoch] = h['customer_name_snapshot'];
    final sums = await tx.rawQuery('''SELECT COALESCE(c.customer_epoch,0) AS epoch,
      COALESCE(c.customer_id, s.customer_id) AS customer_id,
      SUM(p.amount_cents) AS paid
      FROM payments p JOIN sales s ON s.id=p.sale_id
      LEFT JOIN sale_payment_contexts c ON c.payment_id=p.id
      WHERE p.sale_id=? GROUP BY COALESCE(c.customer_epoch,0),
        COALESCE(c.customer_id,s.customer_id) ORDER BY epoch''', [saleId]);
    final result = <Map<String, Object?>>[];
    for (final row in sums) {
      final credit = await SaleCreditLedger.amounts(tx, saleId, row['epoch'] as int);
      final amount = (row['paid'] as int) - credit.transferred -
        await RefundLedger.net(tx, saleId, row['epoch'] as int) - (row['epoch'] == epoch
        ? (h['subtotal_cents'] as int) - (h['discount_cents'] as int) : 0);
      if (amount > 0) {
        result.add({'customerId': row['customer_id'],
          'customerName': names[row['epoch']],
          'epoch': row['epoch'], 'amountCents': amount});
      }
    }
    return result;
  }

  static Future<List<Map<String, Object?>>> returnRows(DatabaseExecutor tx,
    int saleId, Map<String, Object?> snapshot) async {
    final targets = {for (final l in snapshot['lines'] as List)
      (l as Map)['id'] as int: l['length_milli'] as int};
    final shipped = await tx.rawQuery('''SELECT sl.id, sl.code_snapshot, sl.width_milli,
      COALESCE(SUM(dl.length_milli - COALESCE((SELECT SUM(rl.length_milli)
        FROM sale_return_lines rl WHERE rl.dispatch_line_id=dl.id),0)),0) AS net
      FROM sale_lines sl JOIN sale_dispatch_lines dl ON dl.sale_line_id=sl.id
      WHERE sl.sale_id=? GROUP BY sl.id ORDER BY sl.id''', [saleId]);
    return [for (final row in shipped)
      if ((row['net'] as int) > (targets[row['id']] ?? 0))
        {'saleLineId': row['id'], 'code': row['code_snapshot'],
          'widthMilli': row['width_milli'],
          'lengthMilli': (row['net'] as int) - (targets[row['id']] ?? 0)}];
  }

  static Future<void> capture(DatabaseExecutor tx, int saleId,
    Map<String, Object?> snapshot) async {
    final cutoff = await tx.rawQuery('SELECT COALESCE(MAX(id),0) AS n FROM payments WHERE sale_id=?', [saleId]);
    snapshot['paymentCutoff'] = cutoff.single['n'];
    final dispatchCutoff = await tx.rawQuery('SELECT COALESCE(MAX(id),0) AS n FROM sale_dispatches WHERE sale_id=?', [saleId]);
    final returnCutoff = await tx.rawQuery('''SELECT COALESCE(MAX(r.id),0) AS n FROM sale_returns r
      JOIN sale_dispatches d ON d.id=r.dispatch_id WHERE d.sale_id=?''', [saleId]);
    snapshot['dispatchCutoff'] = dispatchCutoff.single['n'];
    snapshot['returnCutoff'] = returnCutoff.single['n'];
    final creditCutoff = await tx.rawQuery('SELECT COALESCE(MAX(id),0) AS n FROM sale_credit_events WHERE sale_id=?', [saleId]);
    snapshot['creditCutoff'] = creditCutoff.single['n'];
    final credit = await SaleCreditLedger.amounts(tx, saleId, snapshot['epoch'] as int);
    snapshot['refundCutoff'] = await RefundLedger.cutoff(tx, saleId);
    snapshot['refundedCents'] = await RefundLedger.net(tx, saleId, snapshot['epoch'] as int);
    snapshot['creditAppliedCents'] = credit.applied;
    snapshot['transferredCents'] = credit.transferred;
    snapshot['receivedCents'] = await received(tx, saleId, snapshot['epoch'] as int);
    snapshot['refunds'] = await refundRows(tx, saleId, snapshot);
    snapshot['returns'] = await returnRows(tx, saleId, snapshot);
  }

  @override
  Future<int> reviseSale({required int saleId, required int expectedRevision,
    required String requestKey, required int customerId, required String date,
    required List<SaleLine> lines, required int discountCents, required String note}) async {
    final key = requestKey.trim();
    if (key.length < 12 || key.length > 128 || key.startsWith('baseline:') || note.length > 2000) {
      throw ArgumentError('改单请求标识或备注无效');
    }
    FinanceMath.validDay(date);
    final input = List<SaleLine>.unmodifiable(lines);
    final payload = jsonEncode({'saleId': saleId, 'expectedRevision': expectedRevision,
      'customerId': customerId, 'date': date, 'discountCents': discountCents,
      'note': note.trim(), 'lines': input.map((l) => {'id': l.id, ...lineRow(saleId, l)}).toList()});
    return db.transaction((tx) async {
      final prior = await tx.query('sale_revisions', where: 'request_key=?', whereArgs: [key]);
      if (prior.isNotEmpty) {
        if (prior.single['payload'] != payload) throw StateError('相同请求标识的改单内容不一致');
        return prior.single['version'] as int;
      }
      final snapshot = await currentSnapshot(tx, saleId);
      if (snapshot == null) throw StateError('销售单不存在');
      final version = snapshot['version'] as int;
      if (expectedRevision != version) throw StateError('销售单已被修改，请重新读取后再保存');
      final old = readSale(snapshot, await received(tx, saleId, snapshot['epoch'] as int));
      final preview = SaleRevisionPreview.calculate(original: old,
        lines: input, discountCents: discountCents);
      await ProductIdentity.validate(tx, input, previous: old.lines);
      final customers = await tx.query('customers', where: 'id=?', whereArgs: [customerId]);
      if (customers.isEmpty) throw ArgumentError('客户不存在');
      final customer = customers.single;
      if (customerId != old.customerId && customer['active'] != 1) {
        throw StateError('不能将销售单改为停用客户');
      }
      final happenedAt = clock();
      final now = happenedAt.toIso8601String();
      if (version == 0) {
        await capture(tx, saleId, snapshot);
        await tx.insert('sale_revisions', {'sale_id': saleId, 'version': 0,
          'request_key': 'baseline:$saleId', 'payload': '{}', 'snapshot': jsonEncode(snapshot),
          'amount_delta_cents': 0, 'created_at': now});
      }
      final next = version + 1;
      final nextLines = <Map<String, Object?>>[];
      final newIds = <int>[];
      for (final change in preview.changes.where((c) => c.after != null)) {
        final row = lineRow(saleId, change.after!);
        var id = change.after!.id;
        if (id == null || change.physicalIdentityChanged) {
          id = await tx.insert('sale_lines', row);
          newIds.add(id);
        }
        nextLines.add({'id': id, ...row});
      }
      final h = Map<String, Object?>.from(snapshot['header'] as Map);
      h.addAll({'date': date, 'customer_id': customerId, 'subtotal_cents': preview.subtotalCents,
        'discount_cents': discountCents, 'note': note.trim()});
      if (customerId != old.customerId) {
        h.addAll({'customer_name_snapshot': customer['name'],
          'customer_phone_snapshot': customer['phone'], 'customer_address_snapshot': customer['address'],
          'prior_due_snapshot': await customerOutstanding(tx, customerId)});
      }
      final updated = <String, Object?>{'header': h, 'lines': nextLines, 'version': next,
        'epoch': customerId == old.customerId ? snapshot['epoch'] : next};
      final oldEpoch = snapshot['epoch'] as int;
      final oldCredit = await SaleCreditLedger.amounts(tx, saleId, oldEpoch);
      final netCash = old.receivedCents - oldCredit.transferred - await RefundLedger.net(tx, saleId, oldEpoch);
      final release = SaleSettlement.calculate(payableCents: preview.payableCents,
        netCashCents: netCash, allocatedCreditCents: oldCredit.applied,
        availableCreditCents: 0, customerChanged: customerId != old.customerId).creditReleasedCents;
      if (release > 0) {
        await SaleCreditLedger.post(tx, saleId: saleId, customerId: old.customerId,
          epoch: oldEpoch, version: next, kind: 'release', amount: release,
          key: 'credit:revision:$saleId:$next:release', now: happenedAt,
          payload: SaleCreditLedger.allocationPayload(saleId: saleId, customerId: old.customerId,
            epoch: oldEpoch, version: next, kind: 'release', amount: release));
      }
      await capture(tx, saleId, updated);
      await tx.insert('sale_revisions', {'sale_id': saleId, 'version': next,
        'request_key': key, 'payload': payload, 'snapshot': jsonEncode(updated),
        'amount_delta_cents': preview.amountDeltaCents, 'created_at': now});
      for (final id in newIds) {
        await tx.insert('sale_line_origins', {'sale_line_id': id, 'sale_id': saleId, 'introduced_version': next});
      }
      return next;
    });
  }

  @override
  Future<List<SaleRevisionRecord>> saleRevisions(int saleId) => db.transaction((tx) async {
    final rows = await tx.query('sale_revisions', where: 'sale_id=?',
      whereArgs: [saleId], orderBy: 'version DESC');
    final records = <SaleRevisionRecord>[];
    for (final r in rows) {
      final snapshot = Map<String, Object?>.from(jsonDecode(r['snapshot'] as String) as Map);
      final returns = await tx.rawQuery('''SELECT COALESCE(SUM(rl.length_milli),0) AS length,
        COALESCE(SUM(rl.area_micro),0) AS area FROM sale_return_lines rl
        JOIN sale_returns sr ON sr.id=rl.return_id JOIN sale_dispatches d ON d.id=sr.dispatch_id
        WHERE d.sale_id=? AND sr.id<=?''', [saleId, snapshot['returnCutoff'] ?? 0]);
      records.add(SaleRevisionRecord(sale: readSale(snapshot, snapshot['receivedCents'] as int,
        returnedLengthMilli: returns.single['length'] as int, returnedAreaMicro: returns.single['area'] as int),
        amountDeltaCents: r['amount_delta_cents'] as int, createdAt: r['created_at'] as String,
        refunds: readRefunds(snapshot), returns: readReturns(snapshot)));
    }
    return records;
  });

  @override
  Future<List<PendingSaleRefund>> pendingSaleRefunds(int saleId) => db.transaction((tx) async {
    final s = await currentSnapshot(tx, saleId);
    if (s == null) throw StateError('销售单不存在');
    return readRefunds({'refunds': await refundRows(tx, saleId, s)});
  });

  @override
  Future<List<PendingSaleReturn>> pendingSaleReturns(int saleId) => db.transaction((tx) async {
    final s = await currentSnapshot(tx, saleId);
    if (s == null) throw StateError('销售单不存在');
    return readReturns({'returns': await returnRows(tx, saleId, s)});
  });
}
