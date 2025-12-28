//! WASI host for wasm32 builds.
const std = @import("std");
const builtins = @import("builtins");

const RocStr = builtins.str.RocStr;
const RocList = builtins.list.RocList;
const RocOps = builtins.host_abi.RocOps;
const RocAlloc = builtins.host_abi.RocAlloc;
const RocDealloc = builtins.host_abi.RocDealloc;
const RocRealloc = builtins.host_abi.RocRealloc;
const RocDbg = builtins.host_abi.RocDbg;
const RocExpectFailed = builtins.host_abi.RocExpectFailed;
const RocCrashed = builtins.host_abi.RocCrashed;

const wasm_allocator = std.heap.wasm_allocator;

fn allocFromWasmHeap(length: usize, alignment_bytes: usize) [*]u8 {
    const min_alignment = @max(alignment_bytes, 1);
    const normalized = std.math.ceilPowerOfTwo(usize, min_alignment) catch min_alignment;
    const alignment = std.mem.Alignment.fromByteUnits(normalized);
    return wasm_allocator.rawAlloc(length, alignment, @returnAddress()) orelse @panic("WASM allocation failed");
}

/// Exported allocator used when Roc-generated Wasm imports `env.roc_alloc`.
export fn roc_alloc(size: i32, alignment: i32) callconv(.c) i32 {
    const positive_size: usize = @intCast(@max(size, 0));
    const align_bytes: usize = @intCast(@max(alignment, 1));
    const ptr = allocFromWasmHeap(positive_size, align_bytes);
    return @intCast(@intFromPtr(ptr));
}

// RocOps callback implementations
fn rocAllocFn(alloc_req: *RocAlloc, env: *anyopaque) callconv(.c) void {
    _ = env;
    const ptr = allocFromWasmHeap(alloc_req.length, alloc_req.alignment);
    alloc_req.answer = @ptrCast(ptr);
}

fn rocDeallocFn(dealloc_req: *RocDealloc, env: *anyopaque) callconv(.c) void {
    _ = env;
    // Intentionally no-op to avoid allocator issues in WASM runtime cleanup.
    _ = dealloc_req;
}

fn rocReallocFn(realloc_req: *RocRealloc, env: *anyopaque) callconv(.c) void {
    _ = env;
    const ptr = allocFromWasmHeap(realloc_req.new_length, realloc_req.alignment);
    realloc_req.answer = @ptrCast(ptr);
}

fn rocDbgFn(roc_dbg_arg: *const RocDbg, env: *anyopaque) callconv(.c) void {
    _ = env;
    std.debug.print("dbg: {s}\n", .{roc_dbg_arg.utf8_bytes[0..roc_dbg_arg.len]});
}

fn rocExpectFailedFn(roc_expect: *const RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    std.debug.print("expect failed: {s}\n", .{roc_expect.utf8_bytes[0..roc_expect.len]});
}

fn rocCrashedFn(roc_crashed: *const RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    std.debug.print("Roc crashed: {s}\n", .{roc_crashed.utf8_bytes[0..roc_crashed.len]});
    std.process.exit(1);
}

// Hosted functions
var seed_state: u64 = 1;

fn hostedRandomSeedU64(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = args_ptr;
    seed_state = (1103515245 * seed_state + 12345) % 2147483648;
    const result: *u64 = @ptrCast(@alignCast(ret_ptr));
    result.* = seed_state;
}

fn hostedStderrLine(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const Args = extern struct { str: RocStr };
    const args: *Args = @ptrCast(@alignCast(args_ptr));
    const message = args.str.asSlice();
    std.debug.print("{s}\n", .{message});
}

fn hostedStdinLine(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = args_ptr;
    const result: *RocStr = @ptrCast(@alignCast(ret_ptr));
    result.* = RocStr.empty();
}

fn hostedStdoutLine(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const Args = extern struct { str: RocStr };
    const args: *Args = @ptrCast(@alignCast(args_ptr));
    const message = args.str.asSlice();
    std.debug.print("{s}\n", .{message});
}

fn hostedHttpGet(ops: *RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = args_ptr;
    // WASM HTTP support depends on the runtime environment (browser fetch or WASI HTTP extension)
    // For now, return empty string as HTTP is not available in standard WASI
    const result: *RocStr = @ptrCast(@alignCast(ret_ptr));
    result.* = RocStr.empty();
}

const hosted_function_ptrs = [_]builtins.host_abi.HostedFn{
    hostedHttpGet, // Http.get! (index 0)
    hostedRandomSeedU64, // Random.seed_u64! (index 1)
    hostedStderrLine, // Stderr.line! (index 2)
    hostedStdinLine, // Stdin.line! (index 3)
    hostedStdoutLine, // Stdout.line! (index 4)
};

extern fn roc__main_for_host(ops: *RocOps, ret_ptr: *anyopaque, arg_ptr: ?*anyopaque) callconv(.c) void;

// WASI entrypoint
export fn _start() void {
    var roc_ops = RocOps{
        .env = @ptrCast(&seed_state),
        .roc_alloc = rocAllocFn,
        .roc_dealloc = rocDeallocFn,
        .roc_realloc = rocReallocFn,
        .roc_dbg = rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{
            .count = hosted_function_ptrs.len,
            .fns = @constCast(&hosted_function_ptrs),
        },
    };

    const args_list = RocList.empty();
    var exit_code: i32 = 0;
    roc__main_for_host(&roc_ops, @ptrCast(&exit_code), @ptrCast(@constCast(&args_list)));

    if (exit_code != 0) {
        std.process.exit(1);
    }
}
