/// Stock quantity is represented as micro-square-meters (mm * mm).
/// Do NOT use double, and do not treat purchasing a PO as a receipt.
class Warehouse {
  const Warehouse({required this.id, required this.code, required this.name, required this.active});
  final int id;
  final String code;
  final String name;
  final bool active;
}

class ReceiptInputLine {
  const ReceiptInputLine({
    required this.purchaseLineId,
    required this.warehouseId,
    required this.lengthMilli,
    this.batchCode = '',
  });
  final int purchaseLineId;
  final int warehouseId;
  final int lengthMilli;
  final String batchCode;
}

class ReceiptLineProgress {
  const ReceiptLineProgress({
    required this.lineId, required this.code,
    required this.orderedLengthMilli, required this.receivedLengthMilli,
    required this.widthMilli, required this.productId,
  });
  final int lineId;
  final String code;
  final int orderedLengthMilli;
  final int receivedLengthMilli;
  final int widthMilli;
  final int productId;
  int get remainingLengthMilli => orderedLengthMilli - receivedLengthMilli;
}

class PurchaseReceiptRecord {
  const PurchaseReceiptRecord({
    required this.id, required this.number, required this.purchaseOrderId,
    required this.orderNumber, required this.note, required this.createdAt,
    required this.totalAreaMicro,
  });
  final int id;
  final String number;
  final int purchaseOrderId;
  final String orderNumber;
  final String note;
  final String createdAt;
  final int totalAreaMicro;
}

class StockMovementRecord {
  const StockMovementRecord({
    required this.id, required this.receiptNumber, required this.productCode,
    required this.warehouseCode, required this.batchCode,
    required this.deltaAreaMicro, required this.createdAt,
    this.sourceType = 'purchase_receipt',
  });
  final int id;
  final String receiptNumber;
  final String productCode;
  final String warehouseCode;
  final String batchCode;
  final int deltaAreaMicro;
  final String createdAt;
  final String sourceType;
}

class StockBalance {
  const StockBalance({
    required this.productId, required this.productCode,
    required this.warehouseId, required this.warehouseCode,
    required this.batchCode, required this.areaMicro,
  });
  final int productId;
  final String productCode;
  final int warehouseId;
  final String warehouseCode;
  final String batchCode;
  final int areaMicro;
}
