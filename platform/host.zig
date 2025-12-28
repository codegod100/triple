///! Platform host that tests effectful functions writing to stdout and stderr.
const std = @import("std");
const builtins = @import("builtins");

// Use lower-level C environ access to avoid std.os.environ initialization issues
extern var environ: [*:null]?[*:0]u8;
extern fn getenv(name: [*:0]const u8) ?[*:0]u8;

comptime {
    _ = &environ;
    _ = &getenv;
}

fn initEnviron() void {
    if (@import("builtin").os.tag != .windows) {
        _ = environ;
        _ = getenv("PATH");
    }
}

/// Global flag to track if dbg or expect_failed was called.
/// If set, program exits with non-zero code to prevent accidental commits.
var debug_or_expect_called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Host environment
const HostEnv = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    stdin_reader: std.fs.File.Reader,
};

// Use C allocator for Roc allocations - it tracks sizes internally
const c_allocator = std.heap.c_allocator;

/// Roc allocation function using C allocator
fn rocAllocFn(roc_alloc: *builtins.host_abi.RocAlloc, env: *anyopaque) callconv(.c) void {
    _ = env;

    const result = c_allocator.rawAlloc(
        roc_alloc.length,
        std.mem.Alignment.fromByteUnits(@max(roc_alloc.alignment, @alignOf(usize))),
        @returnAddress(),
    );

    roc_alloc.answer = result orelse {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[31mHost error:\x1b[0m allocation failed, out of memory\n") catch {};
        std.process.exit(1);
    };
}

/// Roc deallocation function using C allocator
fn rocDeallocFn(roc_dealloc: *builtins.host_abi.RocDealloc, env: *anyopaque) callconv(.c) void {
    _ = env;
    // C allocator tracks sizes internally, so we can pass 0 length
    // The rawFree for C allocator just calls free() which knows the size
    const slice = @as([*]u8, @ptrCast(roc_dealloc.ptr))[0..0];
    c_allocator.rawFree(
        slice,
        std.mem.Alignment.fromByteUnits(@max(roc_dealloc.alignment, @alignOf(usize))),
        @returnAddress(),
    );
}

/// Roc reallocation function using C allocator
fn rocReallocFn(roc_realloc: *builtins.host_abi.RocRealloc, env: *anyopaque) callconv(.c) void {
    _ = env;

    const align_enum = std.mem.Alignment.fromByteUnits(@max(roc_realloc.alignment, @alignOf(usize)));

    // rawResize doesn't work for C allocator (it can't resize in place), so we need alloc + copy + free
    const new_ptr = c_allocator.rawAlloc(roc_realloc.new_length, align_enum, @returnAddress()) orelse {
        const stderr: std.fs.File = .stderr();
        stderr.writeAll("\x1b[31mHost error:\x1b[0m reallocation failed, out of memory\n") catch {};
        std.process.exit(1);
    };

    // Copy old data - we don't know old size, but we can copy up to new_length safely
    // (caller ensures the buffer has at least min(old_len, new_len) valid bytes)
    const old_ptr: [*]const u8 = @ptrCast(roc_realloc.answer);
    @memcpy(new_ptr[0..roc_realloc.new_length], old_ptr[0..roc_realloc.new_length]);

    // Free old allocation
    const old_slice = @as([*]u8, @ptrCast(roc_realloc.answer))[0..0];
    c_allocator.rawFree(old_slice, align_enum, @returnAddress());

    roc_realloc.answer = new_ptr;
}

/// Roc debug function
fn rocDbgFn(roc_dbg: *const builtins.host_abi.RocDbg, env: *anyopaque) callconv(.c) void {
    _ = env;
    debug_or_expect_called.store(true, .release);
    const message = roc_dbg.utf8_bytes[0..roc_dbg.len];
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\x1b[33mdbg:\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Roc expect failed function
fn rocExpectFailedFn(roc_expect: *const builtins.host_abi.RocExpectFailed, env: *anyopaque) callconv(.c) void {
    _ = env;
    debug_or_expect_called.store(true, .release);
    const source_bytes = roc_expect.utf8_bytes[0..roc_expect.len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\x1b[33mexpect failed:\x1b[0m ") catch {};
    stderr.writeAll(trimmed) catch {};
    stderr.writeAll("\n") catch {};
}

/// Roc crashed function
fn rocCrashedFn(roc_crashed: *const builtins.host_abi.RocCrashed, env: *anyopaque) callconv(.c) noreturn {
    _ = env;
    const message = roc_crashed.utf8_bytes[0..roc_crashed.len];
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\n\x1b[31mRoc crashed:\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
    std.process.exit(1);
}

// External symbols provided by the Roc runtime object file
// Follows RocCall ABI: ops, ret_ptr, then argument pointers
extern fn roc__main_for_host(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, arg_ptr: ?*anyopaque) callconv(.c) void;

// OS-specific entry point handling (not exported during tests)
comptime {
    if (!@import("builtin").is_test) {
        // Export main for all platforms
        @export(&main, .{ .name = "main" });

        // Windows MinGW/MSVCRT compatibility: export __main stub
        if (@import("builtin").os.tag == .windows) {
            @export(&__main, .{ .name = "__main" });
        }
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    initEnviron();
    return platform_main(@intCast(argc), argv);
}

// Use the actual types from builtins
const RocStr = builtins.str.RocStr;
const RocList = builtins.list.RocList;

const RocDict = extern struct {
    buckets: RocList,
    data: RocList,
    max_bucket_capacity: u64,
    max_load_factor: f32,
    shifts: u8,
};

// Bucket struct matching Roc's Dict.Bucket
// Fields must be in alphabetical order for Roc: data_index, dist_and_fingerprint
const Bucket = extern struct {
    data_index: u32, // index into data list
    dist_and_fingerprint: u32, // upper 3 bytes: distance, lower byte: fingerprint
};

// Key-value pair for Dict data (Str, Str)
const DictEntry = extern struct {
    key: RocStr,
    value: RocStr,
};

const dict_dist_inc: u32 = 1 << 8; // skip 1 byte fingerprint
const dict_fingerprint_mask: u32 = dict_dist_inc - 1;
const dict_default_max_load_factor: f32 = 0.8;
const dict_initial_shifts: u8 = 61; // 64 - 3

fn emptyDict() RocDict {
    return RocDict{
        .buckets = RocList.empty(),
        .data = RocList.empty(),
        .max_bucket_capacity = 0,
        .max_load_factor = dict_default_max_load_factor,
        .shifts = dict_initial_shifts,
    };
}

/// Build a Dict from a list of key-value string pairs
fn buildDictFromHeaders(
    header_names: []const []const u8,
    header_values: []const []const u8,
    ops: *builtins.host_abi.RocOps,
) RocDict {
    const count = header_names.len;
    if (count == 0) {
        return emptyDict();
    }

    // Get pseudo-random seed for hashing
    const seed = builtins.utils.dictPseudoSeed();

    // Calculate required shifts based on size
    const shifts = calcShiftsForSize(count);
    const bucket_count = calcNumBuckets(shifts);
    const max_bucket_capacity: u64 = @intFromFloat(@floor(@as(f32, @floatFromInt(bucket_count)) * dict_default_max_load_factor));

    // Allocate data list with key-value pairs
    const data_list = RocList.allocateExact(
        @alignOf(DictEntry),
        count,
        @sizeOf(DictEntry),
        true, // elements are refcounted (contain RocStr)
        ops,
    );
    const data_ptr: [*]DictEntry = @ptrCast(@alignCast(data_list.bytes));

    // Fill data list with headers
    for (0..count) |i| {
        data_ptr[i] = DictEntry{
            .key = RocStr.init(header_names[i].ptr, header_names[i].len, ops),
            .value = RocStr.init(header_values[i].ptr, header_values[i].len, ops),
        };
    }

    // Allocate buckets list
    const buckets_list = RocList.allocateExact(
        @alignOf(Bucket),
        bucket_count,
        @sizeOf(Bucket),
        false, // buckets are not refcounted
        ops,
    );
    const buckets_ptr: [*]Bucket = @ptrCast(@alignCast(buckets_list.bytes));

    // Initialize all buckets to empty
    for (0..bucket_count) |i| {
        buckets_ptr[i] = Bucket{ .dist_and_fingerprint = 0, .data_index = 0 };
    }

    // Insert each entry into the hash table
    for (0..count) |data_index| {
        const key_slice = data_ptr[data_index].key.asSlice();
        const hash = wyhash(seed, key_slice);
        var dist_and_fingerprint = distAndFingerprintFromHash(hash);
        var bucket_index = bucketIndexFromHash(hash, shifts);

        // Find the right bucket using Robin Hood probing
        while (true) {
            const loaded = buckets_ptr[bucket_index];
            if (loaded.dist_and_fingerprint == 0) {
                // Empty bucket, place here
                buckets_ptr[bucket_index] = Bucket{
                    .dist_and_fingerprint = dist_and_fingerprint,
                    .data_index = @intCast(data_index),
                };
                break;
            } else if (dist_and_fingerprint > loaded.dist_and_fingerprint) {
                // Robin Hood: steal from richer bucket
                var to_place = Bucket{
                    .dist_and_fingerprint = dist_and_fingerprint,
                    .data_index = @intCast(data_index),
                };
                var current_idx = bucket_index;
                while (true) {
                    const current = buckets_ptr[current_idx];
                    if (current.dist_and_fingerprint == 0) {
                        buckets_ptr[current_idx] = to_place;
                        break;
                    }
                    // Swap and continue
                    buckets_ptr[current_idx] = to_place;
                    to_place = Bucket{
                        .dist_and_fingerprint = incrementDist(current.dist_and_fingerprint),
                        .data_index = current.data_index,
                    };
                    current_idx = nextBucketIndex(current_idx, bucket_count);
                }
                break;
            } else {
                // Continue probing
                bucket_index = nextBucketIndex(bucket_index, bucket_count);
                dist_and_fingerprint = incrementDist(dist_and_fingerprint);
            }
        }
    }

    return RocDict{
        .buckets = buckets_list,
        .data = data_list,
        .max_bucket_capacity = max_bucket_capacity,
        .max_load_factor = dict_default_max_load_factor,
        .shifts = shifts,
    };
}

fn calcNumBuckets(shifts: u8) usize {
    const shift_amount: u6 = @intCast(64 - @as(u8, shifts));
    return @as(usize, 1) << shift_amount;
}

fn calcShiftsForSize(size: usize) u8 {
    var shifts: u8 = dict_initial_shifts;
    while (shifts > 0) {
        const bucket_count = calcNumBuckets(shifts);
        const max_capacity: usize = @intFromFloat(@floor(@as(f32, @floatFromInt(bucket_count)) * dict_default_max_load_factor));
        if (max_capacity >= size) {
            return shifts;
        }
        shifts -= 1;
    }
    return 0;
}

fn distAndFingerprintFromHash(hash: u64) u32 {
    return (@as(u32, @truncate(hash)) & dict_fingerprint_mask) | dict_dist_inc;
}

fn bucketIndexFromHash(hash: u64, shifts: u8) usize {
    return @intCast(hash >> @intCast(shifts));
}

fn incrementDist(dist_and_fingerprint: u32) u32 {
    return dist_and_fingerprint +% dict_dist_inc;
}

fn nextBucketIndex(bucket_index: usize, bucket_count: usize) usize {
    const next = bucket_index + 1;
    return if (next != bucket_count) next else 0;
}

// Wyhash implementation for strings (matches Roc's implementation)
fn wyhash(seed: u64, bytes: []const u8) u64 {
    const primes = [_]u64{
        0xa0761d6478bd642f,
        0xe7037ed1a0b428db,
        0x8ebc6af09c88c6e3,
        0x589965cc75374cc3,
        0x1d8e4e27c47d124f,
    };

    var s = seed;
    const len = bytes.len;

    if (len <= 16) {
        if (len >= 4) {
            const a = readBytes(4, bytes[0..4]) | (readBytes(4, bytes[len - 4 ..][0..4]) << 32);
            const b = readBytes(4, bytes[(len >> 3) << 2 ..][0..4]) | (readBytes(4, bytes[len - 4 - ((len >> 3) << 2) ..][0..4]) << 32);
            return wymix(s ^ primes[0], a ^ primes[1]) ^ wymix(s ^ primes[2], b ^ primes[3]) ^ wymix(s, @as(u64, len));
        } else if (len > 0) {
            const a = (@as(u64, bytes[0]) << 16) | (@as(u64, bytes[len >> 1]) << 8) | @as(u64, bytes[len - 1]);
            return wymix(s ^ primes[0], a ^ primes[1]) ^ wymix(s, @as(u64, len));
        } else {
            return wymix(s ^ primes[0], primes[1]) ^ wymix(s, 0);
        }
    } else if (len <= 32) {
        const a = readBytes8(bytes[0..8]);
        const b = readBytes8(bytes[8..16]);
        const c = readBytes8(bytes[len - 16 ..][0..8]);
        const d = readBytes8(bytes[len - 8 ..][0..8]);
        return wymix(s ^ primes[0], a ^ primes[1]) ^ wymix(s ^ primes[2], b ^ primes[3]) ^
            wymix(s ^ primes[0], c ^ primes[1]) ^ wymix(s ^ primes[2], d ^ primes[3]) ^ wymix(s, @as(u64, len));
    } else {
        var pos: usize = 0;
        while (pos + 32 <= len) : (pos += 32) {
            const a = readBytes8(bytes[pos..][0..8]);
            const b = readBytes8(bytes[pos + 8 ..][0..8]);
            const c = readBytes8(bytes[pos + 16 ..][0..8]);
            const d = readBytes8(bytes[pos + 24 ..][0..8]);
            s = wymix(s ^ primes[0], a ^ primes[1]) ^ wymix(s ^ primes[2], b ^ primes[3]) ^
                wymix(s ^ primes[0], c ^ primes[1]) ^ wymix(s ^ primes[2], d ^ primes[3]);
        }
        const remaining = len - pos;
        if (remaining > 0) {
            const a = readBytes8(bytes[len - 32 ..][0..8]);
            const b = readBytes8(bytes[len - 24 ..][0..8]);
            const c = readBytes8(bytes[len - 16 ..][0..8]);
            const d = readBytes8(bytes[len - 8 ..][0..8]);
            s = wymix(s ^ primes[0], a ^ primes[1]) ^ wymix(s ^ primes[2], b ^ primes[3]) ^
                wymix(s ^ primes[0], c ^ primes[1]) ^ wymix(s ^ primes[2], d ^ primes[3]);
        }
        return wymix(s, @as(u64, len));
    }
}

fn wymix(a: u64, b: u64) u64 {
    const r = @as(u128, a) *% @as(u128, b);
    return @as(u64, @truncate(r)) ^ @as(u64, @truncate(r >> 64));
}

fn readBytes(comptime n: comptime_int, data: *const [n]u8) u64 {
    return std.mem.readInt(std.meta.Int(.unsigned, 8 * n), data, .little);
}

fn readBytes8(data: *const [8]u8) u64 {
    return std.mem.readInt(u64, data, .little);
}

/// Custom writer that collects response body into an ArrayList
const BodyCollector = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    max_size: usize,
    writer_instance: std.io.Writer,

    fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const self: *BodyCollector = @fieldParentPtr("writer_instance", w);
        var total: usize = 0;
        for (data) |slice| {
            if (self.list.items.len + slice.len > self.max_size) {
                return error.WriteFailed;
            }
            self.list.appendSlice(self.allocator, slice) catch {
                return error.WriteFailed;
            };
            total += slice.len;
        }
        if (splat > 0) {
            const last = data[data.len - 1];
            for (0..splat) |_| {
                if (self.list.items.len + last.len > self.max_size) {
                    return error.WriteFailed;
                }
                self.list.appendSlice(self.allocator, last) catch {
                    return error.WriteFailed;
                };
                total += last.len;
            }
        }
        return total;
    }

    const vtable = std.io.Writer.VTable{
        .drain = drain,
    };

    fn init(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, max_size: usize) BodyCollector {
        return .{
            .list = list,
            .allocator = allocator,
            .max_size = max_size,
            .writer_instance = .{
                .vtable = &vtable,
                .buffer = &.{},
            },
        };
    }
};

fn getAsSlice(roc_str: *const RocStr) []const u8 {
    if (roc_str.len() == 0) return "";
    return roc_str.asSlice();
}

fn hostedHttpGet(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const HttpResponse = extern struct {
        // Fields must be in alphabetical order for Roc
        requestHeaders: RocDict,
        requestUrl: RocStr,
        responseBody: RocList,
        responseHeaders: RocDict,
        statusCode: u16,
    };

    const Args = extern struct { url: RocStr };
    const args: *Args = @ptrCast(@alignCast(args_ptr));
    const request_url = args.url;
    const url_slice = getAsSlice(&request_url);

    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const allocator = host.gpa.allocator();

    const result: *HttpResponse = @ptrCast(@alignCast(ret_ptr));

    const uri = std.Uri.parse(url_slice) catch {
        result.requestUrl = RocStr.empty();
        result.responseBody = RocList.empty();
        result.requestHeaders = emptyDict();
        result.responseHeaders = emptyDict();
        result.statusCode = 0;
        return;
    };

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var req = client.request(.GET, uri, .{}) catch {
        result.requestUrl = request_url;
        result.responseBody = RocList.empty();
        result.requestHeaders = emptyDict();
        result.responseHeaders = emptyDict();
        result.statusCode = 0;
        return;
    };
    defer req.deinit();

    req.sendBodiless() catch {
        result.requestUrl = request_url;
        result.responseBody = RocList.empty();
        result.requestHeaders = emptyDict();
        result.responseHeaders = emptyDict();
        result.statusCode = 0;
        return;
    };
    var response = req.receiveHead(&redirect_buffer) catch {
        result.requestUrl = request_url;
        result.responseBody = RocList.empty();
        result.requestHeaders = emptyDict();
        result.responseHeaders = emptyDict();
        result.statusCode = 0;
        return;
    };

    // Collect response headers
    var header_names: [64][]const u8 = undefined;
    var header_values: [64][]const u8 = undefined;
    var header_count: usize = 0;

    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| {
        if (header_count < 64) {
            header_names[header_count] = header.name;
            header_values[header_count] = header.value;
            header_count += 1;
        }
    }

    var body_list = std.ArrayListUnmanaged(u8){};
    defer body_list.deinit(allocator);

    var body_collector = BodyCollector.init(&body_list, allocator, 10 * 1024 * 1024);

    const body_writer = &body_collector.writer_instance;

    var transfer_buffer: [4096]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [64 * 1024]u8 = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    while (true) {
        var read_buf: [4096]u8 = undefined;
        const n = reader.readSliceShort(&read_buf) catch break;
        if (n == 0) break;
        body_writer.writeAll(read_buf[0..n]) catch break;
    }

    // Collect response body
    const body_bytes = body_list.items;

    result.requestUrl = request_url;
    result.responseBody = if (body_bytes.len > 0) RocList.fromSlice(u8, body_bytes, false, ops) else RocList.empty();
    result.requestHeaders = emptyDict();
    result.responseHeaders = buildDictFromHeaders(header_names[0..header_count], header_values[0..header_count], ops);
    result.statusCode = @intFromEnum(response.head.status);
}

/// Hosted function: Random.seed_u64! (index 1 - sorted alphabetically)
/// Follows RocCall ABI: (ops, ret_ptr, args_ptr)
/// Returns U64 and takes {} as argument
fn hostedRandomSeedU64(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = args_ptr;

    var seed: u64 = undefined;
    std.crypto.random.bytes(std.mem.asBytes(&seed));

    const result: *u64 = @ptrCast(@alignCast(ret_ptr));
    result.* = seed;
}

/// Hosted function: Stderr.line! (index 1 - sorted alphabetically)
/// Follows RocCall ABI: (ops, ret_ptr, args_ptr)
/// Returns {} and takes Str as argument
fn hostedStderrLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr; // Return value is {} which is zero-sized

    // The Roc interpreter passes arguments as a pointer to a struct of values
    const Args = extern struct { str: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));

    const message = getAsSlice(&args.str);
    const stderr = std.fs.File.stderr();
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}
/// Hosted function: Stdin.line! (index 2 - sorted alphabetically)
/// Follows RocCall ABI: (ops, ret_ptr, args_ptr)
/// Returns Str and takes {} as argument
fn hostedStdinLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = args_ptr; // Argument is {} which is zero-sized

    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    var reader = &host.stdin_reader.interface;

    var line = while (true) {
        const maybe_line = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => break &.{}, // Return empty string on error
            error.StreamTooLong => {
                // Skip the overlong line so the next call starts fresh.
                _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.ReadFailed, error.EndOfStream => break &.{},
                };
                continue;
            },
        } orelse break &.{};

        break maybe_line;
    };

    // Trim trailing \r for Windows line endings
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }

    if (line.len == 0) {
        // Return empty string
        const result: *RocStr = @ptrCast(@alignCast(ret_ptr));
        result.* = RocStr.empty();
        return;
    }

    // Create RocStr from the read line - RocStr.init handles allocation internally
    const result: *RocStr = @ptrCast(@alignCast(ret_ptr));
    result.* = RocStr.init(line.ptr, line.len, ops);
}

/// Hosted function: Stdout.line! (index 4 - sorted alphabetically)
/// Follows RocCall ABI: (ops, ret_ptr, args_ptr)
/// Returns {} and takes Str as argument
fn hostedStdoutLine(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr; // Return value is {} which is zero-sized

    // The Roc interpreter passes arguments as a pointer to a struct of values.
    // Since args_ptr points to the packed arguments, and Stdout.line! takes a single Str,
    // args_ptr is a pointer to the RocStr itself.
    const roc_str_ptr: *const RocStr = @ptrCast(@alignCast(args_ptr));

    const message = getAsSlice(roc_str_ptr);

    const stdout = std.fs.File.stdout();
    stdout.writeAll(message) catch {};
    stdout.writeAll("\n") catch {};
}

// ============================================================================
// Logger hosted functions
// ============================================================================

/// Hosted function: Logger.debug!
fn hostedLoggerDebug(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const Args = extern struct { str: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const message = getAsSlice(&args.str);
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\x1b[36m[DEBUG]\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Hosted function: Logger.error!
fn hostedLoggerError(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const Args = extern struct { str: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const message = getAsSlice(&args.str);
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\x1b[31m[ERROR]\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Hosted function: Logger.info!
fn hostedLoggerInfo(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const Args = extern struct { str: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const message = getAsSlice(&args.str);
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\x1b[32m[INFO]\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Hosted function: Logger.log!
fn hostedLoggerLog(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const Args = extern struct { str: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const message = getAsSlice(&args.str);
    const stderr = std.fs.File.stderr();
    stderr.writeAll("[LOG] ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

/// Hosted function: Logger.warn!
fn hostedLoggerWarn(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    _ = ret_ptr;
    const Args = extern struct { str: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const message = getAsSlice(&args.str);
    const stderr = std.fs.File.stderr();
    stderr.writeAll("\x1b[33m[WARN]\x1b[0m ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
}

// ============================================================================
// Storage hosted functions - uses .roc_storage/ directory
// ============================================================================

const storage_dir = ".roc_storage";

fn ensureStorageDir() !void {
    std.fs.cwd().makeDir(storage_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn getStoragePath(key: []const u8, buf: *[4096]u8) []const u8 {
    const prefix = storage_dir ++ "/";
    @memcpy(buf[0..prefix.len], prefix);
    const copy_len = @min(key.len, buf.len - prefix.len);
    @memcpy(buf[prefix.len..][0..copy_len], key[0..copy_len]);
    return buf[0 .. prefix.len + copy_len];
}

/// Hosted function: Storage.delete!
/// Returns Result {} Str
fn hostedStorageDelete(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const Args = extern struct { key: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const key = getAsSlice(&args.key);

    // Result layout: { discriminant: u8, payload: union }
    // Ok({}) = discriminant 1, Err(Str) = discriminant 0
    const Result = extern struct {
        payload: RocStr,
        discriminant: u8,
    };
    const result: *Result = @ptrCast(@alignCast(ret_ptr));

    var path_buf: [4096]u8 = undefined;
    const path = getStoragePath(key, &path_buf);

    std.fs.cwd().deleteFile(path) catch |err| {
        const msg = switch (err) {
            error.FileNotFound => "File not found",
            error.AccessDenied => "Access denied",
            else => "Delete failed",
        };
        result.payload = RocStr.init(msg.ptr, msg.len, ops);
        result.discriminant = 0; // Err
        return;
    };

    result.payload = RocStr.empty();
    result.discriminant = 1; // Ok
}

/// Hosted function: Storage.exists!
/// Returns Bool
fn hostedStorageExists(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = ops;
    const Args = extern struct { key: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const key = getAsSlice(&args.key);

    const result: *bool = @ptrCast(@alignCast(ret_ptr));

    var path_buf: [4096]u8 = undefined;
    const path = getStoragePath(key, &path_buf);

    _ = std.fs.cwd().statFile(path) catch {
        result.* = false;
        return;
    };
    result.* = true;
}

/// Hosted function: Storage.list!
/// Returns List Str
fn hostedStorageList(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    _ = args_ptr;

    const result: *RocList = @ptrCast(@alignCast(ret_ptr));

    var dir = std.fs.cwd().openDir(storage_dir, .{ .iterate = true }) catch {
        result.* = RocList.empty();
        return;
    };
    defer dir.close();

    // Count entries first
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file) count += 1;
    }

    if (count == 0) {
        result.* = RocList.empty();
        return;
    }

    // Allocate list
    const list = RocList.allocateExact(@alignOf(RocStr), count, @sizeOf(RocStr), true, ops);
    const items: [*]RocStr = @ptrCast(@alignCast(list.bytes));

    // Fill entries
    var iter2 = dir.iterate();
    var i: usize = 0;
    while (iter2.next() catch null) |entry| {
        if (entry.kind == .file and i < count) {
            items[i] = RocStr.init(entry.name.ptr, entry.name.len, ops);
            i += 1;
        }
    }

    result.* = list;
}

/// Hosted function: Storage.load!
/// Returns Result Str [NotFound, PermissionDenied, Other Str]
fn hostedStorageLoad(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const Args = extern struct { key: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const key = getAsSlice(&args.key);

    // Result layout for Result Str [NotFound, PermissionDenied, Other Str]
    // Tag union: NotFound=0, Other=1, PermissionDenied=2 (alphabetical)
    // Result: Ok=1 with Str payload, Err=0 with tag union payload
    const ErrPayload = extern struct {
        other_str: RocStr,
        tag: u8,
    };
    const Result = extern struct {
        payload: extern union {
            ok_str: RocStr,
            err: ErrPayload,
        },
        discriminant: u8,
    };
    const result: *Result = @ptrCast(@alignCast(ret_ptr));

    var path_buf: [4096]u8 = undefined;
    const path = getStoragePath(key, &path_buf);

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                result.payload.err = .{ .other_str = RocStr.empty(), .tag = 0 }; // NotFound
            },
            error.AccessDenied => {
                result.payload.err = .{ .other_str = RocStr.empty(), .tag = 2 }; // PermissionDenied
            },
            else => {
                const msg = "Failed to open file";
                result.payload.err = .{ .other_str = RocStr.init(msg.ptr, msg.len, ops), .tag = 1 }; // Other
            },
        }
        result.discriminant = 0; // Err
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(c_allocator, 1024 * 1024) catch {
        const msg = "Failed to read file";
        result.payload.err = .{ .other_str = RocStr.init(msg.ptr, msg.len, ops), .tag = 1 };
        result.discriminant = 0;
        return;
    };
    defer c_allocator.free(content);

    result.payload.ok_str = RocStr.init(content.ptr, content.len, ops);
    result.discriminant = 1; // Ok
}

/// Hosted function: Storage.save!
/// Returns Result {} Str
fn hostedStorageSave(ops: *builtins.host_abi.RocOps, ret_ptr: *anyopaque, args_ptr: *anyopaque) callconv(.c) void {
    const Args = extern struct { key: RocStr, value: RocStr };
    const args: *const Args = @ptrCast(@alignCast(args_ptr));
    const key = getAsSlice(&args.key);
    const value = getAsSlice(&args.value);

    const Result = extern struct {
        payload: RocStr,
        discriminant: u8,
    };
    const result: *Result = @ptrCast(@alignCast(ret_ptr));

    ensureStorageDir() catch {
        const msg = "Failed to create storage directory";
        result.payload = RocStr.init(msg.ptr, msg.len, ops);
        result.discriminant = 0;
        return;
    };

    var path_buf: [4096]u8 = undefined;
    const path = getStoragePath(key, &path_buf);

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        const msg = switch (err) {
            error.AccessDenied => "Access denied",
            else => "Failed to create file",
        };
        result.payload = RocStr.init(msg.ptr, msg.len, ops);
        result.discriminant = 0;
        return;
    };
    defer file.close();

    file.writeAll(value) catch {
        const msg = "Failed to write file";
        result.payload = RocStr.init(msg.ptr, msg.len, ops);
        result.discriminant = 0;
        return;
    };

    result.payload = RocStr.empty();
    result.discriminant = 1; // Ok
}

/// Array of hosted function pointers, sorted alphabetically by fully-qualified name
/// These correspond to the hosted functions defined in the platform Type Modules
const hosted_function_ptrs = [_]builtins.host_abi.HostedFn{
    hostedHttpGet, // Http.get! (index 0)
    hostedLoggerDebug, // Logger.debug! (index 1)
    hostedLoggerError, // Logger.error! (index 2)
    hostedLoggerInfo, // Logger.info! (index 3)
    hostedLoggerLog, // Logger.log! (index 4)
    hostedLoggerWarn, // Logger.warn! (index 5)
    hostedRandomSeedU64, // Random.seed_u64! (index 6)
    hostedStderrLine, // Stderr.line! (index 7)
    hostedStdinLine, // Stdin.line! (index 8)
    hostedStdoutLine, // Stdout.line! (index 9)
    hostedStorageDelete, // Storage.delete! (index 10)
    hostedStorageExists, // Storage.exists! (index 11)
    hostedStorageList, // Storage.list! (index 12)
    hostedStorageLoad, // Storage.load! (index 13)
    hostedStorageSave, // Storage.save! (index 14)
};

/// Platform host entrypoint
fn platform_main(argc: usize, argv: [*][*:0]u8) c_int {
    initEnviron();

    var stdin_buffer: [4096]u8 = undefined;

    var host_env = HostEnv{
        .gpa = std.heap.GeneralPurposeAllocator(.{}){},
        .stdin_reader = std.fs.File.stdin().reader(&stdin_buffer),
    };

    var roc_ops = builtins.host_abi.RocOps{
        .env = @as(*anyopaque, @ptrCast(&host_env)),
        .roc_alloc = rocAllocFn,
        .roc_dealloc = rocDeallocFn,
        .roc_realloc = rocReallocFn,
        .roc_dbg = rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{
            .count = hosted_function_ptrs.len,
            .fns = @ptrCast(@constCast(&hosted_function_ptrs)),
        },
    };

    const args_list = buildStrArgsList(argc, argv, &roc_ops);

    var exit_code: i32 = -99;
    roc__main_for_host(&roc_ops, @as(*anyopaque, @ptrCast(&exit_code)), @as(*anyopaque, @ptrCast(@constCast(&args_list))));

    // Note: Memory leaks are expected due to the Roc dealloc protocol not providing
    // allocation sizes. In production, process exit cleans up all memory.
    _ = host_env.gpa.deinit();

    if (debug_or_expect_called.load(.acquire) and exit_code == 0) {
        return 1;
    }

    return exit_code;
}

/// Build a RocList of RocStr from argc/argv
fn buildStrArgsList(argc: usize, argv: [*][*:0]u8, roc_ops: *builtins.host_abi.RocOps) RocList {
    if (argc == 0) {
        return RocList.empty();
    }

    // Allocate list with proper refcount header using RocList.allocateExact
    const args_list = RocList.allocateExact(
        @alignOf(RocStr),
        argc,
        @sizeOf(RocStr),
        true, // elements are refcounted (RocStr)
        roc_ops,
    );

    const args_ptr: [*]RocStr = @ptrCast(@alignCast(args_list.bytes));

    // Build each argument string
    for (0..argc) |i| {
        const arg_cstr = argv[i];
        const arg_len = std.mem.len(arg_cstr);

        // RocStr.init takes a const pointer to read FROM and allocates internally
        args_ptr[i] = RocStr.init(arg_cstr, arg_len, roc_ops);
    }

    return args_list;
}
