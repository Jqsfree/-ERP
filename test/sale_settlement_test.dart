import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/domain/sale_settlement.dart';

void main() {
  test('已确认规则：换客释放原抵扣、现金留待退款，不自动抵扣新客户余额', () {
    final result = SaleSettlement.calculate(payableCents: 10000,
      netCashCents: 6000, allocatedCreditCents: 2000,
      availableCreditCents: 3000, customerChanged: true);
    expect(result.previousCustomerRefundCents, 6000);
    expect(result.creditReleasedCents, 2000);
    expect(result.creditAppliedCents, 0);
    expect(result.creditConsumedCents, 0);
    expect(result.dueCents, 10000);
    expect(result.pendingRefundCents, 0);
  });
  test('减价先释放抵扣，超收现金仍需实际退款', () {
    final result = SaleSettlement.calculate(payableCents: 4000,
      netCashCents: 6000, allocatedCreditCents: 2000,
      availableCreditCents: 3000, customerChanged: false);
    expect(result.creditReleasedCents, 2000);
    expect(result.creditConsumedCents, 0);
    expect(result.creditAppliedCents, 0);
    expect(result.pendingRefundCents, 2000);
    expect(result.dueCents, 0);
  });
  test('新开单现金优先，抵扣不足保留欠款，抵扣充足不超用', () {
    for (final available in [3000, 12000]) {
      final result = SaleSettlement.calculate(payableCents: 10000,
        netCashCents: 1000, allocatedCreditCents: 2000,
        availableCreditCents: available, customerChanged: false, useAvailableCredit: true);
      expect(result.creditAppliedCents, available == 3000 ? 5000 : 9000);
      expect(result.dueCents, available == 3000 ? 4000 : 0);
      expect(result.creditReleasedCents, 0);
      expect(result.pendingRefundCents, 0);
    }
  });
  test('改单即使有可用余额也不追加扣减', () {
    final result = SaleSettlement.calculate(payableCents: 10000, netCashCents: 1000,
      allocatedCreditCents: 2000, availableCreditCents: 12000, customerChanged: false);
    expect(result.creditAppliedCents, 2000);
    expect(result.creditConsumedCents, 0);
    expect(result.dueCents, 7000);
  });
  test('负值被拒绝', () {
    expect(() => SaleSettlement.calculate(payableCents: -1,
      netCashCents: 0, allocatedCreditCents: 0,
      availableCreditCents: 0, customerChanged: false), throwsArgumentError);
  });
}
