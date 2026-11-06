import 'dart:convert';

import '../domain/money.dart';

/// Logical SQLite snapshot contract. Its column allowlist intentionally fails
/// closed on future schema changes until backup migrations are implemented.
class BackupSnapshot {
  BackupSnapshot._(this.createdAt, this.rows);

  static const format = 'kaibao.sqlite.snapshot';
  static const version = 1;
  static const schemaVersion = 2;
  static const maxJsonLength = 32 * 1024 * 1024;
  static const maxRowsPerTable = 50000;

  static const columns = <String, List<String>>{
    'customers': ['id', 'name', 'phone', 'address', 'opening_balance_cents'],
    'products': ['id', 'code', 'specification', 'unit_price_cents'],
    'sales': [
      'id', 'number', 'date', 'customer_id', 'customer_name_snapshot',
      'customer_phone_snapshot', 'customer_address_snapshot', 'subtotal_cents',
      'discount_cents', 'prior_due_snapshot', 'status', 'note', 'created_at',
    ],
    'sale_lines': [
      'id', 'sale_id', 'product_id', 'code_snapshot', 'spec_snapshot',
      'length_milli', 'width_milli', 'unit_price_cents', 'amount_cents', 'note',
    ],
    'payments': ['id', 'sale_id', 'amount_cents', 'method', 'remark', 'created_at'],
    'sale_drafts': ['id', 'payload', 'updated_at'],
  };

  final String createdAt;
  final Map<String, List<Map<String, Object?>>> rows;

  Map<String, int> get counts => {
    for (final name in columns.keys) name: rows[name]!.length,
  };

  String encode() => jsonEncode({
    'format': format, 'version': version, 'schemaVersion': schemaVersion,
    'createdAt': createdAt, 'tables': rows,
  });

  factory BackupSnapshot.create(Map<String, List<Map<String, Object?>>> rows,
      DateTime createdAt) {
    return BackupSnapshot.parse(jsonEncode({
      'format': format, 'version': version, 'schemaVersion': schemaVersion,
      'createdAt': createdAt.toIso8601String(), 'tables': rows,
    }));
  }

  factory BackupSnapshot.parse(String input) {
    if (input.isEmpty || input.length > maxJsonLength) {
      throw const FormatException('备份内容大小超过限制');
    }
    final decoded = jsonDecode(input);
    if (decoded is! Map<String, dynamic> ||
        decoded['format'] != format || decoded['version'] != version ||
        decoded['schemaVersion'] != schemaVersion ||
        decoded['createdAt'] is! String) {
      throw const FormatException('备份格式或数据库版本不兼容');
    }
    final tables = decoded['tables'];
    if (tables is! Map<String, dynamic> ||
        tables.keys.toSet().difference(columns.keys.toSet()).isNotEmpty ||
        columns.keys.toSet().difference(tables.keys.toSet()).isNotEmpty) {
      throw const FormatException('备份数据库表结构不完整');
    }

    final rows = <String, List<Map<String, Object?>>>{};
    for (final entry in columns.entries) {
      final data = tables[entry.key];
      if (data is! List || data.length > maxRowsPerTable) {
        throw FormatException('${entry.key} 表记录数量非法');
      }
      final expected = entry.value.toSet();
      rows[entry.key] = data.map((raw) {
        if (raw is! Map<String, dynamic> || !raw.keys.toSet().containsAll(expected) ||
            raw.keys.toSet().difference(expected).isNotEmpty) {
          throw FormatException('${entry.key} 字段结构不匹配');
        }
        final row = Map<String, Object?>.from(raw);
        if (row['id'] is! int || (row['id'] as int) <= 0) {
          throw FormatException('${entry.key} 的记录 ID 无效');
        }
        return row;
      }).toList();
    }
    final snap = BackupSnapshot._(decoded['createdAt'] as String, rows);
    snap.validateAccounting();
    return snap;
  }

