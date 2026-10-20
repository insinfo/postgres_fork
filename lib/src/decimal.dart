import 'pg_values.dart';

/// Modo de arredondamento de [PgDecimal.round], [PgDecimal.divide] e
/// [PgDecimal.rescale].
enum PgRoundingMode {
  /// Metade para longe do zero (1,5 → 2; -1,5 → -2), como o `round` e a
  /// divisão do PostgreSQL. É o padrão.
  halfAwayFromZero,

  /// Metade para o par mais próximo (1,5 → 2; 2,5 → 2).
  halfEven,

  /// Descarta os dígitos (`trunc` do PostgreSQL).
  towardZero,

  /// Para longe do zero sempre que houver dígitos descartados.
  awayFromZero,

  /// Para baixo (`floor`).
  floor,

  /// Para cima (`ceil`).
  ceiling,
}

/// Número decimal de precisão arbitrária, equivalente ao tipo `numeric` do
/// PostgreSQL (inclusive `NaN`, `Infinity` e `-Infinity`).
///
/// O valor é `unscaledValue × 10^-scale`. A escala (número de dígitos depois
/// da vírgula) é preservada como no PostgreSQL: `PgDecimal.parse('1.50')`
/// tem escala 2 e é impresso como `1.50`, mas é igual (`==`) a `1.5`.
///
/// As operações seguem o PostgreSQL:
/// - `+` e `-`: escala do resultado = maior escala dos operandos;
/// - `*`: soma das escalas;
/// - `/`: a mesma escala que o PostgreSQL escolhe (pelo menos 16 dígitos
///   significativos e não menos que a escala de cada operando), com
///   arredondamento [PgRoundingMode.halfAwayFromZero]; [divide] permite
///   escolher a escala e o arredondamento;
/// - `~/` e `%`: divisão inteira truncada e resto com o sinal do dividendo
///   (`div` e `%` do PostgreSQL);
/// - `NaN` é igual a `NaN` e maior que qualquer outro valor (inclusive
///   `Infinity`), como na ordenação do PostgreSQL; operações com `NaN`
///   resultam em `NaN`; `Infinity - Infinity` e `0 * Infinity` são `NaN`.
///
/// Divisão por zero lança [UnsupportedError].
final class PgDecimal implements Comparable<PgDecimal>, PostgresTextEncodable {
  static const _finite = 0;
  static const _nan = 1;
  static const _posInf = 2;
  static const _negInf = 3;

  /// Maior escala que o PostgreSQL aceita (`NUMERIC_DSCALE_MAX`).
  static const maxScale = 0x3FFF;

  final int _kind;
  final BigInt _unscaled;
  final int _scale;

  PgDecimal._(this._kind, this._unscaled, this._scale);

  PgDecimal._finiteValue(this._unscaled, this._scale) : _kind = _finite;

  static final zero = PgDecimal._finiteValue(BigInt.zero, 0);
  static final one = PgDecimal._finiteValue(BigInt.one, 0);
  static final nan = PgDecimal._(_nan, BigInt.zero, 0);
  static final infinity = PgDecimal._(_posInf, BigInt.zero, 0);
  static final negativeInfinity = PgDecimal._(_negInf, BigInt.zero, 0);

  /// `unscaledValue × 10^-scale`. [scale] não pode ser negativa.
  factory PgDecimal.fromBigInt(BigInt unscaledValue, {int scale = 0}) {
    if (scale < 0) {
      throw ArgumentError.value(scale, 'scale', 'Must not be negative');
    }
    return PgDecimal._finiteValue(unscaledValue, scale);
  }

  /// Valor inteiro (escala 0).
  factory PgDecimal.fromInt(int value) =>
      PgDecimal._finiteValue(BigInt.from(value), 0);

  /// O valor decimal mais curto que representa [value] (o mesmo de
  /// `value.toString()`): `PgDecimal.fromDouble(0.1)` é `0.1`.
  factory PgDecimal.fromDouble(double value) {
    if (value.isNaN) return nan;
    if (value.isInfinite) return value.isNegative ? negativeInfinity : infinity;
    return PgDecimal.parse(value.toString());
  }

