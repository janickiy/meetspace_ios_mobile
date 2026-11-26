import Foundation
import Dispatch
@preconcurrency import Citadel
@preconcurrency import NIOSSH
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import Crypto

private struct ObservedHost: Error { let key: InstallerHostKey }
private final class InspectHost: NIOSSHClientServerAuthenticationDelegate, Sendable {
    /// Передаёт полученный ключ SSH-хоста для проверки отпечатка и завершает проверочное подключение.
    /// - Parameters:
    ///   - hostKey: Публичный ключ, предъявленный SSH-сервером.
    ///   - validationCompletePromise: Объект NIO для завершения проверки предъявленного ключа узла.
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do { validationCompletePromise.fail(ObservedHost(key: try InstallerHostKey(openSSH: String(openSSHPublicKey: hostKey)))) }
        catch { validationCompletePromise.fail(InstallerFailure.response) }
    }
}
/// Each operation owns a fresh connection. Inspection fails host authentication before USERAUTH.
public struct NativeInstallerTransport: InstallerTransport {
    /// Создаёт SSH-транспорт для выполнения команд установщика.
    public init() {}
    /// Открывает проверочное SSH-соединение, чтобы прочитать публичный ключ сервера.
    /// - Parameter endpoint: Адрес, порт и имя пользователя SSH-сервера.
    public func inspect(_ endpoint: InstallerEndpoint) async throws -> InstallerHostKey {
        try Task.checkCancellation()
        let lifetime = ConnectionLifetime()
        defer { lifetime.close() }
        var settings = SSHClientSettings(host: endpoint.host, port: endpoint.port,
            authenticationMethod: { .passwordBased(username: endpoint.user, password: "") }, hostKeyValidator: .custom(InspectHost()))
        settings.connectTimeout = .seconds(15)
        settings.group = lifetime.group
        do {
            let client = try await connect(settings, lifetime: lifetime)
            try? await client.close()
            throw InstallerFailure.response
        } catch let observed as ObservedHost { return observed.key }
        catch { if Task.isCancelled { throw CancellationError() }; throw InstallerFailure.network }
    }
    /// Выполняет программу на удалённом узле через SSH и возвращает стандартный вывод.
    /// - Parameters:
    ///   - endpoint: Адрес, порт и имя пользователя SSH-сервера.
    ///   - credentials: Данные доступа к SSH-серверу.
    ///   - key: Публичный ключ SSH-сервера, которому доверяет пользователь.
    ///   - input: Программа и входные данные, передаваемые установщику через SSH.
    public func execute(_ endpoint: InstallerEndpoint, credentials: InstallerCredentials, key: InstallerHostKey, input: Data) async throws -> Data {
        try Task.checkCancellation()
        guard input.count <= 512 * 1024 else { throw InstallerFailure.response }
        let trusted = try NIOSSHPublicKey(openSSHPublicKey: key.openSSH)
        // Parse keys before creating a connection; never downgrade a failed key to password auth.
        let makeAuth: @Sendable () -> SSHAuthenticationMethod
        switch credentials {
        case .password(let password):
            guard !password.isEmpty, password.utf8.count <= 4096 else { throw InstallerFailure.invalid("Введите пароль SSH.") }
            makeAuth = { .passwordBased(username: endpoint.user, password: password) }
        case .privateKey(let text, let passphrase):
            guard text.utf8.count <= 256 * 1024 else { throw InstallerFailure.invalid("Файл ключа превышает 256 КиБ.") }
            let secret = passphrase.isEmpty ? nil : Data(passphrase.utf8)
            if let parsed = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: secret) {
                makeAuth = { .ed25519(username: endpoint.user, privateKey: parsed) }
            } else { throw InstallerFailure.invalid("Используйте OpenSSH Ed25519-ключ с правильной парольной фразой или пароль SSH. RSA-ключи пока не поддерживаются.") }
        }
        let lifetime = ConnectionLifetime()
        defer { lifetime.close() }
        var settings = SSHClientSettings(host: endpoint.host, port: endpoint.port, authenticationMethod: makeAuth, hostKeyValidator: .trustedKeys([trusted]))
        settings.connectTimeout = .seconds(15)
        settings.group = lifetime.group
        let client: SSHClient
        do { client = try await connect(settings, lifetime: lifetime) }
        catch { throw InstallerFailure.invalid("SSH-подключение не подтверждено. Проверьте ключ сервера, пользователя и данные доступа.") }
        // Only a fixed Python command and a public byte count enter argv. Secrets travel through SSH stdin.
        let command = "if [ \"$(id -u)\" = 0 ]; then exec /usr/bin/python3 -c 'import sys;exec(compile(sys.stdin.buffer.read(\(input.count)),\"meetspace-installer\",\"exec\"))'; else exec sudo -n /usr/bin/python3 -c 'import sys;exec(compile(sys.stdin.buffer.read(\(input.count)),\"meetspace-installer\",\"exec\"))'; fi"
        // A deadline closes the socket; close also releases blocked stream readers on cancellation.
        let deadline = Task { try await Task.sleep(for: .seconds(180)); lifetime.close() }
        defer { deadline.cancel() }
        do {
            let result = try await withTaskCancellationHandler {
                var output = Data(); var stderrCount = 0
                var streamCompleted = false
                try Task.checkCancellation()
                do {
                    try await client.withExec(command) { inbound, outbound in
                        try Task.checkCancellation()
                        try await outbound.write(ByteBuffer(bytes: input))
                        for try await chunk in inbound {
                            try Task.checkCancellation()
                            switch chunk {
                            case .stdout(let bytes):
                                guard output.count + bytes.readableBytes <= 256 * 1024 else { throw InstallerFailure.response }
                                output.append(contentsOf: bytes.readableBytesView)
                            case .stderr(let bytes):
                                stderrCount += bytes.readableBytes
                                guard stderrCount <= 16 * 1024 else { throw InstallerFailure.response }
                            }
                        }
                        streamCompleted = true
                    }
                } catch ChannelError.alreadyClosed where streamCompleted {
                    // Citadel closes the child channel after the peer has already finished it.
                    // Accept only this redundant close after the complete, error-free stream.
                }
                try Task.checkCancellation()
                return output
            } onCancel: { lifetime.close() }
            try? await client.close()
            return result
        } catch {
            try? await client.close()
            if Task.isCancelled { throw CancellationError() }
            if let known = error as? InstallerFailure { throw known }
            throw InstallerFailure.network
        }
    }
}

// Own a dedicated event loop from TCP connect onward. NIO's group shutdown closes all
// registered channels, even when Citadel has not yet returned an authenticated client.
// Citadel.connect(to:) installs handlers in its bootstrap initializer before reads begin;
// its connect(on:) overload currently uses sync pipeline operations off the event loop.
private final class ConnectionLifetime: Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    /// Останавливает выделенную группу событий NIO, закрывая каналы этого SSH-подключения.
    func close() { group.shutdownGracefully(queue: .global()) { _ in } }
}
private func connect(_ settings: SSHClientSettings, lifetime: ConnectionLifetime) async throws -> SSHClient {
    try await withTaskCancellationHandler {
        do {
            try Task.checkCancellation()
            let client = try await SSHClient.connect(to: settings)
            try Task.checkCancellation()
            return client
        } catch { lifetime.close(); throw error }
    } onCancel: { lifetime.close() }
}
