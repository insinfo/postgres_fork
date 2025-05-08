// test/connection_encoding_test.dart
@Timeout(Duration(seconds: 45))
import 'dart:convert';
import 'package:enough_convert/enough_convert.dart';
import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';
import 'docker.dart';

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
const String kContainerName = 'postgres-dart-test-cp1252';
void main() {
  PostgreSQLConnection? connection;

  usePostgresDocker(
    dockerfileContent: dockerfileContent,
    customImageTag: customImageTag,
    customImageName: customImageName,
    customImageVersion: customImageVersion,
    containerName: kContainerName,
    enableLogicalReplication: false,
    onContainerReady: () async {
      PostgreSQLConnection? startConn;

      startConn = PostgreSQLConnection(
        'localhost',
        5432,
        'postgres', // Connect to default 'postgres' db initially
        username: 'dart', // Use user created by setupDatabase
        password: 'dart',
        encoding: utf8,
      );

      await startConn.open();

      await startConn
          .execute('DROP DATABASE IF EXISTS dart_test_cp1252 WITH (FORCE);');
      await Future.delayed(const Duration(seconds: 2)); // Increased delay

      await startConn.query('''
  CREATE DATABASE dart_test_cp1252
    TEMPLATE = template0
    ENCODING = 'WIN1252'
    LC_COLLATE = 'pt_BR'
    LC_CTYPE   = 'pt_BR';
''');

      await startConn.close();

      connection = PostgreSQLConnection(
        'localhost',
        5432,
        'dart_test_cp1252', // Connect to the target DB
        username: 'dart',
        password: 'dart',
        encoding: Windows1252Codec(allowInvalid: false),
      );
      await connection?.open();

      await connection?.query('''DROP TABLE IF EXISTS public.favorites;''');
      await connection?.execute('''
        CREATE TABLE IF NOT EXISTS public.favorites (
          "id" serial4 NOT NULL,
          "date_register" timestamp(6),
          "description" varchar(255),
          CONSTRAINT "favorites_pkey" PRIMARY KEY ("id")
        );
      ''');
      await connection?.query(
        ''' INSERT INTO public.favorites (date_register,description) VALUES ( ? , ? ) returning id ''',
        substitutionValues: [
          DateTime.utc(2023, 8, 15, 16, 07, 36),
          'City Hall of São Paulo - Brazil'
        ],
        placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark,
      );
    },
  );

  tearDown(() async {
    await connection?.close();
    // // --- Database Dropping Logic ---
    PostgreSQLConnection? maintenanceConn;
    try {
      maintenanceConn = PostgreSQLConnection(
          'localhost', 5432, 'postgres', // Connect to default DB
          username: 'dart',
          password: 'dart');
      await maintenanceConn.open();
      await maintenanceConn
          .execute('DROP DATABASE IF EXISTS dart_test_cp1252 WITH (FORCE);');
      //print('Database dart_test_cp1252 dropped.');
    } catch (e) {
      //print('Error dropping database in tearDown: $e.');
    } finally {
      await maintenanceConn?.close();
    }

    // // --- Container Stopping Logic ---

    // final stopResult = await Process.run('docker', ['stop', kContainerName]);
    // if (stopResult.exitCode != 0 &&
    //     !stopResult.stderr.toString().contains('No such container')) {
    //   //print('Error stopping container $kContainerName: ${stopResult.stderr}');
    // } else {
    //   //print('Container $kContainerName stopped.');
    // }

    // // --- Clean up the temporary Dockerfile directory ---
    // try {
    //   await tempDir.delete(recursive: true);
    //   //print('Temporary directory ${tempDir.path} deleted.');
    // } catch (e) {
    //   //print('Error deleting temporary directory ${tempDir.path}: $e');
    // }
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
  });
}
