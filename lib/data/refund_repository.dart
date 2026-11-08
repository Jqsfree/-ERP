import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../application/refund_store.dart';
import '../domain/finance.dart';
import '../domain/sale_refund.dart';
import '../domain/sale_revision.dart';
import 'sale_revision_repository.dart';

class RefundRepository implements RefundStore {
  RefundRepository(this.db, this.clock);
  final Database db;
  final DateTime Function() clock;

  static RefundRequest read(Map<String, Object?> r) => RefundRequest(
    key: r['request_key'] as String,
    saleId: r['sale_id'] as int,
    kind: r['kind'] as String,
    status: r['status'] as String,
    payload: jsonDecode(r['payload'] as String) as Map<String, dynamic>,
    eventId: r['event_id'] as int?,
  );

  Future<void> _open(Transaction tx, String day) async {
    if ((await tx.query(
      'day_closures',
      where: 'business_date=?',
      whereArgs: [day],
    )).isNotEmpty) {
      throw StateError('该日期已经日结，禁止退款登记或冲销');
    }
  }

  Future<Map<String, Object?>?> _validate(
    Transaction tx,
    Map<String, dynamic> p,
    DateTime now,
  ) async {
    final snapshot = await SaleRevisionRepository.currentSnapshot(
      tx,
      p['saleId'] as int,
    );
    if (snapshot == null || snapshot['version'] != p['expectedRevision']) {
      throw StateError('销售单已修改，请取消未入账请求并刷新后重新登记');
    }
    if ((snapshot['header'] as Map)['status'] != 'confirmed') {
      throw StateError('销售单状态不允许退款');
    }
    await _open(tx, FinanceMath.day(now));
    if (p['kind'] == 'refund') {
      final pending = await SaleRevisionRepository.refundRows(
        tx,
        p['saleId'] as int,
        snapshot,
      );
      final sources = pending.where(
        (r) => r['customerId'] == p['customerId'] && r['epoch'] == p['epoch'],
      );
      if (sources.length != 1 ||
          (p['amountCents'] as int) > (sources.single['amountCents'] as int)) {
        throw StateError('可退款金额已变化，登记金额不得超过该客户归属段剩余待处理金额');
      }
      return null;
    }
    final rows = await tx.query(
      'sale_refund_events',
      where: 'id=?',
      whereArgs: [p['originalEventId']],
    );
    if (rows.isEmpty ||
        rows.single['kind'] != 'refund' ||
        rows.single['sale_id'] != p['saleId']) {
      throw StateError('原退款不存在或不能冲销');
    }
    final original = rows.single;
    await _open(tx, (original['created_at'] as String).substring(0, 10));
    if (now.isBefore(DateTime.parse(original['created_at'] as String))) {
      throw StateError('冲销时间不得早于原退款');
    }
    if ((await tx.query(
      'sale_refund_events',
      where: 'original_event_id=?',
      whereArgs: [p['originalEventId']],
    )).isNotEmpty) {
      throw StateError('原退款已经冲销，不允许重复冲销');
    }
    return original;
  }

  Future<RefundRequest> _prepare(
    Map<String, dynamic> payload,
    String requestKey,
  ) async {
    final key = FinanceMath.key(requestKey);
    final encoded = jsonEncode(payload);
    return db.transaction((tx) async {
      final old = await tx.query(
        'refund_requests',
        where: 'request_key=?',
        whereArgs: [key],
      );
      if (old.isNotEmpty) {
        if (old.single['payload'] != encoded) throw StateError('同一退款请求内容不同');
        return read(old.single);
      }
      final now = clock();
      await _validate(tx, payload, now);
      if ((await tx.query(
        'refund_requests',
        where: "sale_id=? AND status='pending'",
        whereArgs: [payload['saleId']],
      )).isNotEmpty) {
        throw StateError('本单有未完成退款请求，请先查询或处理原请求');
      }
      await tx.insert('refund_requests', {
        'request_key': key,
        'sale_id': payload['saleId'],
        'kind': payload['kind'],
        'payload': encoded,
        'status': 'pending',
        'event_id': null,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });
      return read(
        (await tx.query(
          'refund_requests',
          where: 'request_key=?',
          whereArgs: [key],
        )).single,
      );
    });
  }

  @override
  Future<RefundRequest> prepareSaleRefund({
    required int saleId,
    required int expectedRevision,
    required int customerId,
    required int epoch,
    required int amountCents,
    required String method,
    required String requestKey,
    String note = '',
  }) {
    if (amountCents <= 0 ||
        amountCents > 9223372036854775807 ||
        !FinanceMath.methods.contains(method) ||
        note.trim().length > 500 ||
        saleId <= 0 ||
        customerId <= 0 ||
        epoch < 0 ||
        expectedRevision < 0) {
      throw ArgumentError('退款金额、渠道、来源或备注无效');
    }
    return _prepare({
      'kind': 'refund',
      'saleId': saleId,
      'expectedRevision': expectedRevision,
      'customerId': customerId,
      'epoch': epoch,
      'amountCents': amountCents,
      'method': method,
      'note': note.trim(),
    }, requestKey);
  }

