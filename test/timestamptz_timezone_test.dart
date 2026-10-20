import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/timezone.dart';
import 'package:test/test.dart';

import 'docker.dart';

void main() {
  usePostgresDocker();

  Future<PostgreSQLConnection> open(TimeZoneSettings settings) async {
    final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart', timeZone: settings);
    await conn.open();
    return conn;
  }

  for (final variant in TimeZoneDatabaseVariant.values) {
    test('timestamptz em America/New_York preserva o instante ($variant)',
        () async {
      final conn = await open(TimeZoneSettings('America/New_York',
          forceDecodeTimestamptzAsUTC: false, databaseVariant: variant));
      addTearDown(conn.close);
      final rows = await conn.query(
          "SELECT '2024-01-15 12:00:00+00'::timestamptz, "
          "'2024-07-15 12:00:00+00'::timestamptz, "
          "current_setting('TimeZone')");
      final winter = rows.first[0] as DateTime;
      final summer = rows.first[1] as DateTime;
      expect(rows.first[2], 'America/New_York');
      expect(winter, isA<TZDateTime>());
      expect(winter.isAtSameMomentAs(DateTime.utc(2024, 1, 15, 12)), isTrue);
      expect(summer.isAtSameMomentAs(DateTime.utc(2024, 7, 15, 12)), isTrue);
      expect(winter.toString(), '2024-01-15 07:00:00.000-0500');
      expect(summer.toString(), '2024-07-15 08:00:00.000-0400');
    });
  }

  test('timestamptz antigo usa o histórico do fuso (banco completo)', () async {
    final conn = await open(TimeZoneSettings('America/Sao_Paulo',
        forceDecodeTimestamptzAsUTC: false));
    addTearDown(conn.close);
    final rows = await conn.query(
        "SELECT '2010-01-15 12:00:00+00'::timestamptz, "
        "to_char('2010-01-15 12:00:00+00'::timestamptz, 'HH24:MI OF')");
    final value = rows.first[0] as DateTime;
    expect(value.isAtSameMomentAs(DateTime.utc(2010, 1, 15, 12)), isTrue);
    // Mesmo horário local que o próprio PostgreSQL calcula.
    expect(rows.first[1], '10:00 -02');
    expect(value.toString(), '2010-01-15 10:00:00.000-0200');
  });
}
