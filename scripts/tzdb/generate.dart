// Gera os bancos de localizações do driver a partir dos fontes do tzdata.

import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:postgres_fork/src/timezone/location.dart';

import 'common_locations.dart';
import 'tzif.dart';
import 'zic.dart';

/// Arquivos-fonte do tzdata compilados (os mesmos usados pelo pg_timezone).
const tzdataSources = [
  'africa',
  'antarctica',
  'asia',
  'australasia',
  'etcetera',
  'europe',
  'northamerica',
  'southamerica',
  'backward',
];

class TzdbBuild {
  /// Versão do tzdata (conteúdo do arquivo `version`).
  final String version;

  /// Arquivos TZif gerados pelo zic (nome -> bytes).
  final Map<String, Uint8List> tzif;

  /// Banco completo: todas as zonas e links, com todo o histórico.
  final List<Location> full;

  /// Banco reduzido: localizações comuns, transições numa janela de
  /// [reducedYearsAround] anos em torno do ano de referência.
  final List<Location> reduced;

  final int referenceYear;
  final int reducedYearsAround;
  final int? horizonYear;

  TzdbBuild(this.version, this.tzif, this.full, this.reduced,
      this.referenceYear, this.reducedYearsAround, this.horizonYear);
}

int _strcmp(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final c = a.codeUnitAt(i) - b.codeUnitAt(i);
    if (c != 0) return c;
  }
  return a.length - b.length;
}

/// Compila os fontes do tzdata ([files]: nome do arquivo -> conteúdo) e monta
/// os bancos completo e reduzido.
///
/// - O zic é executado em modo `-b fat`, como fazia o pg_timezone.
/// - [horizonYear], se informado, equivale a `zic -R`: gera transições
///   explícitas até o início desse ano (por padrão o modo fat vai até 2037).
/// - O banco reduzido reproduz o do pg_timezone: lista `commonLocations` e
///   transições de 1º de janeiro de `referenceYear - 5` a 1º de janeiro de
///   `referenceYear + 5` (UTC).
TzdbBuild buildTzdb(Map<String, Uint8List> files,
    {required int referenceYear,
    int reducedYearsAround = 5,
    int? horizonYear}) {
  final version = files.containsKey('version')
      ? latin1.decode(files['version']!).trim()
      : 'desconhecida';

  final zic = Zic(
      bloat: true,
      redundantTime: horizonYear == null
          ? null
          : DateTime.utc(horizonYear).millisecondsSinceEpoch ~/ 1000);
  for (final source in tzdataSources) {
    final content = files[source];
    if (content == null) {
      throw StateError('arquivo "$source" não encontrado no tzdata');
    }
    zic.addSource(source, latin1.decode(content));
  }
  final tzif = zic.compile();

  final names = tzif.keys.toList()..sort(_strcmp);
  final raw = <String, Location>{
    for (final name in names) name: TzifData.parse(name, tzif[name]!).toLocation()
  };

  final full = [for (final name in names) raw[name]!];

  // Mesma sequência do encode_tzf.dart do pg_timezone:
  // all = filtro sem limites; common = filtro da lista; 10y = janela.
  final common = commonLocations.toSet();
  final dateFrom =
      DateTime.utc(referenceYear - reducedYearsAround).millisecondsSinceEpoch;
  final dateTo =
      DateTime.utc(referenceYear + reducedYearsAround).millisecondsSinceEpoch;
  final reduced = <Location>[
    for (final name in names)
      if (common.contains(name))
        filterLocation(filterLocation(filterLocation(raw[name]!)),
            dateFrom: dateFrom, dateTo: dateTo)
  ];

  return TzdbBuild(version, tzif, full, reduced, referenceYear,
      reducedYearsAround, horizonYear);
}
