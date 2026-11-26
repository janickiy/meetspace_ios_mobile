import Foundation
import Darwin

enum BroadcastWire {
    static let maximumFrameBytes = 1280 * 720 * 4
    static let descriptorName = "broadcast-session.json"
    static let socketName = "b.sock"
    static let lockName = "broadcast.lock"
    enum Kind: UInt32 { case hello = 1, welcome, heartbeat, frame, paused, resumed, stopped }
    struct Descriptor: Codable, Sendable {
        let version: Int
        let sessionID: UUID
        let nonce: String
        let expiresAt: Date
        let configuration: ScreenBroadcastConfiguration
    }
    struct Hello: Codable { let sessionID: UUID; let nonce: String }

    /// Кодирует заголовок пакета с сигнатурой протокола, типом и длиной данных.
    /// - Parameters:
    ///   - kind: Тип передаваемого сообщения.
    ///   - count: Число байтов полезной нагрузки.
    static func header(kind: Kind, count: Int) -> Data {
        var data = Data([0x4D, 0x53, 0x42, 0x31])
        append(kind.rawValue, to: &data); append(UInt32(count), to: &data)
        return data
    }
    /// Дописывает целое число в сетевом порядке байтов.
    /// - Parameters:
    ///   - value: Число для кодирования.
    ///   - data: Буфер, к которому добавляется число.
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
    /// Читает целое число заданной разрядности в сетевом порядке байтов.
    /// - Parameters:
    ///   - type: Целочисленный тип результата.
    ///   - data: Байты принятого пакета.
    ///   - offset: Начальная позиция числа в байтах.
    static func integer<T: FixedWidthInteger>(_ type: T.Type, _ data: Data, at offset: Int) throws -> T {
        guard offset >= 0, data.count >= offset + MemoryLayout<T>.size else { throw ScreenBroadcastError.invalidFrame }
        return data.withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
    /// Сериализует проверенный кадр вместе с идентификатором сеанса, размерами и временем.
    /// - Parameter frame: Кадр демонстрации в формате BGRA.
    static func frameData(_ frame: ScreenBroadcastFrame) throws -> Data {
        try frame.validated()
        var data = Data(frame.sessionID.uuidString.lowercased().utf8)
        append(UInt32(frame.width), to: &data); append(UInt32(frame.height), to: &data)
        append(UInt64(frame.timestampNs), to: &data); data.append(frame.pixels)
        return data
    }
    /// Декодирует кадр и проверяет его принадлежность ожидаемому сеансу и соответствие ограничениям.
    /// - Parameters:
    ///   - data: Полезная нагрузка пакета с кадром.
    ///   - descriptor: Описание ожидаемого сеанса и допустимых размеров.
    static func frame(_ data: Data, descriptor: Descriptor) throws -> ScreenBroadcastFrame {
        guard data.count >= 52 else { throw ScreenBroadcastError.invalidFrame }
        guard let string = String(data: data.prefix(36), encoding: .utf8),
              let id = UUID(uuidString: string), id == descriptor.sessionID else { throw ScreenBroadcastError.staleSession }
        let width = Int(try integer(UInt32.self, data, at: 36)), height = Int(try integer(UInt32.self, data, at: 40))
        let stamp = try integer(UInt64.self, data, at: 44)
        guard stamp <= UInt64(Int64.max), (2...1280).contains(width), (2...1280).contains(height) else {
            throw ScreenBroadcastError.invalidFrame
        }
        return try ScreenBroadcastFrame(sessionID: id, width: width, height: height, rowBytes: width * 4,
            timestampNs: Int64(stamp), pixels: data.subdata(in: 52..<data.count)).validated(configuration: descriptor.configuration)
    }
    /// Формирует адрес UNIX-сокета в общем каталоге и проверяет длину пути.
    /// - Parameter directory: Каталог для сокета демонстрации.
    static func address(_ directory: URL) throws -> sockaddr_un {
        let path = directory.appendingPathComponent(socketName).path
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else {
            throw ScreenBroadcastError.unavailable
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: Array(path.utf8))
        }
        return address
    }
    /// Возвращает доступный процессу контейнер App Group по её идентификатору.
    /// - Parameter identifier: Идентификатор группы приложений с префиксом group.
    static func groupDirectory(_ identifier: String) -> URL? {
        guard identifier.hasPrefix("group."), identifier.utf8.count <= 200 else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
    /// Читает описание сеанса из общего каталога, проверяет версию, срок действия и параметры видео.
    /// - Parameter directory: Каталог с описанием запущенного сеанса.
    static func descriptor(at directory: URL) throws -> Descriptor {
        let url = directory.appendingPathComponent(descriptorName)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 2048,
              attributes[.type] as? FileAttributeType == .typeRegular else { throw ScreenBroadcastError.staleSession }
        let value = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: url))
        guard value.version == 1, value.nonce.utf8.count == 64,
              value.expiresAt > Date(), value.expiresAt.timeIntervalSinceNow <= 91 else { throw ScreenBroadcastError.staleSession }
        try value.configuration.validated()
        return value
    }
}

