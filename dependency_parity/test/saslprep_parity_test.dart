// Compara lib/src/utils/nfkc.dart e lib/src/utils/saslprep.dart com os
// pacotes `unorm_dart` 0.3.0 e `saslprep` 1.0.3.
//
// ignore_for_file: implementation_imports

import 'dart:math';

import 'package:postgres_fork/src/utils/nfkc.dart' as mine_nfkc;
import 'package:postgres_fork/src/utils/saslprep.dart' as mine;
import 'package:postgres_fork/src/utils/saslprep_tables.dart';
import 'package:saslprep/saslprep.dart' as orig;
import 'package:saslprep/src/code_points/bidirectional_l.dart';
import 'package:saslprep/src/code_points/bidirectional_r_al.dart';
import 'package:saslprep/src/code_points/commonly_mapped_to_nothing.dart';
import 'package:saslprep/src/code_points/non_ASCII_space_characters.dart';
import 'package:saslprep/src/code_points/prohibited_characters.dart';
import 'package:saslprep/src/code_points/unassigned.dart';
import 'package:test/test.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

const _maxCodePoint = 0x10FFFF;

String _cpString(String s) =>
    s.codeUnits.map((c) => c.toRadixString(16).padLeft(4, '0')).join(' ');

String _outcome(String Function() fn) {
  try {
    return 'ok:${_cpString(fn())}';
  } catch (e) {
    return 'error:${e.runtimeType}:$e';
  }
}

/// Code points "interessantes" para montar sequências: todos os que têm
/// decomposição, classe combinante ou composição, além de jamos Hangul,
/// sílabas, surrogates isolados e caracteres das tabelas do SASLprep.
List<int> _interestingCodePoints() {
  final set = <int>{};
  for (var cp = 0; cp <= _maxCodePoint; cp++) {
    if (cp >= 0xD800 && cp <= 0xDFFF) continue;
    final s = String.fromCharCode(cp);
    if (unorm.nfkd(s) != s || unorm.nfkc(s) != s) set.add(cp);
  }
  for (final entry in nfkcCombiningClassData.split(';')) {
    set.add(int.parse(entry.split(':')[0], radix: 16));
  }
  for (final entry in nfkcCompositionData.split(';')) {
    final pair = entry.split(':')[0].split(',');
    set.add(int.parse(pair[0], radix: 16));
    set.add(int.parse(pair[1], radix: 16));
  }
  for (var cp = 0x1100; cp <= 0x11FF; cp++) {
    set.add(cp);
  }
  set.addAll([0xAC00, 0xAC01, 0xD7A3, 0xD7A4, 0xD7A5, 0xD7A6, 0xD7AF]);
  set.addAll(non_ASCII_space_characters);
  set.addAll(commonly_mapped_to_nothing);
  set.addAll([0x05D0, 0x0627, 0x0628, 0x0661, 0xFB1D, 0x0041, 0x0031]);
  return set.toList()..sort();
}

String _randomString(Random random, List<int> interesting) {
  final buffer = StringBuffer();
  final length = random.nextInt(12);
  for (var i = 0; i < length; i++) {
    final kind = random.nextInt(10);
    if (kind < 6) {
      buffer.writeCharCode(interesting[random.nextInt(interesting.length)]);
    } else if (kind < 8) {
      buffer.writeCharCode(0x20 + random.nextInt(0x5F));
    } else if (kind == 8) {
      // Qualquer code point fora da faixa de surrogates.
      var cp = random.nextInt(_maxCodePoint + 1);
      if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0x41;
      buffer.writeCharCode(cp);
    } else {
      // Surrogate isolado.
      buffer.write(String.fromCharCode(0xD800 + random.nextInt(0x800)));
    }
  }
  return buffer.toString();
}

