use criterion::{black_box, criterion_group, criterion_main, Criterion, BenchmarkId};
use rayon;
use parallel_example::{sum, sum_rayon, make_balanced_tree};

fn criterion_benchmark(c: &mut Criterion) {
    for &n in [1000, 100_000_000].iter() {
        let mut group = c.benchmark_group(format!("tree-sum-{}", n));
        group.sample_size(50);
        let root = make_balanced_tree(1, n);
        group.bench_with_input(BenchmarkId::new("Baseline", 1), &1,
            |b, _i| b.iter(|| sum(black_box(&root))));
        for &num_threads in [1, 2, 4, 8, 16, 32].iter() {
            let pool = rayon::ThreadPoolBuilder::new().num_threads(num_threads).build().unwrap();
            group.bench_with_input(BenchmarkId::new("Rayon", num_threads), &num_threads,
                |b, _i| b.iter(|| sum_rayon(&pool, black_box(&root))));
        }
    }
}

criterion_group!(benches, criterion_benchmark);
criterion_main!(benches);