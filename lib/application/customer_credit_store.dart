import '../domain/customer_credit.dart';
import '../domain/models.dart';

abstract interface class CustomerCreditStore {
  Future<CustomerCreditAccount> customerCreditAccount(int customerId);
  Future<int> transferSaleRefundToCredit({required int saleId, required int expectedRevision,
    required int customerId, required int epoch, required int amountCents, required String requestKey});
  Future<int> createSaleWithCredit({required Customer customer, required List<SaleLine> lines,
    required int discountCents, required int initialReceivedCents, required String requestKey, String note = ''});
}
