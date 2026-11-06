import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/services/sales_csv.dart';

void main() {
  test('导出拆分订单和明细；汇总金额不会因多行重复', () {
    final sale = Sale(
      id: 1, number: 'XS202611060001', date: '2026-11-06',
      customerId: 1, customerName: '客户,甲', customerPhone: '',
      customerAddress: '', subtotalCents: 20000, discountCents: 200,
      priorDueCents: 3000, receivedCents: 5000,
      status: 'confirmed', note: '报价"已核对"',
      lines: const [
        SaleLine(code: 'KB1', lengthMilli: 1000, widthMilli: 2000, unitPriceCents: 5000),
        SaleLine(code: 'KB2', lengthMilli: 1000, widthMilli: 2000, unitPriceCents: 5000),
      ],
    );
    final out = SalesCsvExporter.generate([sale]);
    expect(out.orders.startsWith('\uFEFF'), isTrue);
    expect(out.lines.startsWith('\uFEFF'), isTrue);
    expect(out.orders.split('\r\n').where((s) => s.isNotEmpty).length, 2);
    expect(out.lines.split('\r\n').where((s) => s.isNotEmpty).length, 3);
    expect(out.orders, contains('"198.00"'));
    expect(out.orders, contains('"148.00"'));
    expect(out.orders, contains('"客户,甲"'));
    expect(out.orders, contains('"报价""已核对"""'));
    expect(out.lines, isNot(contains('"198.00"')));
  });

  test('未受信任的客户和备注不会在 Excel 中执行公式', () {
    const sale = Sale(
      id: 1, number: 'XS1', date: '2026-11-06',
      customerId: 1, customerName: '=1+2', customerPhone: '@sum',
      customerAddress: '+foo', subtotalCents: 0, discountCents: 0,
      priorDueCents: 0, receivedCents: 0, status: 'confirmed',
      note: '-HYPERLINK', lines: [
        SaleLine(code: '＝1+2', lengthMilli: 1000, widthMilli: 1000,
          unitPriceCents: 0, note: ' =SUM(A1:A3)'),
      ],
    );
    final out = SalesCsvExporter.generate([sale]);
    expect(out.orders, contains('"\t=1+2"'));
    expect(out.orders, contains('"\t@sum"'));
    expect(out.orders, contains('"\t+foo"'));
    expect(out.orders, contains('"\t-HYPERLINK"'));
    expect(out.lines, contains('"\t＝1+2"'));
    expect(out.lines, contains('"\t =SUM(A1:A3)"'));
  });
}
