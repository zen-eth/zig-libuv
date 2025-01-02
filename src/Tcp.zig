//! TCP handles are used to handle TCP connections.
//!
const Tcp = @This();

const std = @import("std");
const c = @import("c.zig");
const Loop = @import("Loop.zig");
const errors = @import("error.zig");
const stream = @import("stream.zig");
const Stream = stream.Stream;
const WriteReq = stream.WriteReq;
const Handle = @import("handle.zig").Handle;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Async = @import("Async.zig");

handle: *c.uv_tcp_t,

pub usingnamespace Handle(Tcp);
pub usingnamespace Stream(Tcp);

pub fn init(loop: Loop, allocator: Allocator) !Tcp {
    const tcp_handle = try allocator.create(c.uv_tcp_t);
    errdefer allocator.destroy(tcp_handle);

    try errors.convertError(c.uv_tcp_init(loop.loop, tcp_handle));

    return Tcp{ .handle = tcp_handle };
}

pub fn deinit(self: *Tcp, allocator: Allocator) void {
    allocator.destroy(self.handle);
    self.* = undefined;
}

pub fn bind(self: *Tcp, addr: std.net.Address) !void {
    var sockaddr = addr.any;
    try errors.convertError(c.uv_tcp_bind(
        self.handle,
        @ptrCast(&sockaddr),
        0,
    ));
}

pub fn listen(self: *Tcp, backlog: i32, comptime cb: fn (*Tcp, i32) void) !void {
    const Wrapper = struct {
        fn callback(tcp_handle: [*c]c.uv_stream_t, status: c_int) callconv(.C) void {
            var tcp_instance: Tcp = .{ .handle = @ptrCast(tcp_handle) };
            @call(.always_inline, cb, .{ &tcp_instance, @as(i32, @intCast(status)) });
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

pub fn connect(self: *Tcp, conn_req: *ConnectReq, addr: std.net.Address, comptime cb: fn (*ConnectReq, i32) void) !void {
    const Wrapper = struct {
        fn callback(req: [*c]c.uv_connect_t, status: c_int) callconv(.C) void {
            var conn_req_callback: ConnectReq = .{ .req = req };
            @call(.always_inline, cb, .{ &conn_req_callback, @as(i32, @intCast(status)) });
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
        fn onClose(_: *Tcp) void {
            std.debug.print("closed\n", .{});
        }
    };
    var tcp = try init(loop, testing.allocator);
    defer tcp.deinit(testing.allocator);

    tcp.close(Wrapper.onClose);
    _ = try loop.run(.default);
}

test "tcp: echo client" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    var client = try Tcp.init(loop, testing.allocator);
    defer client.deinit(testing.allocator);

    const addr = try std.net.Address.parseIp4("127.0.0.1", 7000);

    const Callbacks = struct {
        var connection_attempted: bool = false;
        var connection_status: i32 = 0;

        fn onConnect(req: *ConnectReq, status: i32) void {
            connection_attempted = true;
            connection_status = status;
            if (status < 0) {
                std.debug.print("Connect error: {d}\n", .{status});
            }
            const tcp1: Tcp = req.handle(Tcp).?;
            tcp1.close(onClose);
        }

        fn onClose(_: *Tcp) void {
            std.debug.print("closed\n", .{});
        }
    };

    var conn_req = try ConnectReq.init(testing.allocator);
    defer conn_req.deinit(testing.allocator);
    try client.connect(&conn_req, addr, Callbacks.onConnect);
    _ = try loop.run(.default);

    try testing.expect(Callbacks.connection_attempted);
    try testing.expectEqual(@as(i32, -61), Callbacks.connection_status); // ECONNREFUSED
}

test "tcp try write" {
    const TEST_PORT = 9123;

    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    const ServerContext = struct {
        var server: Tcp = undefined;
        var incoming: Tcp = undefined;
        var bytes_read: usize = 0;
        var connection_cb_called: usize = 0;
        var close_cb_called: usize = 0;

        fn onClose(_: *Tcp) void {
            close_cb_called += 1;
        }

        fn allocCallback(_: *Tcp, size: usize) ?[]u8 {
            const buffer = testing.allocator.alloc(u8, size) catch return null;
            return buffer;
        }

        fn readCallback(_: *Tcp, nread: isize, buf: []const u8) void {
            defer testing.allocator.free(buf);
            if (nread < 0) {
                server.close(onClose);
                incoming.close(onClose);
                return;
            }
            bytes_read += @intCast(nread);
        }

        fn onConnection(server_handle: *Tcp, status: i32) void {
            if (status >= 0) {
                connection_cb_called += 1;
                incoming = Tcp.init(server_handle.loop(), testing.allocator) catch return;
                server_handle.accept(&incoming) catch return;
                incoming.readStart(allocCallback, readCallback) catch return;
            }
        }
    };

    const ClientContext = struct {
        var client: Tcp = undefined;
        var bytes_written: usize = 0;
        var connect_cb_called: usize = 0;

        fn onClose(_: *Tcp) void {
            ServerContext.close_cb_called += 1;
        }

        fn onConnect(req: *ConnectReq, status: i32) void {
            if (status >= 0) {
                connect_cb_called += 1;
                const tcp = req.handle(Tcp).?;

                // Try write "PING"
                const buf = "PING";
                while (true) {
                    const bufs = [_][]const u8{buf};
                    const r = tcp.tryWrite(&bufs) catch break;
                    if (r > 0) {
                        bytes_written += r;
                        break;
                    }
                }

                // Try write empty buffer
                while (true) {
                    const bufs = [_][]const u8{""};
                    const r = tcp.tryWrite(&bufs) catch break;
                    if (r == 0) break;
                }

                tcp.close(onClose);
            }
        }
    };

    // Start server
    ServerContext.server = try Tcp.init(loop, testing.allocator);
    defer ServerContext.incoming.deinit(testing.allocator);
    defer ServerContext.server.deinit(testing.allocator);

    const addr = try std.net.Address.parseIp4("0.0.0.0", TEST_PORT);
    try ServerContext.server.bind(addr);
    try ServerContext.server.listen(128, ServerContext.onConnection);

    // Start client
    ClientContext.client = try Tcp.init(loop, testing.allocator);
    defer ClientContext.client.deinit(testing.allocator);

    const client_addr = try std.net.Address.parseIp4("127.0.0.1", TEST_PORT);
    var connect_req = try ConnectReq.init(testing.allocator);
    defer connect_req.deinit(testing.allocator);
    try ClientContext.client.connect(&connect_req, client_addr, ClientContext.onConnect);

    _ = try loop.run(.default);

    try testing.expectEqual(@as(usize, 1), ClientContext.connect_cb_called);
    try testing.expectEqual(@as(usize, 3), ServerContext.close_cb_called);
    try testing.expectEqual(@as(usize, 1), ServerContext.connection_cb_called);
    try testing.expectEqual(ServerContext.bytes_read, ClientContext.bytes_written);
    try testing.expect(ClientContext.bytes_written > 0);
}
