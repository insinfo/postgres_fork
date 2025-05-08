//C:\MyDartProjects\postgresql-fork\test\docker.dart
//import 'dart:convert';
import 'dart:io';

import 'package:docker_process/containers/postgres.dart';
import 'package:path/path.dart' as p;
import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

const kContainerName = 'postgres-dart-test';

PostgreSQLConnection getNewConnection() {
  return PostgreSQLConnection('localhost', 5432, 'dart_test',
      username: 'dart',
      password: 'dart',
      timeoutInSeconds: 2,
      queryTimeoutInSeconds: 2);
}

void usePostgresDocker({bool enableLogicalReplication = false}) {
  setUpAll(() async {
    // if (Platform.isWindows) {
    //   for (var stmt in setupDatabaseStatements) {
    //     final process =
    //         await Process.start('psql', ['-c', stmt, '-U', 'postgres']);
    //     await process.stdout.transform(utf8.decoder).forEach(print);
    //   }
    //   return;
    // }
    final isRunning = await isPostgresContainerRunning();
    if (isRunning) {
      return;
    }

    final configPath = p.join(Directory.current.path, 'test', 'pg_configs');

    final dp = await startPostgres(
      name: kContainerName,
      imageName: 'postgres',
      version: '16.3',//'14.3'
      pgPort: 5432,
      pgDatabase: 'postgres',
      pgUser: 'postgres',
      pgPassword: 'postgres',
      cleanup: true,
      configurations: [
        // SSL settings
        'ssl=on',
        // The debian image includes a self-signed SSL cert that can be used:
        'ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem',
        'ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key',
        if (enableLogicalReplication) ...[
          'wal_level=logical',
          'max_wal_senders=5',
          'max_replication_slots=5',
        ]
      ],
      pgHbaConfPath: p.join(configPath, 'pg_hba.conf'),
      postgresqlConfPath: p.join(configPath, 'postgresql.conf'),
    );

    await setupDatabase(dp);
  });

  tearDownAll(() async {
    await Process.run('docker', ['stop', kContainerName]);
  });
}

Future<bool> isPostgresContainerRunning(
    {String containerName = kContainerName}) async {
  final pr = await Process.run(
    'docker',
    ['ps', '--format', '{{.Names}}'],
  );
  return pr.stdout
      .toString()
      .split('\n')
      .map((s) => s.trim())
      .contains(containerName);
}

Future<void> setupDatabase(DockerProcess dp) async {
  // Setup the database to support all kind of tests
  // see _setupDatabaseStatements definition for details
  for (var stmt in setupDatabaseStatements) {
    final args = [
      'psql',
      '-c',
      stmt,
      '-U',
      'postgres',
    ];
    final res = await dp.exec(args);
    if (res.exitCode != 0) {
      final message =
          'Failed to setup PostgreSQL database due to the following error:\n'
          '${res.stderr}';
      throw ProcessException(
        'docker exec $kContainerName',
        args,
        message,
        res.exitCode,
      );
    }
  }
}

// This setup supports old and new test
// This is setup is the same as the one from the old travis ci except for the
// replication user which is a new addition.
final setupDatabaseStatements = <String>[
  // create testing database
  'create database dart_test;',
  // create dart user
  'create user dart with createdb;',
  "alter user dart with password 'dart';",
  'grant all on database dart_test to dart;',
  // create darttrust user
  'create user darttrust with createdb;',
  'grant all on database dart_test to darttrust;',
  // create replication user
  "create role replication with replication password 'replication' login;",
];
