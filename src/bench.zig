const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.debug.print;
const mem = std.mem;
const net = std.net;
const time = std.time;
const Allocator = std.mem.Allocator;
const Value = std.atomic.Value;

// Включаем определение UdpIoUringServer из основного файла
// Предполагается, что он находится в том же каталоге
const server_module = @import("udp.zig");
const UdpIoUringServer = server_module.UdpIoUringServer;
const MessageHandlerFn = server_module.MessageHandlerFn;

const BenchmarkConfig = struct {
    local_port: u16,
    remote_port: u16,
    remote_addr: [4]u8 = [_]u8{ 127, 0, 0, 1 }, // localhost по умолчанию
    message_size: usize = 1024,
    duration_ms: u64 = 10000, // 10 секунд по умолчанию
    messages_per_batch: usize = 100, // количество сообщений в пакете
};

const BenchmarkStats = struct {
    messages_sent: Value(u64),
    messages_received: Value(u64),
    bytes_sent: Value(u64),
    bytes_received: Value(u64),
    start_time: i128,
    end_time: i128,

    pub fn init() BenchmarkStats {
        return BenchmarkStats{
            .messages_sent = Value(u64).init(0),
            .messages_received = Value(u64).init(0),
            .bytes_sent = Value(u64).init(0),
            .bytes_received = Value(u64).init(0),
            .start_time = 0,
            .end_time = 0,
        };
    }

    pub fn startTimer(self: *BenchmarkStats) void {
        self.start_time = time.nanoTimestamp();
    }

    pub fn stopTimer(self: *BenchmarkStats) void {
        self.end_time = time.nanoTimestamp();
    }

    pub fn getElapsedMs(self: *const BenchmarkStats) f64 {
        const nanoseconds = @as(f64, @floatFromInt(self.end_time - self.start_time));
        return nanoseconds / 1_000_000.0;
    }

    pub fn printResults(self: *const BenchmarkStats) void {
        const elapsed_ms = self.getElapsedMs();
        const elapsed_s = elapsed_ms / 1000.0;

        const msgs_sent = self.messages_sent.load(.acquire);
        const msgs_received = self.messages_received.load(.acquire);
        const bytes_sent = self.bytes_sent.load(.acquire);
        const bytes_received = self.bytes_received.load(.acquire);

        const msgs_sent_per_sec = @as(f64, @floatFromInt(msgs_sent)) / elapsed_s;
        const msgs_received_per_sec = @as(f64, @floatFromInt(msgs_received)) / elapsed_s;
        const mbits_sent_per_sec = @as(f64, @floatFromInt(bytes_sent)) * 8.0 / 1_000_000.0 / elapsed_s;
        const mbits_received_per_sec = @as(f64, @floatFromInt(bytes_received)) * 8.0 / 1_000_000.0 / elapsed_s;

        log("\n=== Бенчмарк результаты ===\n", .{});
        log("Время выполнения: {d:.2} секунд\n", .{elapsed_s});
        log("Сообщений отправлено: {d} ({d:.2} сообщений/сек)\n", .{ msgs_sent, msgs_sent_per_sec });
        log("Сообщений получено: {d} ({d:.2} сообщений/сек)\n", .{ msgs_received, msgs_received_per_sec });
        log("Отправлено: {d} байт ({d:.2} Мбит/сек)\n", .{ bytes_sent, mbits_sent_per_sec });
        log("Получено: {d} байт ({d:.2} Мбит/сек)\n", .{ bytes_received, mbits_received_per_sec });
    }
};

// Глобальная статистика бенчмарка
var stats = BenchmarkStats.init();
var config: BenchmarkConfig = undefined;
var remote_addr_cache: posix.sockaddr = undefined;
var remote_addr_len: posix.socklen_t = undefined;
var server: *UdpIoUringServer = undefined;
var should_stop = Value(bool).init(false);

