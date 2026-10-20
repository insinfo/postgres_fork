// Compara os bancos gerados por scripts/tzdb/generate.dart (port Dart do zic +
// leitor TZif + filtros) com o pipeline original do pg_timezone: zic em C,
// leitor TZif do pg_timezone (tzdata.dart), tzfileLocationToNativeLocation e
// filterTimeZoneData.
//
// Uso:
//   dart run tool/tzdb_pipeline_parity.dart --zic <zic em C> \
//       --tzdata <diretório> [--reference-year 2026] [--horizon 2100]
//
// ignore_for_file: implementation_imports, depend_on_referenced_packages

import 'dart:io';

import 'package:pg_timezone/src/tools.dart' as pg_tools;
import 'package:pg_timezone/timezone.dart' as pg;
import 'package:pg_timezone/tzdata.dart' as pg_tzfile;
import 'package:postgres_fork/src/timezone/location.dart' as mine;

import '../../scripts/tzdb/generate.dart';

String _describePg(pg.Location l) {
  final transitions = [
    for (var i = 0; i < l.transitionAt.length; i++)
      '${l.transitionAt[i]}:${l.transitionZone[i]}'
  ].join(',');
  final zones =
      l.zones.map((z) => '${z.abbreviation}/${z.offset}/${z.isDst}').join(',');
  return '$transitions | $zones';
}

String _describeMine(mine.Location l) {
  final transitions = [
    for (var i = 0; i < l.transitionAt.length; i++)
      '${l.transitionAt[i]}:${l.transitionZone[i]}'
  ].join(',');
  final zones =
      l.zones.map((z) => '${z.abbreviation}/${z.offset}/${z.isDst}').join(',');
  return '$transitions | $zones';
}

Future<void> main(List<String> args) async {
  String? zicPath;
  String? tzdataDir;
  var referenceYear = DateTime.now().year;
  int? horizon = 2100;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--zic':
        zicPath = args[++i];
        break;
      case '--tzdata':
        tzdataDir = args[++i];
        break;
      case '--reference-year':
        referenceYear = int.parse(args[++i]);
        break;
      case '--horizon':
        final v = args[++i];
        horizon = v == 'none' ? null : int.parse(v);
        break;
    }
  }
  if (zicPath == null || tzdataDir == null) {
    stderr.writeln('uso: tzdb_pipeline_parity.dart --zic <zic> --tzdata <dir>'
        ' [--reference-year <ano>] [--horizon <ano>|none]');
    exit(64);
  }

  // Pipeline novo.
  final files = {
    for (final f in Directory(tzdataDir).listSync().whereType<File>())
      f.uri.pathSegments.last: f.readAsBytesSync()
  };
  final build =
      buildTzdb(files, referenceYear: referenceYear, horizonYear: horizon);

  // Pipeline original.
  final tmp = await Directory.systemTemp.createTemp('tzdb_pipeline_');
  try {
    final result = await Process.run(
        zicPath,
        [
          '-d',
          tmp.path,
          '-b',
          'fat',
          if (horizon != null)
            '-R@${DateTime.utc(horizon).millisecondsSinceEpoch ~/ 1000}',
          ...tzdataSources,
        ],
        workingDirectory: tzdataDir);
    if (result.exitCode != 0) {
      stderr.writeln('zic em C falhou:\n${result.stderr}');
      exit(1);
    }
    final db = pg.LocationDatabase();
    for (final f in tmp.listSync(recursive: true).whereType<File>()) {
      final name = f.path
          .substring(tmp.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      db.add(pg_tools.tzfileLocationToNativeLocation(
          pg_tzfile.Location.fromBytes(name, f.readAsBytesSync())));
    }

    var diffs = 0;
    // Banco completo: dados brutos do TZif.
    final fullNames = build.full.map((l) => l.name).toList();
    final expectedNames = db.locations.keys.toList()..sort();
    if (fullNames.join(',') != expectedNames.join(',')) {
      diffs++;
      print('completo: nomes diferentes');
    }
    for (final l in build.full) {
      final p = db.locations[l.name];
      if (p == null || _describePg(p) != _describeMine(l)) {
        diffs++;
        if (diffs < 10) print('completo: ${l.name} difere');
      }
    }

    // Banco reduzido: mesma sequência de filtros do encode_tzf.dart.
    final all = pg_tools.filterTimeZoneData(db).db;
    final common = pg_tools
        .filterTimeZoneData(all, locations: pg_tools.commonLocations)
        .db;
    final reduced = pg_tools
        .filterTimeZoneData(common,
            dateFrom: DateTime.utc(referenceYear - 5).millisecondsSinceEpoch,
            dateTo: DateTime.utc(referenceYear + 5).millisecondsSinceEpoch,
            locations: pg_tools.commonLocations)
        .db;
    final reducedExpected = reduced.locations.keys.toList()..sort();
    final reducedNames = build.reduced.map((l) => l.name).toList();
    if (reducedNames.join(',') != reducedExpected.join(',')) {
      diffs++;
      print('reduzido: nomes diferentes '
          '(${reducedNames.length} x ${reducedExpected.length})');
    }
    for (final l in build.reduced) {
      final p = reduced.locations[l.name];
      if (p == null || _describePg(p) != _describeMine(l)) {
        diffs++;
        if (diffs < 20) print('reduzido: ${l.name} difere');
      }
    }
    print('tzdata ${build.version} (ano $referenceYear, horizonte '
        '${horizon ?? 'padrão'}): completo ${build.full.length}, reduzido '
        '${build.reduced.length}; $diffs diferença(s).');
    exitCode = diffs == 0 ? 0 : 1;
  } finally {
    await tmp.delete(recursive: true);
  }
}
