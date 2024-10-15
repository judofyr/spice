const std = @import("std");

// The overall design of Spice is as follows:
// - ThreadPool spawns threads which acts as background workers.
// - A Worker, while executing, will share one piece of work (`shared_job`).
// - A Worker, while waiting, will look for shared jobs by other workers.

pub const ThreadPoolConfig = struct {
    /// The number of background workers. If `null` this chooses a sensible
    /// default based on your system (i.e. number of cores).
    background_worker_count: ?usize = null,

    /// How often a background thread is interrupted to find more work.
    heartbeat_interval: usize = 100 * std.time.ns_per_us,
};

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// List of all workers.
    workers: std.ArrayListUnmanaged(*Worker) = .{},
    /// List of all background workers.
    background_threads: std.ArrayListUnmanaged(std.Thread) = .{},
    /// The background thread which beats.
    heartbeat_thread: ?std.Thread = null,
    /// A pool for the JobExecuteState, to minimize allocations.
    execute_state_pool: std.heap.MemoryPool(JobExecuteState),
    /// This is used to signal that more jobs are now ready.
    job_ready: std.Thread.Condition = .{},
    /// This is used to wait for the background workers to be available initially.
    workers_ready: std.Thread.Semaphore = .{},
    /// This is set to true once we're trying to stop.
    is_stopping: bool = false,

    /// A timer which we increment whenever we share a job.
    /// This is used to prioritize always picking the oldest job.
    time: usize = 0,

    heartbeat_interval: usize,

    pub fn init(allocator: std.mem.Allocator) ThreadPool {
        return ThreadPool{
            .allocator = allocator,
            .execute_state_pool = std.heap.MemoryPool(JobExecuteState).init(allocator),
            .heartbeat_interval = undefined,
        };
    }

    /// Starts the thread pool. This should only be invoked once.
    pub fn start(self: *ThreadPool, config: ThreadPoolConfig) void {
        const actual_count = config.background_worker_count orelse (std.Thread.getCpuCount() catch @panic("getCpuCount error")) - 1;

        self.heartbeat_interval = config.heartbeat_interval;
        self.background_threads.ensureUnusedCapacity(self.allocator, actual_count) catch @panic("OOM");
        self.workers.ensureUnusedCapacity(self.allocator, actual_count) catch @panic("OOM");

        for (0..actual_count) |_| {
            const thread = std.Thread.spawn(.{}, backgroundWorker, .{self}) catch @panic("spawn error");
            self.background_threads.append(self.allocator, thread) catch @panic("OOM");
        }

        self.heartbeat_thread = std.Thread.spawn(.{}, heartbeatWorker, .{self}) catch @panic("spawn error");

        // Wait for all of them to be ready:
        for (0..actual_count) |_| {
            self.workers_ready.wait();
        }
    }

    pub fn deinit(self: *ThreadPool) void {
        // Tell all background workers to stop:
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.is_stopping = true;
            self.job_ready.broadcast();
        }

        // Wait for background workers to stop:
        for (self.background_threads.items) |thread| {
            thread.join();
        }

        if (self.heartbeat_thread) |thread| {
            thread.join();
        }

        // Free up memory:
        self.background_threads.deinit(self.allocator);
        self.workers.deinit(self.allocator);
        self.execute_state_pool.deinit();
        self.* = undefined;
    }

    fn backgroundWorker(self: *ThreadPool) void {
        var w = Worker{ .pool = self };
        var first = true;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.workers.append(self.allocator, &w) catch @panic("OOM");

        // We don't bother removing ourselves from the workers list of exit since
        // this only happens when the whole thread pool is destroyed anyway.

        while (true) {
            if (self.is_stopping) break;

            if (self._popReadyJob()) |job| {
                // Release the lock while executing the job.
                self.mutex.unlock();
                defer self.mutex.lock();

                w.executeJob(job);

                continue; // Go straight to another attempt of finding more work.
            }

            if (first) {
                // Register that we are ready.
                self.workers_ready.post();
                first = false;
            }

            self.job_ready.wait(&self.mutex);
        }
    }

    fn heartbeatWorker(self: *ThreadPool) void {
        // We try to make sure that each worker is being heartbeat at the
        // fixed interval by going through the workers-list one by one.
        var i: usize = 0;

        while (true) {
            var to_sleep: u64 = self.heartbeat_interval;

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.is_stopping) break;

                const workers = self.workers.items;
                if (workers.len > 0) {
                    i %= workers.len;
                    workers[i].heartbeat.store(true, .monotonic);
                    i += 1;
                    to_sleep /= workers.len;
                }
            }

            std.time.sleep(to_sleep);
        }
    }

    pub fn call(self: *ThreadPool, comptime T: type, func: anytype, arg: anytype) T {
        // Create an one-off worker:

        var worker = Worker{ .pool = self };
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.workers.append(self.allocator, &worker) catch @panic("OOM");
        }

        defer {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.workers.items, 0..) |worker_ptr, idx| {
                if (worker_ptr == &worker) {
                    _ = self.workers.swapRemove(idx);
                    break;
                }
            }
        }

        var t = worker.begin();
        return t.call(T, func, arg);
    }

    /// The core logic of the heartbeat. Every executing worker invokes this periodically.
    fn heartbeat(self: *ThreadPool, worker: *Worker) void {
        @branchHint(.cold);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (worker.shared_job == null) {
            if (worker.job_head.shift()) |job| {
                // Allocate an execute state for it:
                const execute_state = self.execute_state_pool.create() catch @panic("OOM");
                execute_state.* = .{
                    .result = undefined,
                };
                job.setExecuteState(execute_state);

                worker.shared_job = job;
                worker.job_time = self.time;
                self.time += 1;

                self.job_ready.signal(); // wake up one thread
            }
        }

        worker.heartbeat.store(false, .monotonic);
    }

    /// Waits for (a shared) job to be completed.
    /// This returns `false` if it turns out the job was not actually started.
    fn waitForJob(self: *ThreadPool, worker: *Worker, job: *Job) bool {
        const exec_state = job.getExecuteState();

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (worker.shared_job == job) {
                // This is the job we attempted to share with someone else, but before someone picked it up.
                worker.shared_job = null;
                self.execute_state_pool.destroy(exec_state);
                return false;
            }

            // Help out by picking up more work if it's available.
            while (!exec_state.done.isSet()) {
                if (self._popReadyJob()) |other_job| {
                    self.mutex.unlock();
                    defer self.mutex.lock();

                    worker.executeJob(other_job);
                } else {
                    break;
                }
            }
        }

        exec_state.done.wait();
        return true;
    }

    /// Finds a job that's ready to be executed.
    fn _popReadyJob(self: *ThreadPool) ?*Job {
        var best_worker: ?*Worker = null;

        for (self.workers.items) |other_worker| {
            if (other_worker.shared_job) |_| {
                if (best_worker) |best| {
                    if (other_worker.job_time < best.job_time) {
                        // Pick this one instead if it's older.
                        best_worker = other_worker;
                    }
                } else {
                    best_worker = other_worker;
                }
            }
        }

        if (best_worker) |worker| {
            defer worker.shared_job = null;
            return worker.shared_job;
        }

        return null;
    }

    fn destroyExecuteState(self: *ThreadPool, exec_state: *JobExecuteState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.execute_state_pool.destroy(exec_state);
    }
};

