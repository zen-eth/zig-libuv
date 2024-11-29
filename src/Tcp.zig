const std = @import("std");
const c = @import("c.zig");
const Loop = @import("Loop.zig");
const errors = @import("error.zig");
const stream = @import("stream.zig");
const handle = @import("handle.zig");

pub const Tcp = struct {
    handle: *c.uv_tcp_t,

    // Add shared handle and stream functionality
    pub usingnamespace handle.Handle(@This());
    pub usingnamespace stream.Stream(@This());

    pub fn init(loop: *Loop, allocator: std.mem.Allocator) !Tcp {
        const tcp_handle = try allocator.create(c.uv_tcp_t);
        errdefer allocator.destroy(tcp_handle);

        try errors.convertError(c.uv_tcp_init(loop.loop, tcp_handle));

        return Tcp{ .handle = tcp_handle };
    }

    pub fn deinit(self: *Tcp, allocator: std.mem.Allocator, comptime cb: fn (*Tcp) void) void {
        const State = struct {
            var allocator_ptr: ?std.mem.Allocator = null;
            const user_cb: fn (*Tcp) void = cb;

            fn onClose(tcp: *Tcp) void {
                user_cb(tcp);
                if (allocator_ptr) |alloc| alloc.destroy(tcp.handle);
            }
        };

        State.allocator_ptr = allocator;
        self.close(State.onClose);
        self.* = undefined;
    }

    pub fn bind(self: *Tcp, addr: std.net.Address) !void {
        var sockaddr = addr.any;
        try errors.convertError(c.uv_tcp_bind(
            self.handle,
            &sockaddr,
            0,
        ));
    }

    pub fn listen(self: *Tcp, backlog: i32, comptime cb: fn (*Tcp, i32) void) !void {
        const Wrapper = struct {
            fn callback(tcp_handle: [*c]c.uv_stream_t, status: c_int) callconv(.C) void {
                var tcp_instance: Tcp = .{ .handle = @ptrCast(tcp_handle) };
                cb(&tcp_instance, @intCast(status));
            }
        };

        try errors.convertError(c.uv_listen(
            @ptrCast(self.handle),
            backlog,
            Wrapper.callback,
        ));
    }

    pub fn accept(self: *Tcp, client: *Tcp) !void {
        try errors.convertError(c.uv_accept(
            @ptrCast(self.handle),
            @ptrCast(client.handle),
        ));
    }
};

test "tcp: create and destroy" {
    const testing = std.testing;
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    var tcp = try Tcp.init(&loop, testing.allocator);

    const Wrapper = struct {
        fn onClose(_: *Tcp) void {}
    };

    tcp.deinit(testing.allocator, Wrapper.onClose);
    _ = try loop.run(.default);
}
