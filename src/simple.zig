const std = @import("std");
const posix = std.posix;
const log = std.debug.print;
const net = std.net;

const server_module = @import("udp.zig");
const UdpIoUringServer = server_module.UdpIoUringServer;

// Пример функции обработчика сообщений
fn benchmarkMessageHandler(data: []const u8, client_addr: *const posix.sockaddr, client_addr_len: posix.socklen_t, userdata: ?*anyopaque) void {
    log("Received message: {s}\n", .{data});
    log("Client address: {any}\n", .{client_addr});
    log("Client address length: {d}\n", .{client_addr_len});
    log("Userdata: {any}\n", .{userdata});
}

pub fn main() !void {
    // Разбор аргументов командной строки
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    // Инициализация UDP сервера
    var server: UdpIoUringServer = try UdpIoUringServer.init(gpa, 8888, &benchmarkMessageHandler, null);
    defer server.deinit();

    try server.run(); // First start the server to handle incoming messages

    // After starting the server, send a message
    const remoteAddress = try net.Address.parseIp("192.168.1.1", 8888);
    const message = "Hello, World!";

    // Get the sockaddr representation and its length
    const sockaddr = remoteAddress.any;
    try server.sendToAddr(message, &sockaddr, remoteAddress.getOsSockLen(), server.base_user_data); // Use the server's base_user_data
}
