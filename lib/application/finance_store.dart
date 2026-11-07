import '../domain/finance.dart';

/// Distinct from SalesStore payments: only OTHER money movements are entered
/// here. Daily close freezes one business day's cash movement sources.
abstract interface class FinanceStore {
  Future<int> recordCashEntry({
    required String kind, required String method, required String category,
    required int amountCents, required String requestKey, String note = '',
  });
  Future<int> reverseCashEntry({
    required int originalEntryId, required String requestKey, required String reason,
  });
  Future<List<CashEntry>> cashEntries({String? day});
  Future<DayStatement> dayStatement(String day);
  Future<int> closeDay({
    required String day, required String requestKey,
    required Map<String, int> actualNetByMethod,
    String varianceReason = '',
  });
  Future<DayClose?> dayClose(String day);
  Future<List<DayClose>> closedDays();
}
