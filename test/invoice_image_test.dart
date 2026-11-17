import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaibao_sales/domain/models.dart';
import 'package:kaibao_sales/services/invoice_pdf.dart';

Sale sample(int rows, {String code = 'KB56-34'}) => Sale(id: 1, number: 'XS202611050001', date: '2026-11-05',
  customerId: 1, customerName: '许德新', customerPhone: '', customerAddress: '',
  subtotalCents: 144936 * rows, discountCents: 36, priorDueCents: 0,
  receivedCents: 0, status: 'confirmed', note: '',
  lines: List.generate(rows, (_) => SaleLine(code: code,
    lengthMilli: 37000, widthMilli: 2800, unitPriceCents: 1399)));

void main() {
  test('人民币大写使用分计算', () {
    expect(InvoicePdf.chineseMoney(144900), '壹仟肆佰肆拾玖元整');
    expect(InvoicePdf.chineseMoney(0), '零元整');
    expect(InvoicePdf.chineseMoney(100000001), '壹佰万元零壹分');
    expect(InvoicePdf.chineseMoney(101010), '壹仟零壹拾元壹角');
  });
  testWidgets('长文本附页不截断；实物退货与资金退款分开', (tester) async {
    await tester.runAsync(() async {
      final text = List.generate(70, (i) => '字段内容第${i + 1}段').join();
      final sale = Sale(id: 1, number: 'XS202611170001', date: '2026-11-17',
        customerId: 1, customerName: '客户', customerPhone: '', customerAddress: '',
        subtotalCents: 1000, discountCents: 0, priorDueCents: 0, receivedCents: 1000,
        status: 'confirmed', note: text, returnedLengthMilli: 2000, returnedAreaMicro: 2000000,
        lines: const [SaleLine(code: 'X', lengthMilli: 1000, widthMilli: 1000, unitPriceCents: 1000)]);
      final lines = InvoicePdf.continuationLines(sale);
      final start = lines.indexOf('单据备注（完整）');
      final end = lines.indexWhere((item) => item.startsWith('累计实物退货'));
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      expect(lines.sublist(start + 1, end).join(), '单据备注：$text');
      expect(lines.skip(end + 1).join(), contains('2.000 米 / 2.000000 ㎡'));
      final pages = await InvoicePdf.images(sale);
      expect(pages.length, greaterThan(1));
      final codec = await ui.instantiateImageCodec(pages.last);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 2160);
      frame.image.dispose();
      codec.dispose();
      expect((await InvoicePdf.bytes(sale)).length, greaterThan(0));
    });
  });
  testWidgets('生成可解码的图片并按明细分页', (tester) async {
    await tester.runAsync(() async {
    final pages = await InvoicePdf.images(sample(10));
    expect(pages, hasLength(2));
    final codec = await ui.instantiateImageCodec(pages.first);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 2160);
    expect(frame.image.height, 1520);
    frame.image.dispose();
    codec.dispose();
    expect(await InvoicePdf.images(sample(1)), hasLength(1));
    final longModel = (await InvoicePdf.images(sample(1, code: 'ACCEPTANCE-FABRIC'))).first;
    final dir = Directory('build/third-ui-evidence');
    await dir.create(recursive: true);
    await File('${dir.path}/long-model.png').writeAsBytes(longModel);

    });
  });
}
