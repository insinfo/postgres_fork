// Compara o runtime de fusos horários interno (lib/src/timezone) com o
// pacote `pg_timezone` 1.0.1, usando exatamente os mesmos dados
// (pgDatabaseMap), e a conversão de `timestamptz` antiga com a nova.
//
// ignore_for_file: implementation_imports, depend_on_referenced_packages

import 'dart:math';

import 'package:pg_timezone/pg_timezone.dart' as pg;
import 'package:pg_timezone/src/pg_timezone_data.dart';
import 'package:pg_timezone/timezone.dart' as pgenv;
import 'package:postgres_fork/postgres.dart' show TimeZoneSettings;
import 'package:postgres_fork/src/timezone/database.dart' as mine_db;
import 'package:postgres_fork/src/timezone/date_time.dart' as mine;
import 'package:postgres_fork/src/timezone/env.dart' as mine_env;
import 'package:postgres_fork/src/timezone/location.dart' as mine;
import 'package:postgres_fork/src/timezone/timestamptz.dart';
import 'package:test/test.dart';

/// Banco interno construído a partir dos mesmos dados do pg_timezone,
/// passando pelo codificador/decodificador do formato embutido.
final mine_db.TimeZoneDatabase _myDb = mine_db.TimeZoneDatabase.decode(
    mine_db.encodeLocations(pgDatabaseMap.values.map((l) => mine.Location(
            l.name, List.of(l.transitionAt), List.of(l.transitionZone), [
          for (final z in l.zones)
            mine.TimeZone(z.offset,
                isDst: z.isDst, abbreviation: z.abbreviation)
        ]))));

String _tz(Object z) {
  if (z is pg.TimeZone) return '${z.abbreviation}/${z.offset}/${z.isDst}';
  final m = z as mine.TimeZone;
  return '${m.abbreviation}/${m.offset}/${m.isDst}';
}

String _outcome(Object? Function() fn) {
  try {
    return 'ok:${fn()}';
  } catch (e) {
    return 'error:${e.runtimeType.toString().replaceAll('pg.', '')}:$e';
  }
}

/// Descreve um DateTime/TZDateTime de forma independente da implementação.
String _describe(DateTime d) {
  final buf = StringBuffer()
    ..write('${d.runtimeType}|')
    ..write('${d.toString()}|${d.toIso8601String()}|')
    ..write('${d.millisecondsSinceEpoch}|${d.microsecondsSinceEpoch}|')
    ..write('${d.year}-${d.month}-${d.day} ${d.hour}:${d.minute}:')
    ..write('${d.second}.${d.millisecond}.${d.microsecond}|')
    ..write('wd=${d.weekday}|utc=${d.isUtc}|')
    ..write('tzn=${d.timeZoneName}|tzo=${d.timeZoneOffset}');
  if (d is pg.TZDateTime) {
    buf.write('|loc=${d.location.name}|tz=${_tz(d.timeZone)}');
    buf.write('|local=${d.isLocal}');
  } else if (d is mine.TZDateTime) {
    buf.write('|loc=${d.location.name}|tz=${_tz(d.timeZone)}');
    buf.write('|local=${d.isLocal}');
  }
  return buf.toString().replaceAll('_TZDateTime', 'TZDateTime');
}

/// Instantes de teste para uma localização: em volta de cada transição e
/// valores aleatórios entre 1900 e 2100.
List<int> _instants(List<int> transitions, Random random) {
  final result = <int>[0, minTimeSafe, maxTimeSafe];
  for (final t in transitions) {
    if (t <= -8640000000000000) continue;
    for (final d in const [-3600001, -1, 0, 1, 3599999, 86400000]) {
      result.add(t + d);
    }
  }
  for (var i = 0; i < 40; i++) {
    result.add(-2208988800000 + random.nextInt(1 << 32) * 1474);
  }
  return result;
}

const minTimeSafe = -8640000000000000;
const maxTimeSafe = 8640000000000000 - 1;

