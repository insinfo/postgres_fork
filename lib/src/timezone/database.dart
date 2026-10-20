// Banco de localizações de fuso horário usado pelo decodificador de
// `timestamptz`.
//
// Os dados ficam em tz_data.dart, gerado por scripts/update_tzdb.dart a
// partir do banco de fusos da IANA (https://www.iana.org/time-zones).

import '../timezone_settings.dart';
import 'location.dart';
import 'tz_data.dart';

/// Exceção lançada quando uma localização não é encontrada.
class LocationNotFoundException implements Exception {
  final String msg;

  LocationNotFoundException(this.msg);

  @override
  String toString() => msg;
}

/// Conjunto de [Location]s indexadas pelo nome, na ordem dos dados.
class TimeZoneDatabase {
  /// Mapeamento do nome da [Location] para a [Location].
  final Map<String, Location> locations;

  TimeZoneDatabase(this.locations);

  /// Decodifica dados no formato de [encodeLocations].
  factory TimeZoneDatabase.decode(String data) {
    final locations = <String, Location>{};
    for (final location in decodeLocations(data)) {
      locations[location.name] = location;
    }
    return TimeZoneDatabase(locations);
  }

  /// Procura a [Location] pelo nome ou pela abreviação da zona atual,
  /// ignorando maiúsculas/minúsculas, e devolve a primeira encontrada na
  /// ordem dos dados.
  ///
  /// [pgTimeZone] deve estar em minúsculas.
  ///
  /// O resultado fica em cache até a próxima mudança de zona (por exemplo, de
  /// horário de verão) de alguma das localizações examinadas, pois só elas
  /// poderiam alterar o resultado da busca pela abreviação atual.
  Location? find(String pgTimeZone) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _findCache[pgTimeZone];
    if (cached != null && now >= cached.from && now < cached.until) {
      return cached.location;
    }
    var until = maxTime;
    Location? found;
    for (final e in locations.entries) {
      final instant = e.value.lookupTimeZone(now);
      if (instant.end < until) until = instant.end;
      if (e.key.toLowerCase() == pgTimeZone ||
          instant.timeZone.abbreviation.toLowerCase() == pgTimeZone) {
        found = e.value;
        break;
      }
    }
    _findCache[pgTimeZone] = _FindResult(found, now, until);
    return found;
  }

  final _findCache = <String, _FindResult>{};
}

class _FindResult {
  final Location? location;
  final int from;
  final int until;

  _FindResult(this.location, this.from, this.until);
}

TimeZoneDatabase? _fullDatabase;
TimeZoneDatabase? _reducedDatabase;

/// Banco de localizações embutido no driver (ver tz_data.dart).
///
/// Os dados são decodificados apenas no primeiro uso de cada variante.
TimeZoneDatabase timeZoneDatabaseFor(TimeZoneDatabaseVariant variant) {
  switch (variant) {
    case TimeZoneDatabaseVariant.full:
      return _fullDatabase ??= TimeZoneDatabase.decode(tzdbFullData);
    case TimeZoneDatabaseVariant.reduced:
      return _reducedDatabase ??= TimeZoneDatabase.decode(tzdbReducedData);
  }
}

// ---------------------------------------------------------------------------
// Formato dos dados
// ---------------------------------------------------------------------------
//
// Uma localização por linha ('\n'), no formato:
//
//   nome|zona;zona;...|transição,transição,...|índice,índice,...
//
// onde cada zona é `abreviação,deslocamento,dst` (deslocamento em segundos;
// dst é 1 ou 0), as transições são instantes em segundos desde 1970 UTC
// codificados como diferença em relação à anterior (a primeira é absoluta) e
// os índices apontam para a lista de zonas. Todos os números estão em base 36.
// Os valores em milissegundos de [Location] são sempre múltiplos de 1000.
//
// Uma localização com os mesmos dados de outra anterior (por exemplo, um link
// do tzdata) é gravada apenas como `nome|=outro`.

String _b36(int value) => value.toRadixString(36);

int _parseB36(String value) => int.parse(value, radix: 36);

/// Codifica [locations] no formato compacto lido por [decodeLocations].
String encodeLocations(Iterable<Location> locations) {
  final out = StringBuffer();
  final seen = <String, String>{};
  for (final location in locations) {
    final body = _encodeBody(location);
    final previous = seen[body];
    out
      ..write(location.name)
      ..write('|');
    if (previous != null) {
      out.write('=$previous');
    } else {
      seen[body] = location.name;
      out.write(body);
    }
    out.write('\n');
  }
  return out.toString();
}

String _encodeBody(Location location) {
  final zones = location.zones.map((z) {
    _checkMillis(z.offset, location.name);
    return '${z.abbreviation},${_b36(z.offset ~/ 1000)},${z.isDst ? 1 : 0}';
  }).join(';');
  final transitions = <String>[];
  var previous = 0;
  for (var i = 0; i < location.transitionAt.length; i++) {
    final at = location.transitionAt[i];
    _checkMillis(at, location.name);
    final seconds = at ~/ 1000;
    transitions.add(_b36(i == 0 ? seconds : seconds - previous));
    previous = seconds;
  }
  return '$zones|${transitions.join(',')}|'
      '${location.transitionZone.map(_b36).join(',')}';
}

void _checkMillis(int value, String name) {
  if (value % 1000 != 0) {
    throw ArgumentError('$name: $value não é múltiplo de 1000 ms');
  }
}

/// Decodifica dados produzidos por [encodeLocations].
List<Location> decodeLocations(String data) {
  final result = <Location>[];
  final byName = <String, Location>{};
  for (final line in data.split('\n')) {
    if (line.isEmpty) continue;
    final parts = line.split('|');
    if (parts[1].startsWith('=')) {
      final target = byName[parts[1].substring(1)]!;
      final location = Location(
          parts[0], target.transitionAt, target.transitionZone, target.zones);
      byName[location.name] = location;
      result.add(location);
      continue;
    }
    final zones = parts[1].isEmpty
        ? <TimeZone>[]
        : parts[1].split(';').map((z) {
            final f = z.split(',');
            return TimeZone(_parseB36(f[1]) * 1000,
                isDst: f[2] == '1', abbreviation: f[0]);
          }).toList();
    final transitionAt = <int>[];
    if (parts[2].isNotEmpty) {
      var previous = 0;
      final deltas = parts[2].split(',');
      for (var i = 0; i < deltas.length; i++) {
        final value = _parseB36(deltas[i]);
        final seconds = i == 0 ? value : previous + value;
        transitionAt.add(seconds * 1000);
        previous = seconds;
      }
    }
    final transitionZone = parts[3].isEmpty
        ? <int>[]
        : parts[3].split(',').map(_parseB36).toList();
    final location = Location(parts[0], transitionAt, transitionZone, zones);
    byName[location.name] = location;
    result.add(location);
  }
  return result;
}
