const std = @import("std");

const spice = @import("spice");
const parg = @import("parg");

const usage =
    \\usage: spice-example <options>
    \\
    \\Builds a perfectly balanced binary tree (with integer values) 
    \\and benchmark how quickly we can sum of all its values.
    \\
    \\--baseline and -t/--threads defines the benchmarks that
    \\will be executed. If none of these are present it defaults to
    \\--baseline -t 1 -t 2 -t 4 -t 8 -t 16 -t 32
    \\
    \\OPTIONS
    \\  -n <num> (required)
    \\    Define the size of the binary tree (number of nodes).
    \\    
    \\  -t, --threads <num>
    \\    Run a benchmark using the given the number of threads.
    \\    This can be passed multiple times and multiple benchmarks
    \\    will be run.
    \\
    \\  --baseline
    \\    When present, also run the baseline version.
    \\
    \\  --csv <path>
    \\    Output the benchmark results as CSV.
    \\
    \\  -h, --help
    \\    Show this message.
    \\
;

const Node = struct {
    val: i64,
    left: ?*Node = null,
    right: ?*Node = null,

    fn sum(self: *const Node) i64 {
        var res = self.val;
        if (self.left) |child| res += child.sum();
        if (self.right) |child| res += child.sum();
        return res;
    }
};

fn balancedTree(allocator: std.mem.Allocator, from: i64, to: i64) !*Node {
    var node = try allocator.create(Node);
    node.* = .{ .val = from + @divTrunc(to - from, 2) };
    if (node.val > from) {
        node.left = try balancedTree(allocator, from, node.val - 1);
    }
    if (node.val < to) {
        node.right = try balancedTree(allocator, node.val + 1, to);
    }
    return node;
}

fn sum(t: *spice.Task, node: *Node) i64 {
    var res: i64 = node.val;

    if (node.left) |left_child| {
        if (node.right) |right_child| {
            var fut = spice.Future(*Node, i64).init();
            fut.fork(t, sum, right_child);
            res += t.call(i64, sum, left_child);
            if (fut.join(t)) |val| {
                res += val;
            } else {
                res += t.call(i64, sum, right_child);
            }
            return res;
        }

        res += t.call(i64, sum, left_child);
    }

    if (node.right) |right_child| {
        res += t.call(i64, sum, right_child);
    }

    return res;
}

const BaselineTreeSum = struct {
    pub fn writeName(self: *BaselineTreeSum, writer: *std.Io.Writer) !void {
        _ = self;
        try writer.print("Baseline", .{});
    }

    pub fn init(self: *BaselineTreeSum, allocator: std.mem.Allocator, io: std.Io) void {
        _ = self;
        _ = allocator;
        _ = io;
    }

    pub fn deinit(self: *BaselineTreeSum) void {
        _ = self;
    }

    pub fn run(self: *BaselineTreeSum, input: *Node) i64 {
        _ = self;
        return input.sum();
    }
};

const SpiceTreeSum = struct {
    num_threads: usize,
    thread_pool: spice.ThreadPool = undefined,

    pub fn writeName(self: *SpiceTreeSum, writer: *std.Io.Writer) !void {
        if (self.num_threads == 1) {
            try writer.print("Spice 1 thread", .{});
        } else {
            try writer.print("Spice {} threads", .{self.num_threads});
        }
    }

    pub fn init(self: *SpiceTreeSum, allocator: std.mem.Allocator, io: std.Io) void {
        self.thread_pool = spice.ThreadPool.init(allocator, io);
        self.thread_pool.start(.{ .background_worker_count = self.num_threads - 1 });
    }

    pub fn deinit(self: *SpiceTreeSum) void {
        self.thread_pool.deinit();
    }

    pub fn run(self: *SpiceTreeSum, input: *Node) i64 {
        return self.thread_pool.call(i64, sum, input);
    }
};

const n_samples = 50;
const warmup_duration = 3 * std.time.ns_per_s;

