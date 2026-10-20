// Gera lib/src/utils/saslprep_tables.dart a partir dos dados exatos usados
// pelos pacotes `saslprep` (tabelas do RFC 3454) e `unorm_dart` (dados de
// normalização Unicode 8.0), que eram as dependências transitivas usadas pela
// autenticação SCRAM-SHA-256. Assim a implementação interna se comporta
// exatamente como a original.
//
// Uso:
//   cd dependency_parity && dart run tool/generate_saslprep_tables.dart
//
// ignore_for_file: implementation_imports, depend_on_referenced_packages

import 'dart:io';

import 'package:saslprep/src/code_points/bidirectional_l.dart';
import 'package:saslprep/src/code_points/bidirectional_r_al.dart';
import 'package:saslprep/src/code_points/commonly_mapped_to_nothing.dart';
import 'package:saslprep/src/code_points/non_ASCII_space_characters.dart';
import 'package:saslprep/src/code_points/prohibited_characters.dart';
import 'package:saslprep/src/code_points/unassigned.dart';
import 'package:unorm_dart/src/unormdata.dart';

const _outputPath = '../lib/src/utils/saslprep_tables.dart';

// Mesmas constantes usadas pelo unorm_dart para decidir quais code points
// nunca consultam a tabela de dados (ver nfkc.dart).
bool _isFiltered(int cp) => cp < 60 || (13311 < cp && cp < 42607);
bool _isRuleBasedJamo(int cp) =>
    (0x1100 <= cp && cp < 0x1100 + 19) || (0xAC00 <= cp && cp <= 0xAC00 + 11172);

/// Converte uma lista de code points em pares [início, fim] ordenados.
List<int> _toRanges(Iterable<int> codePoints) {
  final sorted = codePoints.toSet().toList()..sort();
  final ranges = <int>[];
  for (final cp in sorted) {
    if (ranges.isNotEmpty && ranges.last + 1 == cp) {
      ranges[ranges.length - 1] = cp;
    } else {
      ranges
        ..add(cp)
        ..add(cp);
    }
  }
  return ranges;
}

String _hex(int value) => '0x${value.toRadixString(16).padLeft(4, '0')}';

String _rangesConst(String name, String doc, Iterable<int> codePoints) {
  final ranges = _toRanges(codePoints);
  final out = StringBuffer()
    ..writeln('/// $doc')
    ..writeln('///')
    ..writeln('/// Pares ordenados de intervalos fechados `[início, fim]`.')
    ..writeln('const $name = <int>[');
  for (var i = 0; i < ranges.length; i += 2) {
    out.writeln('  ${_hex(ranges[i])}, ${_hex(ranges[i + 1])},');
  }
  out.writeln('];');
  return out.toString();
}

/// Divide uma string longa em vários literais adjacentes para manter as
/// linhas do arquivo gerado curtas.
String _stringConst(String name, String doc, String value) {
  final out = StringBuffer()
    ..writeln('/// $doc')
    ..write('const $name =');
  const chunk = 72;
  if (value.isEmpty) {
    out.writeln(" '';");
    return out.toString();
  }
  out.writeln();
  for (var i = 0; i < value.length; i += chunk) {
    final end = i + chunk < value.length ? i + chunk : value.length;
    out.write("    '${value.substring(i, end)}'");
    out.writeln(end == value.length ? ';' : '');
  }
  return out.toString();
}

String _h(int v) => v.toRadixString(16);

void main() {
  final decompositions = <int, List<int>>{};
  final combiningClasses = <int, int>{};
  final compositions = <List<int>>[]; // [starter, following, composite]

  final data = unormdata as Map;
  for (final unit in data.values) {
    for (final entry in (unit as Map).entries) {
      final cp = entry.key as int;
      if (_isFiltered(cp) || _isRuleBasedJamo(cp)) continue;
      final feature = entry.value as List;

      final decomp = feature[0];
      if (decomp != null) {
        decompositions[cp] = (decomp as List).cast<int>();
      }

      final flags = feature.length > 1 ? feature[1] : null;
      if (flags != null && (flags as int) > 0 && (flags & 0xFF) != 0) {
        combiningClasses[cp] = flags & 0xFF;
      }

      final comp = feature.length > 2 ? feature[2] : null;
      if (comp != null) {
        for (final c in (comp as Map).entries) {
          final composite = c.value;
          if (composite != null && (composite as int) > 0) {
            compositions.add([cp, c.key as int, composite]);
          }
        }
      }
    }
  }

  final decompKeys = decompositions.keys.toList()..sort();
  final decompData = decompKeys
      .map((cp) => '${_h(cp)}:${decompositions[cp]!.map(_h).join(',')}')
      .join(';');

  final cccKeys = combiningClasses.keys.toList()..sort();
  final cccData =
      cccKeys.map((cp) => '${_h(cp)}:${_h(combiningClasses[cp]!)}').join(';');

  compositions.sort((a, b) => a[0] != b[0] ? a[0] - b[0] : a[1] - b[1]);
  final compData =
      compositions.map((c) => '${_h(c[0])},${_h(c[1])}:${_h(c[2])}').join(';');

  final out = StringBuffer()
    ..writeln('// ARQUIVO GERADO - NÃO EDITE MANUALMENTE.')
    ..writeln('// Gerado por dependency_parity/tool/generate_saslprep_tables.dart a partir dos')
    ..writeln('// pacotes saslprep 1.0.3 (MIT, Copyright (c) 2019 Richard')
    ..writeln('// Burkhardt) e unorm_dart 0.3.0 (MIT, Copyright (c) 2018')
    ..writeln('// Yasuhiro Shimizu; dados do Unicode 8.0).')
    ..writeln()
    ..writeln(_rangesConst('nonAsciiSpaceRanges',
        'RFC 3454 C.1.2 - Non-ASCII space characters.', non_ASCII_space_characters))
    ..writeln(_rangesConst('mappedToNothingRanges',
        'RFC 3454 B.1 - Commonly mapped to nothing.', commonly_mapped_to_nothing))
    ..writeln(_rangesConst('prohibitedRanges',
        'RFC 4013 2.3 - Prohibited output (tabelas C.1.2, C.2.1, C.2.2, C.3-C.9).',
        prohibited_characters))
    ..writeln(_rangesConst('unassignedRanges',
        'RFC 3454 A.1 - Unassigned code points in Unicode 3.2.',
        unassigned_code_points))
    ..writeln(_rangesConst('bidiRAndALRanges',
        'RFC 3454 D.1 - Characters with bidirectional property "R" or "AL".',
        bidirectional_r_al))
    ..writeln(_rangesConst('bidiLRanges',
        'RFC 3454 D.2 - Characters with bidirectional property "L".',
        bidirectional_l))
    ..writeln(_stringConst(
        'nfkcDecompositionData',
        'Decomposições (canônicas e de compatibilidade) no formato '
            '`cp:d1,d2;...` em hexadecimal.',
        decompData))
    ..writeln(_stringConst(
        'nfkcCombiningClassData',
        'Canonical combining class diferente de zero no formato `cp:ccc;...` '
            'em hexadecimal.',
        cccData))
    ..write(_stringConst(
        'nfkcCompositionData',
        'Composições no formato `inicial,seguinte:composto;...` em '
            'hexadecimal.',
        compData));

  File(_outputPath).writeAsStringSync(out.toString());
  stdout.writeln('Gerado $_outputPath: ${decompositions.length} decomposições, '
      '${combiningClasses.length} classes combinantes, '
      '${compositions.length} composições.');
}
