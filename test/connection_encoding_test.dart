// test/connection_encoding_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:docker_process/docker_process.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:path/path.dart' as p;
import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

// Dockerfile content to build the custom image
const String dockerfileContent = r'''
# Use a imagem base oficial do PostgreSQL que você já utiliza nos seus testes
# Use a specific version consistent with your tests
FROM postgres:14.3

# Variáveis de ambiente para evitar interatividade durante a instalação
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo

# Instalar pacotes necessários e configurar o locale pt_BR.CP1252
# Os comandos são executados como root por padrão no Dockerfile
# ---------- pacotes + locale CP1252 ----------
RUN apt-get update && \
    apt-get install -y locales tzdata && \
    rm -rf /var/lib/apt/lists/* && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    echo 'pt_BR.CP1252 CP1252' >> /etc/locale.gen && \
    echo 'pt_BR.UTF-8 UTF-8'   >> /etc/locale.gen && \
    locale-gen && \
    # cria alias 'pt_BR' usando charmap CP1252
    localedef -i pt_BR -f CP1252 pt_BR

# ---------- variáveis padrão que o PostgreSQL usará ----------
ENV LANG=pt_BR.CP1252
ENV LC_ALL=pt_BR.CP1252
ENV POSTGRES_INITDB_ARGS="--encoding=WIN1252 --locale=pt_BR.CP1252"
''';


// Define a unique tag for the custom image
const String customImageTag = 'postgres-dart-test-cp1252:latest';
const String customImageName = 'postgres-dart-test-cp1252';
const String customImageVersion = 'latest';
const kContainerName = 'postgres-dart-test';

