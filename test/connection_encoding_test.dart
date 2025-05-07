//dart test .\test\connection_encoding_test.dart   --concurrency 1 --chain-stack-traces --platform vm
import 'dart:convert';
import 'dart:io';
import 'package:enough_convert/enough_convert.dart';
import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

void main() {
  late PostgreSQLConnection connection;
  setUp(() async {
    final startConn = PostgreSQLConnection(
      'localhost',
      5432,
      'dart_test',
      username: 'dart',
      password: 'dart',
      encoding: utf8,
    );
    await startConn.open();
    final dbExist = await startConn.query(
        '''SELECT * FROM pg_database WHERE datname = 'dart_test_cp1252';''');
    if (dbExist.isEmpty) {
      if (Platform.isWindows) {
        await startConn.query(
            '''CREATE DATABASE dart_test_cp1252 TEMPLATE = template0 ENCODING = 'WIN1252' LC_COLLATE = 'pt-BR' LC_CTYPE = 'pt-BR';''');
      } else {
        await startConn.query(
            '''CREATE DATABASE dart_test_cp1252 TEMPLATE = template0 ENCODING = 'WIN1252' LC_COLLATE = 'pt_BR.cp1252' LC_CTYPE = 'pt_BR.cp1252';''');
      }
    }
    //await connection .query('''CREATE ROLE dart WITH LOGIN SUPERUSER PASSWORD 'dart';''');
    await startConn.query(r''' do
$$
begin
  if not exists (select * from pg_user where usename = 'dart') then
     CREATE ROLE dart WITH LOGIN SUPERUSER PASSWORD 'dart';
  end if;
end
$$
; ''');
    await startConn.close();

    connection = PostgreSQLConnection(
      'localhost',
      5432,
      'dart_test_cp1252',
      username: 'dart',
      password: 'dart',
      encoding: Windows1252Codec(allowInvalid: false),
    );
    await connection.open();
    await connection.query('''SET client_encoding = 'win1252';''');
    await connection.query('''DROP TABLE IF EXISTS public.favorites;''');
    await connection.execute('''
  CREATE TABLE IF NOT EXISTS public.favorites (
  "id" serial4 NOT NULL, 
  "date_register" timestamp(6),
  "description" varchar(255),
  CONSTRAINT "favorites_pkey" PRIMARY KEY ("id")
);
''');

    await connection.query(
      ''' INSERT INTO public.favorites (date_register,description) VALUES ( ? , ? ) returning id ''',
      substitutionValues: [
        DateTime.parse('2023-08-15 16:07:36.000'),
        'City Hall of São Paulo - Brazil'
      ],
      placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark,
    );
  });

  tearDown(() async {
    // 1. Fechar a conexão atual para 'dart_test_cp1252'
    await connection.close();

    // 2. Conectar a um banco diferente (ex: 'dart_test' ou 'postgres')
    final maintenanceConn = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart');
    await maintenanceConn.open();

    // 3. Dropar o banco de dados de teste
    try {
      await maintenanceConn
          .query('''DROP DATABASE IF EXISTS dart_test_cp1252;''');
    } catch (e) {
      // Pode haver outras conexões se o teste não foi o único a acessá-lo.
      // Para testes, você pode querer forçar o fechamento de outras conexões.
      // Isso é mais avançado e geralmente requer privilégios de superusuário.
      // Exemplo (CUIDADO AO USAR, ESPECIALMENTE EM AMBIENTES NÃO-TESTE):
      // await maintenanceConn.query('''
      //   SELECT pg_terminate_backend(pg_stat_activity.pid)
      //   FROM pg_stat_activity
      //   WHERE pg_stat_activity.datname = 'dart_test_cp1252'
      //     AND pid <> pg_backend_pid();
      // ''');
      // await maintenanceConn.query('''DROP DATABASE IF EXISTS dart_test_cp1252;''');
      print(
          'Erro ao dropar o banco no tearDown: $e. Pode haver conexões pendentes.');
    } finally {
      await maintenanceConn.close();
    }
  });

  test('select varchar encoding win1252', () async {
    final results = await connection.query(
        'SELECT date_register,description FROM public.favorites LIMIT @l',
        substitutionValues: {'l': 1});

    expect(results, [
      [
        DateTime.parse('2023-08-15 16:07:36.000Z'),
        'City Hall of São Paulo - Brazil'
      ]
    ]);
  });
}
