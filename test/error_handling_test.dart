import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

import 'docker.dart';

void main() {
  // Sobe o contêiner definido em docker.dart antes de rodar os testes
  usePostgresDocker();

  test('Reports stacktrace correctly', () async {
    final conn = PostgreSQLConnection(
      'localhost',
      5432,
      'dart_test',
      username: 'dart',
      password: 'dart',
    );
    await conn.open();
    addTearDown(conn.close);

    //------------------------------------------------------------------
    // 1) Consulta simples – coluna inexistente → SQLSTATE 42703
    //------------------------------------------------------------------
    try {
      await conn.query('SELECT hello');
      fail('Should not reach');
    } catch (e, st) {
      expect(e.toString(), contains('42703'));               // coluna
      expect(st.toString(), contains('/test/error_handling_test.dart'));
    }

    //------------------------------------------------------------------
    // 2) Comando execute – tabela inexistente → SQLSTATE 42P01
    //------------------------------------------------------------------
    try {
      await conn.execute('DELETE FROM hello');
      fail('Should not reach');
    } catch (e, st) {
      expect(e.toString(), contains('42P01'));               // relação
      expect(st.toString(), contains('/test/error_handling_test.dart'));
    }

    //------------------------------------------------------------------
    // 3) Dentro de transação – coluna inexistente → SQLSTATE 42703
    //------------------------------------------------------------------
    try {
      await conn.transaction((ctx) async {
        await ctx.query('SELECT hello');
        fail('Should not reach');
      });
    } catch (e, st) {
      expect(e.toString(), contains('42703'));               // coluna
      expect(st.toString(), contains('/test/error_handling_test.dart'));
    }
  });
}