// Обработчик сообщений для бенчмарка
fn benchmarkMessageHandler(data: []const u8, client_index: usize, client_addr: *const posix.sockaddr, client_addr_len: posix.socklen_t, userdata: ?*anyopaque) void {
    _ = userdata;

    _ = stats.messages_received.fetchAdd(1, .monotonic);
    _ = stats.bytes_received.fetchAdd(data.len, .monotonic);

    // Проверка на особое сообщение для завершения бенчмарка
    if (mem.eql(u8, data, "BENCHMARK_STOP")) {
        should_stop.store(true, .release);
        return;
    }

    // Отправляем ответное сообщение
    server.sendToAddr(data, client_addr, client_addr_len, client_index) catch |err| {
        log("Ошибка отправки ответа: {any}\n", .{err});
    };

    // Увеличиваем счетчики для отправленного сообщения
    _ = stats.messages_sent.fetchAdd(1, .monotonic);
    _ = stats.bytes_sent.fetchAdd(data.len, .monotonic);
}

// Функция генерации тестового сообщения
fn generateMessage(buffer: []u8, message_size: usize, message_num: u64) void {
    // Форматируем заголовок сообщения с номером
    var header_len: usize = 0;
    if (std.fmt.bufPrint(buffer[0..@min(32, message_size)], "MSG-{d}", .{message_num})) |header| {
        header_len = header.len;
    } else |err| {
        log("Ошибка при форматировании сообщения: {s}\n", .{@errorName(err)});
        @memset(buffer[0..@min(32, message_size)], 'X');
        header_len = @min(32, message_size);
    }

    // Заполняем остаток буфера тестовыми данными
    if (message_size > header_len) {
        @memset(buffer[header_len..message_size], 'A' + @as(u8, @intCast(message_num % 26)));
    }
}

// Функция для отправки тестовых сообщений
fn sendBenchmarkMessages(local_server: *UdpIoUringServer, allocator: Allocator, remote_address: *const posix.sockaddr, remote_len: posix.socklen_t, conf: *const BenchmarkConfig) !void {
    var message_buf = try allocator.alloc(u8, conf.message_size);
    defer allocator.free(message_buf);

    var message_num: u64 = 0;
    const start_time = time.milliTimestamp();
    var batch_interval_ns: u64 = 10_000_000; // 10 ms начальный интервал
    var batch_size: usize = 10; // Начинаем с меньшего размера пакета

    log("Начало отправки сообщений...\n", .{});

    while (!should_stop.load(.acquire)) {
        const current_time = time.milliTimestamp();
        if (current_time - start_time > conf.duration_ms) {
            // Отправляем сигнал о завершении бенчмарка
            @memcpy(message_buf[0..14], "BENCHMARK_STOP");
            try local_server.sendToAddr(message_buf[0..14], remote_address, remote_len, 0);
            break;
        }

        // Отправляем batch сообщений
        const batch_start = time.nanoTimestamp();
        var i: usize = 0;
        var error_count: usize = 0;

        batch_loop: while (i < batch_size and !should_stop.load(.acquire)) : (i += 1) {
            generateMessage(message_buf, conf.message_size, message_num);

            // Обрабатываем ошибку переполнения очереди
            local_server.sendToAddr(message_buf[0..conf.message_size], remote_address, remote_len, 0) catch |err| {
                if (err == error.SubmissionQueueFull) {
                    // Если очередь заполнена, делаем паузу и уменьшаем размер пакета
                    error_count += 1;
                    if (error_count > 3) {
                        // Значительно уменьшаем размер пакета и увеличиваем интервал
                        batch_size = @max(batch_size / 2, 1);
                        batch_interval_ns *= 2;
                        // Пауза для очистки очереди
                        std.time.sleep(50 * time.ns_per_ms);
                        break :batch_loop;
                    }
                    // Короткая пауза перед повторной попыткой
                    std.time.sleep(10 * time.ns_per_ms);
                    continue :batch_loop; // Пропускаем инкремент счетчика
                } else {
                    return err; // Для других ошибок выходим с ошибкой
                }
            };

            _ = stats.messages_sent.fetchAdd(1, .monotonic);
            _ = stats.bytes_sent.fetchAdd(conf.message_size, .monotonic);

            message_num += 1;
        }

        // Динамически регулируем интервал между партиями сообщений и размер пакета
        const batch_end = time.nanoTimestamp();
        const batch_duration = @as(u64, @intCast(batch_end - batch_start));

        // Избегаем излишней нагрузки на CPU и сеть
        if (batch_duration < batch_interval_ns) {
            std.time.sleep(batch_interval_ns - batch_duration);

            // Если всё идёт хорошо, можно постепенно увеличивать размер пакета
            if (error_count == 0 and batch_size < conf.messages_per_batch) {
                batch_size = @min(batch_size + 1, conf.messages_per_batch);
                // Постепенно уменьшаем интервал, но не слишком быстро
                if (batch_interval_ns > 1_000_000) {
                    batch_interval_ns = @max(batch_interval_ns * 9 / 10, 1_000_000);
                }
            }
        } else {
            // Если отправка заняла больше времени, увеличиваем интервал
            batch_interval_ns = @min(batch_interval_ns * 2, 100_000_000); // макс 100ms
            // И уменьшаем размер пакета
            batch_size = @max(batch_size / 2, 1);
        }
    }

    log("Завершение отправки сообщений...\n", .{});
}

