import '../domain/models.dart';

/// Master data edits must not rewrite historical sales or inventory.
abstract interface class MasterDataStore {
  Future<void> updateCustomer(Customer customer);
  Future<void> updateProduct(Product product);
}
