import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../application/sales_store.dart';
import '../application/backup_store.dart';
import '../application/procurement_store.dart';
import '../application/inventory_store.dart';
import '../application/fulfillment_store.dart';
import '../domain/fulfillment.dart';
import 'fulfillment_schema.dart';
import 'fulfillment_repository.dart';
import '../domain/inventory.dart';
import 'inventory_schema.dart';
import '../domain/procurement.dart';
import 'backup_snapshot.dart';
import '../domain/money.dart';

class AppDatabase implements SalesStore, BackupStore, ProcurementStore, InventoryStore, FulfillmentStore {
  AppDatabase._({DatabaseFactory? factory, String? databasePath, DateTime Function()? clock})
      : _factory = factory, _databasePath = databasePath, _clock = clock ?? DateTime.now;

  /// Testable independent database; production keeps the Android sqflite plugin.
  AppDatabase.forTesting({required DatabaseFactory factory, required String databasePath,
      DateTime Function()? clock})
      : this._(factory: factory, databasePath: databasePath, clock: clock);

  static final AppDatabase instance = AppDatabase._();
  static const schemaVersion = 5;
  final DatabaseFactory? _factory;
  final String? _databasePath;
  final DateTime Function() _clock;
  Future<Database>? _opening;

  Future<Database> get db => _opening ??= _open();