pub fn main() !void {
    // Разбор аргументов командной строки
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_purpose_allocator.deinit();
    const gpa = general_purpose_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // Настройка конфигурации по умолчанию
    config = BenchmarkConfig{
        .local_port = 8080,
        .remote_port = 8081,
        .message_size = 1024,
        .duration_ms = 10000,
    };

    // Парсинг аргументов командной строки
    if (args.len > 1) {
        config.local_port = try std.fmt.parseInt(u16, args[1], 10);
    }
    if (args.len > 2) {
        config.remote_port = try std.fmt.parseInt(u16, args[2], 10);
    }
    if (args.len > 3) {
        config.message_size = try std.fmt.parseInt(usize, args[3], 10);
    }
    if (args.len > 4) {
        config.duration_ms = try std.fmt.parseInt(u64, args[4], 10);
    }

    log("Запуск UDP бенчмарка:\n", .{});
    log("  Локальный порт: {d}\n", .{config.local_port});
    log("  Удаленный порт: {d}\n", .{config.remote_port});
    log("  Размер сообщения: {d} байт\n", .{config.message_size});
    log("  Длительность: {d} мс\n", .{config.duration_ms});

    // Инициализация UDP сервера
    var local_server_instance = try UdpIoUringServer.init(gpa, config.local_port, &benchmarkMessageHandler, null);
    defer local_server_instance.deinit();

    // Сохраняем сервер в глобальной переменной для доступа из обработчика
    server = &local_server_instance;

    // Подготовка адреса удаленного сервера
    const remote_address = net.Address.initIp4(config.remote_addr, config.remote_port);
    remote_addr_cache = remote_address.any;
    remote_addr_len = remote_address.getOsSockLen();

    // Запускаем таймер
    stats.startTimer();

    // Запускаем отправку сообщений в отдельном потоке
    const sender_thread = try std.Thread.spawn(.{}, sendBenchmarkMessages, .{
        server,
        gpa,
        &remote_addr_cache,
        remote_addr_len,
        &config,
    });

    // Основной цикл обработки входящих сообщений
    log("Запуск основного цикла сервера...\n", .{});

    // Запускаем поток проверки окончания бенчмарка
    while (!should_stop.load(.acquire)) {
        try server.run();
        // Небольшая задержка для предотвращения 100% загрузки CPU
        time.sleep(1 * time.ns_per_ms);
    }

    // Останавливаем таймер и ждем завершения потока отправки
    sender_thread.join();
    stats.stopTimer();

    // Выводим результаты
    stats.printResults();
}
