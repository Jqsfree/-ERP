import '../domain/procurement.dart';

/// Application port: purchase commitments and supplier master data.
///
/// Inventory receipt, supplier billing and cash disbursement MUST use separate
/// future use-cases. A purchase order is not an inventory movement.
abstract interface class ProcurementStore {
  Future<List<Supplier>> suppliers({bool includeInactive = true});
  Future<void> addSupplier(Supplier supplier);
  Future<void> updateSupplier(Supplier supplier);
  Future<int> createPurchaseOrder({
    required int supplierId,
    required List<PurchaseLine> lines,
    String note = '',
  });
  Future<List<PurchaseOrder>> purchaseOrders();
  Future<PurchaseOrder?> purchaseOrderById(int id);
  Future<void> cancelPurchaseOrder(int id);
}
