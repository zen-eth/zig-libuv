const std = @import("std");
const c = @import("c.zig");
const Loop = @import("Loop.zig");
const errors = @import("error.zig");
const stream = @import("stream.zig");
const handle = @import("handle.zig");
const pipe = @import("pipe.zig");

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

    pub fn deinit(self: *Tcp, allocator: std.mem.Allocator) void {
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

    pub fn connect(self: *Tcp, addr: std.net.Address, allocator: std.mem.Allocator, comptime cb: fn (*Tcp, i32) void) !void {
        const Wrapper = struct {
            fn callback(req: [*c]c.uv_connect_t, status: c_int) callconv(.C) void {
                var tcp_instance: Tcp = .{ .handle = @ptrCast(req.*.handle) };
                cb(&tcp_instance, @intCast(status));
            }
        };

        const connect_req = try allocator.create(c.uv_connect_t);
        defer allocator.destroy(connect_req);

        var sockaddr = addr.any;
        try errors.convertError(c.uv_tcp_connect(
            connect_req,
            self.handle,
            @ptrCast(&sockaddr),
            Wrapper.callback,
        ));
    }
};

test "tcp: create and destroy" {
    const testing = std.testing;
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    const Wrapper = struct {
        fn onClose(_: *Tcp) void {}
    };
    var tcp = try Tcp.init(&loop, testing.allocator);
    defer tcp.deinit(testing.allocator);

    tcp.close(Wrapper.onClose);
    _ = try loop.run(.default);
}

test "tcp: echo client" {
    const testing = std.testing;
    var loop = try Loop.init(testing.allocator);
    defer loop.deinit(testing.allocator);

    var client = try Tcp.init(&loop, testing.allocator);
    defer client.deinit(testing.allocator);

    const addr = try std.net.Address.parseIp4("127.0.0.1", 7000);

    const Callbacks = struct {
        var connection_attempted: bool = false;
        var connection_status: i32 = 0;

        fn onConnect(_: *Tcp, status: i32) void {
            connection_attempted = true;
            connection_status = status;
            if (status < 0) {
                std.debug.print("Connect error: {d}\n", .{status});
            }
        }

        fn onClose(_: *Tcp) void {}
    };

    try client.connect(addr, testing.allocator, Callbacks.onConnect);
    client.close(Callbacks.onClose);
    _ = try loop.run(.default);

    try testing.expect(Callbacks.connection_attempted);
    try testing.expectEqual(@as(i32, -89), Callbacks.connection_status); // ECONNREFUSED
}

test "tcp: server and client connection" {
    const testing = std.testing;
    var server_loop = try Loop.init(testing.allocator);
    defer server_loop.deinit(testing.allocator);

    var client_loop = try Loop.init(testing.allocator);
    defer client_loop.deinit(testing.allocator);

    // Initialize server
    var server = try Tcp.init(&server_loop, testing.allocator);
    const addr = try std.net.Address.parseIp4("127.0.0.1", 7000);
    try server.bind(addr);

    const Callbacks = struct {
        var client_connected: bool = false;
        var server_accepted: bool = false;
        var server_loop_ptr: *Loop = undefined;
        var alloc: std.mem.Allocator = undefined;

        fn onServerConnection(server_handle: *Tcp, status: i32) void {
            if (status >= 0) {
                var client = Tcp.init(server_loop_ptr, alloc) catch return;
                if (server_handle.accept(&client)) |_| {
                    server_accepted = true;
                } else |_| {
                    client.deinit(alloc, onClose);
                }
            }
        }

        fn onClientConnect(_: *Tcp, status: i32) void {
            if (status >= 0) {
                client_connected = true;
            }
        }

        fn onClose(_: *Tcp) void {}
    };

    Callbacks.server_loop_ptr = &server_loop;
    Callbacks.alloc = testing.allocator;

    // Start server and run one iteration to ensure it's listening
    try server.listen(128, Callbacks.onServerConnection);
    _ = try server_loop.run(.nowait);

    // Now connect client
    var client = try Tcp.init(&client_loop, testing.allocator);
    try client.connect(addr, testing.allocator, Callbacks.onClientConnect);

    // Run both loops until connection is established
    while (!Callbacks.client_connected or !Callbacks.server_accepted) {
        _ = try server_loop.run(.nowait);
        _ = try client_loop.run(.nowait);
    }

    try testing.expect(Callbacks.client_connected);
    try testing.expect(Callbacks.server_accepted);

    client.deinit(testing.allocator, Callbacks.onClose);
    server.deinit(testing.allocator, Callbacks.onClose);
}

