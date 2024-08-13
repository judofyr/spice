use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use parallel_example::Node;

fn criterion_benchmark(c: &mut Criterion) {
    for n in [1000, 100_000_000] {
        let mut group = c.benchmark_group(format!("tree-sum-{}", n));
        group.sample_size(50);
        let root = Node::make_balanced_tree(1, n);
        group.bench_with_input(BenchmarkId::new("Baseline", 1), &root, |b, root| {
            b.iter(|| root.sum())
        });
        for num_threads in [1, 2, 4, 8, 16, 32] {
            let pool = rayon::ThreadPoolBuilder::new()
                .num_threads(num_threads)
                .build()
                .unwrap();
            group.bench_with_input(BenchmarkId::new("Rayon", num_threads), &root, |b, root| {
                b.iter(|| root.sum_rayon(&pool))
            });
        }
    }
}

criterion_group!(benches, criterion_benchmark);
criterion_main!(benches);