const Runner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    n: usize,
    csv: ?std.Io.File.Writer = null,

    pub fn run(self: *Runner, bench: anytype, input: anytype) !void {
        var out = std.Io.File.stdout();
        var out_buf: [512]u8 = undefined;
        var outw = out.writer(self.io, &out_buf);

        var name_buf: [255]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&name_buf);
        try bench.writeName(&fbs);
        const name = fbs.buffered();

        try outw.interface.print("{s}:\n", .{name});
        try outw.interface.print("  Warming up...\n", .{});

        bench.init(self.allocator, self.io);
        defer bench.deinit();

        {
            var timer = std.time.Timer.start() catch @panic("timer error");
            var warmup_iter: usize = 0;
            while (true) {
                const output = bench.run(input);
                warmup_iter += 1;
                if (timer.read() >= warmup_duration) {
                    try outw.interface.print("  Warmup iterations: {}\n", .{warmup_iter});
                    try outw.interface.print("  Warmup result: {}\n\n", .{output});
                    try outw.interface.flush();
                    break;
                }
            }
        }

        try outw.interface.print("  Running {} times...\n", .{n_samples});
        try outw.interface.flush();
        var sample_times: [n_samples]f64 = undefined;
        for (0..n_samples) |i| {
            var timer = std.time.Timer.start() catch @panic("timer error");
            std.mem.doNotOptimizeAway(bench.run(input));
            const dur = timer.read();
            sample_times[i] = @as(f64, @floatFromInt(dur)) / @as(f64, @floatFromInt(self.n));
        }

        const mean = memSum(f64, &sample_times) / n_samples;

        try outw.interface.print("  Mean: {d} ns\n  Min: {d} ns\n  Max: {d} ns\n", .{
            mean,
            std.mem.min(f64, &sample_times),
            std.mem.max(f64, &sample_times),
        });

        try outw.interface.print("\n", .{});
        try outw.interface.flush();

        if (self.csv) |*csv| {
            try csv.interface.print("{s},{d}\n", .{ name, mean });
            try csv.interface.flush();
        }
    }
};

fn memSum(comptime T: type, slice: []const T) T {
    var result: T = 0;
    for (slice) |val| {
        result += val;
    }
    return result;
}

fn failArgs(io: std.Io, comptime format: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    var err = std.Io.File.stderr();
    var writer = err.writer(io, &buf);
    writer.interface.print("invalid arguments: " ++ format ++ "\n", args) catch @panic("failed to print to stderr");
    writer.interface.flush() catch {};
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var n: ?usize = null;
    var csv_buf: [512]u8 = undefined;
    var csv_file: std.Io.File = undefined;
    var csv: ?std.Io.File.Writer = null;
    var enable_baseline = false;
    var num_threads_list = std.ArrayList(usize).empty;
    defer num_threads_list.deinit(init.gpa);
    var defaults = true;
    var show_usage = false;
    var no_args = true;
    const io = init.io;

    var p = try parg.parseProcess(init, .{});
    defer p.deinit();

    const program_name = p.nextValue() orelse @panic("no executable name");
    _ = program_name;

    while (p.next()) |token| {
        no_args = false;
        switch (token) {
            .flag => |flag| {
                if (flag.isShort("n")) {
                    const n_str = p.nextValue() orelse failArgs(io, "-n requires a value", .{});
                    n = std.fmt.parseInt(usize, n_str, 10) catch failArgs(io, "-n must be an integer", .{});
                } else if (flag.isLong("csv")) {
                    const csv_path = p.nextValue() orelse failArgs(io, "--csv requires a value", .{});
                    csv_file = try std.Io.Dir.cwd().createFile(io, csv_path, .{});
                    csv = csv_file.writer(io, &csv_buf);
                } else if (flag.isLong("baseline")) {
                    enable_baseline = true;
                    defaults = false;
                } else if (flag.isShort("t") or flag.isLong("threads")) {
                    const num_threads_str = p.nextValue() orelse failArgs(io, "{f} requires a value", .{flag});
                    const num_threads = std.fmt.parseInt(usize, num_threads_str, 10) catch failArgs(io, "{f} must be an integer", .{flag});
                    try num_threads_list.append(init.gpa, num_threads);
                    defaults = false;
                } else if (flag.isShort("h") or flag.isLong("help")) {
                    show_usage = true;
                } else {
                    failArgs(io, "{f} is a not a valid flag", .{flag});
                }
            },
            .arg => |arg| {
                failArgs(io, "{s}", .{arg});
            },
            .unexpected_value => |val| {
                failArgs(io, "{s}", .{val});
            },
        }
    }

    if (show_usage or no_args) {
        std.debug.print(usage, .{});
        std.process.exit(0);
    }

    if (n == null) {
        failArgs(io, "-n is required.", .{});
    }

    if (defaults) {
        enable_baseline = true;
        try num_threads_list.appendSlice(init.gpa, &[_]usize{ 1, 2, 4, 8, 16, 32 });
    }

    const root = try balancedTree(init.arena.allocator(), 0, @intCast(n.?));

    var runner = Runner{
        .allocator = init.gpa,
        .io = init.io,
        .n = n.?,
        .csv = csv,
    };

    if (enable_baseline) {
        var baseline: BaselineTreeSum = .{};
        try runner.run(&baseline, root);
    }

    for (num_threads_list.items) |num_threads| {
        var bench: SpiceTreeSum = .{ .num_threads = num_threads };
        try runner.run(&bench, root);
    }

    if (csv) |_| {
        csv_file.close(io);
    }
}
