import 'dart:convert';
import 'dart:typed_data';

import 'pg_values.dart';
import 'v3/types.dart';

/// Conversão de linhas para o formato texto do `COPY` (e de volta).
///
/// Formato texto: colunas separadas por tab, linhas terminadas por `\n`,
/// `\N` para NULL e `\\`, `\t`, `\n` e `\r` escapados com barra invertida.
/// Ver https://www.postgresql.org/docs/current/sql-copy.html.
abstract final class PgCopy {
  /// Tamanho aproximado (em caracteres) de cada bloco produzido por
  /// [encodeTextRows].
  static const defaultChunkSize = 64 * 1024;

  /// Codifica [rows] no formato texto do COPY, em blocos de aproximadamente
  /// [chunkSize] caracteres, prontos para `copyFrom`.
  ///
  /// As linhas são lidas sob demanda, à medida que os blocos são consumidos.
  /// Cada linha deve ter [columnCount] valores, quando informado. Os valores
  /// aceitos estão descritos em [encodeTextValue].
  static Stream<List<int>> encodeTextRows(Iterable<List<Object?>> rows,
          {Encoding encoding = utf8,
          int? columnCount,
          int chunkSize = defaultChunkSize}) =>
      Stream.fromIterable(_chunks(rows, encoding, columnCount, chunkSize));

