// SASLprep (RFC 4013), usado para preparar a senha na autenticação
// SCRAM-SHA-256.
//
// Substitui o pacote `saslprep` 1.0.3 (MIT, Copyright (c) 2019 Richard
// Burkhardt) mantendo o mesmo comportamento, inclusive as mesmas exceções e
// mensagens. As tabelas foram extraídas do pacote original para
// saslprep_tables.dart (ver
// dependency_parity/tool/generate_saslprep_tables.dart).

import 'dart:typed_data';

import 'nfkc.dart';
import 'saslprep_tables.dart';

/// Retorna se [codePoint] está em algum dos intervalos `[início, fim]` de
/// [ranges] (lista ordenada de pares), usando busca binária.
bool codePointInRanges(List<int> ranges, int codePoint) {
  var low = 0;
  var high = ranges.length ~/ 2 - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    final start = ranges[mid * 2];
    final end = ranges[mid * 2 + 1];
    if (codePoint < start) {
      high = mid - 1;
    } else if (codePoint > end) {
      low = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// Converte [input] em code points, combinando pares de surrogates.
Uint32List _toCodePoints(String input) {
  var codePoints = Uint32List(input.length);
  var sizeOffset = 0;
  var codePointIndex = 0;
  for (var i = 0; i < input.length; i++) {
    final before = input.codeUnitAt(i);

    if (before >= 0xd800 && before <= 0xdbff && input.length > i + 1) {
      final next = input.codeUnitAt(i + 1);

      if (next >= 0xdc00 && next <= 0xdfff) {
        codePoints[codePointIndex++] =
            ((before - 0xd800) * 0x400 + next - 0xdc00 + 0x10000);
        i++;
        sizeOffset++;
        continue;
      }
    }
    codePoints[codePointIndex++] = before;
  }
  codePoints = codePoints.sublist(0, codePoints.length - sizeOffset);
  return codePoints;
}

/// Aplica o perfil SASLprep (RFC 4013) a [input].
///
/// Lança [Exception] se o resultado contiver caracteres proibidos, code points
/// não atribuídos no Unicode 3.2 ou violar as regras bidirecionais.
String saslprep(String input) {
  if (input.isEmpty) {
    return '';
  }

  // 1. Map
  final mappedInput = _toCodePoints(input)
      // 1.1 mapping to space
      .map((character) =>
          codePointInRanges(nonAsciiSpaceRanges, character) ? 0x20 : character)
      // 1.2 mapping to nothing
      .where((character) => !codePointInRanges(mappedToNothingRanges, character));

  // 2. Normalize
  final normalizedInput = nfkc(String.fromCharCodes(mappedInput));

  final normalizedMap = _toCodePoints(normalizedInput);

  // 3. Prohibit
  final hasProhibited = normalizedMap
      .any((character) => codePointInRanges(prohibitedRanges, character));

  if (hasProhibited) {
    throw Exception(
        'Prohibited character, see https://tools.ietf.org/html/rfc4013#section-2.3');
  }

  // Unassigned Code Points
  final hasUnassigned = normalizedMap
      .any((character) => codePointInRanges(unassignedRanges, character));
  if (hasUnassigned) {
    throw Exception(
        'Unassigned code point, see https://tools.ietf.org/html/rfc4013#section-2.5');
  }

  // 4. check bidi
  final hasBidiRAL = normalizedMap
      .any((character) => codePointInRanges(bidiRAndALRanges, character));
  final hasBidiL =
      normalizedMap.any((character) => codePointInRanges(bidiLRanges, character));

  // 4.1 If a string contains any RandALCat character, the string MUST NOT
  // contain any LCat character.
  if (hasBidiRAL && hasBidiL) {
    throw Exception(
        'String must not contain RandALCat and LCat at the same time, see https://tools.ietf.org/html/rfc3454#section-6');
  }

  // 4.2 If a string contains any RandALCat character, a RandALCat
  // character MUST be the first character of the string, and a
  // RandALCat character MUST be the last character of the string.
  //
  // Assim como no pacote original, estes valores são calculados mesmo quando
  // não há caracteres RandALCat, usando code units (lança RangeError se o
  // resultado normalizado for vazio).
  final isFirstBidiRAL =
      codePointInRanges(bidiRAndALRanges, normalizedInput.codeUnitAt(0));
  final isLastBidiRAL = codePointInRanges(bidiRAndALRanges,
      normalizedInput.codeUnitAt(normalizedInput.length - 1));

  if (hasBidiRAL && !(isFirstBidiRAL && isLastBidiRAL)) {
    throw Exception(
        'Bidirectional RandALCat character must be the first and the last character of the string, see https://tools.ietf.org/html/rfc3454#section-6');
  }

  return normalizedInput;
}
