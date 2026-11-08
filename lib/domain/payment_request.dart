class PaymentRequest {
  const PaymentRequest({required this.key, required this.saleId, required this.revision,
    required this.amountCents, required this.method, required this.status, this.paymentId});
  final String key;
  final int saleId;
  final int revision;
  final int amountCents;
  final String method;
  final String status;
  final int? paymentId;
  factory PaymentRequest.fromMap(Map<String, Object?> row) => PaymentRequest(
    key: row['request_key'] as String, saleId: row['sale_id'] as int,
    revision: row['expected_revision'] as int, amountCents: row['amount_cents'] as int,
    method: row['method'] as String, status: row['status'] as String, paymentId: row['payment_id'] as int?);
}
