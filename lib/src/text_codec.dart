import 'dart:convert';
import 'dart:typed_data';



import '../postgres.dart';
import 'v3/types.dart';

class PostgresTextEncoder extends Converter<Object, String> {
  const PostgresTextEncoder();

  @override
  String convert(dynamic input, {bool escapeStrings = true}) {
    if (input == null) {
      return 'null';
    }

    if (input is int) {
      return _encodeNumber(input, escapeStrings);
    }

    if (input is double) {
      return _encodeDouble(input, escapeStrings);
    }

    if (input is String) {
      return _encodeString(input, escapeStrings);
    }

    if (input is DateTime) {
      return _encodeDateTime(input, isDateOnly: false);
    }

    if (input is bool) {
      return _encodeBoolean(input);
    }

    if (input is Map) {
      return _encodeJSON(input, escapeStrings);
    }

    if (input is PgPoint) {
      // No SQL, '(1.5, 2)' sem aspas era lido como um record.
      final text = _encodePoint(input);
      return escapeStrings ? "'$text'::point" : text;
    }

    // Duration é o tipo Dart de interval (o decodificador o devolve).
    if (input is Duration) {
      return convert(PgInterval(microseconds: input.inMicroseconds),
          escapeStrings: escapeStrings);
    }

    // Tipos com codificação própria (PgInterval, PgTime, PgTimeTz, PgInet e
    // tipos definidos pela aplicação).
    if (input is PostgresTextEncodable) {
      final text = input.toPostgresText();
      if (!escapeStrings) return text;
      final literal = _encodeString(text, true);
      final type = input.postgresTypeName;
      return type == null ? literal : '$literal::$type';
    }

    // Uint8List é o tipo Dart de bytea (o decodificador devolve Uint8List):
    // codifica no formato hexadecimal de entrada do bytea.
    if (input is Uint8List) {
      final hex = StringBuffer(r'\x');
      for (final byte in input) {
        hex.write(byte.toRadixString(16).padLeft(2, '0'));
      }
      final text = hex.toString();
      return escapeStrings ? '${_encodeString(text, true)}::bytea' : text;
    }

    if (input is List) {
      // No SQL o literal do array precisa de aspas ('{1,2}'); sem elas era
      // um erro de sintaxe.
      final text = _encodeList(input);
      return escapeStrings ? _encodeString(text, true) : text;
    }

    throw PostgreSQLException("Could not infer type of value '$input'.");
  }

  String _encodeString(String text, bool escapeStrings) {
    if (!escapeStrings) {
      return text;
    }

    final backslashCodeUnit = r'\'.codeUnitAt(0);
    final quoteCodeUnit = r"'".codeUnitAt(0);

    var quoteCount = 0;
    var backslashCount = 0;
    final it = RuneIterator(text);
    while (it.moveNext()) {
      if (it.current == backslashCodeUnit) {
        backslashCount++;
      } else if (it.current == quoteCodeUnit) {
        quoteCount++;
      }
    }

    final buf = StringBuffer();

    if (backslashCount > 0) {
      buf.write(' E');
    }

    buf.write("'");

    if (quoteCount == 0 && backslashCount == 0) {
      buf.write(text);
    } else {
      for (final i in text.codeUnits) {
        if (i == quoteCodeUnit || i == backslashCodeUnit) {
          buf.writeCharCode(i);
          buf.writeCharCode(i);
        } else {
          buf.writeCharCode(i);
        }
      }
    }

    buf.write("'");

    return buf.toString();
  }

  /// [escapeStrings]: o valor vai no texto do SQL (protocolo simples). Fora
  /// dele (parâmetro ou elemento de array), NaN e infinito não levam aspas
  /// (antes o servidor recebia "'nan'" e recusava).
  String _encodeNumber(num value, [bool escapeStrings = true]) {
    if (value.isNaN) {
      return escapeStrings ? "'nan'" : 'NaN';
    }

    if (value.isInfinite) {
      if (!escapeStrings) return value.isNegative ? '-Infinity' : 'Infinity';
      return value.isNegative ? "'-infinity'" : "'infinity'";
    }

    return _sqlNumber(value.toInt().toString(), value.isNegative, escapeStrings);
  }

  String _encodeDouble(double value, [bool escapeStrings = true]) {
    if (value.isNaN) {
      return escapeStrings ? "'nan'" : 'NaN';
    }

    if (value.isInfinite) {
      if (!escapeStrings) return value.isNegative ? '-Infinity' : 'Infinity';
      return value.isNegative ? "'-infinity'" : "'infinity'";
    }

    if (escapeStrings && value == 0 && value.isNegative) {
      // (-0.0) no SQL seria o numeric 0 (sem sinal).
      return "'-0'::float8";
    }
    return _sqlNumber(value.toString(), value.isNegative, escapeStrings);
  }

  /// Um número negativo no texto do SQL fica entre parênteses: '5-@x' com
  /// x = -1 virava '5--1' (o resto da linha era um comentário) e '@x::int2'
  /// com -32768 virava '-(32768::int2)', fora do intervalo.
  static String _sqlNumber(String text, bool negative, bool escapeStrings) =>
      escapeStrings && negative ? '($text)' : text;

  String _encodeBoolean(bool value) {
    return value ? 'TRUE' : 'FALSE';
  }