  void validateAccounting() {
    final customers = <int>{};
    final products = <int>{};
    final sales = <int, Map<String, Object?>>{};
    final amounts = <int, int>{};
    final linesCount = <int, int>{};
    final payments = <int, int>{};

    int positiveId(Object? value, String field) {
      if (value is! int || value <= 0) throw FormatException('$field 无效');
      return value;
    }
    int nonNegative(Object? value, String field) {
      if (value is! int || value < 0) throw FormatException('$field 无效');
      return value;
    }
    void requireText(Object? value, String field) {
      if (value is! String) throw FormatException('$field 应为文本');
    }

    for (final row in rows['customers']!) {
      final id = positiveId(row['id'], 'customers.id');
      if (!customers.add(id)) throw const FormatException('客户 ID 重复');
      requireText(row['name'], '客户名称');
      requireText(row['phone'], '客户电话');
      requireText(row['address'], '客户地址');
      if (row['opening_balance_cents'] is! int) throw const FormatException('期初余额无效');
    }
    for (final row in rows['products']!) {
      final id = positiveId(row['id'], 'products.id');
      if (!products.add(id)) throw const FormatException('产品 ID 重复');
      requireText(row['code'], '产品型号');
      requireText(row['specification'], '产品规格');
      nonNegative(row['unit_price_cents'], '产品单价');
    }
    for (final row in rows['sales']!) {
      final id = positiveId(row['id'], 'sales.id');
      if (sales.containsKey(id)) throw const FormatException('销售单 ID 重复');
      if (!customers.contains(positiveId(row['customer_id'], '客户 ID'))) {
        throw const FormatException('销售单引用了不存在的客户');
      }
      for (final key in ['number', 'date', 'customer_name_snapshot',
                         'customer_phone_snapshot', 'customer_address_snapshot',
                         'status', 'note', 'created_at']) {
        requireText(row[key], 'sales.$key');
      }
      if (row['status'] != 'confirmed') throw const FormatException('未知的销售状态');
      final sub = nonNegative(row['subtotal_cents'], '产品小计');
      if (nonNegative(row['discount_cents'], '优惠') > sub) {
        throw const FormatException('优惠超过小计');
      }
      if (row['prior_due_snapshot'] is! int) throw const FormatException('历史欠款无效');
      sales[id] = row;
    }
    for (final row in rows['sale_lines']!) {
      final saleId = positiveId(row['sale_id'], '明细的销售单 ID');
      if (!sales.containsKey(saleId)) throw const FormatException('明细引用不存在的销售单');
      final productId = row['product_id'];
      if (productId != null && !products.contains(positiveId(productId, '产品 ID'))) {
        throw const FormatException('明细引用不存在的产品');
      }
      requireText(row['code_snapshot'], '明细型号');
      requireText(row['spec_snapshot'], '明细规格');
      requireText(row['note'], '明细备注');
      final length = positiveId(row['length_milli'], '米数');
      final width = positiveId(row['width_milli'], '门幅');
      final price = nonNegative(row['unit_price_cents'], '明细单价');
      final amount = nonNegative(row['amount_cents'], '明细金额');
      if (amount != BillingMath.lineCents(length, width, price)) {
        throw const FormatException('明细金额与计价公式不一致');
      }
      amounts[saleId] = (amounts[saleId] ?? 0) + amount;
      linesCount[saleId] = (linesCount[saleId] ?? 0) + 1;
    }
    for (final sale in sales.entries) {
      if (linesCount[sale.key] == null ||
          amounts[sale.key] != sale.value['subtotal_cents']) {
        throw const FormatException('销售单明细小计不一致');
      }
    }
    for (final row in rows['payments']!) {
      final saleId = positiveId(row['sale_id'], '收款的销售单 ID');
      if (!sales.containsKey(saleId)) throw const FormatException('收款引用不存在的销售单');
      positiveId(row['amount_cents'], '收款金额');
      requireText(row['method'], '收款方式');
      requireText(row['remark'], '收款备注');
      requireText(row['created_at'], '收款日期');
      payments[saleId] = (payments[saleId] ?? 0) + (row['amount_cents'] as int);
    }
    for (final sale in sales.entries) {
      final sub = sale.value['subtotal_cents'] as int;
      final discount = sale.value['discount_cents'] as int;
      if ((payments[sale.key] ?? 0) > sub - discount) {
        throw const FormatException('销售单收款金额超过合同金额');
      }
    }
    if (rows['sale_drafts']!.length > 1) throw const FormatException('草稿数量无效');
    for (final draft in rows['sale_drafts']!) {
      if (draft['id'] != 1) throw const FormatException('草稿 ID 无效');
      requireText(draft['payload'], '草稿内容');
      requireText(draft['updated_at'], '草稿更新时间');
    }
  }
}
