/// Separate capability: business screens depend on SalesStore, while backup
/// UI depends only on these explicit, audited data-movement operations.
abstract interface class BackupStore {
  /// Consistent logical copy of all P0 tables. Plaintext stays in memory;
  /// the UI MUST encrypt before saving or sharing.
  Future<String> exportSnapshotJson();

  /// Atomic restore into an *empty* database only; never overwrites data.
  /// Fails before any insert if an unsupported schema/invariant is found.
  Future<void> restoreSnapshotJson(String plaintextSnapshot);
}
