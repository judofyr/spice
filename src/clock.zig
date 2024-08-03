const builtin = @import("builtin");

const aarch64 = struct {
    pub inline fn read() u64 {
        return asm volatile (
            \\mrs %[ret], CNTVCT_EL0
            : [ret] "=r" (-> u64),
        );
    }

    // 1 µs appears to be ~30 ticks on M3.
    // 4096 is a nice round number (probably well-optimized) which represents ~136 µs.
    pub const heartbeat_interval = 4096;
};

// TODO: RDTSC is unfortunately very slow (~50 cycles). We can't use this approach.
// This implementation is here only so that we can at least run it.
pub const x86_64 = struct {
    pub inline fn read() u64 {
        var hi: u32 = 0;
        var low: u32 = 0;

        asm (
            \\rdtsc
            : [low] "={eax}" (low),
              [hi] "={edx}" (hi),
        );
        return (@as(u64, hi) << 32) | @as(u64, low);
    }

    // 1 µs appears to be ~1275 ticks on M3.
    // 2^17 is then roughly ~100 µs.
    pub const heartbeat_interval = 131072;
};

pub const default = switch (builtin.cpu.arch) {
    .aarch64 => aarch64,
    .x86_64 => x86_64,
    else => @compileError("unsupported arch"),
};
