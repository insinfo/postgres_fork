//C:\MyDartProjects\postgresql-fork\test\docker.dart
//import 'dart:convert';

import 'dart:async';
import 'dart:io';
import 'package:docker_process/docker_process.dart';
import 'package:path/path.dart' as p;
import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

// Dockerfile content to build the custom image
const _dockerfileEnUSUTF8Content = r'''
FROM postgres:14.3

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=GMT

# ---------- pacotes + locale (inglês) ----------
RUN apt-get update && \
    apt-get install -y locales tzdata && \
    rm -rf /var/lib/apt/lists/* && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone && \
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && \
    locale-gen

# ---------- variáveis de ambiente ----------
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=en_US.UTF-8 --lc-messages=en_US.UTF-8"
''';
const _containerNameEnUSUTF8 = 'postgres-dart-test';
// Define a unique tag for the custom image
const String _customImageTag = 'postgres-dart-test:latest';
const String _customImageName = 'postgres-dart-test';
const String _customImageVersion = 'latest';

PostgreSQLConnection getNewConnection() {
  return PostgreSQLConnection('localhost', 5432, 'dart_test',
      username: 'dart',
      password: 'dart',
      timeoutInSeconds: 2,
      queryTimeoutInSeconds: 2);
}

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

Future<Directory> buildCustomImage(
    String dockerfileContent, String customImageTag) async {
  // --- Step 1: Build the custom Docker image ---
  final tempDir = await Directory.systemTemp.createTemp('postgres-dart-test-');
  final dockerfilePath = p.join(tempDir.path, 'Dockerfile');
  final dockerfile = File(dockerfilePath);
  await dockerfile.writeAsString(dockerfileContent);

  //print('Building custom Docker image: $customImageTag from ${tempDir.path}');
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
  //print('Custom Docker image built successfully.');

  return tempDir;
}

void usePostgresDocker(
    {bool enableLogicalReplication = true,
    String dockerfileContent = _dockerfileEnUSUTF8Content,
    String customImageTag = _customImageTag,
    String customImageVersion = _customImageVersion,
    String customImageName = _customImageName,
    String containerName = _containerNameEnUSUTF8,
    FutureOr Function()? onContainerReady}) {
  Directory? tempDir; // To store the temporary Dockerfile

  setUpAll(() async {
    // if (Platform.isWindows) {
    //   // for (var stmt in setupDatabaseStatements) {
    //   //   //final process =
    //   //   await Process.start('psql', ['-c', stmt, '-U', 'postgres']);
    //   //   //await process.stdout.transform(utf8.decoder).forEach(print);
    //   // }
    //   if (onContainerReady != null) {
    //     await onContainerReady();
    //   }
    //   return;
    // }

    await findAndStopContainersUsingPort(5432,
        excludeContainerName: containerName);

    // if (containerName != _containerNameEnUSUTF8) {
    //   // para a execução do _container En US UTF8
    //   final isRunningContainerNameEnUSUTF8 =
    //       await isPostgresContainerRunning(_containerNameEnUSUTF8);
    //   if (isRunningContainerNameEnUSUTF8) {
    //     await Process.run('docker', ['stop', _containerNameEnUSUTF8]);
    //     await Future.delayed(const Duration(seconds: 2));
    //   }
    // }
    // if (containerName == _containerNameEnUSUTF8) {
    //   final containerNameCp1252 = 'postgres-dart-test-cp1252';
    //   final isRunning = await isPostgresContainerRunning(containerNameCp1252);
    //   if (isRunning) {
    //     await Process.run('docker', ['stop', containerNameCp1252]);
    //     await Future.delayed(const Duration(seconds: 2));
    //   }
    // }

    final isRunning = await isPostgresContainerRunning(containerName);

    if (isRunning) {
      if (onContainerReady != null) {
        await onContainerReady();
      }
      return;
    }

    tempDir = await buildCustomImage(dockerfileContent, customImageTag);

    final configPath = p.join(Directory.current.path, 'test', 'pg_configs');

    final dp = await startPostgres(
      name: containerName,
      // imageName: 'postgres',
      // version: '14.3', //'14.3' '16.3'
      imageName: customImageName,
      version: customImageVersion,
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

    await setupDatabase(dp, containerName);

    if (onContainerReady != null) {
      await onContainerReady();
    }
  });

  tearDownAll(() async {
    //await Process.run('docker', ['stop', kContainerName]);
    // --- Clean up the temporary Dockerfile directory ---
    try {
      await tempDir?.delete(recursive: true);
      //print('Temporary directory ${tempDir.path} deleted.');
    } catch (e) {
      //print('Error deleting temporary directory ${tempDir.path}: $e');
    }
  });
}

Future<bool> isPostgresContainerRunning(String containerName) async {
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

Future<void> setupDatabase(DockerProcess dp, String containerName) async {
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
        'docker exec $containerName',
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

/// Finds containers using a specific host port and stops them.
///
/// Optionally excludes a specific container name from being stopped.
/// Returns true if any containers were stopped, false otherwise.
Future<bool> findAndStopContainersUsingPort(int port,
    {String? excludeContainerName}) async {
  bool stoppedAny = false;
  final pr = await Process.run(
    'docker',
    // List containers (running or not) filtering by published port
    // Format to get only the Name and ID
    ['ps', '-a', '--filter', 'publish=$port', '--format', '{{.Names}} {{.ID}}'],
    runInShell: true,
  );

  if (pr.exitCode != 0) {
    print(
        'Warning: Failed to list containers using port $port. Error: ${pr.stderr}');
    return false; // Can't determine, proceed cautiously
  }

  final lines = pr.stdout
      .toString()
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);

  for (final line in lines) {
    // Simple split assuming name doesn't contain spaces (usually safe for docker names)
    final parts = line.split(' ');
    if (parts.isEmpty) continue;
    final containerName = parts.first;
    // final containerId = parts.length > 1 ? parts[1] : null; // ID might be useful later

    if (containerName == excludeContainerName) {
      print(
          'Container "$containerName" is using port $port but is excluded from stopping.');
      continue; // Skip the container we intend to use or check later
    }

    print(
        'Found container "$containerName" using host port $port. Attempting to stop and remove...');
    stoppedAny = true;

    // Stop the container
    final stopResult =
        await Process.run('docker', ['stop', containerName], runInShell: true);
    if (stopResult.exitCode == 0) {
      print('Stopped container "$containerName" successfully.');
      // Wait a bit for Docker to process
      await Future.delayed(const Duration(seconds: 1));

      // Remove the container (optional but cleaner)
      final rmResult =
          await Process.run('docker', ['rm', containerName], runInShell: true);
      if (rmResult.exitCode == 0) {
        print('Removed container "$containerName" successfully.');
      } else {
        print(
            'Warning: Failed to remove container "$containerName". Error: ${rmResult.stderr}');
      }
      // Wait again after removal
      await Future.delayed(const Duration(seconds: 1));
    } else if (stopResult.stderr.toString().contains('No such container')) {
      print('Container "$containerName" already gone.');
    } else {
      print(
          'Warning: Failed to stop container "$containerName". Error: ${stopResult.stderr}');
      // Optionally try force remove if stop fails?
      // await Process.run('docker', ['rm', '-f', containerName]);
    }
  }
  return stoppedAny;
}