/// Shutdown wakes borrowers; the fd closes only when their strong references have drained.
/// This prevents an old read/write from touching a reused descriptor after cancellation.
final class BroadcastSocket: @unchecked Sendable {
    let fd: Int32
    private let state = NSLock()
    private let writer = NSLock()
    private var stopped = false
    /// Принимает во владение дескриптор сокета и настраивает неблокирующий обмен.
    /// - Parameter fd: Открытый файловый дескриптор UNIX-сокета.
    init(fd: Int32) throws {
        guard fd >= 0 else { throw ScreenBroadcastError.connectionLost }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(fd); throw ScreenBroadcastError.connectionLost
        }
        self.fd = fd
    }
    /// Закрывает файловый дескриптор после освобождения последней ссылки на сокет.
    deinit { Darwin.close(fd) }
    var isStopped: Bool { state.withLock { stopped } }
    /// Прерывает операции сокета в обоих направлениях и пробуждает ожидающие задачи.
    func shutdown() {
        state.withLock { if !stopped { stopped = true; _ = Darwin.shutdown(fd, SHUT_RDWR) } }
    }
    /// Ожидает указанных событий сокета до монотонного срока или ошибки.
    /// - Parameters:
    ///   - events: Маска ожидаемых событий poll.
    ///   - deadline: Предельное время в наносекундах монотонных часов.
    func wait(_ events: Int16, until deadline: UInt64) throws {
        while !isStopped {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw ScreenBroadcastError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw ScreenBroadcastError.connectionLost }
            if result > 0 {
                // POLLIN may coexist with HUP when the peer sent its final stop packet.
                if descriptor.revents & events != 0 { return }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw ScreenBroadcastError.connectionLost }
            }
        }
        throw ScreenBroadcastError.connectionLost
    }
    /// Читает заданное число байтов до истечения срока.
    /// - Parameters:
    ///   - count: Требуемый размер данных в байтах.
    ///   - deadline: Предельное время чтения по монотонным часам в наносекундах.
    func read(_ count: Int, until deadline: UInt64) throws -> Data {
        guard count >= 0, count <= BroadcastWire.maximumFrameBytes + 52 else { throw ScreenBroadcastError.invalidFrame }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                try wait(Int16(POLLIN), until: deadline)
                let result = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if result < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard result > 0 else { throw ScreenBroadcastError.connectionLost }
                offset += result
            }
        }
        return data
    }
    /// Проверяет заголовок пакета и возвращает его тип и полезную нагрузку.
    /// - Parameter timeout: Время ожидания целого пакета в секундах.
    func readPacket(timeout: Double) throws -> (BroadcastWire.Kind, Data) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let header = try read(12, until: deadline)
        guard header.prefix(4) == Data([0x4D, 0x53, 0x42, 0x31]),
              let kind = BroadcastWire.Kind(rawValue: try BroadcastWire.integer(UInt32.self, header, at: 4)) else {
            throw ScreenBroadcastError.invalidFrame
        }
        let count = Int(try BroadcastWire.integer(UInt32.self, header, at: 8))
        guard count <= (kind == .frame ? BroadcastWire.maximumFrameBytes + 52 : 2048) else { throw ScreenBroadcastError.invalidFrame }
        return (kind, try read(count, until: deadline))
    }
    /// Последовательно записывает целый пакет. Тайм-аут после частичной записи завершает передачу с ошибкой.
    /// - Parameters:
    ///   - kind: Тип сообщения.
    ///   - payload: Данные после заголовка пакета.
    ///   - dropIfBusy: Разрешает вернуть false без записи, если отправитель уже занят.
    func send(_ kind: BroadcastWire.Kind, payload: Data = Data(), dropIfBusy: Bool = false) throws -> Bool {
        if dropIfBusy { guard writer.try() else { return false } } else { writer.lock() }
        defer { writer.unlock() }
        guard payload.count <= (kind == .frame ? BroadcastWire.maximumFrameBytes + 52 : 2048) else {
            throw ScreenBroadcastError.invalidFrame
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        for bytes in [BroadcastWire.header(kind: kind, count: payload.count), payload] {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < bytes.count {
                    try wait(Int16(POLLOUT), until: deadline)
                    let result = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if result < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    guard result > 0 else { throw ScreenBroadcastError.connectionLost }
                    offset += result
                }
            }
        }
        return true
    }
}