  Future<Database> _open() async {
    final path = _databasePath ?? p.join(await getDatabasesPath(), 'kaibao_sales.db');
    return (_factory ?? databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
      version: schemaVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys=ON'),
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE customers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE, phone TEXT NOT NULL DEFAULT '',
          address TEXT NOT NULL DEFAULT '', opening_balance_cents INTEGER NOT NULL DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE products (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          code TEXT NOT NULL UNIQUE, specification TEXT NOT NULL DEFAULT '',
          unit_price_cents INTEGER NOT NULL CHECK(unit_price_cents >= 0)
        )''');
        await db.execute('''CREATE TABLE sales (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          number TEXT NOT NULL UNIQUE, date TEXT NOT NULL,
          customer_id INTEGER NOT NULL REFERENCES customers(id),
          customer_name_snapshot TEXT NOT NULL,
          customer_phone_snapshot TEXT NOT NULL,
          customer_address_snapshot TEXT NOT NULL,
          subtotal_cents INTEGER NOT NULL, discount_cents INTEGER NOT NULL,
          prior_due_snapshot INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'confirmed', note TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL
        )''');
        await db.execute('''CREATE TABLE sale_lines (
          id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL REFERENCES sales(id),
          product_id INTEGER REFERENCES products(id),
          code_snapshot TEXT NOT NULL, spec_snapshot TEXT NOT NULL DEFAULT '',
          length_milli INTEGER NOT NULL CHECK(length_milli > 0),
          width_milli INTEGER NOT NULL CHECK(width_milli > 0),
          unit_price_cents INTEGER NOT NULL CHECK(unit_price_cents >= 0),
          amount_cents INTEGER NOT NULL, note TEXT NOT NULL DEFAULT ''
        )''');
        await db.execute('''CREATE TABLE payments (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sale_id INTEGER NOT NULL REFERENCES sales(id),
          amount_cents INTEGER NOT NULL CHECK(amount_cents > 0),
          method TEXT NOT NULL DEFAULT '其他', remark TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL
        )''');
        await db.execute('CREATE INDEX idx_sales_customer ON sales(customer_id, status)');
        await db.execute('CREATE INDEX idx_payments_sale ON payments(sale_id)');
        await db.execute(_draftSchema);
        await _createProcurementSchema(db);
        await InventorySchema.create(db);
        await FulfillmentSchema.create(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await db.execute(_draftSchema);
        if (from < 3) await _createProcurementSchema(db);
        if (from < 4) await InventorySchema.create(db);
        if (from < 5) await FulfillmentSchema.create(db);
      },
      ),
    );
  }

  static const _draftSchema = '''CREATE TABLE sale_drafts (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    payload TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )''';

  static Future<void> _createProcurementSchema(DatabaseExecutor db) async {
    await db.execute('''CREATE TABLE suppliers (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE,
      phone TEXT NOT NULL DEFAULT '',
      address TEXT NOT NULL DEFAULT '',
      note TEXT NOT NULL DEFAULT '',
      active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0, 1))
    )''');
    await db.execute('''CREATE TABLE purchase_orders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      number TEXT NOT NULL UNIQUE,
      date TEXT NOT NULL,
      supplier_id INTEGER NOT NULL REFERENCES suppliers(id),
      supplier_name_snapshot TEXT NOT NULL,
      supplier_phone_snapshot TEXT NOT NULL,
      supplier_address_snapshot TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('ordered', 'cancelled')),
      total_cents INTEGER NOT NULL CHECK(total_cents >= 0),
      note TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL
    )''');
    await db.execute('''CREATE TABLE purchase_lines (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      purchase_order_id INTEGER NOT NULL REFERENCES purchase_orders(id),
      product_id INTEGER NOT NULL REFERENCES products(id),
      code_snapshot TEXT NOT NULL,
      spec_snapshot TEXT NOT NULL DEFAULT '',
      length_milli INTEGER NOT NULL CHECK(length_milli > 0),
      width_milli INTEGER NOT NULL CHECK(width_milli > 0),
      unit_cost_cents INTEGER NOT NULL CHECK(unit_cost_cents > 0),
      amount_cents INTEGER NOT NULL CHECK(amount_cents >= 0),
      note TEXT NOT NULL DEFAULT ''
    )''');
    await db.execute('CREATE INDEX idx_purchase_orders_supplier ON purchase_orders(supplier_id, status)');
    await db.execute('CREATE INDEX idx_purchase_lines_order ON purchase_lines(purchase_order_id)');
  }

  /// Operational drafts are persisted in SQLite, NOT a second cache of balances.
  /// A single-device P0 editor has only one active draft.
  @override
  Future<void> saveDraft(String jsonPayload) async {
    if (jsonPayload.trim().isEmpty) throw ArgumentError('草稿不能为空');
    final database = await db;
    await database.insert('sale_drafts', {
      'id': 1, 'payload': jsonPayload, 'updated_at': _clock().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<String?> loadDraft() async {
    final rows = await (await db).query('sale_drafts', columns: ['payload'],
      where: 'id = ?', whereArgs: [1], limit: 1);
    return rows.isEmpty ? null : rows.first['payload'] as String;
  }

  @override
  Future<void> deleteDraft() async {
    await (await db).delete('sale_drafts', where: 'id = ?', whereArgs: [1]);
  }

  /// Used for diagnostics, not a substitute for off-device backups.
  Future<bool> integrityOk() async {
    final database = await db;
    final integrity = await database.rawQuery('PRAGMA integrity_check');
    final foreignKeys = await database.rawQuery('PRAGMA foreign_key_check');
    return integrity.length == 1 &&
      integrity.first.values.single == 'ok' && foreignKeys.isEmpty;
  }

  @override
  Future<List<Customer>> customers() async {
    final rows = await (await db).query('customers', orderBy: 'name COLLATE NOCASE');
    return rows.map(Customer.fromMap).toList();
  }

  @override
  Future<void> addCustomer(Customer item) async {
    if (item.name.trim().isEmpty) throw ArgumentError('客户名称不能为空');
    await (await db).insert('customers', {
      'name': item.name.trim(), 'phone': item.phone.trim(),
      'address': item.address.trim(), 'opening_balance_cents': item.openingBalanceCents,
    });
  }

  @override
  Future<List<Product>> products() async {
    final rows = await (await db).query('products', orderBy: 'code COLLATE NOCASE');
    return rows.map(Product.fromMap).toList();
  }

  @override
  Future<void> addProduct(Product item) async {
    if (item.code.trim().isEmpty) throw ArgumentError('产品型号不能为空');
    await (await db).insert('products', {
      'code': item.code.trim(), 'specification': item.specification.trim(),
      'unit_price_cents': item.unitPriceCents,
    });
  }

  @override
  Future<List<Supplier>> suppliers({bool includeInactive = true}) async {
    final rows = await (await db).query('suppliers',
      where: includeInactive ? null : 'active = 1',
      orderBy: 'name COLLATE NOCASE');
    return rows.map(Supplier.fromMap).toList();
  }

  @override
  Future<void> addSupplier(Supplier supplier) async {
    if (supplier.name.trim().isEmpty) throw ArgumentError('供应商名称不能为空');
    await (await db).insert('suppliers', {
      'name': supplier.name.trim(), 'phone': supplier.phone.trim(),
      'address': supplier.address.trim(), 'note': supplier.note.trim(),
      'active': supplier.active ? 1 : 0,
    });
  }

  @override
  Future<void> updateSupplier(Supplier supplier) async {
    if (supplier.id == null || supplier.name.trim().isEmpty) {
      throw ArgumentError('供应商 ID 与名称不能为空');
    }
    final rows = await (await db).update('suppliers', {
      'name': supplier.name.trim(), 'phone': supplier.phone.trim(),
      'address': supplier.address.trim(), 'note': supplier.note.trim(),
      'active': supplier.active ? 1 : 0,
    }, where: 'id = ?', whereArgs: [supplier.id]);
    if (rows != 1) throw StateError('供应商不存在');
  }

  @override
  Future<int> createPurchaseOrder({
    required int supplierId, required List<PurchaseLine> lines, String note = '',
  }) async {
    if (lines.isEmpty) throw ArgumentError('采购订单至少需要一条明细');
    for (final item in lines) {
      if (item.lengthMilli <= 0 || item.widthMilli <= 0 || item.unitCostCents <= 0) {
        throw ArgumentError('采购米数、门幅和单价必须大于零');
      }
    }
    return (await db).transaction((tx) async {
      final suppliers = await tx.query('suppliers',
        where: 'id = ?', whereArgs: [supplierId]);
      if (suppliers.isEmpty) throw ArgumentError('供应商不存在');
      final supplier = Supplier.fromMap(suppliers.single);
      if (!supplier.active) throw StateError('停用供应商不能创建采购订单');

      // Validate product identity inside the same transaction. Product names and
      // specifications are frozen from authoritative product records.
      final persisted = <PurchaseLine>[];
      for (final line in lines) {
        final products = await tx.query('products',
          where: 'id = ?', whereArgs: [line.productId]);
        if (products.isEmpty) throw ArgumentError('采购明细引用了不存在的产品');
        final product = Product.fromMap(products.single);
        persisted.add(PurchaseLine(
          productId: line.productId, code: product.code,
          specification: product.specification, lengthMilli: line.lengthMilli,
          widthMilli: line.widthMilli, unitCostCents: line.unitCostCents,
          note: line.note.trim(),
        ));
      }
      final now = _clock();
      final date = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final prefix = 'CG${date.replaceAll('-', '')}';
      final ids = await tx.rawQuery('''
        SELECT COALESCE(MAX(CAST(SUBSTR(number, ?) AS INTEGER)),0) AS latest
        FROM purchase_orders WHERE number LIKE ?
      ''', [prefix.length + 1, '$prefix%']);
      final next = (ids.single['latest'] as int) + 1;
      final number = '$prefix${next.toString().padLeft(4, '0')}';
      final subtotal = persisted.fold<int>(0, (sum, row) => sum + row.amountCents);
      final id = await tx.insert('purchase_orders', {
        'number': number, 'date': date, 'supplier_id': supplierId,
        'supplier_name_snapshot': supplier.name,
        'supplier_phone_snapshot': supplier.phone,
        'supplier_address_snapshot': supplier.address,
        'status': 'ordered', 'total_cents': subtotal,
        'note': note.trim(), 'created_at': now.toIso8601String(),
      });
      for (final line in persisted) {
        await tx.insert('purchase_lines', {
          'purchase_order_id': id, 'product_id': line.productId,
          'code_snapshot': line.code, 'spec_snapshot': line.specification,
          'length_milli': line.lengthMilli, 'width_milli': line.widthMilli,
          'unit_cost_cents': line.unitCostCents, 'amount_cents': line.amountCents,
          'note': line.note,
        });
      }
      return id;
    });
  }

  Future<List<PurchaseOrder>> _loadPurchaseOrders({int? id}) async {
    final database = await db;
    final rows = await database.query('purchase_orders',
      where: id == null ? null : 'id = ?', whereArgs: id == null ? null : [id],
      orderBy: 'id DESC');
    if (rows.isEmpty) return [];
    final lines = <int, List<PurchaseLine>>{};
    final ids = rows.map((row) => row['id'] as int).toList();
    for (var offset = 0; offset < ids.length; offset += 400) {
      final chunk = ids.skip(offset).take(400).toList();
      final ph = List.filled(chunk.length, '?').join(',');
      final results = await database.rawQuery(
        'SELECT * FROM purchase_lines WHERE purchase_order_id IN ($ph) ORDER BY purchase_order_id, id',
        chunk,
      );
      for (final row in results) {
        (lines[row['purchase_order_id'] as int] ??= []).add(PurchaseLine.fromMap(row));
      }
    }
    return rows.map((row) {
      final key = row['id'] as int;
      return PurchaseOrder(
        id: key, number: row['number'] as String, date: row['date'] as String,
        supplierId: row['supplier_id'] as int,
        supplierName: row['supplier_name_snapshot'] as String,
        supplierPhone: row['supplier_phone_snapshot'] as String,
        supplierAddress: row['supplier_address_snapshot'] as String,
        status: row['status'] as String,
        totalCents: row['total_cents'] as int,
        note: row['note'] as String,
        lines: lines[key] ?? const [],
      );
    }).toList();
  }

  @override
  Future<List<PurchaseOrder>> purchaseOrders() => _loadPurchaseOrders();

  @override
  Future<PurchaseOrder?> purchaseOrderById(int id) async {
    final orders = await _loadPurchaseOrders(id: id);
    return orders.isEmpty ? null : orders.single;
  }

  @override
  Future<void> cancelPurchaseOrder(int id) async {
    final database = await db;
    await database.transaction((tx) async {
      final rows = await tx.query('purchase_orders', where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) throw StateError('采购订单不存在');
      if (rows.single['status'] == 'cancelled') return;
      if (rows.single['status'] != 'ordered') throw StateError('当前状态不能取消采购订单');
      final received = await tx.rawQuery(
        'SELECT COUNT(*) AS n FROM purchase_receipts WHERE purchase_order_id = ?', [id]);
      if ((received.single['n'] as int) > 0) {
        throw StateError('采购单已经发生收货，必须通过退货/冲销流程修正，不能直接取消');
      }
      final count = await tx.update('purchase_orders',
        {'status': 'cancelled'}, where: 'id = ? AND status = ?', whereArgs: [id, 'ordered']);
      if (count != 1) throw StateError('采购订单状态发生变化');
    });
  }

  @override
  Future<List<Warehouse>> warehouses() async {
    final data = await (await db).query('warehouses', orderBy: 'code COLLATE NOCASE');
    return data.map((r) => Warehouse(
      id: r['id'] as int, code: r['code'] as String,
      name: r['name'] as String, active: r['active'] == 1)).toList();
  }

  @override
  Future<int> addWarehouse({required String code, required String name}) async {
    final normalizedCode = code.trim().toUpperCase();
    final normalizedName = name.trim();
    if (normalizedCode.isEmpty || normalizedName.isEmpty ||
        normalizedCode.length > 32 || normalizedName.length > 100) {
      throw ArgumentError('仓库编码或名称不合法');
    }
    return (await db).insert('warehouses',
      {'code': normalizedCode, 'name': normalizedName, 'active': 1});
  }

  @override
  Future<List<ReceiptLineProgress>> receivableLines(int purchaseOrderId) async {
    final data = await (await db).rawQuery('''
      SELECT pl.id AS line_id, pl.product_id, pl.code_snapshot,
        pl.length_milli, pl.width_milli,
        COALESCE((SELECT SUM(rl.length_milli)
          FROM purchase_receipt_lines rl JOIN purchase_receipts pr
          ON pr.id = rl.receipt_id
          WHERE rl.purchase_line_id = pl.id AND pr.purchase_order_id = ?), 0) AS received
      FROM purchase_lines pl WHERE pl.purchase_order_id = ? ORDER BY pl.id
    ''', [purchaseOrderId, purchaseOrderId]);
    return data.map((r) => ReceiptLineProgress(
      lineId: r['line_id'] as int,
      productId: r['product_id'] as int,
      code: r['code_snapshot'] as String,
      orderedLengthMilli: r['length_milli'] as int,
      receivedLengthMilli: r['received'] as int,
      widthMilli: r['width_milli'] as int,
    )).toList();
  }

  @override
  Future<int> postPurchaseReceipt({
    required int purchaseOrderId,
    required String requestKey,
    required List<ReceiptInputLine> lines,
    String note = '',
  }) async {
    final key = requestKey.trim();
    if (key.length < 12 || key.length > 128) {
      throw ArgumentError('收货请求标识格式不合法');
    }
    if (lines.isEmpty) throw ArgumentError('至少需要一条收货明细');
    final normalized = lines.map((l) => ReceiptInputLine(
      purchaseLineId: l.purchaseLineId, warehouseId: l.warehouseId,
      lengthMilli: l.lengthMilli, batchCode: l.batchCode.trim())).toList()
      ..sort((a,b) => a.purchaseLineId.compareTo(b.purchaseLineId));
    final ids = <int>{};
    for (final line in normalized) {
      if (line.purchaseLineId <= 0 || line.warehouseId <= 0 ||
          line.lengthMilli <= 0 || !ids.add(line.purchaseLineId) ||
          line.batchCode.length > 80) {
        throw ArgumentError('收货明细包含重复采购行或无效米数、仓库、批次');
      }
    }
    final payload = jsonEncode({
      'purchaseOrderId': purchaseOrderId, 'note': note.trim(),
      'lines': normalized.map((l) => {
        'line': l.purchaseLineId, 'warehouse': l.warehouseId,
        'lengthMilli': l.lengthMilli, 'batch': l.batchCode,
      }).toList(),
    });
    return (await db).transaction((tx) async {
      final prior = await tx.query('purchase_receipts',
        columns: ['id', 'payload'], where: 'request_key = ?', whereArgs: [key]);
      if (prior.isNotEmpty) {
        if (prior.single['payload'] != payload) {
          throw StateError('请求标识已关联其他收货内容，拒绝重复加库存');
        }
        return prior.single['id'] as int;
      }
      final order = await tx.query('purchase_orders',
        columns: ['status'], where: 'id = ?', whereArgs: [purchaseOrderId]);
      if (order.isEmpty || order.single['status'] != 'ordered') {
        throw StateError('采购订单不存在或已取消，禁止收货');
      }
      final prepared = <({ReceiptInputLine input, int productId, int width, int area})>[];
      for (final input in normalized) {
        final rows = await tx.query('purchase_lines', where: 'id = ? AND purchase_order_id = ?',
          whereArgs: [input.purchaseLineId, purchaseOrderId]);
        if (rows.isEmpty) throw ArgumentError('收货明细不属于这张采购单');
        final row = rows.single;
        final wh = await tx.query('warehouses', columns: ['active'],
          where: 'id = ?', whereArgs: [input.warehouseId]);
        if (wh.isEmpty || wh.single['active'] != 1) {
          throw ArgumentError('收货仓库不存在或已停用');
        }
        final received = await tx.rawQuery(
          'SELECT COALESCE(SUM(length_milli),0) AS n FROM purchase_receipt_lines WHERE purchase_line_id = ?',
          [input.purchaseLineId]);
        final remaining = (row['length_milli'] as int) - (received.single['n'] as int);
        if (input.lengthMilli > remaining) {
          throw StateError('收货米数超过采购行的剩余米数');
        }
        final width = row['width_milli'] as int;
        final area = input.lengthMilli * width;
        if (area <= 0 || area > 9223372036854775807) {
          throw ArgumentError('收货面积超出存储范围');
        }
        prepared.add((input: input, productId: row['product_id'] as int,
          width: width, area: area));
      }
      final now = _clock();
      final date = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
      final prefix = 'SH${date.replaceAll('-', '')}';
      final last = await tx.rawQuery('''
        SELECT COALESCE(MAX(CAST(SUBSTR(number, ?) AS INTEGER)),0) AS latest
        FROM purchase_receipts WHERE number LIKE ?
      ''', [prefix.length + 1, '$prefix%']);
      final serial = (last.single['latest'] as int) + 1;
      final receiptId = await tx.insert('purchase_receipts', {
        'number': '$prefix${serial.toString().padLeft(4, '0')}',
        'purchase_order_id': purchaseOrderId,
        'request_key': key, 'payload': payload,
        'created_at': now.toIso8601String(), 'note': note.trim(),
      });
      for (final line in prepared) {
        final input = line.input;
        final receiptLineId = await tx.insert('purchase_receipt_lines', {
          'receipt_id': receiptId, 'purchase_line_id': input.purchaseLineId,
          'warehouse_id': input.warehouseId, 'batch_code': input.batchCode,
          'length_milli': input.lengthMilli, 'width_milli': line.width,
          'area_micro': line.area,
        });
        await tx.insert('stock_movements', {
          'receipt_line_id': receiptLineId, 'product_id': line.productId,
          'warehouse_id': input.warehouseId, 'batch_code': input.batchCode,
          'delta_area_micro': line.area, 'created_at': now.toIso8601String(),
        });
      }
      return receiptId;
    });
  }

  @override
  Future<List<PurchaseReceiptRecord>> purchaseReceipts({int? purchaseOrderId}) async {
    final rows = await (await db).rawQuery('''
      SELECT r.*, o.number AS order_number,
        COALESCE((SELECT SUM(l.area_micro) FROM purchase_receipt_lines l
          WHERE l.receipt_id=r.id),0) AS area
      FROM purchase_receipts r JOIN purchase_orders o ON o.id=r.purchase_order_id
      ${purchaseOrderId == null ? '' : 'WHERE r.purchase_order_id = ?'}
      ORDER BY r.id DESC
    ''', purchaseOrderId == null ? [] : [purchaseOrderId]);
    return rows.map((r) => PurchaseReceiptRecord(
      id: r['id'] as int, number: r['number'] as String,
      purchaseOrderId: r['purchase_order_id'] as int,
      orderNumber: r['order_number'] as String,
      note: r['note'] as String, createdAt: r['created_at'] as String,
      totalAreaMicro: r['area'] as int,
    )).toList();
  }

  @override
  Future<List<StockMovementRecord>> stockMovements() async {
    final rows = await (await db).rawQuery('''
      SELECT m.event_id, m.source_type, m.document_number,
        m.delta_area_micro, m.batch_code, m.created_at,
        p.code AS product_code, w.code AS warehouse_code
      FROM stock_ledger_entries m JOIN products p ON p.id=m.product_id
      JOIN warehouses w ON w.id=m.warehouse_id
      ORDER BY m.created_at DESC, m.source_type, m.event_id DESC
    ''');
    return rows.map((r) => StockMovementRecord(
      id: r['event_id'] as int, receiptNumber: r['document_number'] as String,
      sourceType: r['source_type'] as String,
      productCode: r['product_code'] as String,
      warehouseCode: r['warehouse_code'] as String,
      batchCode: r['batch_code'] as String,
      deltaAreaMicro: r['delta_area_micro'] as int,
      createdAt: r['created_at'] as String,
    )).toList();
  }

  @override
  Future<List<StockBalance>> stockBalances() async {
    final rows = await (await db).rawQuery('''
      SELECT m.product_id, p.code AS product_code, m.warehouse_id,
        w.code AS warehouse_code, m.batch_code,
        SUM(m.delta_area_micro) AS area
      FROM stock_ledger_entries m JOIN products p ON p.id=m.product_id
      JOIN warehouses w ON w.id=m.warehouse_id
      GROUP BY m.product_id, m.warehouse_id, m.batch_code
      ORDER BY w.code, p.code, m.batch_code
    ''');
    return rows.map((r) => StockBalance(
      productId: r['product_id'] as int,
      productCode: r['product_code'] as String,
      warehouseId: r['warehouse_id'] as int,
      warehouseCode: r['warehouse_code'] as String,
      batchCode: r['batch_code'] as String,
      areaMicro: r['area'] as int,
    )).toList();
  }

  Future<FulfillmentRepository> _fulfillment() async =>
    FulfillmentRepository(await db, _clock);

  @override
  Future<List<DispatchLineProgress>> dispatchableLines(int saleId) async =>
    (await _fulfillment()).dispatchableLines(saleId);

  @override
  Future<int> postSaleDispatch({
    required int saleId,
    required String requestKey,
    required List<DispatchInputLine> lines,
    String note = '',
  }) async => (await _fulfillment()).postSaleDispatch(
    saleId: saleId, requestKey: requestKey, lines: lines, note: note);

  @override
  Future<List<DispatchRecord>> saleDispatches({int? saleId}) async =>
    (await _fulfillment()).saleDispatches(saleId: saleId);

  @override
  Future<List<ReturnLineProgress>> returnableLines(int dispatchId) async =>
    (await _fulfillment()).returnableLines(dispatchId);

  @override
  Future<int> postSaleReturn({
    required int dispatchId,
    required String requestKey,
    required List<ReturnInputLine> lines,
    String note = '',
  }) async => (await _fulfillment()).postSaleReturn(
    dispatchId: dispatchId, requestKey: requestKey, lines: lines, note: note);

  @override
  Future<List<ReturnRecord>> saleReturns({int? dispatchId}) async =>
    (await _fulfillment()).saleReturns(dispatchId: dispatchId);

  @override
  Future<int> customerOutstanding(int customerId, {Transaction? tx}) async {
    final database = tx ?? await db;
    final customers = await database.query('customers', where: 'id=?', whereArgs: [customerId]);
    if (customers.isEmpty) throw StateError('客户不存在');
    final opening = customers.first['opening_balance_cents'] as int;
    final sums = await database.rawQuery('''
      SELECT COALESCE(SUM(s.subtotal_cents - s.discount_cents -
        COALESCE((SELECT SUM(p.amount_cents) FROM payments p WHERE p.sale_id=s.id), 0)),0) AS due
      FROM sales s WHERE s.customer_id=? AND s.status='confirmed'
    ''', [customerId]);
    return opening + (sums.first['due'] as int);
  }

  /// Creates a confirmed invoice in one SQLite transaction.
  /// Serial is allocated inside the transaction to prevent duplicate numbers.
  @override
  Future<int> createSale({required Customer customer, required List<SaleLine> lines,
    required int discountCents, required int initialReceivedCents, String note = ''}) async {
    if (customer.id == null) throw ArgumentError('请选择已保存的客户');
    if (lines.isEmpty) throw ArgumentError('至少需要一条产品');
    for (final line in lines) {
      if (line.code.trim().isEmpty) throw ArgumentError('型号不能为空');
      if (line.lengthMilli <= 0 || line.widthMilli <= 0) throw ArgumentError('米数和门幅必须大于零');
    }
    final subtotal = lines.fold<int>(0, (sum, line) => sum + line.totalCents);
    final payable = BillingMath.payable(subtotal, discountCents);
    if (initialReceivedCents < 0 || initialReceivedCents > payable) {
      throw ArgumentError('本次收款不能超过应收金额');
    }
    return (await db).transaction((tx) async {
      final priorDue = await customerOutstanding(customer.id!, tx: tx);
      final now = _clock();
      final date = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final prefix = 'XS${date.replaceAll('-', '')}';
      final last = await tx.rawQuery(
        'SELECT COALESCE(MAX(CAST(SUBSTR(number, ?) AS INTEGER)),0) AS latest FROM sales WHERE number LIKE ?',
        [prefix.length + 1, '$prefix%']);
      final next = (last.first['latest'] as int) + 1;
      final number = '$prefix${next.toString().padLeft(4, '0')}';
      final saleId = await tx.insert('sales', {
        'number': number, 'date': date, 'customer_id': customer.id!,
        'customer_name_snapshot': customer.name, 'customer_phone_snapshot': customer.phone,
        'customer_address_snapshot': customer.address, 'subtotal_cents': subtotal,
        'discount_cents': discountCents, 'prior_due_snapshot': priorDue,
        'status': 'confirmed', 'note': note.trim(), 'created_at': now.toIso8601String(),
      });
      for (final line in lines) {
        await tx.insert('sale_lines', {
          'sale_id': saleId, 'product_id': line.productId,
          'code_snapshot': line.code, 'spec_snapshot': line.specification,
          'length_milli': line.lengthMilli, 'width_milli': line.widthMilli,
          'unit_price_cents': line.unitPriceCents, 'amount_cents': line.totalCents,
          'note': line.note,
        });
      }
      if (initialReceivedCents > 0) {
        await tx.insert('payments', {
          'sale_id': saleId, 'amount_cents': initialReceivedCents,
          'method': '其他', 'remark': '开单收款', 'created_at': now.toIso8601String(),
        });
      }
      // The order and the draft removal commit or roll back together.
      await tx.delete('sale_drafts', where: 'id = ?', whereArgs: [1]);
      return saleId;
    });
  }

  @override
  Future<List<Sale>> sales() => _loadSales();

  @override
  Future<Sale?> saleById(int id) async {
    final items = await _loadSales(saleId: id);
    return items.isEmpty ? null : items.single;
  }

  /// Two main queries instead of N+1; chunks keep IN clause under SQLite limits.
  Future<List<Sale>> _loadSales({int? saleId}) async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT s.*, COALESCE((SELECT SUM(p.amount_cents) FROM payments p WHERE p.sale_id=s.id),0) AS paid
      FROM sales s ${saleId == null ? '' : 'WHERE s.id = ?'} ORDER BY s.id DESC
    ''', saleId == null ? [] : [saleId]);
    if (rows.isEmpty) return [];
    final linesBySale = <int, List<SaleLine>>{};
    final ids = rows.map((r) => r['id'] as int).toList();
    for (var offset = 0; offset < ids.length; offset += 400) {
      final chunk = ids.skip(offset).take(400).toList();
      final placeholders = List.filled(chunk.length, '?').join(',');
      final details = await database.rawQuery(
        'SELECT * FROM sale_lines WHERE sale_id IN ($placeholders) ORDER BY sale_id, id',
        chunk);
      for (final detail in details) {
        (linesBySale[detail['sale_id'] as int] ??= []).add(SaleLine.fromMap(detail));
      }
    }
    return rows.map((row) {
      final id = row['id'] as int;
      return Sale(
        id: id, number: row['number'] as String, date: row['date'] as String,
        customerId: row['customer_id'] as int,
        customerName: row['customer_name_snapshot'] as String,
        customerPhone: row['customer_phone_snapshot'] as String,
        customerAddress: row['customer_address_snapshot'] as String,
        subtotalCents: row['subtotal_cents'] as int,
        discountCents: row['discount_cents'] as int,
        priorDueCents: row['prior_due_snapshot'] as int,
        receivedCents: row['paid'] as int,
        status: row['status'] as String, note: row['note'] as String,
        lines: linesBySale[id] ?? [],
      );
    }).toList();
  }

  @override
  Future<void> addPayment(Sale sale, int amountCents, {String method = '其他'}) async {
    if (amountCents <= 0) throw ArgumentError('收款金额必须大于零');
    await (await db).transaction((tx) async {
      final r = await tx.rawQuery('''SELECT s.status,
        (s.subtotal_cents-s.discount_cents-COALESCE((SELECT SUM(p.amount_cents)
         FROM payments p WHERE p.sale_id=s.id),0)) AS due
        FROM sales s WHERE s.id=?''', [sale.id]);
      if (r.isEmpty || r.first['status'] != 'confirmed') throw StateError('单据状态不允许收款');
      if (amountCents > (r.first['due'] as int)) throw ArgumentError('收款超过剩余应收款');
      await tx.insert('payments', {
        'sale_id': sale.id, 'amount_cents': amountCents,
        'method': method, 'remark': '', 'created_at': _clock().toIso8601String(),
      });
    });
  }

  /// A single SQLite transaction supplies a consistent multi-table snapshot.
  /// Do not copy only the main DB file: SQLite may be in WAL mode.
  @override
  Future<String> exportSnapshotJson() async {
    final database = await db;
    final snapshot = await database.transaction((tx) async {
      final tables = <String, List<Map<String, Object?>>>{};
      for (final table in BackupSnapshot.columns.keys) {
        final rows = await tx.query(table, orderBy: 'id');
        tables[table] = rows.map((row) => Map<String, Object?>.from(row)).toList();
      }
      return BackupSnapshot.create(tables, _clock());
    });
    return snapshot.encode();
  }

  /// Restore is append-only into a virgin database; existing records are NEVER
  /// replaced. Any failure rolls back the entire import.
  @override
  Future<void> restoreSnapshotJson(String plaintextSnapshot) async {
    final snapshot = BackupSnapshot.parse(plaintextSnapshot);
    final database = await db;
    await database.transaction((tx) async {
      for (final table in BackupSnapshot.columns.keys) {
        final count = await tx.rawQuery('SELECT COUNT(*) AS n FROM $table');
        if ((count.single['n'] as int) != 0) {
          throw StateError('本机已有数据，禁止覆盖恢复；请使用全新空数据库');
        }
      }
      for (final table in BackupSnapshot.columns.keys) {
        for (final row in snapshot.rows[table]!) {
          await tx.insert(table, row, conflictAlgorithm: ConflictAlgorithm.abort);
        }
      }
      final fk = await tx.rawQuery('PRAGMA foreign_key_check');
      if (fk.isNotEmpty) throw StateError('备份恢复后的外键检查失败');
      final integrity = await tx.rawQuery('PRAGMA integrity_check');
      if (integrity.length != 1 || integrity.single.values.single != 'ok') {
        throw StateError('备份恢复后的完整性检查失败');
      }
    });
  }

  Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }
}
