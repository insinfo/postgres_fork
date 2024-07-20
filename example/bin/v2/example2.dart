import 'dart:convert';

import 'package:postgres_fork/postgres.dart';

void main(List<String> args)async {
   final connection = PostgreSQLConnection(
    'localhost',
    5432,
    'dart_test',
    username: 'dart',
    password: 'dart',
    encoding: utf8,
  );

  await connection.open();

  var results = await connection.query('select current_timestamp');
  var currentTimestamp = results.first.first as DateTime;
  print('dafault: $currentTimestamp ${currentTimestamp.timeZoneName}');
  print('local: ${currentTimestamp.toLocal()}');

  await connection.execute("set timezone to 'America/Sao_Paulo'");
  results = await connection.query('select current_timestamp');
  currentTimestamp = results.first.first as DateTime;
  print(
      'America/Sao_Paulo: $currentTimestamp ${currentTimestamp.timeZoneName}');

  await connection.execute("set timezone to 'UTC'");
  results = await connection.query('select current_timestamp');
  currentTimestamp = results.first.first as DateTime;
  print('UTC: $currentTimestamp ${currentTimestamp.timeZoneName}');

  await connection.execute("set timezone to 'America/New_York'");
  results = await connection.query('select current_timestamp');
  currentTimestamp = results.first.first as DateTime;
  print('America/New_York: $currentTimestamp ${currentTimestamp.timeZoneName}');

  await connection.execute("set timezone to 'EST'");
  results = await connection.query('select current_timestamp');
  currentTimestamp = results.first.first as DateTime;
  print('EST: $currentTimestamp ${currentTimestamp.timeZoneName}');

  results = await connection.query(
      "SELECT 'infinity'::TIMESTAMP as col1, '-infinity'::TIMESTAMP as col2, 'infinity'::date as col3, '-infinity'::date as col3");
  print('main: $results');

 await connection.close();
}