import 'safe_int.dart';

/// Business values are stored as scaled integers, never binary floating-point.
/// Yuan values use 2 digits (fen); lengths and widths use 3 (millimetres).
class Fixed {
  static int parse(String input, {required int decimals}) {
    if (decimals < 0 || decimals > 18) throw ArgumentError('小数精度无效');
    final text = input.trim();
    if (text.length > 128) throw const FormatException('输入数值过长');
    if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(text)) {
      throw FormatException('请输入非负数字');
    }
    final parts = text.split('.');
    final fractional = parts.length == 2 ? parts[1] : '';
    if (fractional.length > decimals) {
      throw FormatException('小数最多 $decimals 位');
    }
    final value = BigInt.parse(parts[0]) * BigInt.from(10).pow(decimals) +
        (fractional.isEmpty ? BigInt.zero : BigInt.parse(fractional.padRight(decimals, '0')));
    if (value > SafeInt.max) throw const FormatException('输入数值超过安全范围');
    return value.toInt();
  }

  static String format(int value, {required int decimals, bool trim = false}) {
    final sign = value < 0 ? '-' : '';
    final absValue = BigInt.from(value).abs();
    final scale = BigInt.from(_pow10(decimals));
    if (decimals == 0) return '$sign$absValue';
    var fractional = (absValue % scale).toString().padLeft(decimals, '0');
    if (trim) fractional = fractional.replaceFirst(RegExp(r'0+$'), '');
    return '$sign${absValue ~/ scale}${fractional.isEmpty ? '' : '.$fractional'}';
  }

  static int roundDiv(int dividend, int divisor) {
    if (divisor <= 0 || dividend < 0) throw ArgumentError('invalid positive division');
    return SafeInt.checked((BigInt.from(dividend) * BigInt.two + BigInt.from(divisor)) ~/ (BigInt.from(divisor) * BigInt.two));
  }

  static int _pow10(int n) {
    var result = 1;
    for (var i = 0; i < n; i++) { result *= 10; }
    return result;
  }
}

class BillingMath {
  /// Length mm * width mm => area in millionths of a square metre.
  static int areaMicro(int lengthMilli, int widthMilli) {
    if (lengthMilli <= 0 || widthMilli <= 0) {
      throw ArgumentError('米数和门幅必须大于 0');
    }
    return SafeInt.checked(BigInt.from(lengthMilli) * BigInt.from(widthMilli), label: '面积');
  }

  /// Unit price is yuan / square metre, represented in cents.
  /// Round HALF UP per line, THEN sum line amounts.
  static int lineCents(int lengthMilli, int widthMilli, int priceCents) {
    if (priceCents < 0) throw ArgumentError('单价不得为负数');
    final numerator = BigInt.from(areaMicro(lengthMilli, widthMilli)) * BigInt.from(priceCents);
    return SafeInt.checked((numerator * BigInt.two + BigInt.from(1000000)) ~/ BigInt.from(2000000), label: '行金额');
  }

  static int payable(int subtotalCents, int discountCents) {
    if (discountCents < 0 || discountCents > subtotalCents) {
      throw ArgumentError('优惠不能为负数或超过货款');
    }
    return subtotalCents - discountCents;
  }
}