pub const Worker = struct {
    pool: *ThreadPool,
    job_head: Job = Job.head(),

    /// A job (guaranteed to be in executing state) which other workers can pick up.
    shared_job: ?*Job = null,
    /// The time when the job was shared. Used for prioritizing which job to pick up.
    job_time: usize = 0,

    /// The heartbeat value. This is set to `true` to signal we should do a heartbeat action.
    heartbeat: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    pub fn begin(self: *Worker) Task {
        std.debug.assert(self.job_head.isTail());

        return Task{
            .worker = self,
            .job_tail = &self.job_head,
        };
    }

    fn executeJob(self: *Worker, job: *Job) void {
        var t = self.begin();
        job.handler.?(&t, job);
    }
};

pub const Task = struct {
    worker: *Worker,
    job_tail: *Job,

    pub inline fn tick(self: *Task) void {
        if (self.worker.heartbeat.load(.monotonic)) {
            self.worker.pool.heartbeat(self.worker);
        }
    }

    pub inline fn call(self: *Task, comptime T: type, func: anytype, arg: anytype) T {
        return callWithContext(
            self.worker,
            self.job_tail,
            T,
            func,
            arg,
        );
    }
};

// The following function's signature is actually extremely critical. We take in all of
// the task state (worker, last_heartbeat, job_tail) as parameters. The reason for this
// is that Zig/LLVM is really good at passing parameters in registers, but struggles to
// do the same for "fields in structs". In addition, we then return the changed value
// of last_heartbeat and job_tail.
fn callWithContext(
    worker: *Worker,
    job_tail: *Job,
    comptime T: type,
    func: anytype,
    arg: anytype,
) T {
    var t = Task{
        .worker = worker,
        .job_tail = job_tail,
    };
    t.tick();
    return @call(.always_inline, func, .{
        &t,
        arg,
    });
}

pub const JobState = enum {
    pending,
    queued,
    executing,
};

