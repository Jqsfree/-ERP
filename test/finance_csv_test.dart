import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/domain/finance.dart';
import 'package:kaibao_sales/services/finance_csv.dart';

void main() {
  test('日报导出逐渠道保留净额，仅合计行展示资金来源汇总', () {
    final report = FinanceMath.statement('2026-11-07', [
      {'method': '微信', 'amount_cents': 5000,
        'created_at': '2026-11-07T10:00:00'},
    ], [
      {'method': '现金', 'business_date': '2026-11-07',
        'kind': 'income', 'direction': 1, 'amount_cents': 200},
      {'method': '现金', 'business_date': '2026-11-07',
        'kind': 'expense', 'direction': -1, 'amount_cents': 50},
    ]);
    final close = DayClose(id: 1, day: '2026-11-07',
      expectedNetByMethod: report.expectedNetByMethod,
      actualNetByMethod: {...report.expectedNetByMethod},
      varianceReason: '', createdAt: '2026-11-07T20:00:00');
    final csv = FinanceCsvExporter.generate(report, close);
    expect(csv.startsWith('\uFEFF'), isTrue);
    expect(csv.endsWith('\r\n'), isTrue);
    final rows = csv.substring(1).trimRight().split('\r\n');
    expect(rows, hasLength(FinanceMath.methods.length + 2));
    expect(rows.where((s) => s.contains('"合计"')), hasLength(1));
    expect(rows.where((s) => s.contains('"50.00"')), hasLength(2)); // channel + total
    expect(rows.last, contains('"2.00"'));
    expect(rows.last, contains('"0.50"'));
    expect(rows.last, contains('"51.50"'));
  });

  test('渠道和差异原因的 CSV 公式注入被中和，旧版自定义渠道仍保留', () {
    final report = FinanceMath.statement('2026-11-07', [
      {'method': '=SUM(1,1)', 'amount_cents': 100,
        'created_at': '2026-11-07T09:00:00'},
    ], []);
    final close = DayClose(id: 1, day: '2026-11-07',
      expectedNetByMethod: report.expectedNetByMethod,
      actualNetByMethod: {...report.expectedNetByMethod,
        '=SUM(1,1)': 90},
      varianceReason: '=危险\n"文本"',
      createdAt: '2026-11-07T20:00:00');
    final csv = FinanceCsvExporter.generate(report, close);
    expect(csv, contains('"\t=SUM(1,1)"'));
    expect(csv, contains('"\t=危险 ""文本"""'));
    expect(csv, contains('"-0.10"'));
    final bad = DayStatement(day: '2026-11-07',
      salesReceiptsCents: 101, otherIncomeCents: 0,
      otherExpenseCents: 0, reversalNetCents: 0,
      expectedNetByMethod: {...report.expectedNetByMethod,
        '=SUM(1,1)': 101});
    expect(() => FinanceCsvExporter.generate(bad, close), throwsStateError);
  });
}
