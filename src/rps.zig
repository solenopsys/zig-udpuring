const std = @import("std");
const net = std.net;
const mem = std.mem;
const xev = @import("xev");
const Thread = std.Thread;
const log = std.debug.print;
const udp = @import("udp.zig");
const UdpGate = udp.UdpGate;
const MessageHandler = udp.MessageHandler;

// Структура для хранения статистики
const StatsResult = struct { count: u64, bytes: u64 };

// Структура для отслеживания производительности
const PerformanceTracker = struct {
    counter: u64,
    total_bytes: u64,
    mutex: Thread.Mutex,

    pub fn init() PerformanceTracker {
        return PerformanceTracker{
            .counter = 0,
            .total_bytes = 0,
            .mutex = Thread.Mutex{},
        };
    }

    pub fn reset(self: *PerformanceTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.counter = 0;
        self.total_bytes = 0;
    }

    pub fn increment(self: *PerformanceTracker, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.counter += 1;
        self.total_bytes += bytes;
    }

    pub fn getAndReset(self: *PerformanceTracker) StatsResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = StatsResult{
            .count = self.counter,
            .bytes = self.total_bytes,
        };

        self.counter = 0;
        self.total_bytes = 0;

        return result;
    }
};

// Глобальный трекер производительности
var perf_tracker = PerformanceTracker.init();
var server_running = true;

// Функция для отчета о производительности
fn reporterThread() void {
    // Чтобы не измерять время точно, просто ждем примерно 1 секунду между отчетами
    while (server_running) {
        // Ждем примерно 1 секунду
        std.time.sleep(1 * std.time.ns_per_s);

        // Получаем данные и сбрасываем счетчики
        const stats = perf_tracker.getAndReset();

        // Выводим отчет
        log("Performance: {d} req/s, {d:.2} MB/s\n", .{ stats.count, @as(f64, @floatFromInt(stats.bytes)) / 1024.0 / 1024.0 });
    }
}

// Функция обработчика сообщений с подсчетом
fn benchmarkMessageHandler(self: *anyopaque, data: []const u8, client_addr: net.Address) void {
    _ = self;
    _ = client_addr;

    // Просто инкрементируем счетчики
    perf_tracker.increment(data.len);
}

pub fn main() !void {
    // Инициализация аллокатора
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    const port: u16 = 8888;

    log("Starting UDP benchmark server on port {d}...\n", .{port});
    log("Press Ctrl+C to exit\n", .{});

    // Запускаем поток для отчетов
    var reporter = try Thread.spawn(.{}, reporterThread, .{});

    // Инициализация UDP сервера
    const server_addr = try net.Address.parseIp4("0.0.0.0", port);
    var gate = try UdpGate.init(gpa, server_addr);
    defer {
        server_running = false;
        gate.deinit();
    }

    // Установка обработчика сообщений
    gate.setMessageHandler(MessageHandler{
        .gate = gate,
        .onMessage = benchmarkMessageHandler,
    });

    // Запуск сервера
    try gate.listen();

    // Этот код не должен выполниться, так как gate.listen() никогда не вернется
    reporter.join();
}
