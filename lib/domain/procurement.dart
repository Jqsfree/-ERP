import 'money.dart';

/// A supplier is a business partner, not a payable account.
class Supplier {
  final int? id;
  final String name;
  final String phone;
  final String address;
  final String note;
  final bool active;

  const Supplier({this.id, required this.name, this.phone = '',
    this.address = '', this.note = '', this.active = true});

  factory Supplier.fromMap(Map<String, Object?> row) => Supplier(
    id: row['id'] as int,
    name: row['name'] as String,
    phone: row['phone'] as String,
    address: row['address'] as String,
    note: row['note'] as String,
    active: row['active'] == 1,
  );
}

/// Purchase order line snapshots product and independently entered BUY cost;
/// changing the product's sales price cannot modify a confirmed PO.
class PurchaseLine {
  final int productId;
  final String code;
  final String specification;
  final int lengthMilli;
  final int widthMilli;
  final int unitCostCents;
  final String note;

  const PurchaseLine({
    required this.productId, required this.code,
    this.specification = '', required this.lengthMilli,
    required this.widthMilli, required this.unitCostCents, this.note = '',
  });

  int get areaMicro => BillingMath.areaMicro(lengthMilli, widthMilli);
  int get amountCents => BillingMath.lineCents(lengthMilli, widthMilli, unitCostCents);

  factory PurchaseLine.fromMap(Map<String, Object?> row) => PurchaseLine(
    productId: row['product_id'] as int,
    code: row['code_snapshot'] as String,
    specification: row['spec_snapshot'] as String,
    lengthMilli: row['length_milli'] as int,
    widthMilli: row['width_milli'] as int,
    unitCostCents: row['unit_cost_cents'] as int,
    note: row['note'] as String,
  );
}

/// Commitment to buy: no stock or accounts payable event is posted.
class PurchaseOrder {
  final int id;
  final String number;
  final String date;
  final int supplierId;
  final String supplierName;
  final String supplierPhone;
  final String supplierAddress;
  final String status;
  final String note;
  final int totalCents;
  final List<PurchaseLine> lines;

  const PurchaseOrder({
    required this.id, required this.number, required this.date,
    required this.supplierId, required this.supplierName,
    required this.supplierPhone, required this.supplierAddress,
    required this.status, required this.note, required this.totalCents,
    required this.lines,
  });

  bool get isActive => status == 'ordered';
}
