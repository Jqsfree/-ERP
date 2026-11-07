import '../domain/inventory.dart';

/// Application contract: PO receiving posts physical stock, never supplier payable.
abstract interface class InventoryStore {
  Future<List<Warehouse>> warehouses();
  Future<int> addWarehouse({required String code, required String name});
  Future<List<ReceiptLineProgress>> receivableLines(int purchaseOrderId);
  Future<int> postPurchaseReceipt({
    required int purchaseOrderId,
    required String requestKey,
    required List<ReceiptInputLine> lines,
    String note = '',
  });
  Future<List<PurchaseReceiptRecord>> purchaseReceipts({int? purchaseOrderId});
  Future<List<StockMovementRecord>> stockMovements();
  Future<List<StockBalance>> stockBalances();
}
