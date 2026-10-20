# Compara dois executáveis do benchmark (veja benchmark/README.md).
import statistics
import subprocess
import sys

base = sys.argv[1]
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
repeat = int(sys.argv[3]) if len(sys.argv) > 3 else 4
only = sys.argv[4:]

scenarios = only or [
    'connect_md5_x30', 'connect_scram_x30', 'select_100k_rows_11_cols',
    'select_50k_arrays', 'small_queries_x3000', 'inserts_x3000',
    'transactions_x500', 'mapped_results_50k', 'timestamptz_sao_paulo_50k',
    'eloquent_scalar_select_x3000', 'eloquent_insert_select_x2000',
    'eloquent_result_set_200_x500', 'decode_values_cpu', 'encode_bind_cpu',
    'framer_parse_200k_rows',
]

results = {s: {'old': [], 'new': []} for s in scenarios}
for r in range(rounds):
    for s in scenarios:
        for v in (['old', 'new'] if r % 2 == 0 else ['new', 'old']):
            exe = f'{base}/bench_{v}/bench.exe'
            out = subprocess.run([exe] + [s] * repeat, capture_output=True,
                                 text=True)
            if out.returncode != 0:
                print(v, s, 'FALHOU', out.stderr[:300])
                continue
            times = [float(l.split('\t')[1]) for l in out.stdout.splitlines()
                     if '\t' in l]
            results[s][v].extend(times[1:] if repeat > 1 else times)

print(f"{'cenário':34} {'antigo ms':>10} {'novo ms':>10} {'diferença':>10}")
for s in scenarios:
    o, n = results[s]['old'], results[s]['new']
    if not o or not n:
        continue
    mo, mn = statistics.median(o), statistics.median(n)
    print(f'{s:34} {mo:10.1f} {mn:10.1f} {100 * (mn - mo) / mo:+9.1f}%')