Future<DockerProcess> startPostgres({
  required String name,
  required String version,
  String imageName = 'postgres',
  String? network,
  String? pgUser,
  String pgPassword = 'postgres',
  String? pgDatabase,
  int pgPort = 5432,
  bool? cleanup,
  String? postgresqlConfPath,
  String? pgHbaConfPath,
  List<String>? configurations,
  String? timeZone,
  Duration? startupTimeout,
}) async {
  var ipv4 = false;

  final dockerArgs = <String>[];
  final imageArgs = <String>[];

  if (configurations != null) {
    for (var config in configurations) {
      imageArgs.add('-c');
      imageArgs.add(config);
    }
  }

  if (postgresqlConfPath != null) {
    dockerArgs.add('-v');
    dockerArgs.add('$postgresqlConfPath:/etc/postgresql/postgresql.conf');
    imageArgs.add('-c');
    imageArgs.add('config_file=/etc/postgresql/postgresql.conf');
  }

  if (pgHbaConfPath != null) {
    dockerArgs.add('-v');
    dockerArgs.add('$pgHbaConfPath:/etc/postgresql/pg_hba.conf');
    imageArgs.add('-c');
    imageArgs.add('hba_file=/etc/postgresql/pg_hba.conf');
  }

  // A função DockerProcess.start aceita um timeout para o readySignal
  return await DockerProcess.start(
    name: name,
    dockerArgs: dockerArgs,
    image: '$imageName:$version',
    imageArgs: imageArgs,
    network: network,
    hostname: name,
    ports: ['$pgPort:5432'],
    cleanup: cleanup,
    readySignal: (line) {
      ipv4 |= line.contains('listening on IPv4 address "0.0.0.0", port 5432');
      return ipv4 &&
          line.contains('database system is ready to accept connections');
    },
    // Passando o timeout para DockerProcess.start
    timeout: startupTimeout,
    environment: {
      if (pgUser != null) 'POSTGRES_USER': pgUser,
      'POSTGRES_PASSWORD': pgPassword,
      if (pgDatabase != null) 'POSTGRES_DB': pgDatabase,
      if (timeZone != null) 'TZ': timeZone,
      if (timeZone != null) 'PGTZ': timeZone,
    },
  );
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

void main() {
  // Declare connection here so it's accessible in tearDown,
  // but initialize as nullable or use a flag to check initialization.
  // Using nullable is often cleaner for tearDown error handling.
  PostgreSQLConnection? connection;
  late Directory tempDir; // To store the temporary Dockerfile

  setUp(() async {
    print('Starting setUp...');
    // Reset connection to null at the start of each setup
    connection = null;

    // --- Step 1: Build the custom Docker image ---
    tempDir = await Directory.systemTemp.createTemp('postgres-dart-test-');
    final dockerfilePath = p.join(tempDir.path, 'Dockerfile');
    final dockerfile = File(dockerfilePath);
    await dockerfile.writeAsString(dockerfileContent);

    print('Building custom Docker image: $customImageTag from ${tempDir.path}');
    final stopwatchBuild = Stopwatch()..start();
    final buildResult = await Process.run(
        'docker', ['build', '-t', customImageTag, '.'],
        workingDirectory: tempDir.path, runInShell: true);
    stopwatchBuild.stop();
    print(
        'Docker build finished in ${stopwatchBuild.elapsedMilliseconds} ms. Exit code: ${buildResult.exitCode}');

    if (buildResult.exitCode != 0) {
      print('Docker build failed:');
      print('STDOUT:\n${buildResult.stdout}');
      print('STDERR:\n${buildResult.stderr}');
      // Clean up temp dir even on build failure
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
      throw Exception(
          'Failed to build custom Docker image $customImageTag. Exit code: ${buildResult.exitCode}');
    }
    print('Custom Docker image built successfully.');

    // --- Step 2: Start the container using the custom image ---
    final isRunning =
        await isPostgresContainerRunning(containerName: kContainerName);
    if (isRunning) {
      print('Container $kContainerName already running. Stopping it...');
      await Process.run('docker', ['stop', kContainerName]);
      await Future.delayed(const Duration(seconds: 2)); // Wait for stop
    }

    final configPath = p.join(Directory.current.path, 'test', 'pg_configs');

    print('Starting PostgreSQL container...');
    final stopwatchStart = Stopwatch()..start();
    final dp = await startPostgres(
      name: kContainerName,
      imageName: customImageName,
      version: customImageVersion,
      pgPort: 5432,
      pgDatabase: 'postgres',
      pgUser: 'postgres',
      pgPassword: 'postgres',
      cleanup: true,
      configurations: [
        'ssl=on',
        'ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem',
        'ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key',
      ],
      pgHbaConfPath: p.join(configPath, 'pg_hba.conf'),
      postgresqlConfPath: p.join(configPath, 'postgresql.conf'),
      // Provide a longer timeout specifically for container start
      startupTimeout: Duration(minutes: 2),
    );
    stopwatchStart.stop();
    print(
        'PostgreSQL container started in ${stopwatchStart.elapsedMilliseconds} ms.');

    // --- Step 3: Setup Database and Test Connection ---
    print('Setting up database users and permissions...');
    await setupDatabase(dp); // Standard user/db setup inside the container

    PostgreSQLConnection? startConn;
    try {
      startConn = PostgreSQLConnection(
        'localhost',
        5432,
        'postgres', // Connect to default 'postgres' db initially
        username: 'dart', // Use user created by setupDatabase
        password: 'dart',
        encoding: utf8,
      );
      print('Connecting to postgres DB...');
      await startConn.open();
      print('Connected. Dropping existing test DB (if any)...');
      await startConn
          .execute('DROP DATABASE IF EXISTS dart_test_cp1252 WITH (FORCE);');
      await Future.delayed(const Duration(seconds: 2)); // Increased delay

      print('Creating database dart_test_cp1252...');
      await startConn.query('''
  CREATE DATABASE dart_test_cp1252
    TEMPLATE = template0
    ENCODING = 'WIN1252'
    LC_COLLATE = 'pt_BR'
    LC_CTYPE   = 'pt_BR';
''');
      print('Database created successfully.');
      // Add another delay *after* creating the database
      await Future.delayed(const Duration(seconds: 3)); // Wait for DB init
    } catch (e, s) {
      print('Failed during initial DB setup: $e\n$s');
      // Attempt cleanup even on failure
      await startConn?.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
      // Stop the container if setup failed
      await Process.run('docker', ['stop', kContainerName]);
      rethrow;
    } finally {
      await startConn?.close();
      print('Initial setup connection closed.');
    }

    // --- Final Connection to the test DB ---
    print('Connecting to the test database dart_test_cp1252...');
    try {
      // Initialize the actual test connection variable
      connection = PostgreSQLConnection(
        'localhost',
        5432,
        'dart_test_cp1252', // Connect to the target DB
        username: 'dart',
        password: 'dart',
        encoding: Windows1252Codec(allowInvalid: false),
      );
      await connection!
          .open(); // Use null-check operator ! as it should be assigned
      print('Connected to test database.');

      print('Setting up test table...');
      await connection!.query('''DROP TABLE IF EXISTS public.favorites;''');
      await connection!.execute('''
        CREATE TABLE IF NOT EXISTS public.favorites (
          "id" serial4 NOT NULL,
          "date_register" timestamp(6),
          "description" varchar(255),
          CONSTRAINT "favorites_pkey" PRIMARY KEY ("id")
        );
      ''');
      await connection!.query(
        ''' INSERT INTO public.favorites (date_register,description) VALUES ( ? , ? ) returning id ''',
        substitutionValues: [
          DateTime.utc(2023, 8, 15, 16, 07, 36),
          'City Hall of São Paulo - Brazil'
        ],
        placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark,
      );
      print('Setup complete.');
    } catch (e, s) {
      print('Failed connecting to or setting up test DB: $e\n$s');
      // Cleanup dockerfile directory if connection fails
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {/* Ignore cleanup error */}
      // Stop the container if setup failed
      await Process.run('docker', ['stop', kContainerName]);
      rethrow; // Rethrow the original error
    }
  });

  tearDown(() async {
    print('Running tearDown...');
    // Use null-aware operator ?. to safely call close
    await connection?.close();
    print('Test connection closed.');

    // --- Database Dropping Logic ---
    PostgreSQLConnection? maintenanceConn;
    try {
      maintenanceConn = PostgreSQLConnection(
          'localhost', 5432, 'postgres', // Connect to default DB
          username: 'dart',
          password: 'dart');
      await maintenanceConn.open();
      await maintenanceConn
          .execute('DROP DATABASE IF EXISTS dart_test_cp1252 WITH (FORCE);');
      print('Database dart_test_cp1252 dropped.');
    } catch (e) {
      print('Error dropping database in tearDown: $e.');
    } finally {
      await maintenanceConn?.close();
    }

    // --- Container Stopping Logic ---
    print('Stopping container $kContainerName...');
    final stopResult = await Process.run('docker', ['stop', kContainerName]);
    if (stopResult.exitCode != 0 &&
        !stopResult.stderr.toString().contains('No such container')) {
      print('Error stopping container $kContainerName: ${stopResult.stderr}');
    } else {
      print('Container $kContainerName stopped.');
    }

    // --- Clean up the temporary Dockerfile directory ---
    try {
      await tempDir.delete(recursive: true);
      print('Temporary directory ${tempDir.path} deleted.');
    } catch (e) {
      print('Error deleting temporary directory ${tempDir.path}: $e');
    }
    print('tearDown complete.');
  });

  // Optional: Clean up the built image after all tests in this file run
  // tearDownAll(() async {
  //   print('Running tearDownAll: Removing custom Docker image $customImageTag...');
  //   final rmiResult = await Process.run('docker', ['rmi', customImageTag]);
  //   if (rmiResult.exitCode != 0) {
  //     print('Error removing image $customImageTag: ${rmiResult.stderr}');
  //   } else {
  //     print('Custom Docker image $customImageTag removed.');
  //   }
  // });

  test('select varchar encoding win1252', () async {
    print('Running test: select varchar encoding win1252');
    // Ensure connection was initialized before running the test
    expect(connection, isNotNull,
        reason: 'Test connection was not initialized in setUp');

    final results = await connection!.query(
        // Use null assertion operator
        'SELECT date_register,description FROM public.favorites LIMIT @l',
        substitutionValues: {'l': 1});

    final expectedTimestamp = DateTime.utc(2023, 8, 15, 16, 07, 36);

    expect(results, hasLength(1));
    expect(results[0], hasLength(2));
    expect((results[0][0] as DateTime).isUtc, isTrue);
    expect(results[0][0], equals(expectedTimestamp));
    expect(results[0][1], equals('City Hall of São Paulo - Brazil'));
    print('Test finished successfully.');
  });
}
