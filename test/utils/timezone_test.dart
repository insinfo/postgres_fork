import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/src/timezone/database.dart';
import 'package:postgres_fork/src/timezone/env.dart' as tzenv;
import 'package:postgres_fork/src/timezone/timestamptz.dart';
import 'package:postgres_fork/timezone.dart';
import 'package:test/test.dart';

TimeZoneSettings _settings(String name,
        {TimeZoneDatabaseVariant variant = TimeZoneDatabaseVariant.full}) =>
    TimeZoneSettings(name,
        forceDecodeTimestamptzAsUTC: false, databaseVariant: variant);

void main() {
  group('bancos embutidos', () {
    test('versão e variantes', () {
      expect(tzdbVersion, matches(RegExp(r'^\d{4}[a-z]$')));
      final full = timeZoneDatabaseFor(TimeZoneDatabaseVariant.full);
      final reduced = timeZoneDatabaseFor(TimeZoneDatabaseVariant.reduced);
      expect(full.locations.length, greaterThan(550));
      expect(reduced.locations.length, greaterThan(400));
      expect(full.locations.length, greaterThan(reduced.locations.length));
      // Links do tzdata existem apenas no banco completo.
      expect(full.locations, contains('Brazil/East'));
      expect(reduced.locations, isNot(contains('Brazil/East')));
      expect(full.locations['Brazil/East']!.transitionAt,
          full.locations['America/Sao_Paulo']!.transitionAt);
    });

    test('codificação e decodificação preservam os dados', () {
      final full = timeZoneDatabaseFor(TimeZoneDatabaseVariant.full);
      final again = TimeZoneDatabase.decode(
          encodeLocations(full.locations.values));
      expect(again.locations.keys, full.locations.keys);
      for (final name in full.locations.keys) {
        final a = full.locations[name]!;
        final b = again.locations[name]!;
        expect(b.transitionAt, a.transitionAt, reason: name);
        expect(b.transitionZone, a.transitionZone, reason: name);
        expect(b.zones, a.zones, reason: name);
      }
    });

    test('histórico e futuro no banco completo', () {
      final full = timeZoneDatabaseFor(TimeZoneDatabaseVariant.full);
      final saoPaulo = full.locations['America/Sao_Paulo']!;
      // Horário de verão de 2009/2010 (-02) e sem horário de verão hoje (-03).
      expect(
          saoPaulo
              .timeZone(DateTime.utc(2010, 1, 15).millisecondsSinceEpoch)
              .offset,
          -2 * 3600000);
      expect(
          saoPaulo
              .timeZone(DateTime.utc(2025, 1, 15).millisecondsSinceEpoch)
              .offset,
          -3 * 3600000);
      // Transições explícitas além de 2037.
      final newYork = full.locations['America/New_York']!;
      expect(
          newYork.timeZone(DateTime.utc(2050, 7, 1).millisecondsSinceEpoch),
          const TimeZone(-4 * 3600000, isDst: true, abbreviation: 'EDT'));
      expect(
          newYork.timeZone(DateTime.utc(2050, 1, 1).millisecondsSinceEpoch),
          const TimeZone(-5 * 3600000, isDst: false, abbreviation: 'EST'));
    });
  });

  group('conversão de timestamptz', () {
    test('preserva o instante e usa o deslocamento da data', () {
      for (final variant in TimeZoneDatabaseVariant.values) {
        for (final value in [
          DateTime.utc(2024, 1, 15, 12),
          DateTime.utc(2024, 7, 15, 12),
          DateTime.utc(1990, 3, 1, 23, 59, 59, 999, 999),
        ]) {
          final result =
              convertTimestamptz(value, _settings('America/New_York', variant: variant));
          expect(result, isA<TZDateTime>());
          expect(result.isAtSameMomentAs(value), isTrue);
          expect(result.microsecondsSinceEpoch, value.microsecondsSinceEpoch);
        }
      }
      final winter = convertTimestamptz(
          DateTime.utc(2024, 1, 15, 12), _settings('America/New_York'));
      expect(winter.toString(), '2024-01-15 07:00:00.000-0500');
      expect(winter.timeZoneName, 'EST');
      final summer = convertTimestamptz(
          DateTime.utc(2024, 7, 15, 12), _settings('america/new_york'));
      expect(summer.toString(), '2024-07-15 08:00:00.000-0400');
      expect(summer.timeZoneName, 'EDT');
    });

    test('datas antigas: completo usa o histórico; reduzido, a janela', () {
      final value = DateTime.utc(2010, 1, 15, 12);
      final full = convertTimestamptz(value, _settings('America/Sao_Paulo'));
      expect(full.toString(), '2010-01-15 10:00:00.000-0200');
      final reduced = convertTimestamptz(value,
          _settings('America/Sao_Paulo',
              variant: TimeZoneDatabaseVariant.reduced));
      expect(reduced.toString(), '2010-01-15 09:00:00.000-0300');
      expect(reduced.isAtSameMomentAs(value), isTrue);
    });

    test('nomes só existentes no banco completo', () {
      final value = DateTime.utc(2024, 1, 15, 12);
      expect(convertTimestamptz(value, _settings('Brazil/East')).toString(),
          '2024-01-15 09:00:00.000-0300');
      expect(
          () => convertTimestamptz(value,
              _settings('Brazil/East',
                  variant: TimeZoneDatabaseVariant.reduced)),
          throwsA(isA<LocationNotFoundException>().having((e) => e.toString(),
              'message', 'Location with the name "brazil/east" doesn\'t exist')));
    });

    test('UTC, forceDecodeTimestamptzAsUTC e localização "local"', () {
      final value = DateTime.utc(2024, 1, 15, 12);
      expect(identical(convertTimestamptz(value, _settings('UTC')), value),
          isTrue);
      expect(
          identical(
              convertTimestamptz(value, TimeZoneSettings('Europe/Berlin')),
              value),
          isTrue);
      final berlin = convertTimestamptz(value, _settings('Europe/Berlin'));
      expect(tzenv.local.name, 'Europe/Berlin');
      expect((berlin as TZDateTime).isLocal, isTrue);
      expect(berlin.toString(), '2024-01-15 13:00:00.000+0100');
    });

    test('zona com deslocamento zero também vira TZDateTime', () {
      final value = DateTime.utc(2024, 1, 15, 12);
      final london = convertTimestamptz(value, _settings('Europe/London'));
      expect(london, isA<TZDateTime>());
      expect(london.toString(), '2024-01-15 12:00:00.000+0000');
      expect(london.timeZoneName, 'GMT');
    });
  });
}
