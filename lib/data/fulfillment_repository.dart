import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../application/fulfillment_store.dart';
import '../domain/fulfillment.dart';

/// All stock-affecting writes use a single SQLite transaction and a shared
/// ledger view. Repositories never directly update a mutable balance cache.
class FulfillmentRepository implements FulfillmentStore {
  FulfillmentRepository(this.db, this.clock);
  final Database db;
  final DateTime Function() clock;

  static int checkedArea(int lengthMilli, int widthMilli) {
    if (lengthMilli <= 0 || widthMilli <= 0) {
      throw ArgumentError('出入库米数与门幅必须大于零');
    }
    final n = BigInt.from(lengthMilli) * BigInt.from(widthMilli);
    if (n > BigInt.from(9223372036854775807)) {
      throw ArgumentError('面积超过 SQLite 整数表示范围');
    }
    return n.toInt();
  }

  static String requiredKey(String key) {
    final trimmed = key.trim();
    if (trimmed.length < 12 || trimmed.length > 128) {
      throw ArgumentError('请求标识长度必须为 12–128');
    }
    return trimmed;
  }

  static String numberPrefix(String kind, DateTime when) =>
    '$kind${when.year.toString().padLeft(4, '0')}'
    '${when.month.toString().padLeft(2, '0')}'
    '${when.day.toString().padLeft(2, '0')}';

  Future<String> _nextNumber(Transaction tx, String table, String kind, DateTime when) async {
    final prefix = numberPrefix(kind, when);
    // Names here are fixed source literals, not caller controlled.
    final rows = await tx.rawQuery('''
      SELECT COALESCE(MAX(CAST(SUBSTR(number, ?) AS INTEGER)), 0) AS latest
      FROM $table WHERE number LIKE ?
    ''', [prefix.length + 1, '$prefix%']);
    return '$prefix${((rows.single['latest'] as int) + 1).toString().padLeft(4, '0')}';
  }

  Future<int> _balance(DatabaseExecutor tx, int productId, int warehouseId, String batch) async {
    final rows = await tx.rawQuery('''
      SELECT COALESCE(SUM(delta_area_micro), 0) AS area
      FROM stock_ledger_entries
      WHERE product_id=? AND warehouse_id=? AND batch_code=?
    ''', [productId, warehouseId, batch]);
    return rows.single['area'] as int;
  }

  @override
  Future<List<DispatchLineProgress>> dispatchableLines(int saleId) async {
    final rows = await db.rawQuery('''
      SELECT sl.id AS line_id, sl.product_id, sl.code_snapshot,
        sl.length_milli, sl.width_milli,
        COALESCE((SELECT SUM(dl.length_milli)
          FROM sale_dispatch_lines dl WHERE dl.sale_line_id=sl.id), 0) AS shipped
      FROM sale_lines sl WHERE sl.sale_id=? ORDER BY sl.id
    ''', [saleId]);
    return rows.map((r) => DispatchLineProgress(
      lineId: r['line_id'] as int,
      productId: r['product_id'] as int? ?? 0,
      code: r['code_snapshot'] as String,
      orderedLengthMilli: r['length_milli'] as int,
      dispatchedLengthMilli: r['shipped'] as int,
      widthMilli: r['width_milli'] as int,
    )).toList();
  }

