import '../domain/models.dart';
import '../domain/money.dart';

/// Versioned, pure output adapter. Aggregate order values occur exactly once
/// in the order file; line-level amounts occur only in the detail file.
class SalesCsvBundle {
  final String orders;
  final String lines;
  const SalesCsvBundle({required this.orders, required this.lines});
}

class SalesCsvExporter {
  static const version = 1;

  static SalesCsvBundle generate(List<Sale> sales) {
    final orders = StringBuffer('\uFEFF');
    final lines = StringBuffer('\uFEFF');
    orders.write(_row(const [
      '单号','销售日期','客户','电话','收货地址','产品小计(元)',
      '优惠(元)','合同金额(元)','已收(元)','未收(元)','上期欠款快照(元)','状态','备注',
    ]));
    lines.write(_row(const [
      '单号','行序号','产品型号','规格','米数','门幅','面积(㎡)',
      '单价(元/㎡)','行金额(元)','行备注',
    ]));
    for (final sale in sales) {
      String money(int cents) => Fixed.format(cents, decimals: 2);
      orders.write(_row([
        sale.number, sale.date, _text(sale.customerName), _text(sale.customerPhone),
        _text(sale.customerAddress), money(sale.subtotalCents),
        money(sale.discountCents), money(sale.payableCents),
        money(sale.receivedCents), money(sale.currentDueCents),
        money(sale.priorDueCents), sale.status, _text(sale.note),
      ]));
      for (var i = 0; i < sale.lines.length; i++) {
        final line = sale.lines[i];
        lines.write(_row([
          sale.number, i + 1, _text(line.code), _text(line.specification),
          Fixed.format(line.lengthMilli, decimals: 3, trim: true),
          Fixed.format(line.widthMilli, decimals: 3, trim: true),
          line.areaText, money(line.unitPriceCents), money(line.totalCents),
          _text(line.note),
        ]));
      }
    }
    return SalesCsvBundle(orders: orders.toString(), lines: lines.toString());
  }

  /// Spreadsheet-focused export. Formula-like user data is prefixed with a tab
  /// inside the quoted field to prevent formula evaluation in Excel.
  /// The tab changes text for machine re-import; this is NOT an import format.
  static String _text(String input) {
    var text = input.replaceAll(RegExp(r'[\r\n\t]'), ' ');
    if (RegExp(r'^\s*[=+\-@＝＋－＠]').hasMatch(text)) {
      text = '\t$text';
    }
    return text;
  }

  static String _row(List<Object> cells) =>
      '${cells.map((c) => '"${c.toString().replaceAll('"', '""')}"').join(',')}\r\n';
}
