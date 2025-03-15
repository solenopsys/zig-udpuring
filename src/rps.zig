const std = @import("std");
const posix = std.posix;
const log = std.debug.print;
const Thread = std.Thread;

const server_module = @import("udp.zig");
const UdpIoUringServer = server_module.UdpIoUringServer;

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

// Функция обработчика сообщений с подсчетом
fn benchmarkMessageHandler(data: []const u8, client_addr: *const posix.sockaddr, client_addr_len: posix.socklen_t, userdata: ?*anyopaque) void {
    _ = client_addr;
    _ = client_addr_len;
    _ = userdata;

    // Просто инкрементируем счетчики
    perf_tracker.increment(data.len);
}

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

pub fn main() !void {
    // Инициализация UDP сервера
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    log("Starting UDP benchmark server on port 8888...\n", .{});
    log("Press Ctrl+C to exit\n", .{});

    // Запускаем поток для отчетов
    var reporter = try Thread.spawn(.{}, reporterThread, .{});

    // Инициализация UDP сервера
    var server = try UdpIoUringServer.init(gpa, 8888, &benchmarkMessageHandler, null);
    defer {
        server_running = false;
        server.deinit();
    }

    try server.run();

    // Этот код не должен выполниться, так как server.run() никогда не вернется
    reporter.join();
}
