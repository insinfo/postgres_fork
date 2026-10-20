// Compara, byte a byte, os arquivos TZif gerados pelo port Dart do zic
// (scripts/tzdb/zic.dart) com os gerados pelo zic em C da IANA.
//
// Uso:
//   dart run tool/zic_parity.dart --zic <caminho do zic em C> \
//       --tzdata <diretório do tzdata extraído> [--bloat fat|slim] \
//       [arquivos-fonte...]
//
// Por padrão compila os mesmos arquivos usados pelo driver: africa antarctica
// asia australasia etcetera europe northamerica southamerica backward.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../scripts/tzdb/zic.dart';

const _defaultSources = [
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

Future<void> main(List<String> args) async {
  String? zicPath;
  String? tzdataDir;
  var bloat = 'fat';
  final sources = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--zic':
        zicPath = args[++i];
        break;
      case '--tzdata':
        tzdataDir = args[++i];
        break;
      case '--bloat':
        bloat = args[++i];
        break;
      default:
        sources.add(args[i]);
    }
  }
  if (zicPath == null || tzdataDir == null) {
    stderr.writeln('uso: zic_parity.dart --zic <zic> --tzdata <dir> '
        '[--bloat fat|slim] [fontes...]');
    exit(64);
  }
  if (sources.isEmpty) sources.addAll(_defaultSources);

  final tmp = await Directory.systemTemp.createTemp('zic_parity_');
  try {
    // zic em C.
    final result = await Process.run(
        zicPath, ['-d', tmp.path, '-b', bloat, ...sources],
        workingDirectory: tzdataDir);
    if (result.exitCode != 0) {
      stderr.writeln('zic em C falhou:\n${result.stderr}');
      exit(1);
    }
    final expected = <String, Uint8List>{};
    for (final f in tmp.listSync(recursive: true).whereType<File>()) {
      final name = f.path
          .substring(tmp.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      expected[name] = f.readAsBytesSync();
    }

    // Port Dart.
    final zic = Zic(bloat: bloat == 'fat');
    for (final s in sources) {
      zic.addSource(
          s, latin1.decode(File('$tzdataDir/$s').readAsBytesSync()));
    }
    final actual = zic.compile();

    var diffs = 0;
    for (final name in {...expected.keys, ...actual.keys}.toList()..sort()) {
      final a = expected[name];
      final b = actual[name];
      if (a == null || b == null) {
        diffs++;
        print('$name: ${a == null ? 'só no port Dart' : 'só no zic em C'}');
        continue;
      }
      if (a.length != b.length || !_equal(a, b)) {
        diffs++;
        var at = 0;
        while (at < a.length && at < b.length && a[at] == b[at]) {
          at++;
        }
        print('$name: difere a partir do byte $at '
            '(C: ${a.length} bytes, Dart: ${b.length} bytes)');
      }
    }
    final version = File('$tzdataDir/version').existsSync()
        ? File('$tzdataDir/version').readAsStringSync().trim()
        : '?';
    print('tzdata $version, -b $bloat: ${expected.length} arquivos do zic em '
        'C, ${actual.length} do port Dart, $diffs diferença(s).');
    if (zic.warnings.isNotEmpty) {
      print('avisos do port Dart: ${zic.warnings.length}');
    }
    exitCode = diffs == 0 ? 0 : 1;
  } finally {
    await tmp.delete(recursive: true);
  }
}

bool _equal(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