  String _encodeDateTime(DateTime value, {bool isDateOnly = false}) {
    // Built from the fields: toIso8601String() of a TZDateTime (returned for
    // non-UTC zones) already ends with its offset, so appending one gave
    // '...-0300-03:00' and the server rejected it (22009).
    var string = _iso8601Fields(value);
    // DateTime counts years astronomically: year 0 is 1 BC, -1 is 2 BC.
    // Previously year 0 was sent as '0000' (rejected) and -1 as '0001 BC'.
    final bc = value.year <= 0;

    if (isDateOnly) {
      string = string.split('T').first;
    } else if (value.isUtc) {
      string = '${string}Z';
    } else {
      // The sign comes from the whole offset: -00:30 has zero hours.
      final offset = value.timeZoneOffset.inMinutes;
      final sign = offset < 0 ? '-' : '+';
      final hours = (offset.abs() ~/ 60).toString().padLeft(2, '0');
      final minutes = (offset.abs() % 60).toString().padLeft(2, '0');
      string = '$string$sign$hours:$minutes';
    }

    if (bc) {
      string = '$string BC';
    }

    return "'$string'";
  }

  /// `yyyy-MM-ddTHH:mm:ss.mmmuuu` without a zone (six digits beyond 9999);
  /// years before 1 AD are written as the BC year (without ' BC', added by
  /// the caller).
  static String _iso8601Fields(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final year = value.year <= 0 ? 1 - value.year : value.year;
    final y = year.toString().padLeft(year > 9999 ? 6 : 4, '0');
    final ms = value.millisecond.toString().padLeft(3, '0');
    final us = value.microsecond == 0
        ? ''
        : value.microsecond.toString().padLeft(3, '0');
    return '$y-${two(value.month)}-${two(value.day)}T${two(value.hour)}:'
        '${two(value.minute)}:${two(value.second)}.$ms$us';
  }

  String _encodeJSON(dynamic value, bool escapeStrings) {
    if (value == null) {
      return 'null';
    }

    if (value is String) {
      return "'${json.encode(value)}'";
    }

    return _encodeString(json.encode(value), escapeStrings);
  }

  String _encodePoint(PgPoint value) {
    return '(${_encodeDouble(value.latitude, false)}, ${_encodeDouble(value.longitude, false)})';
  }

  String _encodeList(List value) {
    if (value.isEmpty) {
      return '{}';
    }

    // Elementos null viram NULL. Antes um null levava a lista inteira para o
    // ramo JSON: ['a', null] virava {"\"a\"","null"} (dados errados).
    final items = value.where((item) => item != null);
    if (items.isEmpty) {
      return '{${value.map((_) => 'NULL').join(',')}}';
    }
    String join(String Function(dynamic item) encode) =>
        '{${value.map((item) => item == null ? 'NULL' : encode(item)).join(',')}}';

    final type = items.fold(items.first.runtimeType, (type, item) {
      if (type == item.runtimeType) {
        return type;
      } else if ((type == int || type == double) && item is num) {
        return double;
      } else {
        return Map;
      }
    });

    if (type == bool) {
      return join((s) => s.toString());
    }

    if (type == int || type == double) {
      return join((s) => s is double
          ? _encodeDouble(s, false)
          : _encodeNumber(s as num, false));
    }

    if (type == String) {
      return join((s) {
        final escaped =
            (s as String).replaceAll(r'\', r'\\').replaceAll('"', r'\"');
        return '"$escaped"';
      });
    }

    if (type == Map) {
      return join((s) {
        final escaped =
            json.encode(s).replaceAll(r'\', r'\\').replaceAll('"', r'\"');

        return '"$escaped"';
      });
    }

    throw PostgreSQLException("Could not infer array type of value '$value'.");
  }
}

class PostgresTextDecoder<T extends Object> extends Converter<Uint8List?, T?> {
  final PgDataType<T> _dataType;
  final Encoding encoding;
  const PostgresTextDecoder(this._dataType, this.encoding);

  /// Tipos que [convert] decodifica. Valores de outros tipos no formato
  /// texto (consultas sem parâmetros da API v3) são entregues como a
  /// String do PostgreSQL.
  static bool supports(PgDataType type) => const {
        PgDataType.text,
        PgDataType.varChar,
        PgDataType.timestampWithoutTimezone,
        PgDataType.integer,
        PgDataType.smallInteger,
        PgDataType.bigInteger,
        PgDataType.serial,
        PgDataType.bigSerial,
        PgDataType.real,
        PgDataType.double,
        PgDataType.boolean,
      }.contains(type);

  @override
  T? convert(Uint8List? input) {
    if (input == null) return null;

    final asText = encoding.decode(input);

    // ignore: unnecessary_cast
    switch (_dataType as PgDataType<Object>) {
      case PgDataType.text:
        return asText as T;
      case PgDataType.varChar:
        return asText as T;
      case PgDataType.timestampWithoutTimezone:
        return DateTime.tryParse(asText) as T;
      case PgDataType.integer:
      case PgDataType.smallInteger:
      case PgDataType.bigInteger:
      case PgDataType.serial:
      case PgDataType.bigSerial:
        return int.parse(asText) as T;
      case PgDataType.real:
      case PgDataType.double:
        return num.parse(asText) as T;
      case PgDataType.boolean:
        // O formato texto do PostgreSQL é 't'/'f' (antes só 'true' virava
        // true, então todo booleano do protocolo simples vinha false).
        return (asText == 't' || asText == 'true') as T;
      default:
        throw UnimplementedError(
            'Text decoding for $_dataType and value $asText');
    }
  }
}
