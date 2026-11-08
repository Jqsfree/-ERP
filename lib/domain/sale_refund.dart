class RefundRequest {
  const RefundRequest({
    required this.key,
    required this.saleId,
    required this.kind,
    required this.status,
    required this.payload,
    this.eventId,
  });
  final String key;
  final int saleId;
  final String kind;
  final String status;
  final Map<String, dynamic> payload;
  final int? eventId;
}

class SaleRefundEvent {
  const SaleRefundEvent({
    required this.id,
    required this.saleId,
    required this.customerId,
    required this.epoch,
    required this.version,
    required this.kind,
    required this.amountCents,
    required this.method,
    required this.reason,
    required this.createdAt,
    this.originalId,
    this.closed = false,
    this.customerName = '',
  });
  final int id, saleId, customerId, epoch, version, amountCents;
  final int? originalId;
  final bool closed;
  final String customerName;
  final String kind, method, reason, createdAt;
  bool get isReversal => kind == 'reversal';
  factory SaleRefundEvent.fromMap(Map<String, Object?> r) => SaleRefundEvent(
    id: r['id'] as int,
    saleId: r['sale_id'] as int,
    customerId: r['customer_id'] as int,
    epoch: r['customer_epoch'] as int,
    version: r['sale_version'] as int,
    kind: r['kind'] as String,
    amountCents: r['amount_cents'] as int,
    method: r['method'] as String,
    reason: r['reason'] as String,
    createdAt: r['created_at'] as String,
    originalId: r['original_event_id'] as int?,
    closed: r['closed'] == 1,
    customerName: r['customer_name'] as String? ?? '',
  );
}
