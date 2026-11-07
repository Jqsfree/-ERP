import '../domain/finance.dart';
import '../domain/money.dart';

/// Spreadsheet-oriented read-only reconciliation export. Source cash movements
/// are never modified and internal monetary values remain integer cents.
class FinanceCsvExporter {
  FinanceCsvExporter._();
  static const version = 1;

  static String generate(DayStatement report, DayClose close) {
    if (report.day != close.day ||
        report.expectedNetByMethod.length != close.expectedNetByMethod.length ||
        report.expectedNetByMethod.keys.any(
          (k) => report.expectedNetByMethod[k] != close.expectedNetByMethod[k])) {
      throw StateError('关账日期或账面金额已变化，禁止导出失真的报告');
    }
    final buffer = StringBuffer('\uFEFF');
    buffer.write(_row(const [
      '业务日期','支付渠道','系统资金净变动(元)','外部核对净变动(元)',
      '外部减系统差异(元)','差异原因','销售客户收款合计(元)',
      '其他收入合计(元)','费用支出合计(元)','冲销净额合计(元)',
    ]));
    String money(int cents) => Fixed.format(cents, decimals: 2);
    var actualTotal = 0;
    for (final method in report.expectedNetByMethod.keys) {
      final expected = report.expectedNetByMethod[method]!;
      final actual = close.actualNetByMethod[method];
      if (actual == null) throw StateError('关账报告丢失支付渠道');
      actualTotal += actual;
      buffer.write(_row([
        report.day, _safe(method), money(expected), money(actual),
        money(actual - expected), '', '', '', '', '',
      ]));
    }
    buffer.write(_row([
      report.day, '合计',
      money(report.expectedNetCents), money(actualTotal),
      money(actualTotal - report.expectedNetCents),
      _safe(close.varianceReason),
      money(report.salesReceiptsCents),
      money(report.otherIncomeCents),
      money(report.otherExpenseCents),
      money(report.reversalNetCents),
    ]));
    return buffer.toString();
  }

  static String _safe(String input) {
    var value = input.replaceAll(RegExp(r'[\r\n\t]'), ' ');
    if (RegExp(r'^\s*[=+\-@＝＋－＠]').hasMatch(value)) {
      value = '\t$value';
    }
    return value;
  }

  static String _row(List<Object> values) =>
    '${values.map((v) => '"${v.toString().replaceAll('"', '""')}"').join(',')}\r\n';
}
