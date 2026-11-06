import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';
import '../application/sales_store.dart';
import '../application/backup_store.dart';
import 'backup_snapshot.dart';
import '../domain/money.dart';

class AppDatabase implements SalesStore, BackupStore {
  AppDatabase._({DatabaseFactory? factory, String? databasePath, DateTime Function()? clock})
      : _factory = factory, _databasePath = databasePath, _clock = clock ?? DateTime.now;

  /// Testable independent database; production keeps the Android sqflite plugin.
  AppDatabase.forTesting({required DatabaseFactory factory, required String databasePath,
      DateTime Function()? clock})
      : this._(factory: factory, databasePath: databasePath, clock: clock);

  static final AppDatabase instance = AppDatabase._();
  static const schemaVersion = 2;
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
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await db.execute(_draftSchema);
      },
      ),
    );
  }

  static const _draftSchema = '''CREATE TABLE sale_drafts (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    payload TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )''';

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