void main() {
  test('dados idênticos após codificar/decodificar', () {
    expect(_myDb.locations.keys.toList(), pgDatabaseMap.keys.toList());
    for (final name in pgDatabaseMap.keys) {
      final a = pgDatabaseMap[name]!;
      final b = _myDb.locations[name]!;
      expect(b.transitionAt, a.transitionAt, reason: name);
      expect(b.transitionZone, a.transitionZone, reason: name);
      expect(b.zones.map(_tz).toList(), a.zones.map(_tz).toList(),
          reason: name);
    }
  });

  test('Location: consultas idênticas', () {
    final random = Random(50);
    for (final name in pgDatabaseMap.keys) {
      final a = pgDatabaseMap[name]!;
      final b = _myDb.locations[name]!;
      expect(_tz(b.currentTimeZone), _tz(a.currentTimeZone), reason: name);
      for (final t in _instants(a.transitionAt, random)) {
        final la = a.lookupTimeZone(t);
        final lb = b.lookupTimeZone(t);
        expect('${_tz(lb.timeZone)} ${lb.start} ${lb.end}',
            '${_tz(la.timeZone)} ${la.start} ${la.end}',
            reason: '$name lookup $t');
        expect(b.translate(t), a.translate(t), reason: '$name translate $t');
        expect(_outcome(() => b.translateToUtc(t)),
            _outcome(() => a.translateToUtc(t)),
            reason: '$name translateToUtc $t');
        expect(_tz(b.timeZoneFromLocal(t)), _tz(a.timeZoneFromLocal(t)),
            reason: '$name timeZoneFromLocal $t');
      }
    }
  });

  test('TZDateTime: construtores, getters e operações idênticos', () {
    final random = Random(51);
    final names = pgDatabaseMap.keys.toList();
    for (var round = 0; round < 20000; round++) {
      final name = names[random.nextInt(names.length)];
      final pa = pgDatabaseMap[name]!;
      final mb = _myDb.locations[name]!;

      // Às vezes, define a localização "local" nos dois ambientes.
      if (random.nextInt(4) == 0) {
        pgenv.setLocalLocation(pa);
        mine_env.setLocalLocation(mb);
      }

      // Campos locais: aleatórios ou perto de uma transição (lacunas e
      // sobreposições do horário de verão).
      int year, month, day, hour, minute, second, ms, us;
      final real = pa.transitionAt.where((t) => t > -8640000000000000).toList();
      if (real.isNotEmpty && random.nextBool()) {
        final t = real[random.nextInt(real.length)];
        final local = DateTime.fromMillisecondsSinceEpoch(
            t + pa.timeZone(t).offset + (random.nextInt(7) - 3) * 1800000,
            isUtc: true);
        year = local.year;
        month = local.month;
        day = local.day;
        hour = local.hour;
        minute = local.minute;
      } else {
        year = 1900 + random.nextInt(200);
        month = 1 + random.nextInt(12);
        day = 1 + random.nextInt(31);
        hour = random.nextInt(24);
        minute = random.nextInt(60);
      }
      second = random.nextInt(60);
      ms = random.nextInt(1000);
      us = random.nextInt(1000);

      final a = pg.TZDateTime(pa, year, month, day, hour, minute, second, ms, us);
      final b =
          mine.TZDateTime(mb, year, month, day, hour, minute, second, ms, us);
      expect(_describe(b), _describe(a), reason: '$name $year-$month-$day');

      final duration = Duration(
          microseconds: (random.nextInt(1 << 32) - (1 << 31)) * 1000);
      expect(_describe(b.add(duration)), _describe(a.add(duration)));
      expect(_describe(b.subtract(duration)), _describe(a.subtract(duration)));
      expect(_describe(b.toUtc()), _describe(a.toUtc()));
      expect(_describe(b.toLocal()), _describe(a.toLocal()));

      final other = DateTime.fromMicrosecondsSinceEpoch(
          a.microsecondsSinceEpoch + random.nextInt(1000000) - 500000,
          isUtc: random.nextBool());
      expect(b.difference(other), a.difference(other));
      expect(b.compareTo(other), a.compareTo(other));
      expect(b.isBefore(other), a.isBefore(other));
      expect(b.isAfter(other), a.isAfter(other));
      expect(b.isAtSameMomentAs(other), a.isAtSameMomentAs(other));
      expect(b.hashCode, a.hashCode);

      final b2 = mine.TZDateTime.from(other, mb);
      final a2 = pg.TZDateTime.from(other, pa);
      expect(_describe(b2), _describe(a2));
      expect(b == b2, a == a2);
      expect(b == b.add(Duration.zero), a == a.add(Duration.zero));

      final micros = other.microsecondsSinceEpoch;
      expect(_describe(mine.TZDateTime.fromMicrosecondsSinceEpoch(mb, micros)),
          _describe(pg.TZDateTime.fromMicrosecondsSinceEpoch(pa, micros)));
      expect(
          _describe(mine.TZDateTime.fromMillisecondsSinceEpoch(
              mb, micros ~/ 1000)),
          _describe(
              pg.TZDateTime.fromMillisecondsSinceEpoch(pa, micros ~/ 1000)));
      final iso = other.toIso8601String();
      expect(_describe(mine.TZDateTime.parse(mb, iso)),
          _describe(pg.TZDateTime.parse(pa, iso)));
    }
    expect(
        _describe(mine.TZDateTime.utc(2020, 2, 29, 23, 59, 59, 999, 999)),
        _describe(pg.TZDateTime.utc(2020, 2, 29, 23, 59, 59, 999, 999)));
    expect(_describe(mine.TZDateTime.local(2021, 7, 1, 12)),
        _describe(pg.TZDateTime.local(2021, 7, 1, 12)));
  });

  group('conversão de timestamptz', () {
    // Código antigo do binary_codec.dart (com pg_timezone), sem alterações.
    DateTime oldConvert(DateTime datetime, TimeZoneSettings timeZone) {
      if (timeZone.forceDecodeTimestamptzAsUTC) {
        return datetime;
      }
      if (timeZone.value.toLowerCase() == 'utc') {
        return datetime;
      }

      final pgTimeZone = timeZone.value.toLowerCase();
      final tzLocations = pg.timeZoneDatabase.locations.entries
          .where((e) {
            return (e.key.toLowerCase() == pgTimeZone ||
                e.value.currentTimeZone.abbreviation.toLowerCase() ==
                    pgTimeZone);
          })
          .map((e) => e.value)
          .toList();

      if (tzLocations.isEmpty) {
        throw pg.LocationNotFoundException(
            'Location with the name "$pgTimeZone" doesn\'t exist');
      }
      final tzLocation = tzLocations.first;
      pgenv.setLocalLocation(tzLocation);

      final offsetInMilliseconds = tzLocation.currentTimeZone.offset;
      final double offset = offsetInMilliseconds / (1000 * 60 * 60);

      if (offset < 0) {
        final subtr = Duration(
            hours: offset.abs().truncate(),
            minutes: ((offset.abs() % 1) * 60).round());
        datetime = datetime.subtract(subtr);
        return pg.TZDateTime(
            tzLocation,
            datetime.year,
            datetime.month,
            datetime.day,
            datetime.hour,
            datetime.minute,
            datetime.second,
            datetime.millisecond,
            datetime.microsecond);
      } else if (offset > 0) {
        final addr = Duration(
            hours: offset.truncate(), minutes: ((offset % 1) * 60).round());
        datetime = datetime.add(addr);
        return pg.TZDateTime(
            tzLocation,
            datetime.year,
            datetime.month,
            datetime.day,
            datetime.hour,
            datetime.minute,
            datetime.second,
            datetime.millisecond,
            datetime.microsecond);
      }

      return datetime;
    }

    String run(DateTime Function() fn) {
      try {
        final d = fn();
        return 'ok:${_describe(d)}';
      } catch (e) {
        return 'error:${e.runtimeType}:$e';
      }
    }

    test('todas as localizações, abreviações e nomes desconhecidos', () {
      final random = Random(52);
      final settingsValues = <String>{
        'UTC', 'utc', 'Utc', 'GMT', 'Etc/UTC', 'Zulu',
        for (final e in pgDatabaseMap.entries) ...[
          e.key,
          e.key.toUpperCase(),
          e.value.currentTimeZone.abbreviation,
        ],
        'America/Inexistente', '', 'xyz', 'brt', '-03', '+0530',
      };
      var wrongInstantsBefore = 0;
      var conversions = 0;
      for (final value in settingsValues) {
        for (var i = 0; i < 12; i++) {
          final micros = i == 0
              ? 0
              : (random.nextInt(1 << 32) - (1 << 31)) * 1500000 +
                  random.nextInt(1000000);
          final utc = DateTime.utc(2000).add(Duration(microseconds: micros));
          final settings = TimeZoneSettings(value,
              forceDecodeTimestamptzAsUTC: false,
              forceDecodeTimestampAsUTC: random.nextBool());
          final expected = run(() => oldConvert(utc, settings));
          final actual =
              run(() => convertTimestamptz(utc, settings, database: _myDb));

          // Erros: mesmas exceções e mensagens.
          if (expected.startsWith('error') || actual.startsWith('error')) {
            expect(actual.replaceAll('LocationNotFoundException', 'LNF'),
                expected.replaceAll('LocationNotFoundException', 'LNF'),
                reason: '"$value"');
            continue;
          }
          // Mesma localização escolhida (estado global "local").
          expect(mine_env.local.name, pgenv.local.name, reason: value);

          final result = convertTimestamptz(utc, settings, database: _myDb);
          if (value.toLowerCase() == 'utc') {
            expect(result, utc);
            expect(result.isUtc, isTrue);
            continue;
          }
          conversions++;
          // Correção: o instante é preservado...
          expect(result.isAtSameMomentAs(utc), isTrue, reason: '"$value" $utc');
          // ...e os campos locais seguem o deslocamento daquela data.
          final location = _myDb.locations[mine_env.local.name]!;
          final zone = location.timeZone(utc.millisecondsSinceEpoch);
          final local = utc.add(Duration(milliseconds: zone.offset));
          expect(result, isA<mine.TZDateTime>());
          expect(
              '${result.year}-${result.month}-${result.day} ${result.hour}:'
              '${result.minute}:${result.second}.${result.millisecond}'
              '${result.microsecond} ${result.timeZoneName} '
              '${result.timeZoneOffset}',
              '${local.year}-${local.month}-${local.day} ${local.hour}:'
              '${local.minute}:${local.second}.${local.millisecond}'
              '${local.microsecond} ${zone.abbreviation} '
              '${Duration(milliseconds: zone.offset)}',
              reason: '"$value" $utc');
          // Quando o código antigo acertava o instante, o resultado é igual.
          final before = oldConvert(utc, settings);
          if (before.isAtSameMomentAs(utc) && before is pg.TZDateTime) {
            expect(_describe(result), _describe(before),
                reason: '"$value" $utc');
          } else if (!before.isAtSameMomentAs(utc)) {
            wrongInstantsBefore++;
          }
        }
      }
      // ignore: avoid_print
      print('conversões: $conversions; instantes errados no código antigo: '
          '$wrongInstantsBefore');
      expect(wrongInstantsBefore, greaterThan(0));
    });

    test('forceDecodeTimestamptzAsUTC', () {
      final utc = DateTime.utc(2024, 5, 6, 7, 8, 9, 10, 11);
      for (final value in ['America/Sao_Paulo', 'xyz', 'UTC']) {
        final settings = TimeZoneSettings(value);
        expect(run(() => convertTimestamptz(utc, settings, database: _myDb)),
            run(() => oldConvert(utc, settings)));
      }
    });
  });
}
