import 'refund_ledger.dart';
import 'dart:convert';
import '../domain/models.dart';
import 'fulfillment_snapshot_validator.dart';
import 'sale_credit_ledger.dart';
import 'sale_revision_repository.dart';

class SaleCreditSnapshotValidator {
  static SaleCreditAmounts amountsAt(Map<String,List<Map<String,Object?>>> t,
    int saleId, int epoch, int cutoff) {
    var applied = 0;
    var transferred = 0;
    for (final e in t['sale_credit_events']!) {
      if (e['sale_id'] != saleId || e['customer_epoch'] != epoch || (e['id'] as int) > cutoff) continue;
      final amount = e['amount_cents'] as int;
      if (e['kind'] == 'apply') applied += amount;
      if (e['kind'] == 'release') applied -= amount;
      if (e['kind'] == 'transfer') transferred += amount;
    }
    return SaleCreditAmounts(applied: applied, transferred: transferred);
  }

  static void validate(Map<String,List<Map<String,Object?>>> t) {
    try { _validate(t); }
    on FormatException { rethrow; }
    catch (_) { throw const FormatException('余额来源与抵扣数据无效'); }
  }

  static void _validate(Map<String,List<Map<String,Object?>>> t) {
    final sales = FulfillmentSnapshotValidator.byId(t['sales']!, '销售');
    final ledger = FulfillmentSnapshotValidator.byId(t['customer_credit_entries']!, '余额流水');
    final events = FulfillmentSnapshotValidator.byId(t['sale_credit_events']!, '余额事件');
    final requests = FulfillmentSnapshotValidator.byId(t['sale_creation_requests']!, '开单请求');
    final owners = {for (final c in t['sale_payment_contexts']!) c['payment_id']: c};
    final versions = <int,Map<int,Map>>{};
    for (final r in t['sale_revisions']!) {
      (versions[r['sale_id'] as int] ??= {})[r['version'] as int] = jsonDecode(r['snapshot'] as String) as Map;
    }
    Map snapshot(int sid, int version) {
      if (version == 0) return versions[sid]?[0] ?? {'header': sales[sid], 'epoch': 0};
      final s = versions[sid]?[version];
      if (s == null) throw const FormatException('余额事件引用不存在的销售版本');
      return s;
    }
    int cash(int sid, int epoch, int cutoff) => t['payments']!.where((p) =>
      p['sale_id'] == sid && (p['id'] as int) <= cutoff &&
      (owners[p['id']]?['customer_epoch'] ?? 0) == epoch)
      .fold<int>(0, (sum,p) => sum + (p['amount_cents'] as int));
    int payable(Map h) => (h['subtotal_cents'] as int) - (h['discount_cents'] as int);
    final used = <int>{};
    final keys = <String>{};
    final appliedSales = <int>{};
    for (final e in events.values.toList()..sort((a,b) => (a['id'] as int).compareTo(b['id'] as int))) {
      final sid = e['sale_id'] as int;
      final version = e['sale_version'] as int;
      final epoch = e['customer_epoch'] as int;
      final amount = e['amount_cents'] as int;
      final lid = e['ledger_entry_id'] as int;
      final source = ledger[lid];
      final kind = e['kind'];
      final key = e['request_key'] as String;
      if (source == null || !used.add(lid) || !keys.add(key) || !sales.containsKey(sid) ||
          version < 0 || epoch < 0 || amount <= 0 ||
          source['customer_id'] != e['customer_id'] || source['sale_id'] != sid ||
          source['request_key'] != key || source['created_at'] != e['created_at'] ||
          DateTime.tryParse(e['created_at'] as String) == null) {
        throw const FormatException('余额流水与业务来源不一致');
      }
      if (kind == 'legacy') {
        if (version != 0 || epoch != 0 || (source['delta_cents'] as int).abs() != amount ||
            e['payload'] != jsonEncode({'legacyEntryId': lid})) {
          throw const FormatException('旧版余额来源无效');
        }
        continue;
      }
      if (!['apply','transfer','release'].contains(kind) ||
          source['delta_cents'] != (kind == 'apply' ? -amount : amount) ||
          source['reason'] != {'apply':'开单余额抵扣','transfer':'应退款转入余额','release':'改单释放余额抵扣'}[kind]) {
        throw const FormatException('余额事件类型、金额方向或原因不符');
      }
      final state = snapshot(sid, version);
      final h = state['header'] as Map;
      if (kind == 'transfer') {
        final originalOwner = epoch == 0 ? sales[sid]! : snapshot(sid, epoch)['header'] as Map;
        final next = versions[sid]?[version + 1];
        if (version == 0 || originalOwner['customer_id'] != e['customer_id'] || epoch > version ||
            (e['id'] as int) <= (state['creditCutoff'] as int? ?? 0) ||
            (next != null && (e['id'] as int) > (next['creditCutoff'] as int? ?? 0))) {
          throw const FormatException('转余额的版本或退款客户不符');
        }
        final before = amountsAt(t, sid, epoch, (e['id'] as int) - 1);
        final paid = cash(sid, epoch, next?['paymentCutoff'] as int? ?? 9223372036854775807);
        final expected = paid - before.transferred - RefundLedger.netAt(t['sale_refund_events'] ?? [], sid, epoch, e['refund_cutoff'] as int? ?? 0) - (state['epoch'] == epoch ? payable(h) : 0);
        if (amount > expected || e['payload'] != jsonEncode({'saleId': sid,
          'expectedRevision': version, 'customerId': e['customer_id'], 'epoch': epoch,
          'amountCents': amount, 'kind': 'transfer'})) {
          throw const FormatException('转余额超出待退款或内容不符');
        }
      } else {
        if (e['payload'] != SaleCreditLedger.allocationPayload(saleId: sid,
          customerId: e['customer_id'] as int, epoch: epoch, version: version,
          kind: kind as String, amount: amount)) {
          throw const FormatException('余额分配请求不一致');
        }
        if (kind == 'apply') {
          final openingCash = t['payments']!.where((p) => p['sale_id'] == sid && p['remark'] == '开单收款')
            .fold<int>(0, (n,p) => n + (p['amount_cents'] as int));
          final available = ledger.values.where((l) => l['customer_id'] == e['customer_id'] &&
            (l['id'] as int) < lid).fold<int>(0, (n,l) => n + (l['delta_cents'] as int));
          final capacity = payable(sales[sid]!) - openingCash;
          if (version != 0 || epoch != 0 || !appliedSales.add(sid) ||
              e['customer_id'] != sales[sid]!['customer_id'] || key != 'credit:opening:$sid' ||
              amount != (available < capacity ? available : capacity)) {
            throw const FormatException('开单抵扣不是现金首收后的可用余额');
          }
        } else {
          if (version == 0) throw const FormatException('原始版本不能释放抵扣');
          final previous = snapshot(sid, version - 1);
          final oldHeader = previous['header'] as Map;
          final before = amountsAt(t, sid, epoch, (e['id'] as int) - 1);
          final net = cash(sid, epoch, state['paymentCutoff'] as int) - before.transferred -
            RefundLedger.netAt(t['sale_refund_events'] ?? [], sid, epoch, state['refundCutoff'] as int? ?? 0);
          final capacity = payable(h) > net ? payable(h) - net : 0;
          final keep = h['customer_id'] == oldHeader['customer_id']
            ? (before.applied < capacity ? before.applied : capacity) : 0;
          if (epoch != previous['epoch'] || e['customer_id'] != oldHeader['customer_id'] ||
              amount != before.applied - keep || key != 'credit:revision:$sid:$version:release' ||
              (e['id'] as int) > (state['creditCutoff'] as int? ?? 0) ||
              (e['id'] as int) <= (previous['creditCutoff'] as int? ?? 0)) {
            throw const FormatException('改单释放抵扣超出原分配或版本不符');
          }
        }
      }
    }
    if (used.length != ledger.length) throw const FormatException('余额流水缺少来源记录');
    for (final sid in sales.keys) {
      final group = versions[sid];
      final latestVersion = group == null ? 0 : group.keys.reduce((a,b) => a > b ? a : b);
      final current = snapshot(sid, latestVersion);
      final currentEpoch = current['epoch'] as int;
      final epochs = {0, ...t['sale_credit_events']!.where((e) => e['sale_id'] == sid)
        .map((e) => e['customer_epoch'] as int)};
      for (final epoch in epochs) {
        final credit = amountsAt(t, sid, epoch, 9223372036854775807);
        final netCash = cash(sid, epoch, 9223372036854775807) - credit.transferred -
          RefundLedger.netAt(t['sale_refund_events'] ?? [], sid, epoch, 9223372036854775807);
        final capacity = payable(current['header'] as Map) - netCash;
        if (credit.applied < 0 || netCash < 0 ||
            (epoch != currentEpoch && credit.applied != 0) ||
            (epoch == currentEpoch && credit.applied > (capacity > 0 ? capacity : 0))) {
          throw const FormatException('余额分配与当前销售应收不守恒');
        }
      }
    }
    final requestKeys = <String>{};
    final requestSales = <int>{};
    for (final r in requests.values) {
      final sid = r['sale_id'] as int;
      final h = sales[sid];
      final key = r['request_key'] as String;
      if (h == null || !requestSales.add(sid) || !requestKeys.add(key) || key.length < 12 || key.length > 128 ||
          r['created_at'] != h['created_at']) {
        throw const FormatException('开单幂等来源无效');
      }
      final originalLines = t['sale_lines']!.where((l) => l['sale_id'] == sid &&
        !t['sale_line_origins']!.any((o) => o['sale_line_id'] == l['id'])).toList()
        ..sort((a,b) => (a['id'] as int).compareTo(b['id'] as int));
      final initial = t['payments']!.where((p) => p['sale_id'] == sid && p['remark'] == '开单收款')
        .fold<int>(0, (n,p) => n + (p['amount_cents'] as int));
      final expected = jsonEncode({'customerId': h['customer_id'], 'discountCents': h['discount_cents'],
        'initialReceivedCents': initial, 'note': h['note'],
        'lines': originalLines.map((l) => SaleRevisionRepository.lineRow(0, SaleLine.fromMap(l))..remove('sale_id')).toList()});
      if (r['payload'] != expected) throw const FormatException('开单请求与原始交易不一致');
    }
  }
}
