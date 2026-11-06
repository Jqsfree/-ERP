import '../domain/models.dart';

/// Application data port. UI knows only business operations and value types;
/// Android SQLite and widget-test fakes implement the same contract.
abstract interface class SalesStore {
  Future<List<Customer>> customers();
  Future<void> addCustomer(Customer customer);
  Future<List<Product>> products();
  Future<void> addProduct(Product product);
  Future<List<Sale>> sales();
  Future<Sale?> saleById(int id);
  Future<int> customerOutstanding(int customerId);
  Future<int> createSale({
    required Customer customer,
    required List<SaleLine> lines,
    required int discountCents,
    required int initialReceivedCents,
    String note,
  });
  Future<void> addPayment(Sale sale, int amountCents, {String method});
  Future<void> saveDraft(String jsonPayload);
  Future<String?> loadDraft();
  Future<void> deleteDraft();
}
