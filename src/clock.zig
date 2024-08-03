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

pub const default = switch (builtin.cpu.arch) {
    .aarch64 => aarch64,
    else => @compileError("unsupported arch"),
};
