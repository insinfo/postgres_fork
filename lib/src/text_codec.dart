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
      return _encodeNumber(input);
    }

    if (input is double) {
      return _encodeDouble(input);
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
      return _encodePoint(input);
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
      return _encodeList(input);
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

  String _encodeNumber(num value) {
    if (value.isNaN) {
      return "'nan'";
    }

    if (value.isInfinite) {
      return value.isNegative ? "'-infinity'" : "'infinity'";
    }

    return value.toInt().toString();
  }

  String _encodeDouble(double value) {
    if (value.isNaN) {
      return "'nan'";
    }

    if (value.isInfinite) {
      return value.isNegative ? "'-infinity'" : "'infinity'";
    }

    return value.toString();
  }

  String _encodeBoolean(bool value) {
    return value ? 'TRUE' : 'FALSE';
  }

  String _encodeDateTime(DateTime value, {bool isDateOnly = false}) {
    // Built from the fields: toIso8601String() of a TZDateTime (returned for
    // non-UTC zones) already ends with its offset, so appending one gave
    // '...-0300-03:00' and the server rejected it (22009).
    var string = _iso8601Fields(value);

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

    if (string.substring(0, 1) == '-') {
      string = '${string.substring(1)} BC';
    } else if (string.substring(0, 1) == '+') {
      string = string.substring(1);
    }

    return "'$string'";
  }

  /// `yyyy-MM-ddTHH:mm:ss.mmmuuu` without a zone, years as in
  /// [DateTime.toIso8601String] (`-0010`; six digits beyond ±9999).
  static String _iso8601Fields(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    final year = value.year;
    final sign = year < 0 ? '-' : (year > 9999 ? '+' : '');
    final y = '$sign${year.abs().toString().padLeft(year.abs() > 9999 ? 6 : 4, '0')}';
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
    return '(${_encodeDouble(value.latitude)}, ${_encodeDouble(value.longitude)})';
  }

  String _encodeList(List value) {
    if (value.isEmpty) {
      return '{}';
    }

    final type = value.fold(value.first.runtimeType, (type, item) {
      if (type == item.runtimeType) {
        return type;
      } else if ((type == int || type == double) && item is num) {
        return double;
      } else {
        return Map;
      }
    });

    if (type == bool) {
      return '{${value.cast<bool>().map((s) => s.toString()).join(',')}}';
    }

    if (type == int || type == double) {
      return '{${value.cast<num>().map((s) => s is double ? _encodeDouble(s) : _encodeNumber(s)).join(',')}}';
    }

    if (type == String) {
      return '{${value.cast<String>().map((s) {
        final escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
        return '"$escaped"';
      }).join(',')}}';
    }

    if (type == Map) {
      return '{${value.map((s) {
        final escaped =
            json.encode(s).replaceAll(r'\', r'\\').replaceAll('"', r'\"');

        return '"$escaped"';
      }).join(',')}}';
    }

    throw PostgreSQLException("Could not infer array type of value '$value'.");
  }
}

class PostgresTextDecoder<T extends Object> extends Converter<Uint8List?, T?> {
  final PgDataType<T> _dataType;
  final Encoding encoding;
  const PostgresTextDecoder(this._dataType, this.encoding);

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
