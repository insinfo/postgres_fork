// Grava lib/src/timezone/tz_data.dart com os bancos completo e reduzido.

import 'dart:io';

import 'package:postgres_fork/src/timezone/database.dart';
import 'package:postgres_fork/src/timezone/location.dart';

/// Escreve o arquivo gerado com os dados dos dois bancos.
void writeTzDataFile(
  String path, {
  required String version,
  required String fullDescription,
  required Iterable<Location> full,
  required String reducedDescription,
  required Iterable<Location> reduced,
}) {
  final out = StringBuffer()
    ..writeln('// ARQUIVO GERADO - NÃO EDITE MANUALMENTE.')
    ..writeln('// Gerado por scripts/update_tzdb.dart a partir do banco de')
    ..writeln('// fusos horários da IANA (https://www.iana.org/time-zones).')
    ..writeln('// Formato: veja lib/src/timezone/database.dart.')
    ..writeln()
    ..writeln('/// Versão do banco de fusos horários da IANA.')
    ..writeln('const tzdbVersion = ${_literal(version)};')
    ..writeln()
    ..writeln('/// Como o banco completo foi gerado.')
    ..writeln('const tzdbFullDescription = ${_literal(fullDescription)};')
    ..writeln()
    ..writeln('/// Como o banco reduzido foi gerado.')
    ..writeln('const tzdbReducedDescription = ${_literal(reducedDescription)};')
    ..writeln();
  _writeData(out, 'tzdbFullData', 'Banco completo', full);
  out.writeln();
  _writeData(out, 'tzdbReducedData', 'Banco reduzido', reduced);
  File(path).writeAsStringSync(out.toString());
}

void _writeData(
    StringBuffer out, String name, String doc, Iterable<Location> locations) {
  final lines = encodeLocations(locations).split('\n')..removeLast();
  out
    ..writeln('/// $doc (formato de `encodeLocations`).')
    ..write('const $name =');
  for (final line in lines) {
    out
      ..writeln()
      ..write('    ')
      ..write(_literal('$line\n'));
  }
  out.writeln(';');
}

String _literal(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}
