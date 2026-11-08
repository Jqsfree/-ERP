import 'dart:convert';
import '../domain/finance.dart';
import 'refund_ledger.dart';
import 'sale_credit_snapshot_validator.dart';

/// Replays cash refunds against their exact payment, credit and version bounds.
class RefundSnapshotValidator {
  static void validate(Map<String, List<Map<String, Object?>>> t) {
    try {
      _validate(t);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('退款记录或请求关联无效');
    }
  }

  static void _validate(Map<String, List<Map<String, Object?>>> t) {
    final events = t['sale_refund_events']!;
    final requests = t['refund_requests']!;
    final sales = {for (final r in t['sales']!) r['id']: r};
    final payments = {for (final r in t['payments']!) r['id']: r};
    final credits = {for (final r in t['sale_credit_events']!) r['id']: r};
    final contexts = {
      for (final r in t['sale_payment_contexts']!) r['payment_id']: r,
    };
    final versions = <Object?, Map<int, Map>>{};
    for (final r in t['sale_revisions']!) {
      (versions[r['sale_id']] ??= {})[r['version'] as int] =
          jsonDecode(r['snapshot'] as String) as Map;
    }
    Map state(Object? sid, int version) =>
        versions[sid]?[version] ??
        (version == 0 && sales.containsKey(sid)
            ? {'header': sales[sid], 'epoch': 0}
            : throw const FormatException('退款引用销售版本不存在'));
    void cutoff(
      Object? value,
      Map<Object?, Map<String, Object?>> rows,
      Object? sid,
    ) {
      if (value is! int ||
          value < 0 ||
          (value != 0 && rows[value]?['sale_id'] != sid)) {
        throw const FormatException('退款事件边界不存在或属于其他单据');
      }
    }

    for (final close in t['day_closures']!) {
      final limit = close['refund_cutoff'];
      if (limit is! int ||
          limit < 0 ||
          (limit > 0 && !events.any((e) => e['id'] == limit))) {
        throw const FormatException('日结退款边界无效');
      }
    }
    final byId = <Object?, Map<String, Object?>>{};
    final keys = <Object?>{};
    final reversed = <Object?>{};
    for (final r in [...events]
      ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int))) {
      final id = r['id'] as int;
      final sid = r['sale_id'] as int;
      final epoch = r['customer_epoch'] as int;
      final version = r['sale_version'] as int;
      final amount = r['amount_cents'] as int;
      final now = DateTime.parse(r['created_at'] as String);
      final reason = r['reason'] as String;
      if (id <= 0 ||
          byId.containsKey(id) ||
          !keys.add(r['request_key']) ||
          amount <= 0 ||
          !FinanceMath.methods.contains(r['method']) ||
          reason != reason.trim() ||
          reason.length > 500 ||
          epoch < 0 ||
          epoch > version) {
        throw const FormatException('退款标识、金额或来源无效');
      }
      final s = state(sid, version);
      final owner = state(sid, epoch);
      if ((owner['header'] as Map)['customer_id'] != r['customer_id'] ||
          owner['epoch'] != epoch ||
          id <= (s['refundCutoff'] as int? ?? 0) ||
          (versions[sid]?[version + 1] != null &&
              id >
                  (versions[sid]![version + 1]!['refundCutoff'] as int? ??
                      0))) {
        throw const FormatException('退款客户、归属段或发生版本无效');
      }
      cutoff(r['payment_cutoff'], payments, sid);
      cutoff(r['credit_cutoff'], credits, sid);
      if ((r['payment_cutoff'] as int) < (s['paymentCutoff'] as int? ?? 0) ||
          (r['credit_cutoff'] as int) < (s['creditCutoff'] as int? ?? 0)) {
        throw const FormatException('退款边界早于销售版本');
      }
      final next = versions[sid]?[version + 1];
      if (next != null &&
          ((r['payment_cutoff'] as int) > (next['paymentCutoff'] as int) ||
              (r['credit_cutoff'] as int) >
                  (next['creditCutoff'] as int? ?? 0))) {
        throw const FormatException('退款边界超出销售版本');
      }
      if (r['kind'] == 'refund') {
        if (r['original_event_id'] != null || version == 0) {
          throw const FormatException('原退款引用无效');
        }
        final paid = payments.values
            .where(
              (p) =>
                  p['sale_id'] == sid &&
                  (p['id'] as int) <= (r['payment_cutoff'] as int) &&
                  (contexts[p['id']]?['customer_epoch'] ?? 0) == epoch,
            )
            .fold<int>(0, (n, p) => n + (p['amount_cents'] as int));
        final transferred =
            SaleCreditSnapshotValidator.amountsAt(
              t,
              sid,
              epoch,
              r['credit_cutoff'] as int,
            ).transferred;
        final header = s['header'] as Map;
        final capacity =
            paid -
            transferred -
            RefundLedger.netAt(events, sid, epoch, id - 1) -
            (s['epoch'] == epoch
                ? (header['subtotal_cents'] as int) -
                    (header['discount_cents'] as int)
                : 0);
        if (amount > capacity) throw const FormatException('退款超过当时剩余待处理金额');
      } else if (r['kind'] == 'reversal') {
        final original = byId[r['original_event_id']];
        if (original == null ||
            original['kind'] != 'refund' ||
            !reversed.add(original['id']) ||
            reason.isEmpty ||
            now.isBefore(DateTime.parse(original['created_at'] as String)) ||
            [
              'sale_id',
              'customer_id',
              'customer_epoch',
              'amount_cents',
              'method',
            ].any((k) => original[k] != r[k])) {
          throw const FormatException('退款冲销来源、金额或原因无效');
        }
        for (final close in t['day_closures']!) {
          if ((original['created_at'] as String).startsWith(
                close['business_date'] as String,
              ) &&
              id > (close['refund_cutoff'] as int)) {
            throw const FormatException('已日结原退款被冲销');
          }
        }
      } else {
        throw const FormatException('退款事件类型无效');
      }
      for (final close in t['day_closures']!) {
        if ((r['created_at'] as String).startsWith(
              close['business_date'] as String,
            ) &&
            id > (close['refund_cutoff'] as int)) {
          throw const FormatException('已日结日期追加退款事件');
        }
      }
      byId[id] = r;
    }
    final requestKeys = <Object?>{},
        requestIds = <Object?>{},
        posted = <Object?>{},
        pending = <Object?>{};
    for (final r in requests) {
      final key = r['request_key'] as String;
      FinanceMath.key(key);
      final payload = jsonDecode(r['payload'] as String) as Map;
      final sid = r['sale_id'];
      final kind = r['kind'];
      final version = payload['expectedRevision'] as int;
      state(sid, version);
      final created = DateTime.parse(r['created_at'] as String);
      final updated = DateTime.parse(r['updated_at'] as String);
      if (key != key.trim() ||
          !requestKeys.add(key) ||
          !requestIds.add(r['id']) ||
          (r['id'] as int) <= 0 ||
          payload['saleId'] != sid ||
          payload['kind'] != kind ||
          updated.isBefore(created)) {
        throw const FormatException('退款请求来源或标识无效');
      }
      Map expected;
      if (kind == 'refund') {
        final amount = payload['amountCents'] as int;
        final note = payload['note'] as String;
        final epoch = payload['epoch'] as int;
        if (amount <= 0 ||
            !FinanceMath.methods.contains(payload['method']) ||
            note != note.trim() ||
            note.length > 500 ||
            epoch < 0 ||
            epoch > version ||
            (state(sid, epoch)['header'] as Map)['customer_id'] !=
                payload['customerId']) {
          throw const FormatException('退款请求金额、客户或渠道无效');
        }
        expected = {
          'kind': kind,
          'saleId': sid,
          'expectedRevision': version,
          'customerId': payload['customerId'],
          'epoch': epoch,
          'amountCents': amount,
          'method': payload['method'],
          'note': note,
        };
      } else if (kind == 'reversal') {
        final original = byId[payload['originalEventId']];
        final reason = payload['reason'] as String;
        if (original == null ||
            original['sale_id'] != sid ||
            original['kind'] != 'refund' ||
            reason.trim().isEmpty ||
            reason != reason.trim() ||
            reason.length > 500 ||
            payload['fundsRecoveredOrMistake'] != true) {
          throw const FormatException('冲销请求原因或确认缺失');
        }
        expected = {
          'kind': kind,
          'saleId': sid,
          'expectedRevision': version,
          'originalEventId': original['id'],
          'reason': reason,
          'fundsRecoveredOrMistake': true,
        };
      } else {
        throw const FormatException('退款请求类型无效');
      }
      if (jsonEncode(expected) != r['payload']) {
        throw const FormatException('退款请求载荷不一致');
      }
      if (r['status'] == 'posted') {
        final e = byId[r['event_id']];
        if (e == null ||
            !posted.add(r['event_id']) ||
            e['request_key'] != key ||
            e['sale_id'] != sid ||
            e['sale_version'] != version ||
            e['kind'] != kind ||
            updated != DateTime.parse(e['created_at'] as String) ||
            (kind == 'refund'
                ? [
                  'customer_id',
                  'customer_epoch',
                  'amount_cents',
                  'method',
                  'reason',
                ].asMap().entries.any(
                  (entry) =>
                      e[entry.value] !=
                      payload[[
                        'customerId',
                        'epoch',
                        'amountCents',
                        'method',
                        'note',
                      ][entry.key]],
                )
                : e['original_event_id'] != payload['originalEventId'] ||
                    e['reason'] != payload['reason'])) {
          throw const FormatException('退款请求与入账事件不一致');
        }
      } else if (r['status'] == 'pending' || r['status'] == 'cancelled') {
        if (r['event_id'] != null ||
            (r['status'] == 'pending' && !pending.add(sid))) {
          throw const FormatException('待退款请求重复或入账关联无效');
        }
      } else {
        throw const FormatException('退款请求状态无效');
      }
    }
    if (posted.length != events.length) {
      throw const FormatException('退款事件缺少持久化请求');
    }
    for (final c in credits.values) {
      cutoff(c['refund_cutoff'], byId, c['sale_id']);
      final limit = c['refund_cutoff'] as int;
      // Both ledgers must agree on their interleaving; later refunds cannot be used early.
      for (final e in events.where((e) => e['sale_id'] == c['sale_id'])) {
        if (((e['id'] as int) <= limit) !=
            ((e['credit_cutoff'] as int) < (c['id'] as int))) {
          throw const FormatException('退款与余额事件顺序不一致');
        }
      }
    }
  }
}
