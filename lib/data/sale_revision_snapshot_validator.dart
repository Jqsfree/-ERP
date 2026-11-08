import 'refund_ledger.dart';
import '../domain/safe_int.dart';
import 'dart:convert';

import '../domain/finance.dart';
import '../domain/models.dart';
import '../domain/sale_revision.dart';
import 'fulfillment_snapshot_validator.dart';
import 'sale_revision_repository.dart';
import 'sale_credit_snapshot_validator.dart';

/// Replay version lineage and captured obligations before any restore writes.
class SaleRevisionSnapshotValidator {
  static Object? canonical(Object? value) {
    if (value is List) return value.map(canonical).toList();
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    return value;
  }
  static bool same(Object? a, Object? b) => jsonEncode(canonical(a)) == jsonEncode(canonical(b));
  static Map<String, Object?> decode(Object? value) {
    if (value is! String) throw const FormatException('修订快照不是文本');
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) throw const FormatException('修订快照不是对象');
    return Map<String, Object?>.from(decoded);
  }

  static void validate(Map<String, List<Map<String, Object?>>> tables) {
    try {
      _validate(tables);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('修订快照结构或内容无效');
    }
  }

  static void _validate(Map<String, List<Map<String, Object?>>> t) {
    final sales = FulfillmentSnapshotValidator.byId(t['sales']!, '原销售');
    final lines = FulfillmentSnapshotValidator.byId(t['sale_lines']!, '原销售行');
    final payments = FulfillmentSnapshotValidator.byId(t['payments']!, '收款');
    final customers = FulfillmentSnapshotValidator.byId(t['customers']!, '客户');
    final products = FulfillmentSnapshotValidator.byId(t['products']!, '商品');
    final versions = <int, Map<int, Map<String, Object?>>>{};
    final keys = <String>{};
    FulfillmentSnapshotValidator.byId(t['sale_revisions']!, '修订');
    for (final r in t['sale_revisions']!) {
      final sid = r['sale_id'] as int;
      final version = r['version'] as int;
      if (!sales.containsKey(sid) || version < 0 || r['created_at'] is! String ||
          r['amount_delta_cents'] is! int || !keys.add(r['request_key'] as String) ||
          (versions[sid] ?? {}).containsKey(version)) {
        throw const FormatException('修订版本或标识无效');
      }
      (versions[sid] ??= {})[version] = r;
    }
    final origins = <int, Map<String, Object?>>{};
    FulfillmentSnapshotValidator.byId(t['sale_line_origins']!, '明细来源');
    for (final o in t['sale_line_origins']!) {
      final id = o['sale_line_id'] as int;
      final sid = o['sale_id'] as int;
      final v = o['introduced_version'] as int;
      if (origins.containsKey(id) || lines[id]?['sale_id'] != sid || v <= 0 ||
          versions[sid]?[v] == null) {
        throw const FormatException('新增行版本来源无效');
      }
      origins[id] = o;
    }
    final contexts = <int, Map<String, Object?>>{};
    FulfillmentSnapshotValidator.byId(t['sale_payment_contexts']!, '收款归属');
    for (final c in t['sale_payment_contexts']!) {
      final id = c['payment_id'] as int;
      final payment = payments[id];
      if (payment == null || contexts.containsKey(id) || !customers.containsKey(c['customer_id'])) {
        throw const FormatException('收款归属关联无效');
      }
      final sid = payment['sale_id'] as int;
      final epoch = c['customer_epoch'] as int;
      final owner = epoch == 0 ? sales[sid]! :
        decode(versions[sid]![epoch]!['snapshot'])['header'] as Map;
      if (epoch < 0 || owner['customer_id'] != c['customer_id'] ||
          (epoch > 0 && decode(versions[sid]![epoch]!['snapshot'])['epoch'] != epoch)) {
        throw const FormatException('收款客户或归属段无效');
      }
      contexts[id] = c;
    }
    Map<int, int> paidByEpoch(int sid, int cutoff) {
      final amounts = <int, int>{};
      for (final p in payments.values.where((p) => p['sale_id'] == sid && (p['id'] as int) <= cutoff)) {
        final epoch = contexts[p['id']]?['customer_epoch'] as int? ?? 0;
        amounts[epoch] = (amounts[epoch] ?? 0) + (p['amount_cents'] as int);
      }
      return amounts;
    }
    final epochs = <int, Map<int, Map>>{};
    for (final entry in versions.entries) {
      final sid = entry.key;
      final group = entry.value;
      if (group.length < 2 || !group.containsKey(0) ||
          List.generate(group.length, (i) => i).any((i) => !group.containsKey(i))) {
        throw const FormatException('销售版本不连续或缺少原始版本');
      }
      Map<String, Object?>? previous;
      for (var v = 0; v < group.length; v++) {
        final r = group[v]!;
        final s = decode(r['snapshot']);
        final h = Map<String, Object?>.from(s['header'] as Map);
        final detail = (s['lines'] as List).map((l) => Map<String, Object?>.from(l as Map)).toList();
        final epoch = s['epoch'] as int;
        final cutoff = s['paymentCutoff'] as int;
        final creditCutoff = s['creditCutoff'] as int? ?? 0;
        final refundCutoff = s['refundCutoff'] as int? ?? 0;
        if (refundCutoff < 0 || (refundCutoff != 0 && !t['sale_refund_events']!.any((e) => e['id'] == refundCutoff && e['sale_id'] == sid)) ||
          (previous != null && refundCutoff < (previous['refundCutoff'] as int? ?? 0)) ||
          (s['refundedCents'] as int? ?? 0) != RefundLedger.netAt(t['sale_refund_events']!, sid, epoch, refundCutoff)) {
          throw const FormatException('修订退款快照不守恒');
        }
        if (creditCutoff < 0 || (creditCutoff != 0 && !t['sale_credit_events']!.any((e) =>
          e['id'] == creditCutoff && e['sale_id'] == sid))) {
          throw const FormatException('修订余额事件边界无效');
        }
        final credit = SaleCreditSnapshotValidator.amountsAt(t, sid, epoch, creditCutoff);
        if ((s['creditAppliedCents'] ?? 0) != credit.applied ||
            (s['transferredCents'] ?? 0) != credit.transferred) {
          throw const FormatException('修订余额抵扣或转出快照不守恒');
        }
        if (cutoff != 0 && payments[cutoff]?['sale_id'] != sid) {
          throw const FormatException('修订收款边界不存在或属于其他单据');
        }
        for (final pair in [('dispatchCutoff', 'sale_dispatches'), ('returnCutoff', 'sale_returns')]) {
          final limit = s[pair.$1] as int;
          if (limit != 0 && !t[pair.$2]!.any((r) => r['id'] == limit &&
            (pair.$2 == 'sale_dispatches' ? r['sale_id'] == sid :
              t['sale_dispatches']!.any((d) => d['id'] == r['dispatch_id'] && d['sale_id'] == sid)))) {
            throw const FormatException('修订履约边界不存在或属于其他单据');
          }
        }
        final original = sales[sid]!;
        if (s['version'] != v || h['id'] != sid || h['number'] != original['number'] ||
            h['created_at'] != original['created_at'] || h['status'] != 'confirmed' ||
            h['prior_due_snapshot'] is! int ||
            !customers.containsKey(h['customer_id']) || detail.isEmpty || cutoff < 0 ||
            (s['dispatchCutoff'] as int) < 0 || (s['returnCutoff'] as int) < 0) {
          throw const FormatException('修订头部或事件边界无效');
        }
        FinanceMath.validDay(h['date'] as String);
        for (final field in ['customer_name_snapshot', 'customer_phone_snapshot',
          'customer_address_snapshot', 'note']) {
          if (h[field] is! String) throw const FormatException('修订客户快照无效');
        }
        final ids = <int>{};
        var sum = 0;
        for (final l in detail) {
          final id = l['id'] as int;
          final base = lines[id];
          if (base == null || !ids.add(id) || l['sale_id'] != sid || base['sale_id'] != sid ||
              l['product_id'] != base['product_id'] || l['width_milli'] != base['width_milli'] ||
              l['code_snapshot'] != base['code_snapshot'] || l['spec_snapshot'] != base['spec_snapshot'] ||
              l['note'] is! String || (l['product_id'] != null && !products.containsKey(l['product_id'])) ||
              ((origins[id]?['introduced_version'] as int?) ?? 0) > v) {
            throw const FormatException('修订行身份或来源无效');
          }
          final value = SaleLine.fromMap(l).totalCents;
          if (value != l['amount_cents']) throw const FormatException('修订行金额无效');
          sum = SafeInt.add(sum, value);
        }
        final paid = paidByEpoch(sid, cutoff);
        if (h['subtotal_cents'] != sum || (h['discount_cents'] as int) < 0 ||
            (h['discount_cents'] as int) > sum || s['receivedCents'] != (paid[epoch] ?? 0)) {
          throw const FormatException('修订金额或收款快照不守恒');
        }
        final remainingCapacity = sum - (h['discount_cents'] as int) - ((paid[epoch] ?? 0) - credit.transferred - RefundLedger.netAt(t['sale_refund_events']!, sid, epoch, refundCutoff));
        if (credit.applied < 0 || credit.applied > (remainingCapacity > 0 ? remainingCapacity : 0)) {
          throw const FormatException('修订余额抵扣超过当时应收');
        }
        for (final other in t['sale_credit_events']!.where((e) => e['sale_id'] == sid)
          .map((e) => e['customer_epoch'] as int).toSet()) {
          if (other != epoch && SaleCreditSnapshotValidator.amountsAt(t, sid, other, creditCutoff).applied != 0) {
            throw const FormatException('更换客户时未释放原客户抵扣');
          }
        }
        if (v == 0) {
          final originals = lines.values.where((l) => l['sale_id'] == sid && !origins.containsKey(l['id'])).toList()
            ..sort((a,b) => (a['id'] as int).compareTo(b['id'] as int));
          if (epoch != 0 || !same(h, original) ||
              !same(detail, originals) || r['amount_delta_cents'] != 0 ||
              r['request_key'] != 'baseline:$sid' || r['payload'] != '{}') {
            throw const FormatException('原始版本与交易事实不符');
          }
        } else {
          final ph = previous!['header'] as Map;
          final expectedEpoch = ph['customer_id'] == h['customer_id'] ? previous['epoch'] : v;
          final oldPayable = (ph['subtotal_cents'] as int) - (ph['discount_cents'] as int);
          if (epoch != expectedEpoch || r['amount_delta_cents'] != sum - (h['discount_cents'] as int) - oldPayable ||
              cutoff < (previous['paymentCutoff'] as int) ||
              creditCutoff < (previous['creditCutoff'] as int? ?? 0) ||
              (ph['customer_id'] == h['customer_id'] && ph['prior_due_snapshot'] != h['prior_due_snapshot'])) {
            throw const FormatException('版本差额或收款归属不一致');
          }
          final request = decode(r['payload']);
          if ((r['request_key'] as String).length < 12 || (r['request_key'] as String).length > 128 ||
              request['saleId'] != sid || request['expectedRevision'] != v - 1 ||
              request['customerId'] != h['customer_id'] || request['date'] != h['date'] ||
              request['note'] != h['note'] || request['discountCents'] != h['discount_cents']) {
            throw const FormatException('改单请求与版本头不一致');
          }
          final input = (request['lines'] as List).map((l) => Map<String, Object?>.from(l as Map)).toList();
          final preview = SaleRevisionPreview.calculate(original: SaleRevisionRepository.readSale(previous, 0),
            lines: input.map(SaleLine.fromMap).toList(), discountCents: request['discountCents'] as int);
          if (input.length != detail.length || preview.payableCents != sum - (h['discount_cents'] as int)) {
            throw const FormatException('改单请求金额与明细不一致');
          }
          for (var i = 0; i < input.length; i++) {
            final a = Map<String, Object?>.from(input[i]);
            final b = Map<String, Object?>.from(detail[i]);
            final outputId = b.remove('id') as int;
            final inputId = a.remove('id');
            final change = preview.changes[i];
            if (!same(a, b) ||
                ((inputId == null || change.physicalIdentityChanged)
                  ? (origins[outputId]?['introduced_version'] != v)
                  : outputId != inputId)) {
              throw const FormatException('改单输出与原请求行不一致');
            }
          }
        }
        (epochs[sid] ??= {})[epoch] = h;
        final expectedRefunds = <Map<String, Object?>>[];
        for (final e in paid.entries.toList()..sort((a,b) => a.key.compareTo(b.key))) {
          final owner = epochs[sid]![e.key];
          if (owner == null) throw const FormatException('退款归属缺少客户段');
          final transferred = SaleCreditSnapshotValidator.amountsAt(t, sid, e.key, creditCutoff).transferred;
          final amount = e.value - transferred - RefundLedger.netAt(t['sale_refund_events']!, sid, e.key, refundCutoff) - (e.key == epoch ? sum - (h['discount_cents'] as int) : 0);
          if (amount > 0) {
            expectedRefunds.add({'customerId': owner['customer_id'],
              'customerName': owner['customer_name_snapshot'], 'epoch': e.key, 'amountCents': amount});
          }
        }
        if (jsonEncode(expectedRefunds) != jsonEncode(s['refunds'])) throw const FormatException('待退款快照不守恒');
        final target = {for (final l in detail) l['id'] as int: l['length_milli'] as int};
        final net = <int,int>{};
        for (final d in t['sale_dispatch_lines']!) {
          final dispatchId = d['dispatch_id'] as int;
          if (dispatchId > (s['dispatchCutoff'] as int) || lines[d['sale_line_id']]?['sale_id'] != sid) continue;
          final root = d['sale_line_id'] as int;
          var n = d['length_milli'] as int;
          for (final back in t['sale_return_lines']!.where((back) => back['dispatch_line_id'] == d['id'] &&
            (back['return_id'] as int) <= (s['returnCutoff'] as int))) {
            n -= back['length_milli'] as int;
          }
          net[root] = (net[root] ?? 0) + n;
        }
        final expectedReturns = <Map<String,Object?>>[];
        for (final e in net.entries.toList()..sort((a,b) => a.key.compareTo(b.key))) {
          final n = e.value - (target[e.key] ?? 0);
          if (n > 0) {
            expectedReturns.add({'saleLineId': e.key, 'code': lines[e.key]!['code_snapshot'],
              'widthMilli': lines[e.key]!['width_milli'], 'lengthMilli': n});
          }
        }
        if (jsonEncode(expectedReturns) != jsonEncode(s['returns'])) throw const FormatException('待退货快照不一致');
        previous = s;
      }
      final latest = previous!;
      final epoch = latest['epoch'] as int;
      final cutoff = latest['paymentCutoff'] as int;
      for (final p in payments.values.where((p) => p['sale_id'] == sid)) {
        var expectedEpoch = 0;
        for (var v = 1; v < group.length; v++) {
          final s = decode(group[v]!['snapshot']);
          if ((p['id'] as int) <= (s['paymentCutoff'] as int)) break;
          expectedEpoch = s['epoch'] as int;
        }
        if ((contexts[p['id']]?['customer_epoch'] ?? 0) != expectedEpoch) {
          throw const FormatException('收款归属与发生时有效客户版本不一致');
        }
      }
      for (final p in payments.values.where((p) => p['sale_id'] == sid && (p['id'] as int) > cutoff)) {
        if ((contexts[p['id']]?['customer_epoch'] ?? 0) != epoch) throw const FormatException('旧归属段追加收款');
      }
      final allPaid = paidByEpoch(sid, 9223372036854775807)[epoch] ?? 0;
      final h = latest['header'] as Map;
      final payable = (h['subtotal_cents'] as int) - (h['discount_cents'] as int);
      final atRevision = latest['receivedCents'] as int;
      final netAtRevision = atRevision - (latest['transferredCents'] as int? ?? 0) - (latest['refundedCents'] as int? ?? 0) +
        (latest['creditAppliedCents'] as int? ?? 0);
      final capacity = payable > netAtRevision ? payable - netAtRevision : 0;
      if (allPaid > atRevision + capacity) throw const FormatException('改单后收款超额');
    }
    final dispatches = FulfillmentSnapshotValidator.byId(t['sale_dispatches']!, '出库');
    final seenDispatches = <int>{};
    FulfillmentSnapshotValidator.byId(t['sale_dispatch_contexts']!, '出库版本');
    for (final c in t['sale_dispatch_contexts']!) {
      if (!seenDispatches.add(c['dispatch_id'] as int) ||
          dispatches[c['dispatch_id']]?['sale_id'] != c['sale_id'] ||
          (c['version'] as int) <= 0 || versions[c['sale_id']]?[c['version']] == null) {
        throw const FormatException('出库版本关联无效');
      }
    }
    for (final d in dispatches.values) {
      final group = versions[d['sale_id']];
      if (group == null) continue;
      final did = d['id'] as int;
      var expectedVersion = 0;
      for (var v = 1; v < group.length; v++) {
        if (did <= (decode(group[v]!['snapshot'])['dispatchCutoff'] as int)) break;
        expectedVersion = v;
      }
      final context = t['sale_dispatch_contexts']!.where((c) => c['dispatch_id'] == did);
      if ((context.isEmpty ? 0 : context.single['version']) != expectedVersion) {
        throw const FormatException('出库缺少或错误引用发生时有效版本');
      }
    }
    for (final o in origins.values) {
      final s = decode(versions[o['sale_id']]![o['introduced_version']]!['snapshot']);
      final source = (s['lines'] as List).where((l) => (l as Map)['id'] == o['sale_line_id']);
      if (source.length != 1 || !same(source.single, lines[o['sale_line_id']])) {
        throw const FormatException('新增行没有出现在来源版本');
      }
    }
  }
}
