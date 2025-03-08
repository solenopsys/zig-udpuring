const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.debug.print;
const mem = std.mem;
const net = std.net;
const Allocator = std.mem.Allocator;

const PORT = 8080;
const BUFFER_SIZE = 8192;

pub fn main() !void {
    log("Запуск UDP сервера с io_uring на порту {d}...\n", .{PORT});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Создание UDP сокета
    const server_socket = try createUdpSocket(PORT);
    defer posix.close(server_socket);

    // Инициализация io_uring
    var ring_params = std.mem.zeroes(linux.io_uring_params);
    const ring_size: u13 = 4096;
    var ring = try linux.IoUring.init_params(ring_size, &ring_params);
    defer ring.deinit();

    // Создаем буфер для приема данных
    var buffer = try allocator.alloc(u8, BUFFER_SIZE);
    defer allocator.free(buffer);

    // Объявляем переменные для работы с адресом клиента
    _ = std.mem.zeroes(posix.sockaddr);
    _ = @sizeOf(posix.sockaddr);

    log("UDP сервер запущен и ожидает пакеты...\n", .{});

    // Подготавливаем первую операцию чтения
    const recv_user_data: u64 = 1;
    try recvRequest(&ring, server_socket, buffer, recv_user_data);

    while (true) {
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

            // Проверяем результат операции
            if (cqe.res < 0) {
                log("Ошибка операции: {d}\n", .{cqe.res});

                // Подготавливаем новую операцию чтения
                try recvRequest(&ring, server_socket, buffer, recv_user_data);
            } else if (cqe.res > 0) {
                const bytes_read = @as(usize, @intCast(cqe.res));

                // Поскольку это UDP, нам нужно узнать, кто отправил пакет,
                // чтобы отправить ответ. Для этого используем recvfrom
                var sender_addr = std.mem.zeroes(posix.sockaddr);
                var sender_len: posix.socklen_t = @sizeOf(posix.sockaddr);

                // Этот способ работает только если пакет еще в очереди
                // В реальном приложении нужно сохранять адрес после recvfrom
                log("Получено {d} байт\n", .{bytes_read});

                if (cqe.user_data == recv_user_data) {
                    // Это был запрос на чтение, отправляем эхо
                    log("Данные: {s}\n", .{buffer[0..bytes_read]});

                    // Для примера используем традиционный sendto вместо io_uring
                    // (для надежности)
                    _ = posix.recvfrom(server_socket, buffer[0..0], // Буфер нулевой длины, т.к. данные уже получены
                        0, &sender_addr, &sender_len) catch 0;

                    _ = posix.sendto(server_socket, buffer[0..bytes_read], 0, &sender_addr, sender_len) catch |err| {
                        log("Ошибка отправки ответа: {any}\n", .{err});
                    };

                    // Подготавливаем новую операцию чтения
                    try recvRequest(&ring, server_socket, buffer, recv_user_data);
                }
            } else {
                // res == 0, что необычно для UDP, но на всякий случай обрабатываем
                log("Получен пакет нулевой длины\n", .{});

                // Подготавливаем новую операцию чтения
                try recvRequest(&ring, server_socket, buffer, recv_user_data);
            }
        }
    }
}

fn createUdpSocket(port: u16) !posix.fd_t {
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    errdefer posix.close(socket);

    const yes: i32 = 1;
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, mem.asBytes(&yes));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, mem.asBytes(&yes));

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try posix.bind(socket, &address.any, address.getOsSockLen());

    return socket;
}

fn recvRequest(
    ring: *linux.IoUring,
    socket: posix.fd_t,
    buffer: []u8,
    user_data: u64,
) !void {
    const sqe = try ring.get_sqe();

    // Используем простую операцию RECV
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
