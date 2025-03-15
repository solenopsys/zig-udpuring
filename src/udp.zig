const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.debug.print;
const mem = std.mem;
const net = std.net;
const Allocator = std.mem.Allocator;

const BUFFER_SIZE = 8192;
const CONCURRENT_OPERATIONS = 64; // Количество одновременных операций чтения

// Структура для буфера и метаданных операции
const RecvOperation = struct {
    buffer: []u8,
    addr: posix.sockaddr, // Используем обычный sockaddr
    addr_len: posix.socklen_t,
    msghdr: posix.msghdr,
    iov: [1]posix.iovec,
};

// Тип для функции обработчика сообщений
pub const MessageHandlerFn = *const fn (data: []const u8, client_addr: *const posix.sockaddr, client_addr_len: posix.socklen_t, userdata: ?*anyopaque) void;

// Структура UDP сервера
pub const UdpIoUringServer = struct {
    allocator: Allocator,
    socket: posix.fd_t,
    ring: linux.IoUring,
    recv_ops: []RecvOperation,
    base_user_data: u64,
    message_handler: MessageHandlerFn,
    userdata: ?*anyopaque,

    // Инициализация сервера
    pub fn init(allocator: Allocator, port: u16, message_handler: MessageHandlerFn, userdata: ?*anyopaque) !UdpIoUringServer {
        // Создание UDP сокета
        const socket = try createUdpSocket(port);
        errdefer posix.close(socket);

        // Делаем сокет неблокирующим
        const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
        _ = try posix.fcntl(socket, posix.F.SETFL, flags | linux.SOCK.NONBLOCK);

        // Инициализация io_uring
        var ring_params = std.mem.zeroes(linux.io_uring_params);
        const ring_size: u13 = 4096;
        var ring = try linux.IoUring.init_params(ring_size, &ring_params);
        errdefer ring.deinit();

        // Создаем пул операций чтения
        const recv_ops = try allocator.alloc(RecvOperation, CONCURRENT_OPERATIONS);
        errdefer allocator.free(recv_ops);

        // Инициализируем структуры операций
        for (recv_ops) |*op| {
            op.buffer = try allocator.alloc(u8, BUFFER_SIZE);
            op.addr_len = @sizeOf(posix.sockaddr);
            op.addr = std.mem.zeroes(posix.sockaddr);

            // Предварительно настраиваем структуры msghdr и iovec
            op.iov[0] = posix.iovec{
                .base = op.buffer.ptr,
                .len = op.buffer.len,
            };

            op.msghdr = posix.msghdr{
                .name = @ptrCast(&op.addr),
                .namelen = op.addr_len,
                .iov = &op.iov,
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
        }

        const base_user_data: u64 = 1000;

        // Создаем экземпляр сервера
        var server = UdpIoUringServer{
            .allocator = allocator,
            .socket = socket,
            .ring = ring,
            .recv_ops = recv_ops,
            .base_user_data = base_user_data,
            .message_handler = message_handler,
            .userdata = userdata,
        };

        // Подготавливаем начальные операции чтения
        for (0..CONCURRENT_OPERATIONS) |i| {
            const recv_user_data = base_user_data + i;
            try server.recvRequest(i, recv_user_data);
        }

        return server;
    }

    // Освобождение ресурсов
    pub fn deinit(self: *UdpIoUringServer) void {
        for (self.recv_ops) |*op| {
            self.allocator.free(op.buffer);
        }

        self.allocator.free(self.recv_ops);
        self.ring.deinit();
        posix.close(self.socket);
    }

    // Отправка данных по адресу
    pub fn sendToAddr(self: *UdpIoUringServer, data: []const u8, addr: *const posix.sockaddr, addr_len: posix.socklen_t, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();

        var iov = [_]posix.iovec{.{
            .base = @as([*]u8, @ptrCast(@constCast(data.ptr))),
            .len = data.len,
        }};

        // Создаем стабильный msghdr для отправки
        var msghdr = posix.msghdr{
            .name = @ptrCast(@constCast(addr)),
            .namelen = addr_len,
            .iov = &iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        // Настраиваем операцию SENDMSG
        sqe.* = .{
            .opcode = .SENDMSG,
            .fd = self.socket,
            .off = 0,
            .addr = @intFromPtr(&msghdr),
            .len = 1, // количество векторов (всегда 1 для msghdr)
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

    // Подготовка операции получения данных
    fn recvRequest(self: *UdpIoUringServer, op_index: usize, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        const op = &self.recv_ops[op_index];

        // Обновляем указатель на буфер в iovec (на случай, если он был изменен)
        op.iov[0].base = op.buffer.ptr;
        op.iov[0].len = op.buffer.len;

        // Обновляем указатель на структуру адреса
        op.msghdr.name = @ptrCast(&op.addr);
        op.msghdr.namelen = op.addr_len;

        // Настраиваем операцию RECVMSG с уже подготовленной структурой msghdr
        sqe.* = .{
            .opcode = .RECVMSG,
            .fd = self.socket,
            .off = 0,
            .addr = @intFromPtr(&op.msghdr),
            .len = 1, // количество векторов (всегда 1 для msghdr)
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

    // Основной цикл обработки событий
    pub fn run(self: *UdpIoUringServer) !void {
        while (true) {
            const submitted = self.ring.submit() catch |err| {
                log("Ошибка submit: {any}\n", .{err});
                continue;
            };
            _ = submitted;

            // Используем ручной вызов io_uring_enter с GETEVENTS
            const cqes_ready = self.ring.cq_ready();
            if (cqes_ready == 0) {
                // Если нет готовых событий, ждем с таймаутом
                _ = linux.io_uring_enter(self.ring.fd, 0, // нет новых событий для отправки
                    1, // минимальное количество событий для завершения
                    linux.IORING_ENTER_GETEVENTS, // получить события
                    null // нет маски сигналов
                );
            }

            try self.processEvents();
        }
    }

    // Обработка событий из completion queue
    fn processEvents(self: *UdpIoUringServer) !void {
        while (self.ring.cq_ready() > 0) {
            const cqe = self.ring.copy_cqe() catch |err| {
                log("Ошибка copy_cqe: {any}\n", .{err});
                continue;
            };

            // Определяем индекс операции по user_data
            const op_index = cqe.user_data - self.base_user_data;
            if (op_index >= CONCURRENT_OPERATIONS) {
                log("Некорректный индекс операции: {d}\n", .{op_index});
                continue;
            }

            var op = &self.recv_ops[@intCast(op_index)];

            // Проверяем результат операции
            if (cqe.res < 0) {
                log("Ошибка операции: {d}\n", .{cqe.res});
                // Несмотря на ошибку, подготовим новую операцию чтения
            } else if (cqe.res > 0) {
                const bytes_read = @as(usize, @intCast(cqe.res));

                //   log("Получено {d} байт\n", .{bytes_read});

                // Приведение типа с указанием целевого типа
                const addr = @as(*const posix.sockaddr, &op.addr);

                // Вызываем обработчик сообщений с адресом отправителя
                self.message_handler(op.buffer[0..bytes_read], addr, op.addr_len, self.userdata);
            } else {
                // res == 0, что необычно для UDP, но на всякий случай обрабатываем
                log("Получен пакет нулевой длины\n", .{});
            }

            // После обработки подготавливаем новую операцию чтения
            try self.recvRequest(@intCast(op_index), self.base_user_data + op_index);
        }
    }
};

// Вспомогательная функция для создания UDP сокета
fn createUdpSocket(port: u16) !posix.fd_t {
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    errdefer posix.close(socket);

    // Установка опций сокета
    const yes: i32 = 1;
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, mem.asBytes(&yes));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, mem.asBytes(&yes));

    // Увеличиваем размеры буферов сокета для лучшей производительности при высоких нагрузках
    const buffer_size: i32 = 16 * 1024 * 1024; // 16 MB
    _ = posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVBUF, mem.asBytes(&buffer_size)) catch |err| {
        log("Предупреждение: не удалось установить SO_RCVBUF: {any}\n", .{err});
    };
    _ = posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDBUF, mem.asBytes(&buffer_size)) catch |err| {
        log("Предупреждение: не удалось установить SO_SNDBUF: {any}\n", .{err});
    };

    const address = net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    try posix.bind(socket, &address.any, address.getOsSockLen());

    return socket;
}
