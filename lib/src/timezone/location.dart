// Fusos horários: localizações e zonas.
//
// Substitui o pacote `pg_timezone` 1.0.1 (fork do pacote `timezone`) mantendo
// a mesma lógica. A maior parte deste código foi originalmente portada da
// biblioteca padrão do Go (time/zoneinfo.go) pelo projeto `timezone`.
//
// Copyright (c) 2014, the timezone project authors.
// Copyright (c) 2024, pg_timezone project authors.
// All rights reserved. Use of this source code is governed by a BSD-style
// license (ver lib/src/timezone/LICENSE).

/// Valor máximo para instantes de tempo.
const int maxTime = 8640000000000000;

/// Valor mínimo para instantes de tempo.
const int minTime = -maxTime;

/// Uma [Location] mapeia instantes de tempo para a zona em uso naquele
/// instante. Normalmente representa o conjunto de deslocamentos usados numa
/// área geográfica, como CEST e CET na Europa central.
class Location {
  /// Nome da [Location].
  final String name;

  /// Instantes das transições, em milissegundos desde 1970 UTC.
  final List<int> transitionAt;

  /// Índice da zona que entra em vigor em cada transição.
  final List<int> transitionZone;

  /// [TimeZone]s desta [Location].
  final List<TimeZone> zones;

  /// [TimeZone] do momento atual.
  TimeZone get currentTimeZone =>
      timeZone(DateTime.now().millisecondsSinceEpoch);

  // A maioria das consultas é para o momento atual. Para evitar a busca
  // binária, mantém um cache com a zona em vigor quando a Location foi
  // criada: se cacheStart <= t < cacheEnd, a consulta devolve cacheZone.
  static final int _cacheNow = DateTime.now().millisecondsSinceEpoch;
  int _cacheStart = 0;
  int _cacheEnd = 0;
  late TimeZone _cacheZone;

  Location(this.name, this.transitionAt, this.transitionZone, this.zones) {
    // Preenche o cache com as informações do momento atual.
    for (var i = 0; i < transitionAt.length; i++) {
      final tAt = transitionAt[i];

      if ((tAt <= _cacheNow) &&
          ((i + 1 == transitionAt.length) ||
              (_cacheNow < transitionAt[i + 1]))) {
        _cacheStart = tAt;
        _cacheEnd = maxTime;
        if (i + 1 < transitionAt.length) {
          _cacheEnd = transitionAt[i + 1];
        }
        _cacheZone = zones[transitionZone[i]];
      }
    }
  }

  /// Converte um instante (milissegundos desde 1970-01-01 00:00:00 UTC) para
  /// esta [Location].
  int translate(int millisecondsSinceEpoch) {
    return millisecondsSinceEpoch + timeZone(millisecondsSinceEpoch).offset;
  }

  /// Converte um horário local (milissegundos desde 1970-01-01 00:00:00)
  /// para UTC.
  int translateToUtc(int millisecondsSinceEpoch) {
    final t = lookupTimeZone(millisecondsSinceEpoch);
    final tz = t.timeZone;
    final start = t.start;
    final end = t.end;

    var utc = millisecondsSinceEpoch;

    if (tz.offset != 0) {
      utc -= tz.offset;

      if (utc < start) {
        utc =
            millisecondsSinceEpoch - lookupTimeZone(start - 1).timeZone.offset;
      } else if (utc >= end) {
        utc = millisecondsSinceEpoch - lookupTimeZone(end).timeZone.offset;
      }
    }

    return utc;
  }