  @override
  Future<int> postSaleDispatch({
    required int saleId,
    required String requestKey,
    required List<DispatchInputLine> lines,
    String note = '',
  }) async {
    final key = requiredKey(requestKey);
    if (lines.isEmpty) throw ArgumentError('至少需要一条实际出库明细');
    final normalized = lines.map((l) => DispatchInputLine(
      saleLineId: l.saleLineId, warehouseId: l.warehouseId,
      lengthMilli: l.lengthMilli, batchCode: l.batchCode.trim())).toList()
      ..sort((a,b) => a.saleLineId.compareTo(b.saleLineId));
    final seen = <int>{};
    for (final line in normalized) {
      if (line.saleLineId <= 0 || line.warehouseId <= 0 || line.lengthMilli <= 0 ||
          line.batchCode.length > 80 || !seen.add(line.saleLineId)) {
        throw ArgumentError('出库行 ID、数量、仓库或批次不合法');
      }
    }
    final payload = jsonEncode({
      'saleId': saleId, 'note': note.trim(),
      'lines': normalized.map((l) => {
        'line': l.saleLineId, 'warehouse': l.warehouseId,
        'lengthMilli': l.lengthMilli, 'batch': l.batchCode,
      }).toList(),
    });
    return db.transaction((tx) async {
      final previous = await tx.query('sale_dispatches',
        columns: ['id','payload'], where: 'request_key=?', whereArgs: [key]);
      if (previous.isNotEmpty) {
        if (previous.single['payload'] != payload) {
          throw StateError('相同请求标识的出库内容不一致，拒绝重复出库');
        }
        return previous.single['id'] as int;
      }
      final sale = await tx.query('sales',
        columns: ['status'], where: 'id=?', whereArgs: [saleId]);
      if (sale.isEmpty || sale.single['status'] != 'confirmed') {
        throw StateError('销售单不存在或状态不允许出库');
      }
      final prepared = <({DispatchInputLine input, int productId, int width, int area})>[];
      final available = <String, int>{};
      for (final input in normalized) {
        final rows = await tx.query('sale_lines',
          where: 'id=? AND sale_id=?', whereArgs: [input.saleLineId, saleId]);
        if (rows.isEmpty) throw ArgumentError('出库明细不属于这张销售单');
        final line = rows.single;
        final productId = line['product_id'] as int?;
        if (productId == null) {
          throw StateError('此销售行没有库存产品 ID，必须先通过业务修订建立关联，不能猜测库存');
        }
        final wh = await tx.query('warehouses', columns: ['active'],
          where: 'id=?', whereArgs: [input.warehouseId]);
        if (wh.isEmpty || wh.single['active'] != 1) {
          throw ArgumentError('仓库不存在或已停用');
        }
        final already = await tx.rawQuery('''
          SELECT COALESCE(SUM(length_milli),0) AS n
          FROM sale_dispatch_lines WHERE sale_line_id=?
        ''', [input.saleLineId]);
        final remaining = (line['length_milli'] as int) - (already.single['n'] as int);
        if (input.lengthMilli > remaining) throw StateError('出库米数超过原销售行未出库数量');
        final width = line['width_milli'] as int;
        final area = checkedArea(input.lengthMilli, width);
        final group = '$productId:${input.warehouseId}:${input.batchCode}';
        final balance = available[group] ?? await _balance(tx, productId,
          input.warehouseId, input.batchCode);
        if (balance < area) {
          throw StateError('产品 ${line['code_snapshot']} 的指定仓库/批次库存不足');
        }
        available[group] = balance - area;
        prepared.add((input: input, productId: productId, width: width, area: area));
      }
      final now = clock();
      final id = await tx.insert('sale_dispatches', {
        'number': await _nextNumber(tx, 'sale_dispatches', 'CK', now),
        'sale_id': saleId, 'request_key': key, 'payload': payload,
        'created_at': now.toIso8601String(), 'note': note.trim(),
      });
      for (final line in prepared) {
        await tx.insert('sale_dispatch_lines', {
          'dispatch_id': id, 'sale_line_id': line.input.saleLineId,
          'product_id': line.productId, 'warehouse_id': line.input.warehouseId,
          'batch_code': line.input.batchCode, 'length_milli': line.input.lengthMilli,
          'width_milli': line.width, 'area_micro': line.area,
        });
      }
      return id;
    });
  }

  @override
  Future<List<DispatchRecord>> saleDispatches({int? saleId}) async {
    final rows = await db.rawQuery('''
      SELECT d.*, s.number AS sale_number,
        COALESCE((SELECT SUM(dl.area_micro) FROM sale_dispatch_lines dl
          WHERE dl.dispatch_id=d.id), 0) AS area
      FROM sale_dispatches d JOIN sales s ON s.id=d.sale_id
      ${saleId == null ? '' : 'WHERE d.sale_id=?'}
      ORDER BY d.id DESC
    ''', saleId == null ? [] : [saleId]);
    return rows.map((r) => DispatchRecord(
      id: r['id'] as int, number: r['number'] as String,
      saleId: r['sale_id'] as int, saleNumber: r['sale_number'] as String,
      createdAt: r['created_at'] as String, note: r['note'] as String,
      totalAreaMicro: r['area'] as int,
    )).toList();
  }

  @override
  Future<List<ReturnLineProgress>> returnableLines(int dispatchId) async {
    final rows = await db.rawQuery('''
      SELECT dl.id AS line_id, dl.product_id, p.code AS code,
        dl.warehouse_id, w.code AS wh_code, dl.batch_code,
        dl.length_milli, dl.width_milli,
        COALESCE((SELECT SUM(rl.length_milli) FROM sale_return_lines rl
          WHERE rl.dispatch_line_id=dl.id),0) AS returned
      FROM sale_dispatch_lines dl
      JOIN products p ON p.id=dl.product_id
      JOIN warehouses w ON w.id=dl.warehouse_id
      WHERE dl.dispatch_id=? ORDER BY dl.id
    ''', [dispatchId]);
    return rows.map((r) => ReturnLineProgress(
      lineId: r['line_id'] as int, productId: r['product_id'] as int,
      code: r['code'] as String, warehouseId: r['warehouse_id'] as int,
      warehouseCode: r['wh_code'] as String,
      batchCode: r['batch_code'] as String,
      widthMilli: r['width_milli'] as int,
      dispatchedLengthMilli: r['length_milli'] as int,
      returnedLengthMilli: r['returned'] as int,
    )).toList();
  }

