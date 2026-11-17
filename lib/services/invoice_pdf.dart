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
    for (final png in await images(sale)) {
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

  /// Each image contains at most nine product rows; totals appear on the last page.
  static Future<List<Uint8List>> images(Sale sale) async {
    const pageItems = 9;
    final mainPages = (sale.lines.length / pageItems).ceil().clamp(1, 1 << 30);
    final continuation = continuationLines(sale);
    const continuationPageItems = 24;
    final extraPages = (continuation.length / continuationPageItems).ceil();
    return [
      for (var page = 0; page < mainPages; page++)
        await _pagePng(sale, page, mainPages, pageItems, mainPages + extraPages),
      for (var page = 0; page < extraPages; page++)
        await _continuationPng(sale, continuation.skip(page * continuationPageItems).take(continuationPageItems).toList(),
          mainPages + page + 1, mainPages + extraPages),
    ];
  }

  static Future<void> printInvoice(Sale sale) async {
    final data = await bytes(sale);
    await Printing.layoutPdf(onLayout: (_) async => data);
  }

  static Future<void> shareInvoice(Sale sale) async {
    final data = await bytes(sale);
    await Printing.sharePdf(bytes: data, filename: '${sale.number}-v${sale.revision}.pdf');
  }

  static Future<Uint8List> _pagePng(Sale sale, int page, int pages, int pageItems, int totalPages) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(2.0);
    canvas.drawRect(const Rect.fromLTWH(0, 0, _width, _height), Paint()..color = Colors.white);
    _text(canvas, '凯堡软装销售出库单', 0, 28, _width,
      fontSize: 29, center: true);
    _text(canvas, 'NO.${sale.number} · 版本 ${sale.revision}', 24, 89, 730, fontSize: 17);
    _text(canvas, '客户：${sale.customerName}', 24, 121, 560, fontSize: 17);
    _text(canvas, '销售日期：${sale.date}', 735, 121, 315, fontSize: 17);
    if (totalPages > 1) _text(canvas, '第 ${page + 1} / $totalPages 页', 896, 92, 150, fontSize: 13);

    const top = 155.0;
    const headerH = 36.0;
    const rowH = 36.0;
    final start = page * pageItems;
    final end = (start + pageItems < sale.lines.length) ? start + pageItems : sale.lines.length;
    _gridLine(canvas, top);
    _gridLine(canvas, top + headerH);
    for (var j = 0; j < _headers.length; j++) {
      _cellText(canvas, _headers[j], j, top + 8);
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
        _cellText(canvas, values[j], j, y + 8);
      }
      _gridLine(canvas, y + rowH);
    }
    final tableBottom = top + headerH + (end - start) * rowH;
    final lastPage = page == pages - 1;
    final gridBottom = tableBottom + (lastPage ? rowH : 0);
    if (lastPage) {
      final length = sale.lines.fold<int>(0, (sum, line) => sum + line.lengthMilli);
      final area = sale.lines.fold<int>(0, (sum, line) => sum + line.areaMicro);
      final totals = ['', '合计', '', Fixed.format(length, decimals: 3, trim: true),
        '', Fixed.format(area, decimals: 6, trim: true), '',
        Fixed.format(sale.subtotalCents, decimals: 2), ''];
      for (var j = 0; j < totals.length; j++) {
        _cellText(canvas, totals[j], j, tableBottom + 8);
      }
      _gridLine(canvas, gridBottom);
    }
    for (final x in _columns) {
      canvas.drawLine(Offset(x, top), Offset(x, gridBottom),
        Paint()..color = _ink..strokeWidth = 1.0);
    }
    if (lastPage) {
      final y = gridBottom;
      _line(canvas, 24, y, 24, y + 72);
      _line(canvas, 1056, y, 1056, y + 72);
      _gridLine(canvas, y + 36);
      _gridLine(canvas, y + 72);
      _text(canvas, '优惠金额：${Fixed.format(sale.discountCents, decimals: 2)}  '
        '产品合计：${Fixed.format(sale.subtotalCents, decimals: 2)}  '
        '送货金额：${Fixed.format(sale.subtotalCents, decimals: 2)}',
        28, y + 8, 510, fontSize: 15);
      _text(canvas, '合同金额：${chineseMoney(sale.payableCents)} ${Fixed.format(sale.payableCents, decimals: 2)}',
        540, y + 8, 510, fontSize: 15);
      _text(canvas, '现金已收：${Fixed.format(sale.receivedCents, decimals: 2)}  '
        '已转余额：${Fixed.format(sale.transferredCents, decimals: 2)}  '
        '净退款：${Fixed.format(sale.refundedCents, decimals: 2)}  '
        '余额抵扣：${Fixed.format(sale.creditAppliedCents, decimals: 2)}  '
        '未收款：${Fixed.format(sale.currentDueCents, decimals: 2)}',
        28, y + 40, 1020, fontSize: 13);
      _text(canvas,
        '上期欠款：${Fixed.format(sale.priorDueCents, decimals: 2)}  '
        '累计欠款：${Fixed.format(sale.cumulativeDueCents, decimals: 2)}  '
        '超收待处理：${Fixed.format(sale.overpaidCents, decimals: 2)}',
        28, y + 56, 1020, fontSize: 13);
      _text(canvas, '订货电话：0575-88039929', 24, y + 78, 520, fontSize: 15);
      _text(canvas, '制单人：_________', 716, y + 78, 330, fontSize: 15);
      _text(canvas, '订货地址：${sale.customerAddress}', 24, y + 104, 670, fontSize: 15);
      _text(canvas, '收货人（签字）：_________', 716, y + 104, 330, fontSize: 15);
      _text(canvas, '用户须知：施工前请先核对型号，检查产品，先试贴一面墙，如有问题联系公司，',
        24, y + 130, 1030, fontSize: 15);
      _text(canvas, '不检查不核对，公司概不负责退换，感谢你的惠顾，凯堡软装竭诚为您服务；祝你生意兴隆，财源广进。',
        24, y + 154, 1030, fontSize: 15);
      if (sale.note.isNotEmpty) {
        _text(canvas, '单据备注：${sale.note}', 24, y + 180, 1030, fontSize: 14);
      }
    } else {
      _text(canvas, '续下页', 25, tableBottom + 15, 200, fontSize: 16);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage((_width * 2).toInt(), (_height * 2).toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw StateError('PDF 页渲染失败');
    return data.buffer.asUint8List();
  }

  // The compact original form stays intact. Full-text continuation sheets are
  // appended whenever a field would be clipped, or stock returns exist.
  static bool _fits(String text, double width, double fontSize, int maxLines) {
    final painter = TextPainter(text: TextSpan(text: text, style: TextStyle(fontSize: fontSize)),
      textDirection: TextDirection.ltr, maxLines: maxLines, ellipsis: '…')..layout(maxWidth: width);
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    return fits;
  }

  static List<String> continuationLines(Sale sale) {
    final rows = <String>[];
    void full(String label, String value) {
      rows.add(label);
      // Preserve line boundaries and Unicode code points. Fit each emitted row
      // against the same rendering width; never apply ellipsis to source text.
      for (final paragraph in value.split('\n')) {
        final runes = paragraph.runes.toList();
        if (runes.isEmpty) { rows.add(''); continue; }
        var start = 0;
        while (start < runes.length) {
          var end = (start + 48).clamp(start + 1, runes.length);
          var part = String.fromCharCodes(runes.sublist(start, end));
          while (!_fits(part, 1020, 16, 1) && end > start + 1) {
            end--;
            part = String.fromCharCodes(runes.sublist(start, end));
          }
          rows.add(part);
          start = end;
        }
      }
    }
    void check(String label, String value, double width, double font, int maxLines) {
      if (!_fits(value, width, font, maxLines) || value.contains('\n')) full(label, value);
    }
    check('客户姓名（完整）', '客户：${sale.customerName}', 560, 17, 1);
    if (sale.customerPhone.isNotEmpty) full('客户电话', sale.customerPhone);
    check('收货地址（完整）', '订货地址：${sale.customerAddress}', 670, 15, 1);
    check('单据备注（完整）', '单据备注：${sale.note}', 1030, 14, 1);
    for (var i = 0; i < sale.lines.length; i++) {
      final line = sale.lines[i];
      for (final item in [(1, '型号', line.code), (2, '规格', line.specification), (8, '备注', line.note)]) {
        final width = _columns[item.$1 + 1] - _columns[item.$1] - 6;
        final wrap = !_fits(item.$3, width, 15, 1);
        check('第 ${i + 1} 行 ${item.$2}（完整）', item.$3, width, wrap ? 11 : 15, wrap ? 2 : 1);
      }
    }
    if (sale.returnedLengthMilli != 0 || sale.returnedAreaMicro != 0) {
      full('累计实物退货（按此单据版本的读取时点；独立于资金退款）',
        '${Fixed.format(sale.returnedLengthMilli, decimals: 3)} 米 / '
        '${Fixed.format(sale.returnedAreaMicro, decimals: 6)} ㎡');
    }
    return rows;
  }

  static Future<Uint8List> _continuationPng(Sale sale, List<String> rows, int page, int pages) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(2.0);
    canvas.drawRect(const Rect.fromLTWH(0, 0, _width, _height), Paint()..color = Colors.white);
    _text(canvas, '凯堡软装销售单 · 附页', 24, 30, 1030, fontSize: 26, center: true);
    _text(canvas, 'NO.${sale.number} · 版本 ${sale.revision} · 第 $page / $pages 页',
      24, 80, 1030, fontSize: 17);
    for (var i = 0; i < rows.length; i++) {
      _text(canvas, rows[i], 24, 115 + i * 25.0, 1020, fontSize: 16);
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage((_width * 2).toInt(), (_height * 2).toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose(); picture.dispose();
    if (data == null) throw StateError('单据附页渲染失败');
    return data.buffer.asUint8List();
  }

  /// Chinese uppercase RMB, calculated from integer fen.
  static String chineseMoney(int cents) {
    if (cents == 0) return '零元整';
    const digits = '零壹贰叁肆伍陆柒捌玖';
    const smallUnits = ['', '拾', '佰', '仟'];
    const groupUnits = ['', '万', '亿', '万亿'];
    var yuan = cents ~/ 100;
    final groups = <int>[];
    while (yuan > 0) { groups.add(yuan % 10000); yuan ~/= 10000; }
    if (groups.length > groupUnits.length) return '${Fixed.format(cents, decimals: 2)}元';
    final out = StringBuffer();
    var zeroBetween = false;
    for (var g = groups.length - 1; g >= 0; g--) {
      final group = groups[g];
      if (group == 0) { if (out.isNotEmpty) zeroBetween = true; continue; }
      if (out.isNotEmpty && (zeroBetween || group < 1000)) out.write('零');
      var pendingZero = false;
      for (var i = 3; i >= 0; i--) {
        final divisor = [1, 10, 100, 1000][i];
        final digit = (group ~/ divisor) % 10;
        if (digit == 0) { if (out.isNotEmpty) pendingZero = true; continue; }
        if (pendingZero && !out.toString().endsWith('零')) out.write('零');
        out.write(digits[digit]);
        out.write(smallUnits[i]);
        pendingZero = false;
      }
      out.write(groupUnits[g]);
      zeroBetween = false;
    }
    if (groups.isNotEmpty) out.write('元');
    final jiao = (cents ~/ 10) % 10;
    final fen = cents % 10;
    if (jiao == 0 && fen == 0) { out.write('整'); }
    else {
      if (jiao > 0) out.write('${digits[jiao]}角');
      if (fen > 0) {
        if (jiao == 0 && groups.isNotEmpty) out.write('零');
        out.write('${digits[fen]}分');
      }
    }
    return out.toString();
  }

  static void _gridLine(Canvas canvas, double y) => _line(canvas, 24, y, 1056, y);

  static void _line(Canvas canvas, double x1, double y1, double x2, double y2) {
    canvas.drawLine(Offset(x1, y1), Offset(x2, y2),
      Paint()..color = _ink..strokeWidth = 1.0);
  }

  static void _cellText(Canvas canvas, String text, int column, double y, {bool bold = false}) {
    final x1 = _columns[column];
    final x2 = _columns[column + 1];
    final measure = TextPainter(text: TextSpan(text: text,
      style: TextStyle(fontSize: 15, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
      textDirection: TextDirection.ltr)..layout();
    final wrap = [1, 2, 8].contains(column) && measure.width > x2 - x1 - 6;
    measure.dispose();
    _text(canvas, text, x1 + 3, y, x2 - x1 - 6,
      fontSize: wrap ? 11 : 15, center: true, bold: bold, maxLines: wrap ? 2 : 1);
  }

  static void _text(Canvas canvas, String value, double x, double y, double maxWidth,
      {double fontSize = 16, bool bold = false, bool center = false, int maxLines = 1}) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: TextStyle(color: _ink,
        fontSize: fontSize, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
      textDirection: TextDirection.ltr,
      textAlign: center ? TextAlign.center : TextAlign.left,
      maxLines: maxLines, ellipsis: '…',
    );
    painter.layout(minWidth: center ? maxWidth : 0, maxWidth: maxWidth);
    painter.paint(canvas, Offset(x, y));
    painter.dispose();
  }
}
