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

pub fn listen(self: *Tcp1, backlog: i32, comptime cb: fn (*Tcp1, i32) void) !void {
    const Wrapper = struct {
        fn callback(tcp_handle: [*c]c.uv_stream_t, status: c_int) callconv(.C) void {
            var tcp_instance: Tcp1 = .{ .handle = @ptrCast(tcp_handle) };
            @call(.always_inline, cb, .{ &tcp_instance, @as(i32, @intCast(status)) });
        }
    };

    try errors.convertError(c.uv_listen(
        @ptrCast(self.handle),
        backlog,
        Wrapper.callback,
    ));
}

pub fn accept(self: *Tcp1, client: *Tcp1) !void {
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

pub fn connect(self: *Tcp1, conn_req: *ConnectReq, addr: std.net.Address, comptime cb: fn (*ConnectReq, i32) void) !void {
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

// test "Write: create and destroy" {
//     var h = try ConnectReq.init(testing.allocator);
//     defer h.deinit(testing.allocator);
// }
//
// test "tcp: create and destroy" {
//     var loop = try Loop.init(testing.allocator);
//     defer loop.deinit(testing.allocator);
//
//     const Wrapper = struct {
//         fn onClose(_: *Tcp1) void {
//             std.debug.print("closed\n", .{});
//         }
//     };
//     var tcp = try init(&loop, testing.allocator);
//     defer tcp.deinit(testing.allocator);
//
//     tcp.close(Wrapper.onClose);
//     _ = try loop.run(.default);
// }

test "tcp: echo client" {
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    var client = try Tcp1.init(&loop, testing.allocator);
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
            const tcp1: Tcp1 = req.handle(Tcp1).?;
            tcp1.close(onClose);
        }

        fn onClose(_: *Tcp1) void {
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

// test "tcp: server and client connection" {
//     var server_loop = try Loop.init(testing.allocator);
//     defer server_loop.deinit(testing.allocator);
//
//     // Initialize server
//     var server = try Tcp1.init(&server_loop, testing.allocator);
//     defer server.deinit(testing.allocator);
//
//     const addr = try std.net.Address.parseIp4("127.0.0.1", 7000);
//     std.debug.print("Binding to {any}\n", .{addr});
//     try server.bind(addr);
//     std.debug.print("Listening\n", .{});
//
//     const Callbacks = struct {
//         var client_connected: bool = false;
//         var server_accepted: bool = false;
//         var server_loop_ptr: *Loop = undefined;
//         var alloc: std.mem.Allocator = undefined;
//         var client1: Tcp1 = undefined;
//
//         fn onServerConnection(server_handle: *Tcp1, status: i32) void {
//             if (status >= 0) {
//                 var client = Tcp1.init(server_loop_ptr, alloc) catch return;
//                 std.debug.print("Server connection\n", .{});
//                 client.setData(server_handle);
//                 if (server_handle.accept(&client)) |_| {
//                     server_accepted = true;
//                     std.debug.print("Server accepted\n", .{});
//                     client1 = client;
//                 } else |_| {
//
//                 }
//             }
//         }
//
//         fn onClientConnect(_: *Tcp1, status: i32) void {
//             if (status >= 0) {
//                 client_connected = true;
//             }
//         }
//
//         fn onClose(_: *Tcp1) void {
//             client1.close(onCloseInner);
//             client1.deinit(alloc);
//         }
//
//         fn onCloseInner(_: *Tcp1) void {
//             std.debug.print("closed\n", .{});
//         }
//     };
//
//     Callbacks.server_loop_ptr = &server_loop;
//     Callbacks.alloc = testing.allocator;
//
//     // Create thread for running the event loop
//     const ServerThread = struct {
//         fn run(loop: *Loop) void {
//             _=loop.run(.default) catch unreachable;
//         }
//     };
//
//     // Start server and run one iteration to ensure it's listening
//     try server.listen(128, Callbacks.onServerConnection);
//     std.debug.print("Server started\n", .{});
//     server.close(Callbacks.onCloseInner);
//     _ = try std.Thread.spawn(.{}, ServerThread.run, .{&server_loop});
//
//     // // Now connect client
//     // var client = try Tcp1.init(&client_loop, testing.allocator);
//     // try client.connect(addr, testing.allocator, Callbacks.onClientConnect);
//     //
//     // // Run both loops until connection is established
//     // while (!Callbacks.client_connected or !Callbacks.server_accepted) {
//     //     _ = try server_loop.run(.nowait);
//     //     _ = try client_loop.run(.nowait);
//     // }
//     //
//     // try testing.expect(Callbacks.client_connected);
//     // try testing.expect(Callbacks.server_accepted);
//
// }

// test "tcp: server and client connection1" {
//     var server_loop = try Loop.init(testing.allocator);
//     defer server_loop.deinit(testing.allocator);
//     var client_loop = try Loop.init(testing.allocator);
//     defer client_loop.deinit(testing.allocator);
//
//     var server = try Tcp1.init(&server_loop, testing.allocator);
//     defer server.deinit(testing.allocator);
//
//     const addr = try std.net.Address.parseIp4("127.0.0.1", 7000);
//     try server.bind(addr);
//
//     const Context = struct {
//         var connection_received = std.atomic.Value(bool).init(false);
//         var client_connected = std.atomic.Value(bool).init(false);
//     };
//
//     const Callbacks = struct {
//         fn onServerConnection(_: *Tcp1, status: i32) void {
//             if (status >= 0) {
//                 Context.connection_received.store(true, .release);
//             }
//         }
//         fn onClientConnect(_: *Tcp1, status: i32) void {
//             if (status >= 0) {
//                 Context.client_connected.store(true, .release);
//             }
//         }
//         fn onClose(_: *Tcp1) void {}
//     };
//
//     const ServerThread = struct {
//         fn run(loop: *Loop) void {
//             _=loop.run(.default) catch unreachable;
//         }
//     };
//
//     try server.listen(128, Callbacks.onServerConnection);
//     var server_thread = try std.Thread.spawn(.{}, ServerThread.run, .{&server_loop});
//
//     // Connect client
//     var client = try Tcp1.init(&client_loop, testing.allocator);
//     defer client.deinit(testing.allocator);
//     var conn_req = try ConnectReq.init(testing.allocator);
//     defer conn_req.deinit(testing.allocator);
//     try client.connect(&conn_req, addr, Callbacks.onClientConnect);
//     _=try client_loop.run(.default);
//     // Wait for connection with timeout
//     const timeout_ns = 1 * std.time.ns_per_s;
//     const start = std.time.nanoTimestamp();
//     while (!Context.connection_received.load(.acquire) or !Context.client_connected.load(.acquire)) {
//         if (std.time.nanoTimestamp() - start > timeout_ns) {
//             break;
//         }
//         std.time.sleep(1 * std.time.ns_per_ms);
//     }
//
//     server.close(Callbacks.onClose);
//     client.close(Callbacks.onClose);
//     server_thread.join();
//
//     try testing.expect(Context.connection_received.load(.acquire));
//     try testing.expect(Context.client_connected.load(.acquire));
// }
