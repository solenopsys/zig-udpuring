const std = @import("std");
const net = std.net;
const mem = std.mem;
const xev = @import("xev");

const BUFFER_SIZE = 8192;

pub const MessageHandler = struct {
    gate: *UdpGate,
    onMessage: *const fn (ctx: *anyopaque, data: []const u8, sender: net.Address) void,
};

/// UdpGate provides a simple interface for UDP communication
pub const UdpGate = struct {
    allocator: mem.Allocator,
    loop: *xev.IO_Uring.Loop,
    udp: xev.UDP,
    recv_state: xev.UDP.State = undefined, // Separate state for receiving
    send_state: xev.UDP.State = undefined, // Separate state for sending
    buffer: [BUFFER_SIZE]u8 = undefined,
    recv_completion: xev.Completion = undefined,
    send_completion: xev.Completion = undefined,
    address: net.Address,
    message_handler: ?MessageHandler = null,

    /// Initialize a new UdpGate
    pub fn init(allocator: mem.Allocator, address: net.Address) !*UdpGate {
        // Create the loop first
        const loop_ptr = try allocator.create(xev.IO_Uring.Loop);
        loop_ptr.* = try xev.IO_Uring.Loop.init(.{
            .entries = 4096,
        });

        // Create the gate
        var gate = try allocator.create(UdpGate);

        gate.* = .{
            .allocator = allocator,
            .loop = loop_ptr,
            .udp = try xev.UDP.init(address),
            .address = address,
        };

        try gate.udp.bind(address);
        return gate;
    }

    /// Clean up resources
    pub fn deinit(self: *UdpGate) void {
        self.loop.deinit();
        self.allocator.destroy(self.loop);
        self.allocator.destroy(self);
    }

    /// Set a handler for incoming messages
    pub fn setMessageHandler(self: *UdpGate, handler: MessageHandler) void {
        self.message_handler = handler;
    }

    /// Send data to a specified address
    pub fn send(self: *UdpGate, address: net.Address, data: []const u8) void {
        self.udp.write(
            @ptrCast(self.loop),
            &self.send_completion,
            &self.send_state, // Use the dedicated send state
            address,
            .{ .slice = data },
            UdpGate,
            self,
            onSend,
        );
    }

    /// Start listening for incoming messages
    pub fn listen(self: *UdpGate) !void {
        std.debug.print("UDP сервер слушает на порту {d}...\n", .{self.address.getPort()});

        // Start listening for incoming data
        self.startReceiving();

        // Run the event loop indefinitely
        while (true) {
            try self.loop.run(.until_done);
            // Add a very small sleep to avoid tight loop CPU usage
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Internal method to start the receive operation
    fn startReceiving(self: *UdpGate) void {
        self.udp.read(
            @ptrCast(self.loop),
            &self.recv_completion,
            &self.recv_state, // Use the dedicated receive state
            .{ .slice = &self.buffer },
            UdpGate,
            self,
            onReceive,
        );
    }
};

// Callback for handling send operations
fn onSend(
    gate: ?*UdpGate,
    _: *xev.Loop,
    _: *xev.Completion,
    _: *xev.UDP.State,
    _: xev.UDP,
    _: xev.WriteBuffer,
    result: xev.WriteError!usize,
) xev.CallbackAction {
    _ = gate;
    const bytes_sent = result catch |e| {
        std.debug.print("Ошибка отправки: {}\n", .{e});
        return .disarm;
    };

    std.debug.print("Отправлено {d} байт\n", .{bytes_sent});
    return .disarm;
}

// Callback for handling receive operations
fn onReceive(
    gate: ?*UdpGate,
    loop: *xev.Loop,
    comp: *xev.Completion,
    state: *xev.UDP.State,
    addr: net.Address,
    _: xev.UDP,
    buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    _ = loop;
    _ = comp;
    _ = state;
    const bytes_read = result catch |e| {
        std.debug.print("Ошибка чтения: {}\n", .{e});
        // Re-arm the receiver for next message
        if (gate) |g| {
            g.startReceiving();
        }
        return .disarm;
    };

    if (bytes_read == 0) {
        // Re-arm the receiver for next message
        if (gate) |g| {
            g.startReceiving();
        }
        return .disarm;
    }

    const data = buffer.slice[0..bytes_read];

    // Process received data
    if (gate) |g| {
        if (g.message_handler) |handler| {
            handler.onMessage(g, data, addr);
        } else {
            // Default behavior: print received data
            std.debug.print("Получено {d} байт от {}: {s}\n", .{ bytes_read, addr, data });
        }

        // Re-arm the receiver for next message
        g.startReceiving();
    }

    return .disarm; // We'll manually re-arm
}
