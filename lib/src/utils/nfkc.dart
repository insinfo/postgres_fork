// Normalização Unicode NFKC usada pelo SASLprep (RFC 4013) na autenticação
// SCRAM-SHA-256.
//
// Esta implementação substitui o pacote `unorm_dart` 0.3.0 (MIT, Copyright (c)
// 2018 Yasuhiro Shimizu), que era dependência transitiva via `saslprep`. Para
// manter exatamente o mesmo resultado, ela reproduz o mesmo algoritmo e usa os
// mesmos dados (Unicode 8.0, extraídos para saslprep_tables.dart), inclusive as
// particularidades do original:
//
// * code points < 60 e no intervalo (13311, 42607) nunca são consultados na
//   tabela de dados (não decompõem, não compõem e têm classe combinante 0);
// * o intervalo de sílabas Hangul tratado algoritmicamente inclui U+D7A4
//   (`SBase + SCount`), um code point além da última sílaba;
// * a regra de bloqueio da composição canônica é a do unorm
//   (`ultimaClasse < classe || ultimaClasse == 0`).

import 'saslprep_tables.dart';

const _sBase = 0xAC00;
const _lBase = 0x1100;
const _vBase = 0x1161;
const _tBase = 0x11A7;
const _lCount = 19;
const _vCount = 21;
const _tCount = 28;
const _nCount = _vCount * _tCount;
const _sCount = _lCount * _nCount;

class _NfkcData {
  final Map<int, List<int>> decompositions;
  final Map<int, int> combiningClasses;
  final Map<int, int> compositions;

  _NfkcData(this.decompositions, this.combiningClasses, this.compositions);

  static final instance = _load();

  static _NfkcData _load() {
    final decompositions = <int, List<int>>{};
    for (final entry in nfkcDecompositionData.split(';')) {
      final parts = entry.split(':');
      decompositions[_parseHex(parts[0])] =
          List<int>.unmodifiable(parts[1].split(',').map(_parseHex));
    }

    final combiningClasses = <int, int>{};
    for (final entry in nfkcCombiningClassData.split(';')) {
      final parts = entry.split(':');
      combiningClasses[_parseHex(parts[0])] = _parseHex(parts[1]);
    }

    final compositions = <int, int>{};
    for (final entry in nfkcCompositionData.split(';')) {
      final parts = entry.split(':');
      final pair = parts[0].split(',');
      compositions[_pairKey(_parseHex(pair[0]), _parseHex(pair[1]))] =
          _parseHex(parts[1]);
    }

    return _NfkcData(decompositions, combiningClasses, compositions);
  }
}

int _parseHex(String value) => int.parse(value, radix: 16);

int _pairKey(int starter, int following) => starter * 0x200000 + following;

bool _isFiltered(int cp) => cp < 60 || (13311 < cp && cp < 42607);

bool _isLeadingJamo(int cp) => _lBase <= cp && cp < _lBase + _lCount;

// Inclui `_sBase + _sCount` de propósito (mesmo comportamento do unorm_dart).
bool _isHangulSyllable(int cp) => _sBase <= cp && cp <= _sBase + _sCount;

List<int>? _decomposition(int cp) {
  if (_isFiltered(cp) || _isLeadingJamo(cp)) return null;
  if (_isHangulSyllable(cp)) {
    final sIndex = cp - _sBase;
    final tIndex = sIndex % _tCount;
    if (tIndex != 0) {
      return [_sBase + sIndex - tIndex, _tBase + tIndex];
    }
    return [_lBase + sIndex ~/ _nCount, _vBase + (sIndex % _nCount) ~/ _tCount];
  }
  return _NfkcData.instance.decompositions[cp];
}

int _combiningClass(int cp) {
  if (_isFiltered(cp) || _isLeadingJamo(cp) || _isHangulSyllable(cp)) {
    return 0;
  }
  return _NfkcData.instance.combiningClasses[cp] ?? 0;
}

int? _composite(int starter, int following) {
  if (_isFiltered(starter)) return null;
  if (_isLeadingJamo(starter)) {
    final vIndex = following - _vBase;
    if (vIndex < 0 || vIndex >= _vCount) return null;
    return _sBase + _tCount * (vIndex + (starter - _lBase) * _vCount);
  }
  if (_isHangulSyllable(starter)) {
    final sIndex = starter - _sBase;
    if (sIndex % _tCount != 0) return null;
    final j = following - _tBase;
    if (j < 1 || j >= _tCount) return null;
    return starter + j;
  }
  final composite =
      _NfkcData.instance.compositions[_pairKey(starter, following)];
  return composite != null && composite > 0 ? composite : null;
}

void _decomposeRecursively(int cp, List<int> out) {
  final decomposition = _decomposition(cp);
  if (decomposition == null) {
    out.add(cp);
    return;
  }
  for (final d in decomposition) {
    _decomposeRecursively(d, out);
  }
}

/// Normaliza [input] na forma NFKC (decomposição de compatibilidade seguida de
/// composição canônica), com o mesmo resultado de `nfkc` do `unorm_dart`.
String nfkc(String input) {
  // 1. Lê os code points (pares de surrogates são combinados; surrogates
  //    isolados são mantidos como estão) e decompõe recursivamente.
  final decomposed = <int>[];
  for (var i = 0; i < input.length;) {
    var cp = input.codeUnitAt(i++);
    if (cp >= 0xD800 && cp <= 0xDBFF && i < input.length) {
      final next = input.codeUnitAt(i);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        cp = (cp - 0xD800) * 0x400 + (next - 0xDC00) + 0x10000;
        i++;
      }
    }
    _decomposeRecursively(cp, decomposed);
  }

  // 2. Ordenação canônica: cada lote lido vai até o próximo caractere com
  //    classe combinante 0 (inclusive), e os caracteres com classe diferente
  //    de zero são inseridos ordenados de forma estável.
  final ordered = <int>[];
  final batch = <int>[];
  var position = 0;
  while (true) {
    if (batch.isEmpty) {
      while (position < decomposed.length) {
        final cp = decomposed[position++];
        final cc = _combiningClass(cp);
        var insertAt = batch.length;
        if (cc != 0) {
          for (; insertAt > 0; --insertAt) {
            if (_combiningClass(batch[insertAt - 1]) <= cc) break;
          }
        }
        batch.insert(insertAt, cp);
        if (cc == 0) break;
      }
    }
    if (batch.isEmpty) break;
    ordered.add(batch.removeAt(0));
  }

  // 3. Composição canônica.
  final out = StringBuffer();
  var processing = <int>[];
  var lastClass = -1;
  for (final cp in ordered) {
    if (processing.isEmpty) {
      lastClass = _combiningClass(cp);
      processing.add(cp);
      continue;
    }
    final composite = _composite(processing[0], cp);
    final cc = _combiningClass(cp);
    if (composite != null && (lastClass < cc || lastClass == 0)) {
      processing[0] = composite;
    } else {
      if (cc == 0) {
        processing.forEach(out.writeCharCode);
        processing = <int>[];
      }
      lastClass = cc;
      processing.add(cp);
    }
  }
  processing.forEach(out.writeCharCode);
  return out.toString();
}
