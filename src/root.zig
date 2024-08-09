const std = @import("std");

pub const clock = @import("clock.zig").default;

pub const ThreadPoolConfig = struct {
    /// The number of background workers. If `null` this chooses a sensible
    /// default based on your system (i.e. number of cores).
    background_worker_count: ?usize = null,
};

pub const ThreadPool = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// List of all background workers.
    background_workers: std.ArrayListUnmanaged(std.Thread) = .{},
    /// The background thread which beats.
    heartbeat_thread: ?std.Thread = null,
    /// List of values to heartbeat.
    heartbeats: std.ArrayListUnmanaged(*std.atomic.Value(bool)) = .{},
    /// The beginning of a linked-list for workers who are ready to pick up work.
    next_waiting_worker: ?*Worker = null,
    /// A pool for the JobExecuteState, to minimize allocations.
    execute_state_pool: std.heap.MemoryPool(JobExecuteState),
    /// This is used to wait for the background workers to be available initially.
    workers_ready: std.Thread.Semaphore = .{},
    /// This is set to true once we're trying to stop.
    is_stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator) ThreadPool {
        return ThreadPool{
            .allocator = allocator,
            .execute_state_pool = std.heap.MemoryPool(JobExecuteState).init(allocator),
        };
    }

    /// Starts the thread pool. This should only be invoked once.
    pub fn start(self: *ThreadPool, config: ThreadPoolConfig) void {
        const actual_count = config.background_worker_count orelse (std.Thread.getCpuCount() catch @panic("getCpuCount error")) - 1;
        self.background_workers.ensureUnusedCapacity(self.allocator, actual_count) catch @panic("OOM");
        self.heartbeats.ensureTotalCapacity(self.allocator, actual_count) catch @panic("OOM");

        for (0..actual_count) |_| {
            const thread = std.Thread.spawn(.{}, backgroundWorker, .{self}) catch @panic("spawn error");
            self.background_workers.append(self.allocator, thread) catch @panic("OOM");
        }

        self.heartbeat_thread = std.Thread.spawn(.{}, heartbeatWorker, .{self}) catch @panic("spawn error");

        // Wait for all of them to be ready:
        for (0..actual_count) |_| {
            self.workers_ready.wait();
        }
    }

    pub fn deinit(self: *ThreadPool) void {
        var stopped_workers: usize = 0;

        // Tell all background workers to stop:
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.is_stopping = true;

            while (self.next_waiting_worker) |w| {
                self.next_waiting_worker = w.next_worker;
                w.next_worker = null;

                w.sendAction(.stop);
                stopped_workers += 1;
            }
        }

        if (stopped_workers != self.background_workers.items.len) {
            @panic("TheadPool deinited while background workers were busy");
        }

        // Wait for background workers to stop:
        for (self.background_workers.items) |thread| {
            thread.join();
        }

        if (self.heartbeat_thread) |thread| {
            thread.join();
        }

        // Free up memory:
        self.background_workers.deinit(self.allocator);
        self.heartbeats.deinit(self.allocator);
        self.execute_state_pool.deinit();
        self.* = undefined;
    }

    pub fn call(self: *ThreadPool, comptime T: type, func: anytype, arg: anytype) T {
        var worker = Worker{ .pool = self };
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.heartbeats.append(self.allocator, &worker.heartbeat) catch @panic("OOM");
        }

        defer {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.heartbeats.items, 0..) |beat, idx| {
                if (beat == &worker.heartbeat) {
                    _ = self.heartbeats.swapRemove(idx);
                    break;
                }
            }
        }

        var t = worker.begin();
        return t.call(T, func, arg);
    }

    fn addToWaitingQueue(self: *ThreadPool, worker: *Worker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Add ourselves to the queue:
        worker.next_worker = self.next_waiting_worker;
        self.next_waiting_worker = worker;
    }

    fn heartbeat(self: *ThreadPool, worker: *Worker) void {
        @setCold(true);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (worker.current_execute_state) |exec_state| {
            // Prefer sending work to the requester if it's waiting:
            if (exec_state.isWaiting()) {
                if (worker.job_head.shift()) |job| {
                    // Allocate an execute state for it:
                    const execute_state = self.execute_state_pool.create() catch @panic("OOM");
                    execute_state.* = .{
                        .result = undefined,
                        .requester = worker,
                    };
                    job.setExecuteState(execute_state);
                    exec_state.requester.next_action = .{ .invoke_job = job };
                    exec_state.done.set();
                }

                return;
            }
        }

        if (self.next_waiting_worker) |w| {
            if (worker.job_head.shift()) |job| {
                // Move it out of the queue:
                self.next_waiting_worker = w.next_worker;
                w.next_worker = null;

                // Allocate an execute state for it:
                const execute_state = self.execute_state_pool.create() catch @panic("OOM");
                execute_state.* = .{
                    .result = undefined,
                    .requester = worker,
                };
                job.setExecuteState(execute_state);

                w.sendAction(.{ .invoke_job = job });
            }
        }

        worker.heartbeat.store(false, .monotonic);
    }

    fn destroyExecuteState(self: *ThreadPool, exec_state: *JobExecuteState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.execute_state_pool.destroy(exec_state);
    }

    fn backgroundWorker(self: *ThreadPool) void {
        var w = Worker{ .pool = self };
        var first = true;

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.heartbeats.append(self.allocator, &w.heartbeat) catch @panic("OOM");
        }

        while (true) {
            self.addToWaitingQueue(&w);

            if (first) {
                // Report the first time we've queued up.
                self.workers_ready.post();
                first = false;
            }

            w.waker.wait();
            w.waker.reset();

            // The waker should make sure we're no longer in the queue.
            std.debug.assert(w.next_worker == null);

            const action = w.next_action.?;
            w.next_action = null;

            switch (action) {
                .invoke_job => |job| {
                    w.executeJob(job);
                    std.debug.assert(w.job_head.isTail());
                },
                .stop => break,
            }
        }
    }

    fn heartbeatWorker(self: *ThreadPool) void {
        const heartbeat_interval = 100 * std.time.ns_per_us;
        var i: usize = 0;

        while (true) {
            var to_sleep: u64 = heartbeat_interval;

            {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.is_stopping) break;

                const heartbeats = self.heartbeats.items;
                if (heartbeats.len > 0) {
                    i %= heartbeats.len;
                    heartbeats[i].store(true, .monotonic);
                    i += 1;
                    to_sleep /= heartbeats.len;
                }
            }

            std.time.sleep(to_sleep);
        }
    }

    fn waitForStop(self: *ThreadPool, worker: *Worker, event: *std.Thread.ResetEvent) void {
        _ = self;

        while (true) {
            event.wait();
            event.reset();

            if (worker.next_action) |action| {
                worker.next_action = null;
                switch (action) {
                    .invoke_job => |job| worker.executeJob(job),
                    .stop => unreachable,
                }
            } else {
                break;
            }
        }
    }
};

