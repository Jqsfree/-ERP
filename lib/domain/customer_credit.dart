import 'models.dart';

class CustomerCreditEntry {
  const CustomerCreditEntry({required this.id, required this.saleId,
    required this.saleNumber, required this.deltaCents, required this.balanceAfterCents,
    required this.reason, required this.createdAt});
  final int id;
  final int saleId;
  final String saleNumber;
  final int deltaCents;
  final int balanceAfterCents;
  final String reason;
  final String createdAt;
}

/// The account and its running balances come from one consistent ledger read.
class CustomerCreditAccount {
  CustomerCreditAccount({required this.customer, required this.balanceCents,
    required List<CustomerCreditEntry> entries}) : entries = List.unmodifiable(entries);
  final Customer customer;
  final int balanceCents;
  final List<CustomerCreditEntry> entries;
}
