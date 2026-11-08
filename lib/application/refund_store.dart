import '../domain/sale_refund.dart';
import '../domain/sale_revision.dart';

abstract interface class RefundStore {
  Future<List<PendingSaleRefund>> pendingSaleRefunds(int saleId);
  Future<RefundRequest> prepareSaleRefund({
    required int saleId,
    required int expectedRevision,
    required int customerId,
    required int epoch,
    required int amountCents,
    required String method,
    required String requestKey,
    String note = '',
  });
  Future<RefundRequest> prepareRefundReversal({
    required int originalEventId,
    required String reason,
    required bool fundsRecoveredOrMistake,
    required String requestKey,
  });
  Future<int> postRefundRequest(String requestKey);
  Future<void> cancelRefundRequest(String requestKey);
  Future<RefundRequest?> refundRequest(String requestKey);
  Future<RefundRequest?> latestRefundRequest(int saleId);
  Future<List<SaleRefundEvent>> saleRefundEvents(int saleId);
}
