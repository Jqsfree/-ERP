/// Financial operations in this version track *cash movements*, not P&L.
/// Customer receipts already exist in payments and MUST NOT be reentered.
class CashEntry {
  const CashEntry({
    required this.id, required this.number, required this.businessDate,
    required this.kind, required this.method, required this.category,
    required this.amountCents, required this.direction,
    required this.note, required this.createdAt, this.originalEntryId,
  });
  final int id;
  final String number;
  final String businessDate;
  final String kind;
  final String method;
  final String category;
  final int amountCents;
  final int direction;
  final int? originalEntryId;
  final String note;
  final String createdAt;
  int get signedCents => direction * amountCents;
}

class DayStatement {
  const DayStatement({
    required this.day, required this.salesReceiptsCents,
    required this.otherIncomeCents, required this.otherExpenseCents,
    required this.reversalNetCents, required this.expectedNetByMethod,
  });
  final String day;
  final int salesReceiptsCents;
  final int otherIncomeCents;
  final int otherExpenseCents;
  final int reversalNetCents;
  final Map<String, int> expectedNetByMethod;
  int get expectedNetCents =>
    salesReceiptsCents + otherIncomeCents - otherExpenseCents + reversalNetCents;
}

class DayClose {
  const DayClose({
    required this.id, required this.day, required this.expectedNetByMethod,
    required this.actualNetByMethod, required this.varianceReason,
    required this.createdAt,
  });
  final int id;
  final String day;
  final Map<String, int> expectedNetByMethod;
  final Map<String, int> actualNetByMethod;
  final String varianceReason;
  final String createdAt;
  Map<String, int> get differenceByMethod => {
    for (final name in expectedNetByMethod.keys)
      name: actualNetByMethod[name]! - expectedNetByMethod[name]!,
  };
  int get totalDifferenceCents => differenceByMethod.values.fold<int>(0, (a, b) => a + b);
  bool get hasDifference => differenceByMethod.values.any((v) => v != 0);
}

/// One shared calculation for the SQLite runtime and backup auditing.
/// "Actual" means external statement's *daily net change*, not account balance.
class FinanceMath {
  FinanceMath._();

  static const methods = ['微信', '支付宝', '现金', '银行转账', '其他'];
  static const reservedCategories = {
    '销售收款', '销售回款', '客户收款', '销售收入', '回款',
    '供应商付款', '供应商货款', '采购付款',
  };

  static String day(DateTime now) =>
    '${now.year.toString().padLeft(4, '0')}-'
    '${now.month.toString().padLeft(2, '0')}-'
    '${now.day.toString().padLeft(2, '0')}';

  static void validDay(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw FormatException('日期应为 YYYY-MM-DD');
    }
    final pieces = value.split('-').map(int.parse).toList();
    final d = DateTime(pieces[0], pieces[1], pieces[2]);
    if (day(d) != value) throw FormatException('日期不是有效公历日期');
  }

  static String key(String value) {
    final v = value.trim();
    if (v.length < 12 || v.length > 128) {
      throw ArgumentError('请求标识长度必须为 12–128');
    }
    return v;
  }

  static Map<String, int> normalized(Map<String, int> source) => {
    for (final name in source.keys.toList()..sort()) name: source[name]!,
  };

  static DayStatement statement(
    String day, List<Map<String, Object?>> salePayments,
    List<Map<String, Object?>> cashEntries,
  ) {
    validDay(day);
    final totals = <String, int>{for (final method in methods) method: 0};
    var saleCents = 0;
    var income = 0;
    var expense = 0;
    var reversals = 0;
    for (final row in salePayments) {
      final when = row['created_at'] as String;
      if (!when.startsWith(day)) continue;
      final method = row['method'] as String;
      if (method.trim().isEmpty) throw const FormatException('收款方式缺失');
      final amount = row['amount_cents'] as int;
      if (amount <= 0) throw const FormatException('收款金额无效');
      saleCents += amount;
      totals[method] = (totals[method] ?? 0) + amount;
    }
    for (final row in cashEntries) {
      if (row['business_date'] != day) continue;
      final method = row['method'] as String;
      if (method.trim().isEmpty) throw const FormatException('其他收支方式缺失');
      final amount = row['amount_cents'] as int;
      final direction = row['direction'] as int;
      final kind = row['kind'] as String;
      if (amount <= 0 || (direction != 1 && direction != -1)) {
        throw const FormatException('收支方向或金额无效');
      }
      final signed = amount * direction;
      totals[method] = (totals[method] ?? 0) + signed;
      switch (kind) {
        case 'income':
          if (direction != 1) throw const FormatException('其他收入方向不合法');
          income += amount;
          break;
        case 'expense':
          if (direction != -1) throw const FormatException('费用支出方向不合法');
          expense += amount;
          break;
        case 'reversal':
          reversals += signed;
          break;
        default:
          throw const FormatException('未知收支类型');
      }
    }
    return DayStatement(day: day,
      salesReceiptsCents: saleCents, otherIncomeCents: income,
      otherExpenseCents: expense, reversalNetCents: reversals,
      expectedNetByMethod: normalized(totals));
  }
}
