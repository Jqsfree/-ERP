import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/data/app_database.dart';
import 'package:kaibao_sales/data/backup_snapshot.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/services/backup_codec.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('加密备份→解密→全新 SQLite 恢复：原始客户/账单/收款/草稿完整', () async {
    final temp = await Directory.systemTemp.createTemp('kaibao-backup-');
    final source = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'source.db'),
      clock: () => DateTime(2026, 11, 7, 10));
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'target.db'));
    try {
      await source.addCustomer(const Customer(
        name: '测试客户A', openingBalanceCents: 1000,
        phone: '13011112222', address: '测试路 10 号'));
      await source.addProduct(const Product(code: 'TEST-01',
        specification: '窗帘', unitPriceCents: 1399));
      final customer = (await source.customers()).single;
      final product = (await source.products()).single;
      final saleId = await source.createSale(
        customer: customer,
        lines: [
          SaleLine(productId: product.id, code: 'TEST-01',
            specification: '窗帘', lengthMilli: 37000,
            widthMilli: 2800, unitPriceCents: 1399),
        ],
        discountCents: 36,
        initialReceivedCents: 50000,
      );
      await source.addPayment((await source.saleById(saleId))!, 10000, method: '微信');
      await source.saveDraft('{"schema":1,"note":"另一笔尚未开单"}');
      final plain = await source.exportSnapshotJson();
      final original = BackupSnapshot.parse(plain);
      expect(original.counts['sales'], 1);
      expect(original.counts['payments'], 2);
      expect(original.counts['sale_drafts'], 1);

      const password = 'test-passphrase-2026';
      final encrypted = await BackupCodec.encrypt(plain, password);
      expect(utf8.decode(encrypted), isNot(contains('13011112222')));
      expect(utf8.decode(encrypted), contains('AES-256-GCM'));
      final clear = await BackupCodec.decrypt(encrypted, password);
      expect(clear, plain);

      await target.restoreSnapshotJson(clear);
      final restored = (await target.sales()).single;
      expect(restored.number, 'XS202611070001');
      expect(restored.payableCents, 144900);
      expect(restored.receivedCents, 60000);
      expect(restored.currentDueCents, 84900);
      expect(restored.lines.single.areaText, '103.6');
      expect((await target.customers()).single.name, '测试客户A');
      expect((await target.products()).single.code, 'TEST-01');
      expect(await target.loadDraft(), contains('另一笔'));
      expect(await target.customerOutstanding(customer.id!), 85900);
      expect(await target.integrityOk(), isTrue);

      await target.close();
      final reopened = AppDatabase.forTesting(factory: databaseFactoryFfi,
        databasePath: p.join(temp.path, 'target.db'));
      try {
        expect((await reopened.sales()).single.currentDueCents, 84900);
        expect(await reopened.integrityOk(), isTrue);
      } finally {
        await reopened.close();
      }
    } finally {
      await source.close();
      await target.close();
      await temp.delete(recursive: true);
    }
  });

  test('错误口令与密文篡改不得解密', () async {
    final encrypted = await BackupCodec.encrypt('{"test":true}', 'correct-password-2026');
    await expectLater(
      BackupCodec.decrypt(encrypted, 'wrong-password-2026'), throwsFormatException);
    final envelope = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    ciphertext[0] ^= 1;
    envelope['ciphertext'] = base64Encode(ciphertext);
    await expectLater(
      BackupCodec.decrypt(utf8.encode(jsonEncode(envelope)), 'correct-password-2026'),
      throwsFormatException);
    await expectLater(
      BackupCodec.encrypt('{}', 'short'), throwsFormatException);
  });

  test('已有业务数据时恢复被拒绝，原记录不能被覆盖', () async {
    final temp = await Directory.systemTemp.createTemp('kaibao-restore-');
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'existing.db'));
    final blank = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'blank.db'));
    try {
      final snapshot = await blank.exportSnapshotJson();
      await db.addCustomer(const Customer(name: 'Existing'));
      await expectLater(db.restoreSnapshotJson(snapshot), throwsStateError);
      expect((await db.customers()).single.name, 'Existing');
      expect(await db.integrityOk(), isTrue);
    } finally {
      await db.close();
      await blank.close();
      await temp.delete(recursive: true);
    }
  });

  test('金额、关联、版本不一致的备份在写入前拒绝', () async {
    final temp = await Directory.systemTemp.createTemp('kaibao-invalid-');
    final db = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'seed.db'));
    final target = AppDatabase.forTesting(factory: databaseFactoryFfi,
      databasePath: p.join(temp.path, 'dest.db'));
    try {
      await db.addCustomer(const Customer(name: 'A'));
      final customer = (await db.customers()).single;
      await db.createSale(customer: customer, lines: const [
        SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 2000, unitPriceCents: 1000),
      ], discountCents: 0, initialReceivedCents: 0);
      final good = jsonDecode(await db.exportSnapshotJson()) as Map<String, dynamic>;
      final badAmount = jsonDecode(jsonEncode(good)) as Map<String, dynamic>;
      final tables = badAmount['tables'] as Map<String, dynamic>;
      ((tables['sale_lines'] as List).first as Map<String, dynamic>)['amount_cents'] = 1;
      expect(() => BackupSnapshot.parse(jsonEncode(badAmount)), throwsFormatException);
      await expectLater(target.restoreSnapshotJson(jsonEncode(badAmount)), throwsFormatException);
      expect(await target.sales(), isEmpty);

      final wrongVersion = jsonDecode(jsonEncode(good)) as Map<String, dynamic>;
      wrongVersion['schemaVersion'] = 999;
      expect(() => BackupSnapshot.parse(jsonEncode(wrongVersion)), throwsFormatException);
      expect(await target.integrityOk(), isTrue);
    } finally {
      await db.close();
      await target.close();
      await temp.delete(recursive: true);
    }
  });
}
