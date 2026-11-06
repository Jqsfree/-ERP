import 'money.dart';

class Customer {
  final int? id;
  final String name;
  final String phone;
  final String address;
  final int openingBalanceCents;

  const Customer({this.id, required this.name, this.phone = '', this.address = '', this.openingBalanceCents = 0});

  factory Customer.fromMap(Map<String, Object?> m) => Customer(
    id: m['id'] as int, name: m['name'] as String,
    phone: m['phone'] as String? ?? '', address: m['address'] as String? ?? '',
    openingBalanceCents: m['opening_balance_cents'] as int? ?? 0,
  );
}

class Product {
  final int? id;
  final String code;
  final String specification;
  final int unitPriceCents;

  const Product({this.id, required this.code, this.specification = '', required this.unitPriceCents});

  factory Product.fromMap(Map<String, Object?> m) => Product(
    id: m['id'] as int, code: m['code'] as String,
    specification: m['specification'] as String? ?? '',
    unitPriceCents: m['unit_price_cents'] as int,
  );
}

class SaleLine {
  final int? productId;
  final String code;
  final String specification;
  final int lengthMilli;
  final int widthMilli;
  final int unitPriceCents;
  final String note;

  const SaleLine({this.productId, required this.code, this.specification = '',
    required this.lengthMilli, required this.widthMilli, required this.unitPriceCents,
    this.note = ''});

  int get areaMicro => BillingMath.areaMicro(lengthMilli, widthMilli);
  int get totalCents => BillingMath.lineCents(lengthMilli, widthMilli, unitPriceCents);
  String get areaText => Fixed.format(areaMicro, decimals: 6, trim: true);

  factory SaleLine.fromMap(Map<String, Object?> m) => SaleLine(
    productId: m['product_id'] as int?, code: m['code_snapshot'] as String,
    specification: m['spec_snapshot'] as String? ?? '',
    lengthMilli: m['length_milli'] as int,
    widthMilli: m['width_milli'] as int,
    unitPriceCents: m['unit_price_cents'] as int,
    note: m['note'] as String? ?? '',
  );
}

class Sale {
  final int id;
  final String number;
  final String date;
  final int customerId;
  final String customerName;
  final String customerPhone;
  final String customerAddress;
  final int subtotalCents;
  final int discountCents;
  final int priorDueCents;
  final int receivedCents;
  final String status;
  final String note;
  final List<SaleLine> lines;

  const Sale({required this.id, required this.number, required this.date,
    required this.customerId, required this.customerName, required this.customerPhone,
    required this.customerAddress, required this.subtotalCents, required this.discountCents,
    required this.priorDueCents, required this.receivedCents,
    required this.status, required this.note, required this.lines});

  int get payableCents => subtotalCents - discountCents;
  int get currentDueCents => payableCents - receivedCents;
  int get cumulativeDueCents => priorDueCents + currentDueCents;
}