const WorkerAction = union(enum) {
    invoke_job: *Job,
    stop,
};

pub const Worker = struct {
    pool: *ThreadPool,
    job_head: Job = Job.head(),
    waker: std.Thread.ResetEvent = .{},
    next_action: ?WorkerAction = null,
    next_worker: ?*Worker = null,
    current_execute_state: ?*JobExecuteState = null,
    heartbeat: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn begin(self: *Worker) Task {
        std.debug.assert(self.job_head.isTail());

        return Task{
            .worker = self,
            .job_tail = &self.job_head,
        };
    }

    fn sendAction(self: *Worker, action: WorkerAction) void {
        self.next_action = action;
        self.waker.set();
    }

    fn executeJob(self: *Worker, job: *Job) void {
        const exec_state = self.current_execute_state;
        self.current_execute_state = job.getExecuteState();
        var t = self.begin();
        job.handler.?(&t, job);
        self.current_execute_state = exec_state;
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
    // The worker which originally placed the job on the queue and then decided
    // the work should be done in a different thread/worker.
    requester: *Worker,
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

    /// Returns true if the requester is currently _definitely_ waiting.
    fn isWaiting(self: *JobExecuteState) bool {
        // This is a bit hacky:
        return self.done.impl.state.load(.monotonic) == 1;
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

        pub inline fn fork(
            self: *Self,
            task: *Task,
            comptime func: fn (task: *Task, input: Input) Output,
            input: Input,
        ) void {
            const handler = struct {
                fn handler(t: *Task, job: *Job) void {
                    const fut: *Self = @fieldParentPtr("job", job);
                    // Do the actual work:
                    const value = t.call(Output, func, fut.input);
                    const exec_state = job.getExecuteState();
                    // Place the result into the state and mark it as complete:
                    exec_state.resultPtr(Output).* = value;
                    exec_state.done.set();
                }
            }.handler;
            self.input = input;
            self.job.push(&task.job_tail, handler);
        }

        pub inline fn join(
            self: *Self,
            task: *Task,
        ) ?Output {
            std.debug.assert(self.job.state() != .pending);
            return self.tryJoin(task);
        }

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

        fn joinExecuting(self: *Self, task: *Task) Output {
            @setCold(true);

            const w = task.worker;
            const pool = w.pool;
            const exec_state = self.job.getExecuteState();

            // Only the requester should call `join`.
            std.debug.assert(w == exec_state.requester);

            // Wait until the background worker tells us we're done.
            pool.waitForStop(w, &exec_state.done);

            const result = exec_state.resultPtr(Output).*;
            pool.destroyExecuteState(exec_state);
            return result;
        }
    };
}
