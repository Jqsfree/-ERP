/// Reject overflow before narrowing a calculation to SQLite/Dart int64.
class SafeInt {
  static final max = BigInt.parse('9223372036854775807');
  static final min = -max - BigInt.one;
  static int checked(BigInt value, {String label = '数值'}) {
    if (value < min || value > max) throw ArgumentError('$label超过安全范围');
    return value.toInt();
  }
  static int add(int a, int b, {String label = '合计'}) =>
    checked(BigInt.from(a) + BigInt.from(b), label: label);
}