  /// Lê um número no formato de entrada do `numeric` do PostgreSQL: sinal
  /// opcional, dígitos com ponto decimal opcional e expoente opcional
  /// (`1.5e-3`), ou `NaN`, `Infinity`, `-Infinity`, `inf`, `-inf`
  /// (maiúsculas ou minúsculas). Espaços nas pontas são ignorados.
  ///
  /// Lança [FormatException] se o texto não for um número.
  factory PgDecimal.parse(String source) {
    final result = tryParse(source);
    if (result == null) {
      throw FormatException('Invalid numeric value', source);
    }
    return result;
  }

  /// Como [PgDecimal.parse], mas devolve `null` se o texto não for um número.
  static PgDecimal? tryParse(String source) {
    final text = source.trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    switch (lower) {
      case 'nan':
        return nan;
      case 'infinity':
      case '+infinity':
      case 'inf':
      case '+inf':
        return infinity;
      case '-infinity':
      case '-inf':
        return negativeInfinity;
    }

    var i = 0;
    var negative = false;
    final first = text.codeUnitAt(0);
    if (first == 0x2B || first == 0x2D) {
      negative = first == 0x2D;
      i++;
    }
    final digits = StringBuffer();
    var fractionDigits = 0;
    var seenPoint = false;
    var anyDigit = false;
    for (; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        digits.writeCharCode(c);
        anyDigit = true;
        if (seenPoint) fractionDigits++;
      } else if (c == 0x2E && !seenPoint) {
        seenPoint = true;
      } else {
        break;
      }
    }
    if (!anyDigit) return null;

    var exponent = 0;
    if (i < text.length) {
      final c = text.codeUnitAt(i);
      if (c != 0x65 && c != 0x45) return null; // e / E
      i++;
      var expNegative = false;
      if (i < text.length) {
        final s = text.codeUnitAt(i);
        if (s == 0x2B || s == 0x2D) {
          expNegative = s == 0x2D;
          i++;
        }
      }
      final start = i;
      for (; i < text.length; i++) {
        final c = text.codeUnitAt(i);
        if (c < 0x30 || c > 0x39) return null;
      }
      if (i == start || i - start > 9) return null;
      exponent = int.parse(text.substring(start, i));
      if (exponent > 1000000) return null;
      if (expNegative) exponent = -exponent;
    }

