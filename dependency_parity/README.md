# dependency_parity

Pacote auxiliar (não publicado) que compara as implementações internas do
`postgres_fork` (`lib/src/utils` e `lib/src/auth/scram.dart`) com os pacotes
que elas substituíram, nas mesmas versões usadas antes da remoção:

| Implementação interna                   | Pacote original                                       |
|-----------------------------------------|-------------------------------------------------------|
| `utils/buffer.dart`                     | `buffer` 1.2.3                                        |
| `utils/crypto.dart`                     | `crypto` 3.0.6 (md5, sha256, hmac)                    |
| `auth/scram.dart`                       | `sasl_scram` 0.1.1                                    |
| `utils/saslprep.dart`, `utils/nfkc.dart`| `saslprep` 1.0.3 e `unorm_dart` 0.3.0                 |
| `utils/operation_lock.dart`             | `Pool(1)` do `pool` 1.5.1                             |
| `utils/stream_channel.dart`             | `stream_channel` 2.1.4 e `async` 2.13.0               |
| `utils/delegating_list.dart`, `_bytesEqual` | `collection` 1.19.1                               |
| `utils/ascii.dart`                      | `charcode` 1.4.0                                      |
| detecção do `windows-1252`              | `enough_convert` 1.6.0                                |
| `lib/src/timezone/` (runtime)           | `pg_timezone` 1.0.1                                   |
| `scripts/tzdb/zic.dart`                 | `zic` em C da IANA (tzcode)                           |

Os testes executam as duas implementações com as mesmas entradas (aleatórias
com sementes fixas e casos-limite) e exigem resultados idênticos, inclusive
exceções, mensagens de erro, ordem de eventos assíncronos e aliasing de buffers.

```sh
cd dependency_parity
dart pub get
dart test
```

Ferramentas que exigem o `zic` em C compilado (tzcode da IANA) e um tzdata
extraído:

```sh
# Arquivos TZif idênticos byte a byte (modos fat e slim):
dart run tool/zic_parity.dart --zic <zic> --tzdata <dir> --bloat fat
# Casos extremos da sintaxe do zic:
dart run tool/zic_parity.dart --zic <zic> --tzdata tool/zic_edge_cases --bloat slim edge.zi
# Bancos completo e reduzido iguais ao pipeline original do pg_timezone:
dart run tool/tzdb_pipeline_parity.dart --zic <zic> --tzdata <dir>
```

As tabelas Unicode do SASLprep/NFKC (`lib/src/utils/saslprep_tables.dart`) são
geradas a partir dos dados exatos dos pacotes originais:

```sh
cd dependency_parity
dart run tool/generate_saslprep_tables.dart
```
