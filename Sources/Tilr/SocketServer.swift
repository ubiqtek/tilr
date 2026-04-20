import Darwin
import Foundation
import OSLog

final class SocketServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "io.ubiqtek.tilr.socket", qos: .utility)
    private let handler: CommandHandler

    init(configStore: ConfigStore, service: SpaceService, appWindowManager: AppWindowManager? = nil) {
        self.handler = CommandHandler(configStore: configStore, service: service, appWindowManager: appWindowManager)
    }

    func start() {
        let socketPath = TilrPaths.socket.path

        guard socketPath.utf8.count < 104 else {
            Logger.socket.error("Socket path too long: \(socketPath)")
            return
        }

        let dir = TilrPaths.socket.deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        unlink(socketPath)

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            Logger.socket.error("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Logger.socket.error("bind() failed: \(String(cString: strerror(errno)))")
            close(sock)
            return
        }

        guard listen(sock, 5) == 0 else {
            Logger.socket.error("listen() failed: \(String(cString: strerror(errno)))")
            close(sock)
            return
        }

        fd = sock
        Logger.socket.info("Listening on \(socketPath)")

        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnection() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(TilrPaths.socket.path)
        Logger.socket.info("Socket closed")
    }

    private func acceptConnection() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in
            self?.handleClient(client)
        }
    }

    private func handleClient(_ client: Int32) {
        defer { close(client) }

        var buffer = Data()
        var byte = UInt8(0)
        while recv(client, &byte, 1, 0) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }

        guard let request = try? JSONDecoder().decode(TilrRequest.self, from: buffer) else {
            Logger.socket.warning("Failed to decode request")
            return
        }

        let (response, postSend) = handler.handle(request)
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { _ = send(client, $0.baseAddress!, data.count, 0) }
        postSend?()
    }
}