    var unscaled = BigInt.parse(digits.toString());
    if (negative) unscaled = -unscaled;
    // Escala como no PostgreSQL: dígitos depois do ponto menos o expoente.
    final scale = fractionDigits - exponent;
    if (scale >= 0) return PgDecimal._finiteValue(unscaled, scale);
    return PgDecimal._finiteValue(unscaled * _pow10(-scale), 0);
  }

  /// Se é `NaN`.
  bool get isNaN => _kind == _nan;

  /// Se é `Infinity` ou `-Infinity`.
  bool get isInfinite => _kind == _posInf || _kind == _negInf;

  /// Se não é `NaN` nem infinito.
  bool get isFinite => _kind == _finite;

  /// Se é menor que zero (inclusive `-Infinity`).
  bool get isNegative =>
      _kind == _negInf || (_kind == _finite && _unscaled.isNegative);

  /// Se é zero (com qualquer escala).
  bool get isZero => _kind == _finite && _unscaled == BigInt.zero;

  /// -1, 0 ou 1 (`NaN` → 0).
  int get sign => switch (_kind) {
        _posInf => 1,
        _negInf => -1,
        _nan => 0,
        _ => _unscaled.sign,
      };

  /// Número de dígitos depois da vírgula (0 para valores não finitos).
  int get scale => _scale;

  /// O valor sem a vírgula: `this == unscaledValue × 10^-scale`.
  ///
  /// Lança [UnsupportedError] para valores não finitos.
  BigInt get unscaledValue {
    _requireFinite('unscaledValue');
    return _unscaled;
  }

  /// Número de dígitos significativos (sem zeros à esquerda; zero → 1).
  int get precision {
    _requireFinite('precision');
    if (_unscaled == BigInt.zero) return 1;
    return _unscaled.abs().toString().length;
  }

  void _requireFinite(String operation) {
    if (_kind != _finite) {
      throw UnsupportedError('$operation of ${toString()}');
    }
  }

  static final _bigTen = BigInt.from(10);
  static final List<BigInt> _pow10Cache =
      List.generate(40, (i) => BigInt.from(10).pow(i));

  static BigInt _pow10(int n) =>
      n < _pow10Cache.length ? _pow10Cache[n] : _bigTen.pow(n);

  /// [unscaled] (na escala [from]) convertido para a escala [to] >= [from].
  static BigInt _upscale(BigInt unscaled, int from, int to) =>
      to == from ? unscaled : unscaled * _pow10(to - from);

  /// Divide [numerator] por [denominator] arredondando conforme [mode].
  static BigInt _divRound(
      BigInt numerator, BigInt denominator, PgRoundingMode mode) {
    final negative = numerator.isNegative != denominator.isNegative;
    final n = numerator.abs();
    final d = denominator.abs();
    var q = n ~/ d;
    final r = n - q * d;
    if (r != BigInt.zero) {
      final bool increment;
      switch (mode) {
        case PgRoundingMode.towardZero:
          increment = false;
        case PgRoundingMode.awayFromZero:
          increment = true;
        case PgRoundingMode.floor:
          increment = negative;
        case PgRoundingMode.ceiling:
          increment = !negative;
        case PgRoundingMode.halfAwayFromZero:
          increment = (r * BigInt.two).compareTo(d) >= 0;
        case PgRoundingMode.halfEven:
          final cmp = (r * BigInt.two).compareTo(d);
          increment = cmp > 0 || (cmp == 0 && q.isOdd);
      }
      if (increment) q += BigInt.one;
    }
    return negative ? -q : q;
  }

  /// O valor arredondado para [scale] dígitos depois da vírgula (como
  /// `round(x, scale)` do PostgreSQL). [scale] pode ser negativa: `round(-1)`
  /// arredonda para dezenas e o resultado tem escala 0. A escala do
  /// resultado é `max(scale, 0)`, mesmo que maior que a atual
  /// (`round(1.5, 3)` → `1.500`). Valores não finitos são devolvidos como
  /// estão.
  PgDecimal round(
          [int scale = 0,
          PgRoundingMode mode = PgRoundingMode.halfAwayFromZero]) =>
      rescale(scale, mode);

  /// Como [round], com [PgRoundingMode.towardZero] (`trunc` do PostgreSQL).
  PgDecimal truncate([int scale = 0]) =>
      rescale(scale, PgRoundingMode.towardZero);

  /// Maior inteiro menor ou igual a este valor (escala 0).
  PgDecimal floor() => rescale(0, PgRoundingMode.floor);

  /// Menor inteiro maior ou igual a este valor (escala 0).
  PgDecimal ceil() => rescale(0, PgRoundingMode.ceiling);

  /// O valor com exatamente [scale] dígitos depois da vírgula (ver [round]).
  PgDecimal rescale(int scale,
      [PgRoundingMode mode = PgRoundingMode.halfAwayFromZero]) {
    if (_kind != _finite) return this;
    if (scale >= _scale) {
      return PgDecimal._finiteValue(_upscale(_unscaled, _scale, scale), scale);
    }
    final rounded = _divRound(_unscaled, _pow10(_scale - scale), mode);
    if (scale >= 0) return PgDecimal._finiteValue(rounded, scale);
    return PgDecimal._finiteValue(rounded * _pow10(-scale), 0);
  }

  PgDecimal operator -() => switch (_kind) {
        _posInf => negativeInfinity,
        _negInf => infinity,
        _nan => this,
        _ => PgDecimal._finiteValue(-_unscaled, _scale),
      };

  /// Valor absoluto.
  PgDecimal abs() => isNegative ? -this : this;

  PgDecimal operator +(PgDecimal other) {
    if (_kind != _finite || other._kind != _finite) {
      if (_kind == _nan || other._kind == _nan) return nan;
      if (_kind == _finite) return other;
      if (other._kind == _finite) return this;
      return _kind == other._kind ? this : nan;
    }
    final scale = _scale > other._scale ? _scale : other._scale;
    return PgDecimal._finiteValue(
        _upscale(_unscaled, _scale, scale) +
            _upscale(other._unscaled, other._scale, scale),
        scale);
  }

  PgDecimal operator -(PgDecimal other) => this + (-other);

  PgDecimal operator *(PgDecimal other) {
    if (_kind != _finite || other._kind != _finite) {
      if (_kind == _nan || other._kind == _nan) return nan;
      final s = sign * other.sign;
      if (s == 0) return nan; // 0 * Infinity
      return s > 0 ? infinity : negativeInfinity;
    }
    final result =
        PgDecimal._finiteValue(_unscaled * other._unscaled, _scale + other._scale);
    return result._scale > maxScale ? result.rescale(maxScale) : result;
  }

  /// Divisão com a escala escolhida pelo PostgreSQL (ver a documentação da
  /// classe). Use [divide] para escolher a escala.
  PgDecimal operator /(PgDecimal other) {
    final special = _divideSpecial(other);
    if (special != null) return special;
    final scale = _divisionScale(other);
    return PgDecimal._finiteValue(
        _divideUnscaled(other, scale, PgRoundingMode.halfAwayFromZero), scale);
  }

  /// Divisão com [scale] dígitos depois da vírgula, arredondada conforme
  /// [mode].
  PgDecimal divide(PgDecimal other,
      {required int scale,
      PgRoundingMode mode = PgRoundingMode.halfAwayFromZero}) {
    final special = _divideSpecial(other);
    if (special != null) return special;
    // Um único arredondamento, também para escala negativa.
    final rounded = _divideUnscaled(other, scale, mode);
    if (scale >= 0) return PgDecimal._finiteValue(rounded, scale);
    return PgDecimal._finiteValue(rounded * _pow10(-scale), 0);
  }

  /// Divisão inteira truncada em direção a zero (`div` do PostgreSQL).
  PgDecimal operator ~/(PgDecimal other) {
    final special = _divideSpecial(other);
    if (special != null) return special;
    return PgDecimal._finiteValue(
        _divideUnscaled(other, 0, PgRoundingMode.towardZero), 0);
  }

  /// Resto da divisão truncada, com o sinal do dividendo (`%` do
  /// PostgreSQL). A escala é a maior dos operandos.
  PgDecimal operator %(PgDecimal other) {
    if (_kind == _nan || other._kind == _nan) return nan;
    if (_kind != _finite) return nan;
    if (other._kind != _finite) return this;
    if (other._unscaled == BigInt.zero) {
      throw UnsupportedError('Division by zero');
    }
    final scale = _scale > other._scale ? _scale : other._scale;
    final a = _upscale(_unscaled, _scale, scale);
    final b = _upscale(other._unscaled, other._scale, scale);
    return PgDecimal._finiteValue(a.remainder(b), scale);
  }

  /// Resultado da divisão quando um dos operandos não é finito ou o divisor
  /// é zero; `null` se os dois são finitos e o divisor não é zero.
  PgDecimal? _divideSpecial(PgDecimal other) {
    if (_kind == _nan || other._kind == _nan) return nan;
    if (_kind != _finite) {
      if (other._kind != _finite) return nan; // Infinity / Infinity
      final s = other.sign;
      if (s == 0) throw UnsupportedError('Division by zero');
      return (sign * s) > 0 ? infinity : negativeInfinity;
    }
    if (other._kind != _finite) return zero;
    if (other._unscaled == BigInt.zero) {
      throw UnsupportedError('Division by zero');
    }
    return null;
  }

  /// `this / other × 10^scale`, arredondado ([scale] pode ser negativa).
  BigInt _divideUnscaled(PgDecimal other, int scale, PgRoundingMode mode) {
    // resultado × 10^scale = a × 10^(scale + sb - sa) / b
    final k = scale + other._scale - _scale;
    final BigInt numerator;
    final BigInt denominator;
    if (k >= 0) {
      numerator = _unscaled * _pow10(k);
      denominator = other._unscaled;
    } else {
      numerator = _unscaled;
      denominator = other._unscaled * _pow10(-k);
    }
    return _divRound(numerator, denominator, mode);
  }

  /// Escala da divisão escolhida pelo PostgreSQL (`select_div_scale` em
  /// `numeric.c`): pelo menos 16 dígitos significativos, não menos que a
  /// escala de cada operando, no máximo 1000.
  int _divisionScale(PgDecimal other) {
    final (weight1, first1) = _nbaseWeightAndFirstDigit();
    final (weight2, first2) = other._nbaseWeightAndFirstDigit();
    var qweight = weight1 - weight2;
    if (first1 <= first2) qweight--;
    var scale = 16 - qweight * 4;
    if (scale < _scale) scale = _scale;
    if (scale < other._scale) scale = other._scale;
    if (scale < 0) scale = 0;
    if (scale > 1000) scale = 1000;
    return scale;
  }

  /// Peso e primeiro dígito na base 10000 usada internamente pelo
  /// PostgreSQL (valor = d0 × 10000^peso + ...).
  (int, int) _nbaseWeightAndFirstDigit() {
    if (_unscaled == BigInt.zero) return (0, 0);
    final scale4 = (_scale + 3) ~/ 4 * 4;
    final text = _upscale(_unscaled.abs(), _scale, scale4).toString();
    final length = text.length;
    final firstLength = (length - 1) % 4 + 1;
    return (
      (length - 1) ~/ 4 - scale4 ~/ 4,
      int.parse(text.substring(0, firstLength))
    );
  }

  /// Compara como o PostgreSQL: `-Infinity` < finitos < `Infinity` < `NaN`.
  @override
  int compareTo(PgDecimal other) {
    if (_kind != _finite || other._kind != _finite) {
      return _rank.compareTo(other._rank);
    }
    if (_scale == other._scale) return _unscaled.compareTo(other._unscaled);
    final scale = _scale > other._scale ? _scale : other._scale;
    return _upscale(_unscaled, _scale, scale)
        .compareTo(_upscale(other._unscaled, other._scale, scale));
  }

  int get _rank => switch (_kind) {
        _negInf => 0,
        _finite => 1,
        _posInf => 2,
        _ => 3,
      };

  bool operator <(PgDecimal other) => compareTo(other) < 0;
  bool operator <=(PgDecimal other) => compareTo(other) <= 0;
  bool operator >(PgDecimal other) => compareTo(other) > 0;
  bool operator >=(PgDecimal other) => compareTo(other) >= 0;

  /// Igualdade numérica (`1.5 == 1.50`); `NaN == NaN`, como no PostgreSQL.
  @override
  bool operator ==(Object other) =>
      other is PgDecimal && compareTo(other) == 0;

  @override
  int get hashCode {
    if (_kind != _finite) return _kind.hashCode;
    var unscaled = _unscaled;
    var scale = _scale;
    while (scale > 0 && (unscaled % _bigTen) == BigInt.zero) {
      unscaled = unscaled ~/ _bigTen;
      scale--;
    }
    return Object.hash(unscaled, scale);
  }

  /// O valor como [double] (o mais próximo).
  double toDouble() => switch (_kind) {
        _nan => double.nan,
        _posInf => double.infinity,
        _negInf => double.negativeInfinity,
        _ => double.parse(toString()),
      };

  /// A parte inteira (truncada). Lança [UnsupportedError] para valores não
  /// finitos.
  BigInt toBigInt() {
    _requireFinite('toBigInt');
    return _scale == 0 ? _unscaled : _unscaled ~/ _pow10(_scale);
  }

  /// A parte inteira (truncada). Lança [UnsupportedError] para valores não
  /// finitos ou fora da faixa de [int].
  int toInt() {
    final value = toBigInt();
    if (!value.isValidInt) {
      throw UnsupportedError('$value does not fit in an int');
    }
    return value.toInt();
  }

  /// Texto no formato de saída do PostgreSQL: sem expoente e com exatamente
  /// [scale] dígitos depois da vírgula (`NaN`, `Infinity`, `-Infinity` para
  /// os valores especiais).
  @override
  String toString() {
    switch (_kind) {
      case _nan:
        return 'NaN';
      case _posInf:
        return 'Infinity';
      case _negInf:
        return '-Infinity';
    }
    final digits = _unscaled.abs().toString();
    final sign = _unscaled.isNegative ? '-' : '';
    if (_scale == 0) return '$sign$digits';
    if (digits.length > _scale) {
      final point = digits.length - _scale;
      return '$sign${digits.substring(0, point)}.${digits.substring(point)}';
    }
    return '${sign}0.${digits.padLeft(_scale, '0')}';
  }

  @override
  String toPostgresText() => toString();

  @override
  String? get postgresTypeName => 'numeric';
}
