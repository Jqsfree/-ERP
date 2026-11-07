import 'dart:convert';

import '../domain/finance.dart';

/// Reject cashbook and close contradictions before importing any records.
/// All source rows and signed amounts are replayed; close totals are not trusted.
class FinanceSnapshotValidator {
  FinanceSnapshotValidator._();

  static void validate(Map<String, List<Map<String, Object?>>> rows) {
    final events = <int, Map<String, Object?>>{};
    final numbers = <String>{};
    final keys = <String>{};
    final reversed = <int>{};
    String text(Object? value, String label) {
      if (value is! String) throw FormatException('$label 必须为字符串');
      return value;
    }
    int positive(Object? value, String label) {
      if (value is! int || value <= 0) throw FormatException('$label 必须为正整数');
      return value;
    }

    for (final row in rows['cash_entries']!) {
      final id = positive(row['id'], '其他收支 ID');
      final number = text(row['number'], '其他收支凭证编号');
      final key = text(row['request_key'], '其他收支请求键');
      final category = text(row['category'], '其他收支分类');
      final method = text(row['method'], '其他收支方式');
      final date = text(row['business_date'], '业务日期');
      final created = text(row['created_at'], '创建时间');
      final note = text(row['note'], '收支备注');
      text(row['payload'], '原始操作内容');
      FinanceMath.validDay(date);
      if (!created.startsWith(date) || method.isEmpty ||
          !FinanceMath.methods.contains(method) || category.trim().isEmpty ||
          FinanceMath.reservedCategories.contains(category) ||
          category.length > 80 || note.length > 500 ||
          !numbers.add(number) || !keys.add(key) || events.containsKey(id) ||
          key.length < 12 || key.length > 128) {
        throw const FormatException('其他收支凭证标识、类型或日期不合法');
      }
      final amount = positive(row['amount_cents'], '其他收支金额');
      final direction = row['direction'];
      if (direction != 1 && direction != -1) {
        throw const FormatException('现金流方向不合法');
      }
      final kind = row['kind'];
      final related = row['original_entry_id'];
      if (kind == 'income' || kind == 'expense') {
        if (related != null || direction != (kind == 'income' ? 1 : -1)) {
          throw const FormatException('原始收支的金额方向或冲销引用不合法');
        }
        final payload = jsonEncode({
          'kind': kind, 'method': method, 'category': category,
          'amountCents': amount, 'note': note,
        });
        if (row['payload'] != payload) {
          throw const FormatException('收支明细与幂等请求内容不一致');
        }
      } else if (kind == 'reversal') {
        if (related is! int || related <= 0 || !reversed.add(related) ||
            note.trim().isEmpty) {
          throw const FormatException('冲销凭证原始引用无效或重复冲销');
        }
        if (row['payload'] != jsonEncode({'reverseOf': related, 'reason': note})) {
          throw const FormatException('冲销原因与原始操作请求不一致');
        }
      } else {
        throw const FormatException('未知现金流类型');
      }
      events[id] = row;
    }

    for (final row in events.values) {
      if (row['kind'] != 'reversal') continue;
      final original = events[row['original_entry_id']];
      if (original == null || original['kind'] == 'reversal' ||
          original['method'] != row['method'] ||
          original['category'] != row['category'] ||
          original['amount_cents'] != row['amount_cents'] ||
          (original['direction'] as int) != -(row['direction'] as int) ||
          (original['business_date'] as String).compareTo(
            row['business_date'] as String) > 0) {
        throw const FormatException('冲销金额、时间、方式必须与原业务相反');
      }
    }

    final closureDates = <String>{};
    final closureKeys = <String>{};
    final closureIds = <int>{};
    final payments = rows['payments']!;
    final cash = rows['cash_entries']!;
    for (final row in rows['day_closures']!) {
      final id = positive(row['id'], '日结 ID');
      final day = text(row['business_date'], '日结日期');
      FinanceMath.validDay(day);
      final key = text(row['request_key'], '日结请求键');
      final created = text(row['created_at'], '日结时间');
      final reason = text(row['variance_reason'], '差异原因');
      if (!closureDates.add(day) || !closureKeys.add(key) ||
          !closureIds.add(id) || key.length < 12 || key.length > 128 ||
          created.compareTo(day) < 0 || reason.length > 500) {
        throw const FormatException('日结日期、请求键或差异原因不合法');
      }
      Map<String, int> decodeAmounts(String field) {
        final raw = jsonDecode(text(row[field], field));
        if (raw is! Map<String, dynamic>) {
          throw FormatException('$field 格式不合法');
        }
        final obj = <String, int>{};
        for (final item in raw.entries) {
          if (item.value is! int) throw FormatException('$field 存在非整数金额');
          obj[item.key] = item.value as int;
        }
        if (jsonEncode(FinanceMath.normalized(obj)) != row[field]) {
          throw FormatException('$field 渠道顺序或内容不规范');
        }
        return obj;
      }
      final expected = decodeAmounts('expected_json');
      final actual = decodeAmounts('actual_json');
      final recomputed = FinanceMath.statement(day, payments, cash).expectedNetByMethod;
      if (jsonEncode(recomputed) != row['expected_json'] ||
          actual.keys.toSet().difference(recomputed.keys.toSet()).isNotEmpty ||
          recomputed.keys.toSet().difference(actual.keys.toSet()).isNotEmpty) {
        throw const FormatException('日结快照不等于真实销售收款与其他收支的净额');
      }
      if (expected.keys.any((method) => expected[method] != actual[method]) &&
          reason.trim().isEmpty) {
        throw const FormatException('有日结差异却没有原因说明');
      }
    }
  }
}