  static Iterable<List<int>> _chunks(Iterable<List<Object?>> rows,
      Encoding encoding, int? columnCount, int chunkSize) sync* {
    final buffer = StringBuffer();
    var rowIndex = 0;
    for (final row in rows) {
      if (columnCount != null && row.length != columnCount) {
        throw ArgumentError.value(row, 'rows[$rowIndex]',
            'Expected $columnCount values, got ${row.length}');
      }
      for (var i = 0; i < row.length; i++) {
        if (i > 0) buffer.write('\t');
        final value = row[i];
        if (value == null) {
          buffer.write(r'\N');
        } else {
          _writeEscaped(buffer, encodeTextValue(value));
        }
      }
      buffer.write('\n');
      rowIndex++;
      if (buffer.length >= chunkSize) {
        yield encoding.encode(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) {
      yield encoding.encode(buffer.toString());
    }
  }

  static void _writeEscaped(StringBuffer buffer, String text) {
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final String replacement;
      switch (text.codeUnitAt(i)) {
        case 0x5C: // \
          replacement = r'\\';
        case 0x0A:
          replacement = r'\n';
        case 0x0D:
          replacement = r'\r';
        case 0x09:
          replacement = r'\t';
        default:
          continue;
      }
      buffer
        ..write(text.substring(start, i))
        ..write(replacement);
      start = i + 1;
    }
    if (start == 0) {
      buffer.write(text);
    } else {
      buffer.write(text.substring(start));
    }
  }

  /// Representação de [value] no formato de entrada do PostgreSQL (antes do
  /// escape do COPY):
  ///
  /// - [String]: o próprio texto;
  /// - [int], [double] (`NaN`, `Infinity`, `-Infinity`), [bool] (`t`/`f`);
  /// - [DateTime]: data, hora com microssegundos e deslocamento (`+00:00`
  ///   quando UTC). Numa coluna `timestamptz` grava o instante; numa coluna
  ///   `timestamp` o PostgreSQL ignora o deslocamento e grava a data e a hora
  ///   do próprio [DateTime] (locais ou UTC, conforme `isUtc`); numa coluna
  ///   `date` grava a data;
  /// - [Uint8List]: `bytea` em hexadecimal (`\x...`);
  /// - [Map]: JSON;
  /// - [List]: array (`{...}`); para uma coluna `json`/`jsonb` com um array
  ///   JSON, passe uma [String] com `jsonEncode(lista)`;
  /// - [PostgresTextEncodable] (PgInterval, PgTime, PgTimeTz, PgInet e
  ///   tipos da aplicação) e [PgPoint].
  ///
  /// Outros tipos lançam [ArgumentError].
  static String encodeTextValue(Object value) {
    if (value is String) return value;
    if (value is int) return value.toString();
    if (value is double) {
      if (value.isNaN) return 'NaN';
      if (value.isInfinite) return value.isNegative ? '-Infinity' : 'Infinity';
      return value.toString();
    }
    if (value is bool) return value ? 't' : 'f';
    if (value is DateTime) return _encodeDateTime(value);
    if (value is Uint8List) {
      final hex = StringBuffer(r'\x');
      for (final byte in value) {
        hex.write(byte.toRadixString(16).padLeft(2, '0'));
      }
      return hex.toString();
    }
    if (value is Map) return json.encode(value);
    if (value is List) {
      final buffer = StringBuffer();
      _writeArray(buffer, value);
      return buffer.toString();
    }
    if (value is PostgresTextEncodable) return value.toPostgresText();
    if (value is PgPoint) return '(${value.latitude},${value.longitude})';
    throw ArgumentError.value(value, 'value',
        'Cannot encode ${value.runtimeType} for COPY');
  }

  static void _writeArray(StringBuffer buffer, List<Object?> list) {
    buffer.write('{');
    for (var i = 0; i < list.length; i++) {
      if (i > 0) buffer.write(',');
      final element = list[i];
      if (element == null) {
        buffer.write('NULL');
      } else if (element is List && element is! Uint8List) {
        _writeArray(buffer, element);
      } else {
        // Todo elemento entre aspas: vale para qualquer tipo e evita
        // ambiguidades (texto vazio, "NULL", vírgulas, chaves, espaços).
        buffer.write('"');
        final text = encodeTextValue(element);
        for (var j = 0; j < text.length; j++) {
          final c = text.codeUnitAt(j);
          if (c == 0x22 || c == 0x5C) buffer.write(r'\');
          buffer.writeCharCode(c);
        }
        buffer.write('"');
      }
    }
    buffer.write('}');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _encodeDateTime(DateTime value) {
    final year = value.year;
    // O ano 0 do DateTime (calendário astronômico) é o ano 1 a.C.
    final bc = year <= 0;
    final buffer = StringBuffer()
      ..write((bc ? 1 - year : year).toString().padLeft(4, '0'))
      ..write('-${_two(value.month)}-${_two(value.day)} ')
      ..write('${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}')
      ..write('.')
      ..write((value.millisecond * 1000 + value.microsecond)
          .toString()
          .padLeft(6, '0'));
    final offset = value.isUtc ? Duration.zero : value.timeZoneOffset;
    final minutes = offset.inMinutes.abs();
    buffer
      ..write(offset.isNegative ? '-' : '+')
      ..write('${_two(minutes ~/ 60)}:${_two(minutes % 60)}');
    if (bc) buffer.write(' BC');
    return buffer.toString();
  }

  /// Decodifica uma linha no formato texto do COPY (como as recebidas por
  /// `copyTo`; o `\n` final é opcional) em uma lista de valores, com `null`
  /// para `\N`.
  static List<String?> decodeTextRow(List<int> line,
      {Encoding encoding = utf8}) {
    var text = encoding.decode(line);
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    final values = <String?>[];
    final current = StringBuffer();
    var isNull = false;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x09) {
        values.add(isNull ? null : current.toString());
        current.clear();
        isNull = false;
      } else if (c == 0x5C && i + 1 < text.length) {
        final next = text[++i];
        switch (next) {
          case 'N':
            isNull = true;
          case 'n':
            current.write('\n');
          case 'r':
            current.write('\r');
          case 't':
            current.write('\t');
          case 'b':
            current.write('\b');
          case 'f':
            current.write('\f');
          case 'v':
            current.write('\v');
          default:
            current.write(next);
        }
      } else {
        current.writeCharCode(c);
      }
    }
    values.add(isNull ? null : current.toString());
    return values;
  }
}
