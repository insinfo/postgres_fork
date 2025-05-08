// test/substituter2_test.dart

import 'package:postgres_fork/src/substituter2.dart';
import 'package:test/test.dart';

void main() {
  group('toStatement2 function tests', () {
    test('Basic single placeholder', () {
      const input = 'SELECT * FROM users WHERE id = ?';
      const expected = 'SELECT * FROM users WHERE id = \$1';
      expect(toStatement2(input), equals(expected));
    });

    test('Multiple placeholders', () {
      const input = 'INSERT INTO products (name, price) VALUES (?, ?)';
      const expected = 'INSERT INTO products (name, price) VALUES (\$1, \$2)';
      expect(toStatement2(input), equals(expected));
    });

    test('No placeholders', () {
      const input = 'SELECT 1';
      const expected = 'SELECT 1';
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder ignored inside single quotes', () {
      const input = "SELECT 'Hello ? world' WHERE name = ?";
      const expected = "SELECT 'Hello ? world' WHERE name = \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder ignored inside escaped single quotes (\'\')', () {
      const input = "SELECT 'Hello ''?'' world' WHERE name = ?";
      const expected = "SELECT 'Hello ''?'' world' WHERE name = \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder ignored inside double quoted identifiers', () {
      const input = 'SELECT "column?" FROM table WHERE id = ?';
      const expected = 'SELECT "column?" FROM table WHERE id = \$1';
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder ignored inside escaped strings (E\'..\')', () {
      const input = "SELECT E'Hello \\? world' WHERE value = ?";
      const expected = "SELECT E'Hello \\? world' WHERE value = \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder ignored inside single-line comments', () {
      const input = 'SELECT * FROM data -- Where id = ? \nWHERE key = ?';
      const expected = 'SELECT * FROM data -- Where id = ? \nWHERE key = \$1';
      expect(toStatement2(input), equals(expected));
    });

    test('Ignores ?? operator', () {
      const input = "SELECT data ?? 'default' WHERE id = ?";
      const expected = "SELECT data ?? 'default' WHERE id = \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Ignores ?= operator', () {
      const input = "SELECT tags ?= ARRAY['tag1'] WHERE id = ?";
      const expected = "SELECT tags ?= ARRAY['tag1'] WHERE id = \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Ignores ?( operator (jsonb)', () {
      const input = "SELECT data ?(ARRAY['key']) WHERE id = ?";
      const expected = "SELECT data ?(ARRAY['key']) WHERE id = \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Ignores ::? type cast placeholder lookalike', () {
      const input = 'SELECT data::? WHERE id = ?';
      const expected = 'SELECT data::? WHERE id = \$1';
      expect(toStatement2(input), equals(expected));
    });

    test('Mixed placeholders, strings, and comments', () {
      const input =
          "UPDATE tbl SET name = ?, descr = 'hello ? -- test?' WHERE id = ? -- final ?";
      const expected =
          "UPDATE tbl SET name = \$1, descr = 'hello ? -- test?' WHERE id = \$2 -- final ?";
      expect(toStatement2(input), equals(expected));
    });

    test('Empty string', () {
      const input = '';
      const expected = '';
      expect(toStatement2(input), equals(expected));
    });

    test('String with only placeholder', () {
      const input = '?';
      const expected = '\$1';
      expect(toStatement2(input), equals(expected));
    });

    test('String starting with placeholder', () {
      const input = '? SELECT';
      const expected = '\$1 SELECT';
      expect(toStatement2(input), equals(expected));
    });

    test('String ending with placeholder', () {
      const input = 'SELECT ?';
      const expected = 'SELECT \$1';
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder after comment end', () {
      const input = 'SELECT 1 -- comment \n?';
      const expected = 'SELECT 1 -- comment \n\$1';
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder after string end', () {
      const input = "SELECT 'text' ?";
      const expected = "SELECT 'text' \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Complex query with multiple contexts', () {
      const input = """
         SELECT a, b, 'hello? -- no'
         FROM test_table -- comment ? here
         WHERE id = ? AND status = 'pending?' -- another comment
         AND config -> 'key?' = ? -- json access
         AND extra ?? ? = "ident?" -- coalesce and identifier
         ORDER BY ?; -- final placeholder
       """;
      // CORREÇÃO AQUI: O terceiro '?' é um placeholder, o último é o próximo.
      const expected = """
         SELECT a, b, 'hello? -- no'
         FROM test_table -- comment ? here
         WHERE id = \$1 AND status = 'pending?' -- another comment
         AND config -> 'key?' = \$2 -- json access
         AND extra ?? \$3 = "ident?" -- coalesce and identifier
         ORDER BY \$4; -- final placeholder
       """;
      expect(toStatement2(input), equals(expected));
    });
    //avançados
    test('Placeholder ignorado em comentário multilinha', () {
      const input = 'SELECT /* aqui ? */ 1, ?';
      const expected = 'SELECT /* aqui ? */ 1, \$1';
      expect(toStatement2(input), equals(expected));
    });

    test('Placeholder ignorado em dollar-quoted sem tag', () {
      const input = r'SELECT $$texto ?$$, ?';

      const expected = r'SELECT $$texto ?$$, $1';
      expect(toStatement2(input), equals(expected));
    });
    test('Placeholder ignorado em dollar-quoted com tag', () {
      const input = r'SELECT $tag$? dentro$tag$, ?';
      const expected = r'SELECT $tag$? dentro$tag$, $1';
      expect(toStatement2(input), equals(expected));
    });

    test('Operadores JSON adicionais', () {
      const input =
          "SELECT data ?| ARRAY['a','b'] AND data ?& ARRAY['x'] AND id = ?";
      const expected =
          "SELECT data ?| ARRAY['a','b'] AND data ?& ARRAY['x'] AND id = \$1";
      expect(toStatement2(input), equals(expected));
    });

    test('Espaço entre ? e = ainda conta como operador JSON path', () {
      const input = "SELECT jsonb_col ? = 'key' AND x = ?";
      // Como "? =" não é operador válido, o ? deve virar placeholder
      const expected = "SELECT jsonb_col \$1 = 'key' AND x = \$2";
      expect(toStatement2(input), equals(expected));
    });
  });
}