  @override
  Future<int> postSaleReturn({
    required int dispatchId,
    required String requestKey,
    required List<ReturnInputLine> lines,
    String note = '',
  }) async {
    final key = requiredKey(requestKey);
    if (lines.isEmpty) throw ArgumentError('至少需要一条实物退货明细');
    final normalized = [...lines]..sort((a,b) => a.dispatchLineId.compareTo(b.dispatchLineId));
    final seen = <int>{};
    for (final line in normalized) {
      if (line.dispatchLineId <= 0 || line.lengthMilli <= 0 ||
          !seen.add(line.dispatchLineId)) {
        throw ArgumentError('退货明细的出库行 ID 或米数不合法');
      }
    }
    final payload = jsonEncode({
      'dispatchId': dispatchId, 'note': note.trim(),
      'lines': normalized.map((l) => {
        'line': l.dispatchLineId, 'lengthMilli': l.lengthMilli,
      }).toList(),
    });
    return db.transaction((tx) async {
      final prior = await tx.query('sale_returns', columns: ['id','payload'],
        where: 'request_key=?', whereArgs: [key]);
      if (prior.isNotEmpty) {
        if (prior.single['payload'] != payload) {
          throw StateError('相同请求标识的退货内容不一致，拒绝重复退货');
        }
        return prior.single['id'] as int;
      }
      final dispatch = await tx.query('sale_dispatches',
        columns: ['id'], where: 'id=?', whereArgs: [dispatchId]);
      if (dispatch.isEmpty) throw StateError('原出库单不存在');
      final prepared = <({ReturnInputLine input, int productId, int warehouseId,
        String batch, int width, int area})>[];
      for (final input in normalized) {
        final records = await tx.query('sale_dispatch_lines',
          where: 'id=? AND dispatch_id=?', whereArgs: [input.dispatchLineId, dispatchId]);
        if (records.isEmpty) throw ArgumentError('退货明细不属于该出库单');
        final line = records.single;
        final returned = await tx.rawQuery('''
          SELECT COALESCE(SUM(length_milli),0) AS n
          FROM sale_return_lines WHERE dispatch_line_id=?
        ''', [input.dispatchLineId]);
        final remaining = (line['length_milli'] as int) - (returned.single['n'] as int);
        if (input.lengthMilli > remaining) throw StateError('退货米数超过原出库行可退数量');
        final width = line['width_milli'] as int;
        final area = checkedArea(input.lengthMilli, width);
        prepared.add((input: input, productId: line['product_id'] as int,
          warehouseId: line['warehouse_id'] as int,
          batch: line['batch_code'] as String, width: width, area: area));
      }
      final now = clock();
      final id = await tx.insert('sale_returns', {
        'number': await _nextNumber(tx, 'sale_returns', 'TH', now),
        'dispatch_id': dispatchId, 'request_key': key,
        'payload': payload, 'created_at': now.toIso8601String(), 'note': note.trim(),
      });
      for (final line in prepared) {
        await tx.insert('sale_return_lines', {
          'return_id': id, 'dispatch_line_id': line.input.dispatchLineId,
          'product_id': line.productId, 'warehouse_id': line.warehouseId,
          'batch_code': line.batch, 'length_milli': line.input.lengthMilli,
          'width_milli': line.width, 'area_micro': line.area,
        });
      }
      return id;
    });
  }

  @override
  Future<List<ReturnRecord>> saleReturns({int? dispatchId}) async {
    final rows = await db.rawQuery('''
      SELECT r.*, d.number AS dispatch_number,
        COALESCE((SELECT SUM(rl.area_micro) FROM sale_return_lines rl
          WHERE rl.return_id=r.id), 0) AS area
      FROM sale_returns r JOIN sale_dispatches d ON d.id=r.dispatch_id
      ${dispatchId == null ? '' : 'WHERE r.dispatch_id=?'}
      ORDER BY r.id DESC
    ''', dispatchId == null ? [] : [dispatchId]);
    return rows.map((r) => ReturnRecord(
      id: r['id'] as int, number: r['number'] as String,
      dispatchId: r['dispatch_id'] as int,
      dispatchNumber: r['dispatch_number'] as String,
      createdAt: r['created_at'] as String, note: r['note'] as String,
      totalAreaMicro: r['area'] as int,
    )).toList();
  }
}
