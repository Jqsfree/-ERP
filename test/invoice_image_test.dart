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
    final longModel = (await InvoicePdf.images(sample(1, code: 'ACCEPTANCE-FABRIC'))).single;
    final dir = Directory('build/third-ui-evidence');
    await dir.create(recursive: true);
    await File('${dir.path}/long-model.png').writeAsBytes(longModel);

    });
  });
}