  /// Procura a [TimeZone] e os limites do período em vigor num instante
  /// (milissegundos desde 1970-01-01 00:00:00 UTC).
  TzInstant lookupTimeZone(int millisecondsSinceEpoch) {
    if (zones.isEmpty) {
      return const TzInstant(TimeZone.UTC, minTime, maxTime);
    }

    if (millisecondsSinceEpoch >= _cacheStart &&
        millisecondsSinceEpoch < _cacheEnd) {
      return TzInstant(_cacheZone, _cacheStart, _cacheEnd);
    }

    if (transitionAt.isEmpty || millisecondsSinceEpoch < transitionAt[0]) {
      final zone = _firstZone();
      const start = minTime;
      final end = transitionAt.isEmpty ? maxTime : transitionAt.first;
      return TzInstant(zone, start, end);
    }

    // Busca binária pela maior transição <= instante.
    var lo = 0;
    var hi = transitionAt.length;
    var end = maxTime;

    while (hi - lo > 1) {
      final m = lo + (hi - lo) ~/ 2;
      final at = transitionAt[m];

      if (millisecondsSinceEpoch < at) {
        end = at;
        hi = m;
      } else {
        lo = m;
      }
    }

    return TzInstant(zones[transitionZone[lo]], transitionAt[lo], end);
  }

  /// [TimeZone] em uso num instante (milissegundos desde 1970 UTC).
  TimeZone timeZone(int millisecondsSinceEpoch) {
    return lookupTimeZone(millisecondsSinceEpoch).timeZone;
  }

  /// [TimeZone] em uso num horário local (milissegundos desde 1970).
  TimeZone timeZoneFromLocal(int millisecondsSinceEpoch) {
    final t = lookupTimeZone(millisecondsSinceEpoch);
    var tz = t.timeZone;
    final start = t.start;
    final end = t.end;

    if (tz.offset != 0) {
      final utc = millisecondsSinceEpoch - tz.offset;

      if (utc < start) {
        tz = lookupTimeZone(start - 1).timeZone;
      } else if (utc >= end) {
        tz = lookupTimeZone(end).timeZone;
      }
    }

    return tz;
  }

  /// [TimeZone] usada antes da primeira transição, ou quando não há
  /// transições (mesmo algoritmo do localtime.c da IANA):
  ///
  /// 1. Se a primeira zona não é usada pelas transições, usa-a.
  /// 2. Senão, se há transições e a primeira é para horário de verão, usa a
  ///    zona sem horário de verão mais próxima antes dela.
  /// 3. Senão, usa a primeira zona sem horário de verão, se houver.
  /// 4. Senão, usa a primeira zona.
  TimeZone _firstZone() {
    // caso 1
    if (!_firstZoneIsUsed()) {
      return zones.first;
    }

    // caso 2
    if (transitionZone.isNotEmpty && zones[transitionZone.first].isDst) {
      for (var zi = transitionZone.first - 1; zi >= 0; zi--) {
        final z = zones[zi];
        if (!z.isDst) {
          return z;
        }
      }
    }

    // caso 3
    for (final zi in transitionZone) {
      final z = zones[zi];
      if (!z.isDst) {
        return z;
      }
    }

    // caso 4
    return zones.first;
  }

  /// Indica se a primeira zona é usada por alguma transição.
  bool _firstZoneIsUsed() {
    for (final i in transitionZone) {
      if (i == 0) {
        return true;
      }
    }

    return false;
  }

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Location &&
            runtimeType == other.runtimeType &&
            name == other.name;
  }

  @override
  int get hashCode {
    return name.hashCode;
  }
}

/// Uma [TimeZone] representa uma única zona, como CEST ou CET.
class TimeZone {
  // ignore: constant_identifier_names
  static const TimeZone UTC = TimeZone(0, isDst: false, abbreviation: 'UTC');

  /// Milissegundos a leste de UTC.
  final int offset;

  /// Indica se é horário de verão.
  final bool isDst;

  /// Nome abreviado, como "CET".
  final String abbreviation;

  const TimeZone(this.offset,
      {required this.isDst, required this.abbreviation});

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TimeZone &&
            offset == other.offset &&
            isDst == other.isDst &&
            abbreviation == other.abbreviation;
  }

  @override
  int get hashCode {
    var result = 17;
    result = 37 * result + offset.hashCode;
    result = 37 * result + isDst.hashCode;
    result = 37 * result + abbreviation.hashCode;
    return result;
  }

  @override
  String toString() => '[$abbreviation offset=$offset dst=$isDst]';
}

/// Uma [TzInstant] representa uma zona e o período em que ela vigora.
class TzInstant {
  final TimeZone timeZone;
  final int start;
  final int end;

  const TzInstant(this.timeZone, this.start, this.end);
}
