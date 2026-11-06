import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/domain/money.dart';
import 'package:kaibao_sales/domain/models.dart';

void main() {
  test('图片示例：37 × 2.8 × 13.99, 优惠 0.36', () {
    final item = SaleLine(code: 'KB56-34', lengthMilli: Fixed.parse('37', decimals: 3),
      widthMilli: Fixed.parse('2.8', decimals: 3), unitPriceCents: Fixed.parse('13.99', decimals: 2));
    expect(item.areaText, '103.6');
    expect(item.totalCents, 144936);
    expect(BillingMath.payable(item.totalCents, 36), 144900);
  });
  test('Sheet2 示例：小计 2192.40 元', () {
    final entries = [(11, 2580), (12, 1280), (27, 1280)];
    final total = entries.fold<int>(0, (sum, e) => sum + BillingMath.lineCents(e.$1 * 1000, 2800, e.$2));
    expect(total, 219240);
  });
  test('Sheet1 示例：小计按每行四舍五入为 1334.26', () {
    final total = BillingMath.lineCents(7000, 2800, 2090) +
      BillingMath.lineCents(15800, 2800, 2090);
    expect(total, 133426);
  });
  test('金额和非负输入精度校验', () {
    expect(Fixed.parse('001.20', decimals: 2), 120);
    expect(Fixed.format(144900, decimals: 2), '1449.00');
    expect(() => Fixed.parse('13.999', decimals: 2), throwsFormatException);
    expect(() => Fixed.parse('-1', decimals: 2), throwsFormatException);
    expect(() => BillingMath.payable(100, 101), throwsArgumentError);
  });
  test('0.005 元按四舍五入到 0.01 元', () {
    expect(Fixed.roundDiv(5, 10), 1);
  });
}
