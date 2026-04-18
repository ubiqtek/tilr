import Darwin
import Foundation

enum SocketError: Error {
    case notRunning
    case io(String)
}

final class SocketClient {
    func send(_ request: TilrRequest) throws -> TilrResponse {
        let socketPath = TilrPaths.socket.path

        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SocketError.notRunning
        }

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw SocketError.io("socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(sock) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src)
            }
        }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connected != 0 {
            if errno == ECONNREFUSED || errno == ENOENT {
                throw SocketError.notRunning
            }
            throw SocketError.io("connect() failed: \(String(cString: strerror(errno)))")
        }

        var payload = (try? JSONEncoder().encode(request)) ?? Data()
        payload.append(UInt8(ascii: "\n"))
        payload.withUnsafeBytes { _ = Darwin.send(sock, $0.baseAddress!, payload.count, 0) }

        var responseData = Data()
        var byte = UInt8(0)
        while recv(sock, &byte, 1, 0) == 1 {
            if byte == UInt8(ascii: "\n") { break }
            responseData.append(byte)
        }

        guard let response = try? JSONDecoder().decode(TilrResponse.self, from: responseData) else {
            throw SocketError.io("Failed to decode response")
        }
        return response
    }
}