// test "tcp: echo server with data transfer" {
//     const testing = std.testing;
//     std.debug.print("\n=== Starting echo server test ===\n", .{});
//
//     var loop = try Loop.init(testing.allocator);
//     defer loop.deinit(testing.allocator);
//
//     var server = try Tcp.init(&loop, testing.allocator);
//     const addr = try std.net.Address.parseIp4("127.0.0.1", 7000);
//     try server.bind(addr);
//
//     const test_message = "Hello from client";
//     const Callbacks = struct {
//         var received_data: bool = false;
//         var data_echoed: bool = false;
//         var loop_ptr: *Loop = undefined;
//         var alloc: std.mem.Allocator = undefined;
//         var server_client: ?*Tcp = null; // Keep track of accepted client
//         var write_req: ?*stream.WriteReq = null;
//
//         fn allocCallback(_: *Tcp, size: usize) ?[]u8 {
//             std.debug.print("Allocating buffer size: {}\n", .{size});
//             const buffer = alloc.alloc(u8, size) catch return null;
//             return buffer;
//         }
//
//         fn onServerRead(tcp_server: *Tcp, nread: isize, buffer: []const u8) void {
//             std.debug.print("Server received bytes: {}\n", .{nread});
//             if (nread > 0) {
//                 received_data = true;
//                 write_req = alloc.create(stream.WriteReq) catch return;
//                 write_req.?.* = stream.WriteReq.init(alloc) catch return;
//                 const bufs = [_][]const u8{buffer[0..@intCast(nread)]};
//                 tcp_server.write(write_req.?.*, &bufs, onWrite) catch return;
//             }
//         }
//
//         fn onWrite(_: *stream.WriteReq, status: i32) void {
//             std.debug.print("Write completed with status: {}\n", .{status});
//             if (write_req) |wr| {
//                 alloc.destroy(wr);
//                 write_req = null;
//             }
//         }
//
//         fn onClientRead(_: *Tcp, nread: isize, buffer: []const u8) void {
//             std.debug.print("Client read: {} bytes\n", .{nread});
//             if (nread > 0) {
//                 const received = buffer[0..@intCast(nread)];
//                 std.debug.print("Client received: {s}\nExpected: {s}\n", .{ received, test_message });
//                 if (std.mem.eql(u8, received, test_message)) {
//                     data_echoed = true;
//                 }
//             }
//         }
//
//         fn onServerConnection(server_handle: *Tcp, status: i32) void {
//             std.debug.print("Server connection status: {}\n", .{status});
//             if (status >= 0) {
//                 var client = Tcp.init(loop_ptr, alloc) catch return;
//                 server_handle.accept(&client) catch {
//                     client.deinit(alloc, onClose);
//                     return;
//                 };
//                 server_client = &client;
//                 client.readStart(allocCallback, onServerRead) catch {
//                     client.deinit(alloc, onClose);
//                     return;
//                 };
//             }
//         }
//
//         fn onClose(tcp_handle: *Tcp) void {
//             if (server_client) |client| {
//                 if (tcp_handle == client) {
//                     server_client = null;
//                 }
//             }
//         }
//
//         fn onClientConnect(_: *Tcp, status: i32) void {
//             std.debug.print("Client connect status: {}\n", .{status});
//         }
//     };
//
//     Callbacks.loop_ptr = &loop;
//     Callbacks.alloc = testing.allocator;
//
//     try server.listen(128, Callbacks.onServerConnection);
//
//     var client = try Tcp.init(&loop, testing.allocator);
//     try client.connect(addr, testing.allocator, Callbacks.onClientConnect);
//     try client.readStart(Callbacks.allocCallback, Callbacks.onClientRead);
//
//     const write_req = try stream.WriteReq.init(testing.allocator);
//     const bufs = [_][]const u8{test_message};
//     try client.write(write_req, &bufs, Callbacks.onWrite);
//
//     while (!Callbacks.received_data or !Callbacks.data_echoed) {
//         _ = try loop.run(.nowait);
//     }
//
//     try testing.expect(Callbacks.received_data);
//     try testing.expect(Callbacks.data_echoed);
// }
//
// test "tcp: echo server with data transfer1" {
//     const testing = std.testing;
//     std.debug.print("\n=== Starting echo server test ===\n", .{});
//
//     var loop = try Loop.init(testing.allocator);
//     defer loop.deinit(testing.allocator);
//
//     var server = try Tcp.init(&loop, testing.allocator);
//     const addr = try std.net.Address.parseIp4("127.0.0.1", 8001);
//     try server.bind(addr);
//
//     const test_message = "Hello from client";
//     const Callbacks = struct {
//         var received_data: bool = false;
//         var connected: usize = 0;
//         var data_echoed: bool = false;
//         var loop_ptr: *Loop = undefined;
//         var alloc: std.mem.Allocator = undefined;
//         var server_clients: std.ArrayList(*Tcp) = undefined; // Track multiple clients
//         var write_reqs: std.ArrayList(*stream.WriteReq) = undefined;
//         // Add write completion tracking
//         var write_completed: usize = 0;
//         var total_writes: usize = 0;
//         var clients_completed: usize = 0;
//         fn init() void {
//             server_clients = std.ArrayList(*Tcp).init(alloc);
//             write_reqs = std.ArrayList(*stream.WriteReq).init(alloc);
//         }
//
//         fn deinit() void {
//             server_clients.deinit();
//             write_reqs.deinit();
//         }
//
//         fn allocCallback(_: *Tcp, size: usize) ?[]u8 {
//             std.debug.print("Allocating buffer size: {}\n", .{size});
//             const buffer = alloc.alloc(u8, size) catch return null;
//             return buffer;
//         }
//
//         fn onServerRead(tcp_server: *Tcp, nread: isize, buffer: []const u8) void {
//             if (nread > 0) {
//                 received_data = true;
//                 const write_req = alloc.create(stream.WriteReq) catch return;
//                 write_req.* = stream.WriteReq.init(alloc) catch return;
//                 write_reqs.append(write_req) catch return;
//                 const bufs = [_][]const u8{buffer[0..@intCast(nread)]};
//                 tcp_server.write(write_req.*, &bufs, onWrite) catch return;
//             }
//         }
//
//         fn onWrite(req: *stream.WriteReq, _: i32) void {
//             write_completed += 1;
//             for (write_reqs.items, 0..) |write_req, i| {
//                 if (req == write_req) {
//                     _ = write_reqs.orderedRemove(i);
//                     alloc.destroy(write_req);
//                     break;
//                 }
//             }
//         }
//
//         fn onClientRead(_: *Tcp, nread: isize, buffer: []const u8) void {
//             std.debug.print("Client read: {} bytes\n", .{nread});
//             if (nread > 0) {
//                 const received = buffer[0..@intCast(nread)];
//                 std.debug.print("Client received: {s}\nExpected: {s}\n", .{ received, test_message });
//                 if (std.mem.eql(u8, received, test_message)) {
//                     data_echoed = true;
//                     clients_completed += 1;
//                 }
//             }
//         }
//
//         fn onServerConnection(server_handle: *Tcp, status: i32) void {
//             if (status >= 0) {
//                 connected += 1;
//                 var client = Tcp.init(loop_ptr, alloc) catch return;
//                 server_handle.accept(&client) catch {
//                     client.deinit(alloc, onClose);
//                     return;
//                 };
//                 server_clients.append(&client) catch {
//                     client.deinit(alloc, onClose);
//                     return;
//                 };
//                 client.readStart(allocCallback, onServerRead) catch {
//                     _ = server_clients.pop();
//                     client.deinit(alloc, onClose);
//                     return;
//                 };
//             }
//         }
//
//         fn onClose(tcp_handle: *Tcp) void {
//             for (server_clients.items, 0..) |client, i| {
//                 if (tcp_handle == client) {
//                     _ = server_clients.orderedRemove(i);
//                     break;
//                 }
//             }
//         }
//
//         fn onClientConnect(_: *Tcp, status: i32) void {
//             std.debug.print("Client connect status: {}\n", .{status});
//         }
//     };
//
//     Callbacks.loop_ptr = &loop;
//     Callbacks.alloc = testing.allocator;
//     Callbacks.init();
//     defer Callbacks.deinit();
//
//     try server.listen(128, Callbacks.onServerConnection);
//
//     var client = try Tcp.init(&loop, testing.allocator);
//     try client.connect(addr, testing.allocator, Callbacks.onClientConnect);
//     try client.readStart(Callbacks.allocCallback, Callbacks.onClientRead);
//
//     const write_req = try stream.WriteReq.init(testing.allocator);
//     const bufs = [_][]const u8{test_message};
//     Callbacks.total_writes += 1;
//     try client.write(write_req, &bufs, Callbacks.onWrite);
//
//     var client1 = try Tcp.init(&loop, testing.allocator);
//     try client1.connect(addr, testing.allocator, Callbacks.onClientConnect);
//     try client1.readStart(Callbacks.allocCallback, Callbacks.onClientRead);
//
//     const write_req1 = try stream.WriteReq.init(testing.allocator);
//     const bufs1 = [_][]const u8{test_message};
//     Callbacks.total_writes += 1;
//
//     try client1.write(write_req1, &bufs1, Callbacks.onWrite);
//
//     while (!Callbacks.received_data or
//         Callbacks.clients_completed < 2 or
//         Callbacks.write_completed < Callbacks.total_writes)
//     {
//         _ = try loop.run(.nowait);
//     }
//
//     try testing.expect(Callbacks.received_data);
//     try testing.expect(Callbacks.data_echoed);
//     try testing.expect(Callbacks.connected == 2);
// }