  @override
  Future<RefundRequest> prepareRefundReversal({
    required int originalEventId,
    required String reason,
    required bool fundsRecoveredOrMistake,
    required String requestKey,
  }) async {
    final why = reason.trim();
    if (!fundsRecoveredOrMistake || why.isEmpty || why.length > 500) {
      throw ArgumentError('必须填写冲销原因并确认误登记或退款资金已经收回');
    }
    // Preserve payload on idempotent retries, even if the sale has since changed.
    final existing = await refundRequest(FinanceMath.key(requestKey));
    if (existing != null) {
      if (existing.kind != 'reversal' ||
          existing.payload['originalEventId'] != originalEventId ||
          existing.payload['reason'] != why) {
        throw StateError('同一退款请求内容不同');
      }
      return existing;
    }
    final rows = await db.query(
      'sale_refund_events',
      where: 'id=?',
      whereArgs: [originalEventId],
    );
    if (rows.isEmpty) throw StateError('原退款不存在');
    final sid = rows.single['sale_id'] as int;
    final snapshot = await SaleRevisionRepository.currentSnapshot(db, sid);
    return _prepare({
      'kind': 'reversal',
      'saleId': sid,
      'expectedRevision': snapshot!['version'],
      'originalEventId': originalEventId,
      'reason': why,
      'fundsRecoveredOrMistake': true,
    }, requestKey);
  }

  @override
  Future<int> postRefundRequest(String requestKey) async {
    final key = FinanceMath.key(requestKey);
    return db.transaction((tx) async {
      final rows = await tx.query(
        'refund_requests',
        where: 'request_key=?',
        whereArgs: [key],
      );
      if (rows.isEmpty) throw StateError('退款请求不存在，请先保存请求');
      final r = rows.single;
      if (r['status'] == 'posted') return r['event_id'] as int;
      if (r['status'] != 'pending') throw StateError('该退款请求已取消');
      final p = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
      final now = clock();
      final original = await _validate(tx, p, now);
      final sid = p['saleId'] as int;
      final payments = await tx.rawQuery(
        'SELECT COALESCE(MAX(id),0) AS n FROM payments WHERE sale_id=?',
        [sid],
      );
      final credits = await tx.rawQuery(
        'SELECT COALESCE(MAX(id),0) AS n FROM sale_credit_events WHERE sale_id=?',
        [sid],
      );
      final id = await tx.insert('sale_refund_events', {
        'sale_id': sid,
        'customer_id': original?['customer_id'] ?? p['customerId'],
        'customer_epoch': original?['customer_epoch'] ?? p['epoch'],
        'sale_version': p['expectedRevision'],
        'kind': p['kind'],
        'amount_cents': original?['amount_cents'] ?? p['amountCents'],
        'method': original?['method'] ?? p['method'],
        'reason': p['reason'] ?? p['note'],
        'original_event_id': p['originalEventId'],
        'request_key': key,
        'payment_cutoff': payments.single['n'],
        'credit_cutoff': credits.single['n'],
        'created_at': now.toIso8601String(),
      });
      await tx.update(
        'refund_requests',
        {
          'status': 'posted',
          'event_id': id,
          'updated_at': now.toIso8601String(),
        },
        where: 'request_key=?',
        whereArgs: [key],
      );
      return id;
    });
  }

  @override
  Future<void> cancelRefundRequest(String requestKey) async {
    await db.transaction((tx) async {
      final rows = await tx.query(
        'refund_requests',
        where: 'request_key=?',
        whereArgs: [FinanceMath.key(requestKey)],
      );
      if (rows.isEmpty || rows.single['status'] == 'posted') {
        throw StateError('请求不存在或已经入账，不能取消');
      }
      await tx.update(
        'refund_requests',
        {'status': 'cancelled', 'updated_at': clock().toIso8601String()},
        where: "request_key=? AND status='pending'",
        whereArgs: [requestKey.trim()],
      );
    });
  }

  @override
  Future<RefundRequest?> refundRequest(String requestKey) async {
    final rows = await db.query(
      'refund_requests',
      where: 'request_key=?',
      whereArgs: [requestKey],
    );
    return rows.isEmpty ? null : read(rows.single);
  }

  @override
  Future<RefundRequest?> latestRefundRequest(int saleId) async {
    final rows = await db.query(
      'refund_requests',
      where: 'sale_id=?',
      whereArgs: [saleId],
      orderBy: "CASE status WHEN 'pending' THEN 0 ELSE 1 END, id DESC",
      limit: 1,
    );
    return rows.isEmpty ? null : read(rows.single);
  }

  @override
  Future<List<SaleRefundEvent>> saleRefundEvents(int saleId) async =>
      (await db.rawQuery(
        '''SELECT e.*, (SELECT customer_name_snapshot FROM sales s WHERE s.id=e.sale_id) AS original_name,
      (SELECT snapshot FROM sale_revisions r WHERE r.sale_id=e.sale_id AND r.version=e.customer_epoch) AS owner_snapshot,
      EXISTS(SELECT 1 FROM day_closures c
      WHERE c.business_date=SUBSTR(e.created_at,1,10)) AS closed
      FROM sale_refund_events e WHERE e.sale_id=? ORDER BY e.id DESC''',
        [saleId],
      )).map((r) {
        final name =
            r['customer_epoch'] == 0
                ? r['original_name']
                : (jsonDecode(r['owner_snapshot'] as String)
                    as Map)['header']['customer_name_snapshot'];
        return SaleRefundEvent.fromMap({...r, 'customer_name': name});
      }).toList();
  @override
  Future<List<PendingSaleRefund>> pendingSaleRefunds(int saleId) =>
      SaleRevisionRepository(db, clock).pendingSaleRefunds(saleId);
}
