import 'package:sqflite/sqflite.dart';
import '../domain/models.dart';

class ProductIdentity {
  /// Existing snapshots remain valid if catalog labels later change. New stock
  /// associations must agree with the selected current catalog item.
  static Future<void> validate(DatabaseExecutor tx, List<SaleLine> lines,
      {List<SaleLine> previous = const []}) async {
    final originals = {for (final l in previous) l.id: l};
    for (final line in lines) {
      if (line.productId == null) continue;
      final old = line.id == null ? null : originals[line.id];
      if (old != null && old.productId == line.productId && old.code == line.code && old.specification == line.specification) continue;
      final products = await tx.query('products', where: 'id=?', whereArgs: [line.productId]);
      // Foreign keys reject missing products on the actual insert, preserving
      // the database's rollback/error contract for invalid references.
      if (products.isEmpty) continue;
      if (products.single['active'] != 1) throw StateError('停用产品不能新关联销售行');
      if (products.single['code'] != line.code) {
        throw StateError('商品型号或规格与库存商品不一致，请重新选择商品，或改为手填且不关联库存。');
      }
    }
  }
}
