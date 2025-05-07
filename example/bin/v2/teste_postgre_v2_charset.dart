import 'package:postgres_fork/postgres.dart';

Future<void> main(List<String> args) async {
  final conn = PostgreSQLConnection('localhost', 5432, 'siamweb',
      username: 'dart', password: 'dart', useSSL: false);

  try {
    print('Tentando abrir a conexão com o PostgreSQL...');
    await conn.open();
    print('Conexão aberta com sucesso!');

    print('\nTentando executar uma query que gerará um erro intencional...');
    // Query que sabemos que vai dar erro  e vai esibir  caracteres especiais na mensagem
    //  lc_messages esta em pt_BR.UTF-8
    await conn.query(
        'SELECT * FROM tabela_inexistente_com_acentuação_na_mensagem_de_erro;');
  } on PostgreSQLException catch (e) {
    print('\n--- ERRO CAPTURADO PELO postgres_fork ---');
    print('Tipo da Exceção: ${e.runtimeType}');

    // A mensagem principal do erro
    print('Mensagem (e.message): ${e.message}');

    // Mensagem formatada, pode conter mais detalhes
    print('Mensagem Formatada (e.toString()): ${e.toString()}');

    final sm = e;
    print('--- Detalhes do ServerMessage ---');
    print('Severity: ${sm.severity?.name}');
    print('Code: ${sm.code}');
    print('Message (sm.message): ${sm.message}');
    print('Detail (sm.detail): ${sm.detail}');
    print('Hint (sm.hint): ${sm.hint}');
    print('Position (sm.position): ${sm.position}');
    print('Internal Position (sm.internalPosition): ${sm.internalPosition}');
    print('Internal Query (sm.internalQuery): ${sm.internalQuery}');

    print('Schema Name (sm.schemaName): ${sm.schemaName}');
    print('Table Name (sm.tableName): ${sm.tableName}');
    print('Column Name (sm.columnName): ${sm.columnName}');
    print('Data Type Name (sm.dataTypeName): ${sm.dataTypeName}');
    print('Constraint Name (sm.constraintName): ${sm.constraintName}');

    print('----------------------------------');
  } catch (e, s) {
    print('\n--- ERRO INESPERADO ---');
    print('Erro: $e');
    print('Stack trace: $s');
  }
}
