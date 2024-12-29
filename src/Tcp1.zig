//! TCP handles are used to handle TCP connections.
//!
const Tcp1 = @This();

const std = @import("std");
const c = @import("c.zig");
const Loop = @import("Loop.zig");
const errors = @import("error.zig");
const stream = @import("stream.zig");
const Stream = stream.Stream;
const Handle = @import("handle.zig").Handle;
const testing = std.testing;
const Allocator = std.mem.Allocator;

handle: *c.uv_tcp_t,

pub usingnamespace Handle(Tcp1);
pub usingnamespace Stream(Tcp1);

pub fn init(loop: *Loop, allocator: Allocator) !Tcp1 {
    const tcp_handle = try allocator.create(c.uv_tcp_t);
    errdefer allocator.destroy(tcp_handle);

    try errors.convertError(c.uv_tcp_init(loop.loop, tcp_handle));

    return Tcp1{ .handle = tcp_handle };
}

pub fn deinit(self: *Tcp1, allocator: Allocator) void {
    allocator.destroy(self.handle);
    self.* = undefined;
}

pub fn bind(self: *Tcp1, addr: std.net.Address) !void {
    var sockaddr = addr.any;
    try errors.convertError(c.uv_tcp_bind(
        self.handle,
        @ptrCast(&sockaddr),
        0,
    ));
}

pub const ConnectReq = struct {
    pub const T = c.uv_connect_t;

    req: *T,

    pub fn init(alloc: Allocator) !ConnectReq {
        const req = try alloc.create(c.uv_connect_t);
        errdefer alloc.destroy(req);
        return ConnectReq{ .req = req };
    }

    pub fn deinit(self: *ConnectReq, alloc: Allocator) void {
        alloc.destroy(self.req);
        self.* = undefined;
    }

    /// Pointer to the stream where this connect request is running.
    /// T should be a high-level handle type such as "Tcp".
    pub fn handle(self: ConnectReq, comptime HT: type) ?HT {
        const tInfo = @typeInfo(HT).@"struct";
        const HandleType = tInfo.fields[0].type;

        return if (self.req.handle) |ptr|
            return HT{ .handle = @as(HandleType, @ptrCast(ptr)) }
        else
            null;
    }
};

pub fn connect(self: *Tcp1, conn_req: *ConnectReq, addr: std.net.Address, comptime cb: fn (*Tcp1, i32) void) !void {
    const Wrapper = struct {
        fn callback(req: [*c]c.uv_connect_t, status: c_int) callconv(.C) void {
            var tcp_instance: Tcp1 = .{ .handle = @ptrCast(req.*.handle) };
            @call(.always_inline, cb, .{ &tcp_instance, @as(i32, @intCast(status)) });
        }
    };

    var sockaddr = addr.any;
    try errors.convertError(c.uv_tcp_connect(
        conn_req.req,
        self.handle,
        @ptrCast(&sockaddr),
        Wrapper.callback,
    ));
}

test "Write: create and destroy" {
    var h = try ConnectReq.init(testing.allocator);
    defer h.deinit(testing.allocator);
}

test "tcp: create and destroy" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    const Wrapper = struct {
        fn onClose(_: *Tcp1) void {
            std.debug.print("closed\n", .{});
        }
    };
    var tcp = try init(&loop, testing.allocator);
    defer tcp.deinit(testing.allocator);

    tcp.close(Wrapper.onClose);
    _ = try loop.run(.default);
}

test "tcp: echo client" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    var client = try Tcp1.init(&loop, testing.allocator);
    defer client.deinit(testing.allocator);

    const addr = try std.net.Address.parseIp4("127.0.0.1", 7000);

    const Callbacks = struct {
        var connection_attempted: bool = false;
        var connection_status: i32 = 0;

        fn onConnect(_: *Tcp1, status: i32) void {
            connection_attempted = true;
            connection_status = status;
            if (status < 0) {
                std.debug.print("Connect error: {d}\n", .{status});
            }
        }

        fn onClose(_: *Tcp1) void {
            std.debug.print("closed\n", .{});
        }
    };

    var conn_req = try ConnectReq.init(testing.allocator);
    defer conn_req.deinit(testing.allocator);
    try client.connect(&conn_req, addr, Callbacks.onConnect);
    client.close(Callbacks.onClose);
    _ = try loop.run(.default);

    try testing.expect(Callbacks.connection_attempted);
    try testing.expectEqual(@as(i32, -89), Callbacks.connection_status); // ECONNREFUSED
}
