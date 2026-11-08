import '../domain/models.dart';
import '../domain/payment_request.dart';

abstract interface class PaymentRequestStore {
  Future<PaymentRequest?> latestPaymentRequest(int saleId);
  Future<PaymentRequest> preparePayment(Sale sale, int amountCents, {required String requestKey, required String method});
  Future<void> cancelPaymentRequest(String requestKey);
}
