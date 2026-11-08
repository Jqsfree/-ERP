import '../domain/models.dart';
import '../domain/sale_revision.dart';

abstract interface class SaleRevisionStore {
  Future<int> reviseSale({required int saleId, required int expectedRevision,
    required String requestKey, required int customerId, required String date,
    required List<SaleLine> lines, required int discountCents, required String note});
  Future<List<SaleRevisionRecord>> saleRevisions(int saleId);
  Future<List<PendingSaleRefund>> pendingSaleRefunds(int saleId);
  Future<List<PendingSaleReturn>> pendingSaleReturns(int saleId);
}
