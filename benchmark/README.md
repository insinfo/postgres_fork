# Benchmark do driver

`driver_benchmark.dart` mede os caminhos mais usados do driver (API v2):

| Cenário | O que mede |
|---|---|
| `connect_md5_x30` / `connect_scram_x30` | abrir e fechar 30 conexões (autenticação MD5 / SCRAM-SHA-256) |
| `select_100k_rows_11_cols` | SELECT de 100 mil linhas com int, bigint, text, numeric, timestamptz, timestamp, date, bool, float8, uuid e jsonb |
| `select_50k_arrays` | 50 mil linhas com `int4[]`, `text[]` e `int8[]` |
| `small_queries_x3000` | 3000 consultas pequenas com parâmetros tipados |
| `inserts_x3000` | 3000 INSERTs com parâmetros tipados |
| `transactions_x500` | 500 transações (INSERT + SELECT) |
| `mapped_results_50k` | `mappedResultsQuery` com 50 mil linhas |
| `timestamptz_sao_paulo_50k` | 50 mil `timestamptz` convertidos para `America/Sao_Paulo` |
| `eloquent_*` | o mesmo padrão do eloquent/new_sali: placeholders `?` sem tipo e `toColumnMap()` |
| `decode_values_cpu` / `encode_bind_cpu` / `framer_parse_200k_rows` | só CPU (sem servidor): decodificação, codificação de parâmetros e leitura de mensagens |

Requer o PostgreSQL de teste em `localhost:5432` (banco `dart_test`, usuário
`dart`/`dart`, como em `test/docker.dart`). O cenário `connect_scram_x30` usa um
papel com senha SCRAM:

```sql
SET password_encryption = 'scram-sha-256';
CREATE ROLE dart_bench_scram LOGIN PASSWORD 'S3nh@-bench';
```

## Comparar duas versões

Compile o mesmo benchmark contra cada versão (AOT, como em produção) e use
`compare.py`, que alterna as versões a cada rodada e mostra as medianas:

```sh
# <base>/bench_old e <base>/bench_new: pacotes com uma dependência
# "postgres_fork: path: ..." apontando para cada versão e
# bin/bench.dart = benchmark/driver_benchmark.dart
dart compile exe bin/bench.dart -o bench.exe   # em cada um
python benchmark/compare.py <base> [rodadas] [repetições] [cenários...]
```

Resultado de referência (Windows, PostgreSQL 16 local, 2.8.5 x 3.0.0): sem
regressão em consultas, inserts, transações e decodificação; arrays ~9% mais
rápidos, conexões SCRAM ~18% mais rápidas e `timestamptz` com fuso ~40x mais
rápido. O ruído medido com duas cópias da mesma versão (teste A/A) foi de ±1–2%.
