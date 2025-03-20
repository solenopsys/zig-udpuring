const std = @import("std");
const net = std.net;
const mem = std.mem;
const xev = @import("xev");
const udp = @import("udp.zig");
const UdpGate = udp.UdpGate;

const DEFAULT_PORT = 8080;

// Example message handler that sends echo responses
fn echoHandler(self: *UdpGate, data: []const u8, sender: net.Address) void {
    std.debug.print("Эхо-обработчик получил: {s}\n", .{data});
    self.send(sender, data);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Get port from command line arguments
    var port: u16 = DEFAULT_PORT;

    var args = std.process.args();
    _ = args.skip(); // Skip program name

    if (args.next()) |arg| {
        port = try std.fmt.parseInt(u16, arg, 10);
    }

    // Initialize server address
    const server_addr = try net.Address.parseIp4("0.0.0.0", port);

    // print listen port
    std.debug.print("Listening on port {d}\n", .{port});

    // Create and initialize UdpGate
    var gate = try UdpGate.init(allocator, server_addr);
    defer gate.deinit();

    // Set echo handler
    gate.setMessageHandler(echoHandler);

    // Start listening for messages
    try gate.listen();
}
