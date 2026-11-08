abstract interface class DataIntegrityStore {
  /// Read-only diagnostics. Never repairs or deletes historical transactions.
  Future<List<String>> checkDataIntegrity();
}
