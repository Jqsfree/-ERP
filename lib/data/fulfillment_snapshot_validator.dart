import 'dart:convert';

/// Pre-restore integrity checks for the additive v5 physical stock ledger.
/// Reject accounting/stock contradictions before opening a SQLite write txn.
class FulfillmentSnapshotValidator {
  FulfillmentSnapshotValidator._();

  static int id(Object? value, String label) {
    if (value is! int || value <= 0) throw FormatException('$label 必须为正整数');
    return value;
  }

  static String text(Object? value, String label) {
    if (value is! String) throw FormatException('$label 应为文本');
    return value;
  }

  static Map<int, Map<String, Object?>> byId(
    List<Map<String, Object?>> data, String label,
  ) {
    final result = <int, Map<String, Object?>>{};
    for (final row in data) {
      final key = id(row['id'], '$label.id');
      if (result.containsKey(key)) throw FormatException('$label ID 重复');
      result[key] = row;
    }
    return result;
  }

  static void validate(Map<String, List<Map<String, Object?>>> rows) {
    final sales = byId(rows['sales']!, '销售');
    final saleLines = byId(rows['sale_lines']!, '销售明细');
    final warehouses = byId(rows['warehouses']!, '仓库');
    final productIds = byId(rows['products']!, '产品').keys.toSet();
    final dispatches = byId(rows['sale_dispatches']!, '出库单');
    final dispatchLines = byId(rows['sale_dispatch_lines']!, '出库明细');
    final returns = byId(rows['sale_returns']!, '退货单');
    final returnLines = byId(rows['sale_return_lines']!, '退货明细');
    final dispatchNumbers = <String>{};
    final dispatchKeys = <String>{};
    final returnNumbers = <String>{};
    final returnKeys = <String>{};
    final dispatchGroups = <int, List<Map<String, Object?>>>{};
    final returnGroups = <int, List<Map<String, Object?>>>{};
    final shipped = <int, int>{};
    final returned = <int, int>{};
    final stock = <String, int>{};

    String group(int product, int warehouse, String batch) =>
      '$product:$warehouse:$batch';
    void move(int product, int warehouse, String batch, int delta) {
      final key = group(product, warehouse, batch);
      stock[key] = (stock[key] ?? 0) + delta;
    }

    for (final moveRow in rows['stock_movements']!) {
      move(id(moveRow['product_id'], '入库产品'),
        id(moveRow['warehouse_id'], '入库仓库'),
        text(moveRow['batch_code'], '批次'),
        id(moveRow['delta_area_micro'], '入库数量'));
    }
    for (final row in dispatches.values) {
      final saleId = id(row['sale_id'], '出库销售单');
      if (!sales.containsKey(saleId) || sales[saleId]!['status'] != 'confirmed') {
        throw const FormatException('出库单必须关联有效销售单');
      }
      if (!dispatchNumbers.add(text(row['number'], '出库编号')) ||
          !dispatchKeys.add(text(row['request_key'], '出库请求标识'))) {
        throw const FormatException('出库编号或请求标识重复');
      }
      text(row['payload'], '出库操作内容');
      text(row['created_at'], '出库时间');
      text(row['note'], '出库备注');
    }

    final dispatchPair = <String>{};
    for (final row in dispatchLines.values) {
      final dispatchId = id(row['dispatch_id'], '出库单');
      final saleLineId = id(row['sale_line_id'], '原销售明细');
      final source = saleLines[saleLineId];
      final dispatch = dispatches[dispatchId];
      if (source == null || dispatch == null ||
          source['sale_id'] != dispatch['sale_id'] ||
          !dispatchPair.add('$dispatchId:$saleLineId')) {
        throw const FormatException('出库行不存在、跨销售单或重复');
      }
      final product = id(row['product_id'], '出库产品');
      final warehouse = id(row['warehouse_id'], '出库仓库');
      final length = id(row['length_milli'], '出库米数');
      final width = id(row['width_milli'], '出库门幅');
      final area = id(row['area_micro'], '出库面积');
      final batch = text(row['batch_code'], '出库批次');
      if (!productIds.contains(product) || !warehouses.containsKey(warehouse) ||
          source['product_id'] != product || source['width_milli'] != width ||
          BigInt.from(length) * BigInt.from(width) != BigInt.from(area)) {
        throw const FormatException('出库行产品、仓库、门幅或数量不一致');
      }
      shipped[saleLineId] = (shipped[saleLineId] ?? 0) + length;
      (dispatchGroups[dispatchId] ??= []).add(row);
      move(product, warehouse, batch, -area);
    }
    for (final line in saleLines.values) {
      if ((shipped[line['id']] ?? 0) > (line['length_milli'] as int)) {
        throw const FormatException('出库超过原销售行订购米数');
      }
    }
    for (final dispatch in dispatches.values) {
      final did = dispatch['id'] as int;
      final groupRows = dispatchGroups[did] ?? [];
      if (groupRows.isEmpty) throw const FormatException('出库单没有明细');
      groupRows.sort((a,b) => (a['sale_line_id'] as int).compareTo(b['sale_line_id'] as int));
      final canonical = jsonEncode({
        'saleId': dispatch['sale_id'], 'note': dispatch['note'],
        'lines': groupRows.map((line) => {
          'line': line['sale_line_id'], 'warehouse': line['warehouse_id'],
          'lengthMilli': line['length_milli'], 'batch': line['batch_code'],
        }).toList(),
      });
      if (canonical != dispatch['payload']) {
        throw const FormatException('出库幂等内容与实际明细不符');
      }
    }

    for (final row in returns.values) {
      final dispatchId = id(row['dispatch_id'], '退货原出库单');
      if (!dispatches.containsKey(dispatchId)) {
        throw const FormatException('退货单缺少原出库单');
      }
      if (!returnNumbers.add(text(row['number'], '退货编号')) ||
          !returnKeys.add(text(row['request_key'], '退货请求标识'))) {
        throw const FormatException('退货编号或请求标识重复');
      }
      text(row['payload'], '退货操作内容');
      text(row['created_at'], '退货时间');
      text(row['note'], '退货备注');
    }
    final returnPair = <String>{};
    for (final row in returnLines.values) {
      final returnId = id(row['return_id'], '退货单');
      final dispatchLineId = id(row['dispatch_line_id'], '原出库明细');
      final source = dispatchLines[dispatchLineId];
      final returnDoc = returns[returnId];
      if (source == null || returnDoc == null ||
          source['dispatch_id'] != returnDoc['dispatch_id'] ||
          !returnPair.add('$returnId:$dispatchLineId')) {
        throw const FormatException('退货行不存在、跨出库单或重复');
      }
      final product = id(row['product_id'], '退货产品');
      final warehouse = id(row['warehouse_id'], '退货仓库');
      final length = id(row['length_milli'], '退货米数');
      final width = id(row['width_milli'], '退货门幅');
      final area = id(row['area_micro'], '退货面积');
      final batch = text(row['batch_code'], '退货批次');
      if (source['product_id'] != product || source['warehouse_id'] != warehouse ||
          source['batch_code'] != batch || source['width_milli'] != width ||
          BigInt.from(length) * BigInt.from(width) != BigInt.from(area)) {
        throw const FormatException('实物退货必须关联原出库产品/仓库/批次');
      }
      returned[dispatchLineId] = (returned[dispatchLineId] ?? 0) + length;
      (returnGroups[returnId] ??= []).add(row);
      move(product, warehouse, batch, area);
    }
    for (final line in dispatchLines.values) {
      if ((returned[line['id']] ?? 0) > (line['length_milli'] as int)) {
        throw const FormatException('退货累计米数超过原出库');
      }
    }
    for (final doc in returns.values) {
      final returnId = doc['id'] as int;
      final groupRows = returnGroups[returnId] ?? [];
      if (groupRows.isEmpty) throw const FormatException('退货单没有明细');
      groupRows.sort((a,b) => (a['dispatch_line_id'] as int).compareTo(b['dispatch_line_id'] as int));
      final canonical = jsonEncode({
        'dispatchId': doc['dispatch_id'], 'note': doc['note'],
        'lines': groupRows.map((line) => {
          'line': line['dispatch_line_id'], 'lengthMilli': line['length_milli'],
        }).toList(),
      });
      if (canonical != doc['payload']) {
        throw const FormatException('退货幂等内容与实际明细不符');
      }
    }
    if (stock.values.any((amount) => amount < 0)) {
      throw const FormatException('备份中的出入库造成负库存');
    }
  }
}
