import 'dart:math';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:test/test.dart';

import 'docker.dart';

/// Papel temporário criado para o teste, com a senha armazenada no formato
/// [passwordEncryption] ('scram-sha-256' ou 'md5'). Com `md5` no pg_hba.conf,
/// o servidor usa SCRAM-SHA-256 quando a senha está armazenada como SCRAM.
class _TestRole {
  final String name;
  final String password;
  final String passwordEncryption;

  _TestRole(this.name, this.password, this.passwordEncryption);
}

String _quoteLiteral(String value) => "'${value.replaceAll("'", "''")}'";

PostgreSQLConnection _adminConnection() => PostgreSQLConnection(
    'localhost', 5432, 'dart_test',
    username: 'postgres', password: 'postgres');

void main() {
  usePostgresDocker();

  final suffix = Random.secure().nextInt(1 << 32).toRadixString(36);
  final roles = <_TestRole>[
    _TestRole('dart_auth_scram_ascii_$suffix', 'S3nh@-ascii,=x',
        'scram-sha-256'),
    _TestRole('dart_auth_scram_utf8_$suffix', 'pöstgrēs_üšęr_pæsswœêrd',
        'scram-sha-256'),
    // O SASLprep normaliza a senha (NFKC): "²" vira "2" e "ﬁ" vira "fi",
    // tanto no servidor (ao armazenar) quanto no cliente.
    _TestRole('dart_auth_scram_nfkc_$suffix', 'ﬁle-senha²', 'scram-sha-256'),
    _TestRole('dart_auth_md5_$suffix', 'md5-S3nh@', 'md5'),
    // MD5 com senha não-ASCII (o hash usa os bytes UTF-8, como o libpq).
    _TestRole('dart_auth_md5_utf8_$suffix', 'pöstgrēs_üšęr', 'md5'),
    // SCRAM com senha rejeitada pelo SASLprep (caractere de controle ou
    // resultado vazio): servidor e cliente usam a senha como está.
    _TestRole('dart_auth_scram_ctrl_$suffix',
        'abc${String.fromCharCode(7)}def', 'scram-sha-256'),
    _TestRole('dart_auth_scram_empty_$suffix',
        String.fromCharCodes([0xAD, 0xAD]), 'scram-sha-256'),
  ];

  setUpAll(() async {
    final admin = _adminConnection();
    await admin.open();
    try {
      for (final role in roles) {
        await admin.execute(
            'SET password_encryption = ${_quoteLiteral(role.passwordEncryption)}');
        await admin.execute('CREATE ROLE "${role.name}" LOGIN '
            'PASSWORD ${_quoteLiteral(role.password)}');
      }
    } finally {
      await admin.close();
    }
  });

  tearDownAll(() async {
    final admin = _adminConnection();
    await admin.open();
    try {
      for (final role in roles) {
        await admin.execute('DROP ROLE IF EXISTS "${role.name}"');
      }
    } finally {
      await admin.close();
    }
  });

  for (final role in roles) {
    group(role.name.replaceAll('_$suffix', ''), () {
      test('API v2 conecta com a senha correta', () async {
        final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
            username: role.name, password: role.password);
        await conn.open();
        try {
          final result = await conn.query('SELECT current_user');
          expect(result.first.first, role.name);
        } finally {
          await conn.close();
        }
      });

      test('API v2 rejeita senha incorreta', () async {
        final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
            username: role.name, password: '${role.password}-errada');
        await expectLater(conn.open(), throwsA(isA<PostgreSQLException>()));
      });

      test('API v3 conecta com a senha correta', () async {
        final conn = await PgConnection.open(
          PgEndpoint(
            host: 'localhost',
            database: 'dart_test',
            username: role.name,
            password: role.password,
          ),
          sessionSettings:
              PgSessionSettings(onBadSslCertificate: (cert) => true),
        );
        try {
          expect(await conn.execute('SELECT current_user::text'), [
            [role.name]
          ]);
        } finally {
          await conn.close();
        }
      });

      test('API v3 rejeita senha incorreta', () async {
        await expectLater(
          PgConnection.open(
            PgEndpoint(
              host: 'localhost',
              database: 'dart_test',
              username: role.name,
              password: '${role.password}-errada',
            ),
            sessionSettings:
                PgSessionSettings(onBadSslCertificate: (cert) => true),
          ),
          throwsA(isA<PostgreSQLException>()),
        );
      });
    });
  }
}
