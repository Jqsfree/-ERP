import "dart:typed_data";
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../domain/models.dart';
import '../domain/money.dart';

/// Renders Chinese using the Android system font before embedding each page as
/// a PNG in a standard A4 PDF. No runtime font download or network is needed.
class InvoicePdf {
  static const _width = 1080.0;
  static const _height = 760.0;
  static const _ink = Color(0xff111827);
  static const _columns = <double>[24, 72, 200, 322, 402, 516, 624, 734, 850, 1056];
  static const _headers = <String>['编号', '产品', '规格型号', '数量', '下单门幅', '总数量', '单价', '金额', '备注'];

  static Future<Uint8List> bytes(Sale sale) async {
    final document = pw.Document();
    const pageItems = 9;
    final pages = (sale.lines.length / pageItems).ceil();
    for (var page = 0; page < pages; page++) {
      final png = await _pagePng(sale, page, pages, pageItems);
      document.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Image(pw.MemoryImage(png),
          fit: pw.BoxFit.fill, width: PdfPageFormat.a4.landscape.width,
          height: PdfPageFormat.a4.landscape.height),
      ));
    }
    return document.save();
  }

  static Future<void> printInvoice(Sale sale) async {
    final data = await bytes(sale);
    await Printing.layoutPdf(onLayout: (_) async => data);
  }

  static Future<void> shareInvoice(Sale sale) async {
    final data = await bytes(sale);
    await Printing.sharePdf(bytes: data, filename: '${sale.number}.pdf');
  }

  static Future<Uint8List> _pagePng(Sale sale, int page, int pages, int pageItems) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(2.0);
    canvas.drawRect(const Rect.fromLTWH(0, 0, _width, _height), Paint()..color = Colors.white);
    _text(canvas, '凯堡软装销售出货单', 0, 28, _width,
      fontSize: 29, center: true, bold: true);
    _text(canvas, 'NO.${sale.number}', 24, 89, 500, fontSize: 17);
    _text(canvas, '客户：${sale.customerName}', 24, 121, 560, fontSize: 17);
    _text(canvas, '销售日期：${sale.date}', 735, 121, 315, fontSize: 17);
    _text(canvas, '第 ${page + 1} / $pages 页', 896, 92, 150, fontSize: 13);

    const top = 164.0;
    const headerH = 42.0;
    const rowH = 42.0;
    final start = page * pageItems;
    final end = (start + pageItems < sale.lines.length) ? start + pageItems : sale.lines.length;
    _gridLine(canvas, top);
    _gridLine(canvas, top + headerH);
    for (var j = 0; j < _headers.length; j++) {
      _cellText(canvas, _headers[j], j, top + 11, bold: true);
    }
    for (var i = start; i < end; i++) {
      final line = sale.lines[i];
      final y = top + headerH + (i - start) * rowH;
      final values = [
        '${i + 1}', line.code, line.specification,
        Fixed.format(line.lengthMilli, decimals: 3, trim: true),
        Fixed.format(line.widthMilli, decimals: 3, trim: true),
        line.areaText, Fixed.format(line.unitPriceCents, decimals: 2),
        Fixed.format(line.totalCents, decimals: 2), line.note,
      ];
      for (var j = 0; j < values.length; j++) {
        _cellText(canvas, values[j], j, y + 11);
      }
      _gridLine(canvas, y + rowH);
    }
    for (var c = 0; c < _columns.length; c++) {
      final x = _columns[c];
      canvas.drawLine(Offset(x, top), Offset(x, top + headerH + (end - start) * rowH),
        Paint()..color = _ink..strokeWidth = 1.0);
    }
    if (page == pages - 1) {
      const summaryY = 610.0;
      _line(canvas, 24, summaryY, 1056, summaryY);
      _text(canvas, '产品合计：¥${Fixed.format(sale.subtotalCents, decimals: 2)}'
        '    优惠：¥${Fixed.format(sale.discountCents, decimals: 2)}'
        '    合同金额：¥${Fixed.format(sale.payableCents, decimals: 2)}',
        26, summaryY + 10, 1020, fontSize: 17, bold: true);
      _text(canvas, '已收款：¥${Fixed.format(sale.receivedCents, decimals: 2)}'
        '    本单未收：¥${Fixed.format(sale.currentDueCents, decimals: 2)}'
        '    上期欠款：¥${Fixed.format(sale.priorDueCents, decimals: 2)}'
        '    累计欠款：¥${Fixed.format(sale.cumulativeDueCents, decimals: 2)}',
        26, summaryY + 45, 1020, fontSize: 15);
      _text(canvas, '订货地址：${sale.customerAddress}    客户电话：${sale.customerPhone}',
        26, summaryY + 82, 1000, fontSize: 15);
      _text(canvas, '制单人：_________      收货人（签字）：_________      单据备注：${sale.note}',
        26, summaryY + 116, 1010, fontSize: 14);
    } else {
      _text(canvas, '续下页', 25, 650, 200, fontSize: 16);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage((_width * 2).toInt(), (_height * 2).toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw StateError('PDF 页渲染失败');
    return data.buffer.asUint8List();
  }

  static void _gridLine(Canvas canvas, double y) => _line(canvas, 24, y, 1056, y);

  static void _line(Canvas canvas, double x1, double y1, double x2, double y2) {
    canvas.drawLine(Offset(x1, y1), Offset(x2, y2),
      Paint()..color = _ink..strokeWidth = 1.0);
  }

  static void _cellText(Canvas canvas, String text, int column, double y, {bool bold = false}) {
    final x1 = _columns[column];
    final x2 = _columns[column + 1];
    _text(canvas, text, x1 + 3, y, x2 - x1 - 6,
      fontSize: 15, center: true, bold: bold);
  }

  static void _text(Canvas canvas, String value, double x, double y, double maxWidth,
      {double fontSize = 16, bool bold = false, bool center = false}) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: TextStyle(color: _ink,
        fontSize: fontSize, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
      textDirection: TextDirection.ltr,
      textAlign: center ? TextAlign.center : TextAlign.left,
      maxLines: 1, ellipsis: '…',
    );
    painter.layout(minWidth: 0, maxWidth: maxWidth);
    painter.paint(canvas, Offset(x, y));
    painter.dispose();
  }
}
