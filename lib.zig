const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.debug.print;
const mem = std.mem;
const net = std.net;
const Allocator = std.mem.Allocator;

const BUFFER_SIZE = 8192;
const MAX_CLIENTS = 64; // Максимальное количество одновременных клиентов

const ClientData = struct {
    addr: posix.sockaddr,
    addr_len: posix.socklen_t,
    buffer: []u8,
    used: bool,
};

// Тип для функции обработчика сообщений
pub const MessageHandlerFn = *const fn (data: []const u8, client_index: usize, client_addr: *const posix.sockaddr, client_addr_len: posix.socklen_t, userdata: ?*anyopaque) void;

// Структура UDP сервера
pub const UdpIoUringServer = struct {
    allocator: Allocator,
    socket: posix.fd_t,
    ring: linux.IoUring,
    clients: []ClientData,
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

        // Создаем пул буферов и клиентских данных
        const clients = try allocator.alloc(ClientData, MAX_CLIENTS);
        errdefer {
            allocator.free(clients);
        }

        // Инициализируем структуры клиентов
        for (clients) |*client| {
            client.buffer = try allocator.alloc(u8, BUFFER_SIZE);
            client.addr_len = @sizeOf(posix.sockaddr);
            client.addr = std.mem.zeroes(posix.sockaddr);
            client.used = false;
        }

        const base_user_data: u64 = 1000;

        // Создаем экземпляр сервера
        var server = UdpIoUringServer{
            .allocator = allocator,
            .socket = socket,
            .ring = ring,
            .clients = clients,
            .base_user_data = base_user_data,
            .message_handler = message_handler,
            .userdata = userdata,
        };

        // Подготавливаем начальные операции чтения
        for (0..MAX_CLIENTS) |i| {
            const recv_user_data = base_user_data + i;
            try server.recvRequestWithMsgName(i, recv_user_data);
        }

        return server;
    }

    // Освобождение ресурсов
    pub fn deinit(self: *UdpIoUringServer) void {
        for (self.clients) |*client| {
            if (client.used) {
                self.allocator.free(client.buffer);
            }
        }
        self.allocator.free(self.clients);
        self.ring.deinit();
        posix.close(self.socket);
    }

    // Метод для отправки данных клиенту
    pub fn send(self: *UdpIoUringServer, data: []const u8, client_index: usize, user_data: u64) !void {
        if (client_index >= MAX_CLIENTS) {
            return error.InvalidClientIndex;
        }

        const client = &self.clients[client_index];
        try self.sendInternal(data, &client.addr, client.addr_len, user_data);
    }

    // Отправка данных по адресу
    pub fn sendToAddr(self: *UdpIoUringServer, data: []const u8, addr: *const posix.sockaddr, addr_len: posix.socklen_t, user_data: u64) !void {
        try self.sendInternal(data, addr, addr_len, user_data);
    }

    // Внутренний метод для отправки данных
    fn sendInternal(self: *UdpIoUringServer, data: []const u8, addr: *const posix.sockaddr, addr_len: posix.socklen_t, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();

        // Настраиваем операцию SENDMSG для ответа
        var msghdr = std.mem.zeroes(posix.msghdr);
        var iov = [_]posix.iovec{.{
            .base = @as([*]u8, @ptrCast(@constCast(data.ptr))),
            .len = data.len,
        }};

        msghdr.name = @constCast(addr);
        msghdr.namelen = addr_len;
        msghdr.iov = &iov;
        msghdr.iovlen = 1;

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
    fn recvRequestWithMsgName(self: *UdpIoUringServer, client_index: usize, user_data: u64) !void {
        const sqe = try self.ring.get_sqe();
        const client = &self.clients[client_index];

        // Используем RECVMSG для получения адреса отправителя
        var msghdr = std.mem.zeroes(posix.msghdr);
        var iov = [_]posix.iovec{.{
            .base = client.buffer.ptr,
            .len = client.buffer.len,
        }};

        msghdr.name = &client.addr;
        msghdr.namelen = client.addr_len;
        msghdr.iov = &iov;
        msghdr.iovlen = 1;

        // Настраиваем операцию RECVMSG
        sqe.* = .{
            .opcode = .RECVMSG,
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

    // Основной цикл обработки событий
    pub fn run(self: *UdpIoUringServer) !void {
        while (true) {
            const submitted = self.ring.submit() catch |err| {
                log("Ошибка submit: {any}\n", .{err});
                continue;
            };
            _ = submitted;

            // Неблокирующее ожидание событий с тайм-аутом
            _ = linux.kernel_timespec{
                .tv_sec = 0,
                .tv_nsec = 100, // 100 ns
            };

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

            // Определяем индекс клиента по user_data
            const client_index = cqe.user_data - self.base_user_data;
            if (client_index >= MAX_CLIENTS) {
                log("Некорректный индекс клиента: {d}\n", .{client_index});
                continue;
            }

            var client = &self.clients[@intCast(client_index)];

            // Проверяем результат операции
            if (cqe.res < 0) {
                log("Ошибка операции: {d}\n", .{cqe.res});
                // Подготавливаем новую операцию чтения для этого клиента
                try self.recvRequestWithMsgName(@intCast(client_index), self.base_user_data + client_index);
            } else if (cqe.res > 0) {
                const bytes_read = @as(usize, @intCast(cqe.res));

                log("Получено {d} байт от клиента {d}\n", .{ bytes_read, client_index });

                // Вызываем обработчик сообщений
                self.message_handler(client.buffer[0..bytes_read], client_index, &client.addr, client.addr_len, self.userdata);

                // Подготавливаем новую операцию чтения для этого клиента
                try self.recvRequestWithMsgName(@intCast(client_index), self.base_user_data + client_index);
            } else {
                // res == 0, что необычно для UDP, но на всякий случай обрабатываем
                log("Получен пакет нулевой длины\n", .{});
                // Подготавливаем новую операцию чтения для этого клиента
                try self.recvRequestWithMsgName(@intCast(client_index), self.base_user_data + client_index);
            }
        }
    }
};

// Вспомогательная функция для создания UDP сокета
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

// Пример функции обработчика сообщений
fn handleMessage(data: []const u8, client_index: usize, client_addr: *const posix.sockaddr, client_addr_len: posix.socklen_t, userdata: ?*anyopaque) void {
    _ = userdata;
    _ = client_addr_len;
    _ = client_addr;
    log("Обработка сообщения: {s} от клиента {d}\n", .{ data, client_index });
    // Здесь обрабатываем сообщение
    // НЕ отправляем автоматический ответ
}
