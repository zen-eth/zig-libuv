const Signal = @This();

const std = @import("std");
const c = @import("c.zig");
const Loop = @import("Loop.zig");
const errors = @import("error.zig");
const Handle = @import("handle.zig").Handle;
const Allocator = std.mem.Allocator;
const testing = std.testing;

handle: *c.uv_signal_t,

pub usingnamespace Handle(Signal);

pub fn init(loop: Loop, allocator: Allocator) !Signal {
    const signal_handle = try allocator.create(c.uv_signal_t);
    errdefer allocator.destroy(signal_handle);

    try errors.convertError(c.uv_signal_init(loop.loop, signal_handle));

    return Signal{ .handle = signal_handle };
}

pub fn deinit(self: *Signal, allocator: Allocator) void {
    allocator.destroy(self.handle);
    self.* = undefined;
}

pub fn start(self: *Signal, signum: c_int, comptime cb: fn (*Signal, c_int) void) !void {
    const Wrapper = struct {
        fn callback(handle: [*c]c.uv_signal_t, signum_: c_int) callconv(.C) void {
            var signal = Signal{ .handle = @ptrCast(handle) };
            @call(.always_inline, cb, .{ &signal, signum_ });
        }
    };

    try errors.convertError(c.uv_signal_start(
        self.handle,
        Wrapper.callback,
        signum,
    ));
}

pub fn stop(self: *Signal) !void {
    try errors.convertError(c.uv_signal_stop(self.handle));
}

test "signal: create and destroy" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    const Wrapper = struct {
        fn onClose(_: *Signal) void {
            std.debug.print("closed\n", .{});
        }
    };

    var sig = try init(loop, testing.allocator);
    defer sig.deinit(testing.allocator);

    sig.close(Wrapper.onClose);
    _ = try loop.run(.default);
}

test "signal: handle SIGINT" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    const Context = struct {
        var signal_received: bool = false;
        var signal_number: c_int = 0;

        fn onSignal(sig: *Signal, signum: c_int) void {
            std.debug.print("received signal\n", .{});
            signal_received = true;
            signal_number = signum;
            sig.close(onClose);
        }

        fn onClose(_: *Signal) void {
            std.debug.print("closed signal\n", .{});
        }
    };

    var sig = try init(loop, testing.allocator);
    defer sig.deinit(testing.allocator);

    try sig.start(@as(c_int, std.posix.SIG.INT), Context.onSignal);

    // Simulate sending a signal
    try errors.convertError(c.uv_kill(c.uv_os_getpid(), @as(c_int, std.posix.SIG.INT)));

    _ = try loop.run(.default);

    try testing.expect(Context.signal_received);
    try testing.expectEqual(@as(c_int, std.posix.SIG.INT), Context.signal_number);
}
