/// Separate physical inventory events from accounting. Sale return restores
/// usable stock to the original warehouse/batch; no refund or credit is posted.
class DispatchInputLine {
  const DispatchInputLine({
    required this.saleLineId,
    required this.warehouseId,
    required this.lengthMilli,
    this.batchCode = '',
  });
  final int saleLineId;
  final int warehouseId;
  final int lengthMilli;
  final String batchCode;
}

class DispatchLineProgress {
  const DispatchLineProgress({
    required this.lineId, required this.productId, required this.code,
    required this.orderedLengthMilli, required this.dispatchedLengthMilli,
    required this.widthMilli,
  });
  final int lineId;
  final int productId;
  final String code;
  final int orderedLengthMilli;
  final int dispatchedLengthMilli;
  final int widthMilli;
  int get remainingLengthMilli => orderedLengthMilli - dispatchedLengthMilli;
}

class DispatchRecord {
  const DispatchRecord({
    required this.id, required this.number, required this.saleId,
    required this.saleNumber, required this.createdAt, required this.note,
    required this.totalAreaMicro,
  });
  final int id;
  final String number;
  final int saleId;
  final String saleNumber;
  final String createdAt;
  final String note;
  final int totalAreaMicro;
}

class ReturnInputLine {
  const ReturnInputLine({required this.dispatchLineId, required this.lengthMilli});
  final int dispatchLineId;
  final int lengthMilli;
}

class ReturnLineProgress {
  const ReturnLineProgress({
    required this.lineId, required this.productId, required this.code,
    required this.warehouseId, required this.warehouseCode,
    required this.batchCode, required this.widthMilli,
    required this.dispatchedLengthMilli, required this.returnedLengthMilli,
  });
  final int lineId;
  final int productId;
  final String code;
  final int warehouseId;
  final String warehouseCode;
  final String batchCode;
  final int widthMilli;
  final int dispatchedLengthMilli;
  final int returnedLengthMilli;
  int get remainingLengthMilli => dispatchedLengthMilli - returnedLengthMilli;
}

class ReturnRecord {
  const ReturnRecord({
    required this.id, required this.number, required this.dispatchId,
    required this.dispatchNumber, required this.createdAt, required this.note,
    required this.totalAreaMicro,
  });
  final int id;
  final String number;
  final int dispatchId;
  final String dispatchNumber;
  final String createdAt;
  final String note;
  final int totalAreaMicro;
}