void main() {
  group('tabelas', () {
    void compareTable(String name, List<int> original, List<int> ranges) {
      final set = original.toSet();
      for (var cp = 0; cp <= _maxCodePoint; cp++) {
        final expected = set.contains(cp);
        if (mine.codePointInRanges(ranges, cp) != expected) {
          fail('$name: divergência em U+${cp.toRadixString(16)} '
              '(original: $expected)');
        }
      }
    }

    test('non-ASCII space',
        () => compareTable('C.1.2', non_ASCII_space_characters, nonAsciiSpaceRanges));
    test('mapped to nothing',
        () => compareTable('B.1', commonly_mapped_to_nothing, mappedToNothingRanges));
    test('prohibited',
        () => compareTable('2.3', prohibited_characters, prohibitedRanges));
    test('unassigned',
        () => compareTable('A.1', unassigned_code_points, unassignedRanges));
    test('bidi R/AL',
        () => compareTable('D.1', bidirectional_r_al, bidiRAndALRanges));
    test('bidi L', () => compareTable('D.2', bidirectional_l, bidiLRanges));
  });

  group('nfkc', () {
    test('todos os code points isolados (inclusive surrogates isolados)', () {
      for (var cp = 0; cp <= _maxCodePoint; cp++) {
        final s = String.fromCharCode(cp);
        final expected = unorm.nfkc(s);
        final actual = mine_nfkc.nfkc(s);
        if (actual != expected) {
          fail('U+${cp.toRadixString(16)}: esperado ${_cpString(expected)}, '
              'obtido ${_cpString(actual)}');
        }
      }
    });

    test('pares de code points interessantes e sequências aleatórias', () {
      final interesting = _interestingCodePoints();
      final random = Random(20);
      // Pares (inicial, seguinte) de todas as composições + um caractere
      // combinante entre eles, para exercitar a regra de bloqueio.
      final combining = [0x0300, 0x0301, 0x0316, 0x031B, 0x0345, 0x05B0, 0x3099];
      for (final entry in nfkcCompositionData.split(';')) {
        final pair = entry.split(':')[0].split(',');
        final a = int.parse(pair[0], radix: 16);
        final b = int.parse(pair[1], radix: 16);
        for (final s in [
          String.fromCharCodes([a, b]),
          String.fromCharCodes([b, a]),
          String.fromCharCodes([a, combining[random.nextInt(combining.length)], b]),
          String.fromCharCodes([a, b, a, b]),
        ]) {
          expect(_cpString(mine_nfkc.nfkc(s)), _cpString(unorm.nfkc(s)),
              reason: _cpString(s));
        }
      }
      for (var i = 0; i < 300000; i++) {
        final s = _randomString(random, interesting);
        final expected = unorm.nfkc(s);
        final actual = mine_nfkc.nfkc(s);
        if (actual != expected) {
          fail('entrada ${_cpString(s)}: esperado ${_cpString(expected)}, '
              'obtido ${_cpString(actual)}');
        }
      }
    });
  });

  group('saslprep', () {
    test('exemplos e casos-limite', () {
      final inputs = <String>[
        '', 'user', 'USER', 'I\u00ADX', '\u00AA', '\u2168', '\u0007',
        '\u06271', '\u06271\u0628', '\u0627a\u0628', 'a\u0627',
        '\u00AD', '\u00AD\u200B', ' ', '\u00A0', 'pass\u2003word',
        'p\u00F6stgr\u0113s_\u00FC\u0161\u0119r_p\u00E6ssw\u0153\u00EArd', 'senha\u00B2', '\uFF50\uFF41\uFF53\uFF53', '\uFB01le', '\u{1D400}',
        '\uD800', 'a\uDC00b', '\u0221', '\uE000', '\u{F0000}', '\uFFFE',
        '\u0340', '\u2FF0', '\u200E', '\u202A', '\uD7A4', '\u1100\u1161',
        '\u1100\u1161\u11A8', 'e\u0301\u0316', '\u05D0\u05B0\u05D1',
        '\u01C4', '\u01C5', '\u2126', '\u212B', '\u0958', '\u0F73',
      ];
      for (final input in inputs) {
        expect(_outcome(() => mine.saslprep(input)),
            _outcome(() => orig.Saslprep.saslprep(input)),
            reason: _cpString(input));
      }
    });

    test('code points isolados (amostra de todas as faixas)', () {
      final random = Random(21);
      final codePoints = <int>{
        ..._interestingCodePoints().where((_) => random.nextInt(6) == 0),
        for (var cp = 0; cp < 0x3000; cp += 3) cp,
        for (var i = 0; i < 1500; i++) random.nextInt(_maxCodePoint + 1),
      };
      for (final cp in codePoints) {
        final input = String.fromCharCode(cp);
        expect(_outcome(() => mine.saslprep(input)),
            _outcome(() => orig.Saslprep.saslprep(input)),
            reason: 'U+${cp.toRadixString(16)}');
      }
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('sequências aleatórias', () {
      final interesting = _interestingCodePoints();
      final random = Random(22);
      for (var i = 0; i < 2500; i++) {
        final input = _randomString(random, interesting);
        expect(_outcome(() => mine.saslprep(input)),
            _outcome(() => orig.Saslprep.saslprep(input)),
            reason: _cpString(input));
      }
    }, timeout: const Timeout(Duration(minutes: 20)));
  });
}
