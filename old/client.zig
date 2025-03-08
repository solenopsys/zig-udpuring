const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.debug.print;
const mem = std.mem;
const net = std.net;
const Allocator = std.mem.Allocator;
const time = std.time;

const SERVER_PORT = 8080;
const BUFFER_SIZE = 8192;
const DEFAULT_MESSAGE = "Привет, сервер!";

pub fn main() !void {
    // Обработка аргументов командной строки
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Получаем адрес сервера (по умолчанию localhost)
    var server_addr_str: []const u8 = "127.0.0.1";
    var message_to_send: []const u8 = DEFAULT_MESSAGE;

    if (args.len > 1) {
        server_addr_str = args[1];
    }
    if (args.len > 2) {
        message_to_send = args[2];
    }

    // Парсим адрес сервера
    const server_addr = try net.Address.parseIp4(server_addr_str, SERVER_PORT);

    log("Запуск UDP клиента с io_uring для отправки на {s}:{d}...\n", .{ server_addr_str, SERVER_PORT });

    // Создание UDP сокета
    const client_socket = try createUdpSocket();
    defer posix.close(client_socket);

    // Инициализация io_uring
    var ring_params = std.mem.zeroes(linux.io_uring_params);
    const ring_size: u13 = 4096;
    var ring = try linux.IoUring.init_params(ring_size, &ring_params);
    defer ring.deinit();

    // Создаем буфер для отправки и приема данных
    var send_buffer = try allocator.alloc(u8, BUFFER_SIZE);
    defer allocator.free(send_buffer);

    var recv_buffer = try allocator.alloc(u8, BUFFER_SIZE);
    defer allocator.free(recv_buffer);

    // Копируем сообщение для отправки
    std.mem.copyForwards(u8, send_buffer, message_to_send);
    const message_len = message_to_send.len;

    log("Отправка сообщения: '{s}'\n", .{message_to_send});

    // Отправляем сообщение используя стандартный sendto
    _ = try posix.sendto(client_socket, send_buffer[0..message_len], 0, &server_addr.any, server_addr.getOsSockLen());

    log("Сообщение отправлено, ожидаем ответ...\n", .{});

    // Подготавливаем операцию чтения с помощью io_uring
    const recv_user_data: u64 = 1;
    try recvResponse(&ring, client_socket, recv_buffer, recv_user_data);

    // Устанавливаем таймаут для ожидания ответа (5 секунд)
    const timeout_ns: u64 = 5 * 1000 * 1000 * 1000; // 5 секунд в наносекундах
    const start_time = time.nanoTimestamp();

    var response_received = false;

    while (!response_received) {
        const current_time = time.nanoTimestamp();
        if (current_time - start_time > timeout_ns) {
            log("Таймаут: сервер не ответил в течение 5 секунд\n", .{});
            break;
        }

        // Ждем завершения операции или проверяем каждые 100 мс
        const submitted = ring.submit_and_wait(1) catch |err| {
            log("Ошибка submit_and_wait: {any}\n", .{err});
            continue;
        };
        _ = submitted;

        while (ring.cq_ready() > 0) {
            const cqe = ring.copy_cqe() catch |err| {
                log("Ошибка copy_cqe: {any}\n", .{err});
                continue;
            };

            if (cqe.res < 0) {
                log("Ошибка получения ответа: {d}\n", .{cqe.res});
            } else if (cqe.res > 0) {
                const bytes_read = @as(usize, @intCast(cqe.res));
                log("Получен ответ ({d} байт): '{s}'\n", .{ bytes_read, recv_buffer[0..bytes_read] });
                response_received = true;
            } else {
                log("Получен пустой ответ\n", .{});
            }
        }

        // Если ответ еще не получен, ждем немного перед следующей проверкой
        if (!response_received) {
            std.time.sleep(100 * 1000 * 1000); // 100 мс
        }
    }

    if (!response_received) {
        log("Ответ не получен\n", .{});
    }
}

fn createUdpSocket() !posix.fd_t {
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    errdefer posix.close(socket);

    return socket;
}

fn recvResponse(
    ring: *linux.IoUring,
    socket: posix.fd_t,
    buffer: []u8,
    user_data: u64,
) !void {
    const sqe = try ring.get_sqe();

    // Используем простую операцию RECV, как в сервере
    sqe.* = .{
        .opcode = .RECV,
        .fd = socket,
        .off = 0,
        .addr = @intFromPtr(buffer.ptr),
        .len = @intCast(buffer.len),
        .rw_flags = 0,
        .flags = 0,
        .ioprio = 0,
        .user_data = user_data,
        .buf_index = 0,
        .splice_fd_in = 0,
        .resv = 0,
        .addr3 = 0,
        .personality = 0,
    };
}
