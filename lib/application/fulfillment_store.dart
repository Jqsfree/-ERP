import '../domain/fulfillment.dart';

/// A sale is the commercial record, a dispatch is the physical stock decrement,
/// and a physical return is a stock increment. Neither changes customer dues.
abstract interface class FulfillmentStore {
  Future<List<DispatchLineProgress>> dispatchableLines(int saleId);
  Future<int> postSaleDispatch({
    required int saleId,
    required String requestKey,
    required List<DispatchInputLine> lines,
    String note = '',
  });
  Future<List<DispatchRecord>> saleDispatches({int? saleId});
  Future<List<ReturnLineProgress>> returnableLines(int dispatchId);
  Future<int> postSaleReturn({
    required int dispatchId,
    required String requestKey,
    required List<ReturnInputLine> lines,
    String note = '',
  });
  Future<List<ReturnRecord>> saleReturns({int? dispatchId});
}
