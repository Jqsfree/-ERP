/// Integer-fen allocation for a sale revision. This does not post money or stock.
class SaleSettlement {
  const SaleSettlement._({required this.creditAppliedCents,
    required this.creditReleasedCents, required this.creditConsumedCents,
    required this.pendingRefundCents, required this.dueCents,
    required this.previousCustomerRefundCents});

  final int creditAppliedCents;
  final int creditReleasedCents;
  final int creditConsumedCents;
  final int pendingRefundCents;
  final int dueCents;
  final int previousCustomerRefundCents;

  /// [netCashCents] excludes amounts already refunded or transferred to credit.
  /// Available credit excludes the allocation currently attached to this sale.
  static SaleSettlement calculate({required int payableCents,
    required int netCashCents, required int allocatedCreditCents,
    required int availableCreditCents, required bool customerChanged,
    bool useAvailableCredit = false}) {
    if ([payableCents, netCashCents, allocatedCreditCents,
        availableCreditCents].any((value) => value < 0)) {
      throw ArgumentError('结算金额不得为负数');
    }
    final cash = customerChanged ? 0 : netCashCents;
    final oldAllocation = customerChanged ? 0 : allocatedCreditCents;
    final capacity = payableCents > cash ? payableCents - cash : 0;
    // Confirmed revisions may retain/release old allocations. Only a new sale
    // explicitly opts into consuming available credit; customer changes never do.
    final pool = oldAllocation + (useAvailableCredit && !customerChanged ? availableCreditCents : 0);
    final applied = pool < capacity ? pool : capacity;
    final released = customerChanged ? allocatedCreditCents
        : (oldAllocation > applied ? oldAllocation - applied : 0);
    final consumed = applied > oldAllocation ? applied - oldAllocation : 0;
    return SaleSettlement._(
      creditAppliedCents: applied,
      creditReleasedCents: released,
      creditConsumedCents: consumed,
      pendingRefundCents: cash > payableCents ? cash - payableCents : 0,
      dueCents: capacity - applied,
      previousCustomerRefundCents: customerChanged ? netCashCents : 0,
    );
  }
}