// A job represents something which _potentially_ could be executed on a different thread.
// The jobs forms a doubly-linked list: You call `push` to append a job and `pop` to remove it.
const Job = struct {
    handler: ?*const fn (t: *Task, job: *Job) void,
    prev_or_null: ?*anyopaque,
    next_or_state: ?*anyopaque,

    // This struct gets placed on the stack in _every_ frame so we're very cautious
    // about the size of it. There's three possible states, but we don't use a union(enum)
    // since this would actually increase the size.
    //
    // 1. pending: handler is null. a/b is undefined.
    // 2. queued: handler is set. prev_or_null is `prev`, next_or_state is `next`.
    // 3. executing: handler is set. prev_or_null is null, next_or_state is `*JobExecuteState`.

    /// Returns a new job which can be used for the head of a list.
    fn head() Job {
        return Job{
            .handler = undefined,
            .prev_or_null = null,
            .next_or_state = null,
        };
    }

    pub fn pending() Job {
        return Job{
            .handler = null,
            .prev_or_null = undefined,
            .next_or_state = undefined,
        };
    }

    pub fn state(self: Job) JobState {
        if (self.handler == null) return .pending;
        if (self.prev_or_null != null) return .queued;
        return .executing;
    }

    pub fn isTail(self: Job) bool {
        return self.next_or_state == null;
    }

    fn getExecuteState(self: *Job) *JobExecuteState {
        std.debug.assert(self.state() == .executing);
        return @ptrCast(@alignCast(self.next_or_state));
    }

    pub fn setExecuteState(self: *Job, execute_state: *JobExecuteState) void {
        std.debug.assert(self.state() == .executing);
        self.next_or_state = execute_state;
    }

    /// Pushes the job onto a stack.
    fn push(self: *Job, tail: **Job, handler: *const fn (task: *Task, job: *Job) void) void {
        std.debug.assert(self.state() == .pending);
        defer std.debug.assert(self.state() == .queued);

        self.handler = handler;
        tail.*.next_or_state = self; // tail.next = self
        self.prev_or_null = tail.*; // self.prev = tail
        self.next_or_state = null; // self.next = null
        tail.* = self; // tail = self
    }

    fn pop(self: *Job, tail: **Job) void {
        std.debug.assert(self.state() == .queued);
        std.debug.assert(tail.* == self);
        const prev: *Job = @ptrCast(@alignCast(self.prev_or_null));
        prev.next_or_state = null; // prev.next = null
        tail.* = @ptrCast(@alignCast(self.prev_or_null)); // tail = self.prev
        self.* = undefined;
    }

    fn shift(self: *Job) ?*Job {
        const job = @as(?*Job, @ptrCast(@alignCast(self.next_or_state))) orelse return null;

        std.debug.assert(job.state() == .queued);

        const next: ?*Job = @ptrCast(@alignCast(job.next_or_state));
        // Now we have: self -> job -> next.

        // If there is no `next` then it means that `tail` actually points to `job`.
        // In this case we can't remove `job` since we're not able to also update the tail.
        if (next == null) return null;

        defer std.debug.assert(job.state() == .executing);

        next.?.prev_or_null = self; // next.prev = self
        self.next_or_state = next; // self.next = next

        // Turn the job into "executing" state.
        job.prev_or_null = null;
        job.next_or_state = undefined;
        return job;
    }
};

const max_result_words = 4;

const JobExecuteState = struct {
    done: std.Thread.ResetEvent = .{},
    result: ResultType,

    const ResultType = [max_result_words]u64;

    fn resultPtr(self: *JobExecuteState, comptime T: type) *T {
        if (@sizeOf(T) > @sizeOf(ResultType)) {
            @compileError("value is too big to be returned by background thread");
        }

        const bytes = std.mem.sliceAsBytes(&self.result);
        return std.mem.bytesAsValue(T, bytes);
    }
};

pub fn Future(comptime Input: type, Output: type) type {
    return struct {
        const Self = @This();

        job: Job,
        input: Input,

        pub inline fn init() Self {
            return Self{ .job = Job.pending(), .input = undefined };
        }

        /// Schedules a piece of work to be executed by another thread.
        /// After this has been called you MUST call `join` or `tryJoin`.
        pub inline fn fork(
            self: *Self,
            task: *Task,
            comptime func: fn (task: *Task, input: Input) Output,
            input: Input,
        ) void {
            const handler = struct {
                fn handler(t: *Task, job: *Job) void {
                    const fut: *Self = @fieldParentPtr("job", job);
                    const exec_state = job.getExecuteState();
                    const value = t.call(Output, func, fut.input);
                    exec_state.resultPtr(Output).* = value;
                    exec_state.done.set();
                }
            }.handler;
            self.input = input;
            self.job.push(&task.job_tail, handler);
        }

        /// Waits for the result of `fork`.
        /// This is only safe to call if `fork` was _actually_ called.
        /// Use `tryJoin` if you conditionally called it.
        pub inline fn join(
            self: *Self,
            task: *Task,
        ) ?Output {
            std.debug.assert(self.job.state() != .pending);
            return self.tryJoin(task);
        }

        /// Waits for the result of `fork`.
        /// This function is safe to call even if you didn't call `fork` at all.
        pub inline fn tryJoin(
            self: *Self,
            task: *Task,
        ) ?Output {
            switch (self.job.state()) {
                .pending => return null,
                .queued => {
                    self.job.pop(&task.job_tail);
                    return null;
                },
                .executing => return self.joinExecuting(task),
            }
        }

        fn joinExecuting(self: *Self, task: *Task) ?Output {
            @branchHint(.cold);

            const w = task.worker;
            const pool = w.pool;
            const exec_state = self.job.getExecuteState();

            if (pool.waitForJob(w, &self.job)) {
                const result = exec_state.resultPtr(Output).*;
                pool.destroyExecuteState(exec_state);
                return result;
            }

            return null;
        }
    };
}
