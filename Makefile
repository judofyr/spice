.PHONY: all bench bench-spice bench-rayon plot plot-spice plot-rayon

all: plot

N := 1000 100M

# Expands SI suffixes (100k => 100000)
expand_SI = $(subst k,000,$(subst M,000k,$(1)))

bench: bench-spice bench-rayon
bench-spice: $(foreach n,$(N),bench/spice-tree-sum-$(n).csv)
bench-rayon: $(foreach n,$(N),bench/rayon-tree-sum-$(n).csv)

plot: plot-spice plot-rayon
plot-spice: $(foreach n,$(N),bench/spice-tree-sum-$(n).svg)
plot-rayon: $(foreach n,$(N),bench/rayon-tree-sum-$(n).svg)

## Spice

bench/spice-tree-sum-%.csv:
	zig build -Doptimize=ReleaseFast
	./zig-out/bin/spice-example -n $(call expand_SI,$*) --csv $@

bench/spice-tree-sum-%.svg: bench/spice-tree-sum-%.csv bench/plot.py
	python3 bench/plot.py $< "Time to calculate sum of binary tree of $* nodes" $@

## Rayon

bench/rayon-tree-sum-%.csv: | examples/rust-parallel-example/target/criterion
	python3 bench/criterion-to-csv.py tree-sum-$(call expand_SI,$*) > $@

examples/rust-parallel-example/target/criterion:
	(cd examples/rust-parallel-example && cargo bench)

bench/rayon-tree-sum-%.svg: bench/rayon-tree-sum-%.csv bench/plot.py
	python3 bench/plot.py $< "Time to calculate sum of binary tree of $* nodes" $@
