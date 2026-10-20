// Leitor de arquivos TZif (RFC 9636) e conversão para Location.
//
// Mesma lógica de `zicfile.dart` e `tzfileLocationToNativeLocation` do pacote
// pg_timezone 1.0.1 / timezone (Copyright (c) 2014, the timezone project
// authors; licença BSD, ver lib/src/timezone/LICENSE): para as versões 2+ são
// lidos os dados de 64 bits.

import 'dart:collection';
import 'dart:convert' show ascii;
import 'dart:typed_data';

import 'package:postgres_fork/src/timezone/location.dart';

const int _ziMagic = 1415211366; // "TZif"

const int _maxMillisecondsSinceEpoch = 8640000000000000;
const int _maxSecondsSinceEpoch = 8640000000000;

class InvalidZoneInfoDataException implements Exception {
  final String msg;
  InvalidZoneInfoDataException(this.msg);
  @override
  String toString() => msg;
}

class _Header {
  static const size = 6 * 4;
  final int ttisgmtcnt, ttisstdcnt, leapcnt, timecnt, typecnt, charcnt;

  _Header(ByteData data, int offset)
      : ttisgmtcnt = data.getInt32(offset),
        ttisstdcnt = data.getInt32(offset + 4),
        leapcnt = data.getInt32(offset + 8),
        timecnt = data.getInt32(offset + 12),
        typecnt = data.getInt32(offset + 16),
        charcnt = data.getInt32(offset + 20);

  int dataLength(int longSize) =>
      ttisgmtcnt +
      ttisstdcnt +
      leapcnt * (longSize + 4) +
      timecnt * (longSize + 1) +
      typecnt * 6 +
      charcnt;
}

/// Dados de um arquivo TZif (instantes em segundos).
class TzifData {
  final String name;
  final List<int> transitionAt;
  final List<int> transitionZone;
  final List<int> offsets;
  final List<bool> isDst;
  final List<String> abbreviations;

  TzifData(this.name, this.transitionAt, this.transitionZone, this.offsets,
      this.isDst, this.abbreviations);

  /// Lê um arquivo TZif. Para as versões 2 em diante, usa os dados de 64 bits.
  factory TzifData.parse(String name, Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(0) != _ziMagic) {
      throw InvalidZoneInfoDataException('$name: cabeçalho inválido');
    }
    final version = data.getUint8(4);
    var offset = 20;
    var longSize = 4;
    if (version != 0) {
      if (version < 0x32 || version > 0x34) {
        throw InvalidZoneInfoDataException('$name: versão desconhecida $version');
      }
      // Pula os dados de 32 bits.
      final header1 = _Header(data, offset);
      offset += _Header.size + header1.dataLength(4);
      if (data.getUint32(offset) != _ziMagic ||
          data.getUint8(offset + 4) != version) {
        throw InvalidZoneInfoDataException('$name: segundo cabeçalho inválido');
      }
      offset += 20;
      longSize = 8;
    }
    final h = _Header(data, offset);
    var p = offset + _Header.size;

    final transitionAt = <int>[];
    for (var i = 0; i < h.timecnt; i++) {
      transitionAt
          .add(longSize == 8 ? data.getInt64(p) : data.getInt32(p));
      p += longSize;
    }
    final transitionZone = <int>[];
    for (var i = 0; i < h.timecnt; i++) {
      transitionZone.add(data.getUint8(p++));
    }

    final typesOffset = p;
    final abbrOffset = typesOffset + h.typecnt * 6;
    final abbrevs = bytes.sublist(abbrOffset, abbrOffset + h.charcnt);
    String abbrAt(int index) {
      var end = index;
      while (end < abbrevs.length && abbrevs[end] != 0) {
        end++;
      }
      return ascii.decode(abbrevs.sublist(index, end));
    }

    final cache = HashMap<int, String>();
    final offsets = <int>[];
    final isDst = <bool>[];
    final abbreviations = <String>[];
    for (var i = 0; i < h.typecnt; i++) {
      final q = typesOffset + i * 6;
      offsets.add(data.getInt32(q));
      isDst.add(data.getInt8(q + 4) == 1);
      final idx = data.getUint8(q + 5);
      abbreviations.add(cache.putIfAbsent(idx, () => abbrAt(idx)));
    }
    return TzifData(
        name, transitionAt, transitionZone, offsets, isDst, abbreviations);
  }

  /// Converte para [Location] (milissegundos), como
  /// `tzfileLocationToNativeLocation` do pg_timezone.
  Location toLocation() {
    final at = transitionAt
        .map((i) =>
            (i < -_maxSecondsSinceEpoch) ? -_maxMillisecondsSinceEpoch : i * 1000)
        .toList();
    final zones = <TimeZone>[
      for (var i = 0; i < offsets.length; i++)
        TimeZone(offsets[i] * 1000,
            isDst: isDst[i], abbreviation: abbreviations[i])
    ];
    return Location(name, at, List.of(transitionZone), zones);
  }
}

/// Recorte das transições de uma localização, idêntico a
/// `filterTimeZoneData` do pg_timezone (inclusive no detalhe de que a
/// transição sintética em [minTime] recebe a zona da primeira transição
/// >= [dateFrom], que é então descartada).
Location filterLocation(Location l,
    {int dateFrom = -_maxMillisecondsSinceEpoch,
    int dateTo = _maxMillisecondsSinceEpoch}) {
  final transitionsCount = l.transitionAt.length;
  final newTransitionAt = <int>[];
  final newTransitionZone = <int>[];

  if (transitionsCount == 0) {
    return Location(l.name, newTransitionAt, newTransitionZone, l.zones);
  }

  var i = 0;
  while (i < transitionsCount && dateFrom > l.transitionAt[i]) {
    i++;
  }

  if (i < transitionsCount) {
    newTransitionAt.add(-_maxMillisecondsSinceEpoch);
    newTransitionZone.add(l.transitionZone[i]);
    i++;
    while (i < transitionsCount && l.transitionAt[i] <= dateTo) {
      newTransitionAt.add(l.transitionAt[i]);
      newTransitionZone.add(l.transitionZone[i]);
      i++;
    }
  } else {
    newTransitionAt.add(-_maxMillisecondsSinceEpoch);
    newTransitionZone.add(l.transitionZone[i - 1]);
  }
  return Location(l.name, newTransitionAt, newTransitionZone, l.zones);
}
