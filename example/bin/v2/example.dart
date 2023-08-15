import 'dart:convert';
import 'dart:io';

import 'package:enough_convert/enough_convert.dart';
import 'package:postgres_fork/postgres.dart';

void main(List<String> args) async {
  var connection = PostgreSQLConnection(
    'localhost',
    5432,
    'siamweb',
    username: 'dart',
    password: 'dart',
    encoding: utf8,
  );

  await connection.open();
  final dbExist = await connection
      .query('''SELECT * FROM pg_database WHERE datname = 'dart_test';''');
  if (dbExist.isEmpty) {
    if (Platform.isWindows) {
      await connection.query(
          '''CREATE DATABASE dart_test TEMPLATE = template0 ENCODING = 'WIN1252' LC_COLLATE = 'pt-BR' LC_CTYPE = 'pt-BR';''');
    } else {
      await connection.query(
          '''CREATE DATABASE dart_test TEMPLATE = template0 ENCODING = 'WIN1252' LC_COLLATE = 'pt_BR.cp1252' LC_CTYPE = 'pt_BR.cp1252';''');
    }
  }
  //await connection .query('''CREATE ROLE dart WITH LOGIN SUPERUSER PASSWORD 'dart';''');
  await connection.query(r''' do
$$
begin
  if not exists (select * from pg_user where usename = 'dart') then
     CREATE ROLE dart WITH LOGIN SUPERUSER PASSWORD 'dart';
  end if;
end
$$
; ''');
  await connection.close();

  connection = PostgreSQLConnection(
    'localhost',
    5432,
    'dart_test',
    username: 'dart',
    password: 'dart',
    encoding: Windows1252Codec(allowInvalid: false),
  );
  await connection.open();
  await connection.query('''SET client_encoding = 'win1252';''');

  await connection.execute('''
  CREATE TABLE IF NOT EXISTS public.favorites (
  "id" serial4 NOT NULL, 
  "date_register" timestamp(6),
  "description" varchar(255),
  CONSTRAINT "favorites_pkey" PRIMARY KEY ("id")
);
''');

  final now1 = DateTime.parse(DateTime.now().toIso8601String());

  final res = await connection.query(''' INSERT INTO public.favorites (date_register,description) VALUES ( ? , ? ) returning id ''',
      substitutionValues: [now1, 'City Hall of São Paulo - Brazil'],
      placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark);

  print('result: $res');

  // final res2 = await connection.transaction((ctx) {
  //   return ctx.query(' SELECT * FROM public.favorites WHERE id = ? ',
  //       substitutionValues: [res.first.first],
  //       allowReuse: true,
  //       timeoutInSeconds: 10,
  //       placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark);
  // });

  // print('result: $res2');

  final res3 = await connection.queryAsMap(
      ' SELECT * FROM public.favorites ORDER BY id desc LIMIT @limite',
      substitutionValues: {'limite': 10},
      placeholderIdentifier: PlaceholderIdentifier.atSign);

  print('result: $res3');

  await connection.close();
}
