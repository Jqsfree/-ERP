import 'models.dart';
import 'money.dart';

class SaleRevisionRecord {
  const SaleRevisionRecord({required this.sale, required this.amountDeltaCents,
    required this.createdAt, required this.refunds, required this.returns});
  final Sale sale;
  final int amountDeltaCents;
  final String createdAt;
  final List<PendingSaleRefund> refunds;
  final List<PendingSaleReturn> returns;
}

class PendingSaleRefund {
  const PendingSaleRefund({required this.customerId, required this.customerName,
    required this.epoch, required this.amountCents});
  final int customerId;
  final String customerName;
  final int epoch;
  final int amountCents;
}

class PendingSaleReturn {
  const PendingSaleReturn({required this.saleLineId, required this.code,
    required this.widthMilli, required this.lengthMilli});
  final int saleLineId;
  final String code;
  final int widthMilli;
  final int lengthMilli;
}

/// A proposed change to one identified line, not a posted money/stock event.
class SaleLineChange {
  const SaleLineChange({required this.before, required this.after});

  final SaleLine? before;
  final SaleLine? after;

  int get amountDeltaCents => (after?.totalCents ?? 0) - (before?.totalCents ?? 0);

  /// Quantity is comparable only for the same physical item and width.
  /// A replacement needs an explicit fulfillment policy before posting.
  bool get physicalIdentityChanged => before != null && after != null &&
      (before!.productId != after!.productId ||
       before!.code != after!.code || before!.specification != after!.specification ||
       before!.widthMilli != after!.widthMilli);
}

/// Read-only revision calculation. Does not decide refunds, credit allocation,
/// customer changes or physical returns; those require confirmed posting rules.
class SaleRevisionPreview {
  SaleRevisionPreview._({required this.saleId, required this.number,
    required this.lines, required this.changes, required this.subtotalCents,
    required this.discountCents, required this.amountDeltaCents});

  final int saleId;
  final String number;
  final List<SaleLine> lines;
  final List<SaleLineChange> changes;
  final int subtotalCents;
  final int discountCents;
  final int amountDeltaCents;
  int get payableCents => subtotalCents - discountCents;

  static SaleRevisionPreview calculate({required Sale original,
    required List<SaleLine> lines, required int discountCents}) {
    if (original.status != 'confirmed') throw StateError('只能修订已确认销售单');
    if (lines.isEmpty) throw ArgumentError('至少需要一条产品');
    final old = <int, SaleLine>{};
    for (final line in original.lines) {
      final id = line.id;
      if (id == null || id <= 0 || old.containsKey(id)) {
        throw StateError('原销售明细缺少唯一行标识，请重新读取单据');
      }
      old[id] = line;
    }
    final seen = <int>{};
    final changes = <SaleLineChange>[];
    var subtotal = BigInt.zero;
    final max = BigInt.from(9223372036854775807);
    for (final line in lines) {
      if (line.code.trim().isEmpty || line.lengthMilli <= 0 ||
          line.widthMilli <= 0 || line.unitPriceCents < 0) {
        throw ArgumentError('销售行型号、米数、门幅或单价无效');
      }
      final area = BigInt.from(line.lengthMilli) * BigInt.from(line.widthMilli);
      final numerator = area * BigInt.from(line.unitPriceCents);
      // Compute in BigInt before calling existing integer billing arithmetic.
      // Its rounding uses numerator*2; reject values that would overflow it.
      if (area > max || numerator * BigInt.two + BigInt.from(1000000) > max) {
        throw ArgumentError('销售行数值超过安全计算范围');
      }
      final id = line.id;
      if (id != null && (!old.containsKey(id) || !seen.add(id))) {
        throw ArgumentError('修改行不属于原单或行标识重复');
      }
      subtotal += BigInt.from(line.totalCents);
      if (subtotal > max) throw ArgumentError('产品合计超过可保存范围');
      changes.add(SaleLineChange(before: id == null ? null : old[id], after: line));
    }
    for (final entry in old.entries) {
      if (!seen.contains(entry.key)) {
        changes.add(SaleLineChange(before: entry.value, after: null));
      }
    }
    final payable = BillingMath.payable(subtotal.toInt(), discountCents);
    return SaleRevisionPreview._(saleId: original.id, number: original.number,
      lines: List.unmodifiable(lines), changes: List.unmodifiable(changes),
      subtotalCents: subtotal.toInt(), discountCents: discountCents,
      amountDeltaCents: payable - original.payableCents);
  }
}
