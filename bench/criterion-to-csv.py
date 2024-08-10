from collections import namedtuple
from glob import glob
import json
import os
import sys

name = sys.argv[1]
n = int(name.split("-")[-1])

target_directory = "examples/rust-parallel-example/target/criterion"

BenchData = namedtuple('BenchData', ('nano_mean', 'threadcount'))
BenchRow = namedtuple('BenchRow', ('name', 'value', 'sort_key'))

def read_data(path):
    bench = json.loads(open(os.path.join(path, "benchmark.json")).read())
    est = json.loads(open(os.path.join(path, "estimates.json")).read())
    nano_mean = est["mean"]["point_estimate"]
    threadcount = int(bench["value_str"])
    return BenchData(nano_mean, threadcount)

rows = []

baseline_data = read_data(os.path.join(target_directory, name, "Baseline", "1", "new"))
rows.append(BenchRow("Baseline", baseline_data.nano_mean / n, (1, 0)))

for bench_dir in glob(os.path.join(target_directory, name, "Rayon", "*", "new")):
    bench_data = read_data(bench_dir)
    threadcount = bench_data.threadcount
    threadlabel = "1 thread" if threadcount == 1 else f"{threadcount} threads"
    rows.append(BenchRow(f"Rayon {threadlabel}", bench_data.nano_mean / n, (2, threadcount)))

rows.sort(key=lambda row: row.sort_key)

for row in rows:
    print(f"{row.name},{row.value}")
