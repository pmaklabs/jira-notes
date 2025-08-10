import Foundation
import Network

// MARK: - Simple HTTP types

struct SimpleRequest {
    let method: String
    let path: String
    let query: [String: String]
    let bodyData: Data?
    var bodyString: String? { bodyData.flatMap { String(data: $0, encoding: .utf8) } }
}

struct SimpleResponse {
    let status: String
    let headers: [(String, String)]
    let body: Data

    static func okJSON(_ obj: [String: Any]) -> SimpleResponse {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
        return SimpleResponse(status: "200 OK",
                              headers: [("Content-Type", "application/json")],
                              body: data)
    }

    static func okJSONText(_ s: String) -> SimpleResponse {
        SimpleResponse(status: "200 OK",
                       headers: [("Content-Type","application/json")],
                       body: Data(s.utf8))
    }

    static func bad(_ msg: String) -> SimpleResponse {
        let json = #"{"error":"\#(msg)"}"#
        return SimpleResponse(status: "400 Bad Request",
                              headers: [("Content-Type","application/json")],
                              body: Data(json.utf8))
    }

    static func notFound() -> SimpleResponse {
        SimpleResponse(status: "404 Not Found",
                       headers: [("Content-Type","text/plain")],
                       body: Data("Not Found".utf8))
    }
}

// MARK: - NWListener-based HTTP server

final class SimpleHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "JiraNotes.HTTPServer")
    var onRequest: ((SimpleRequest) -> SimpleResponse)?

    init(port: UInt16) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: self.receive(on: connection)
                case .failed, .cancelled: connection.cancel()
                default: break
                }
            }
            connection.start(queue: self.queue)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func receive(on connection: NWConnection) {
        // Accumulate until we have headers + optional body (very small requests)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                let req = self.parseRequest(data)
                let resp = self.onRequest?(req) ?? SimpleResponse.notFound()
                self.send(resp, over: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                // Keep reading in case the client pipelined (rare for our use)
                self.receive(on: connection)
            }
        }
    }

    private func send(_ resp: SimpleResponse, over connection: NWConnection) {
        var headerLines: [String] = []
        headerLines.append("HTTP/1.1 \(resp.status)")

        // Existing headers from the response
        for (k, v) in resp.headers {
            headerLines.append("\(k): \(v)")
        }

        // ✅ Add CORS headers for Safari extension requests
        headerLines.append("Access-Control-Allow-Origin: *")
        headerLines.append("Access-Control-Allow-Headers: Content-Type")
        headerLines.append("Access-Control-Allow-Methods: GET, POST, OPTIONS")

        // Standard HTTP headers
        headerLines.append("Content-Length: \(resp.body.count)")
        headerLines.append("Connection: close")
        headerLines.append("") // end of headers
        headerLines.append("") // blank line before body

        let headerData = headerLines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        let total = headerData + resp.body

        connection.send(content: total, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing

    private func parseRequest(_ data: Data) -> SimpleRequest {
        guard let s = String(data: data, encoding: .utf8) else {
            return SimpleRequest(method: "GET", path: "/", query: [:], bodyData: nil)
        }
        // split headers/body
        let parts = s.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? ""
        let body = parts.count > 1 ? Data(parts[1].utf8) : nil

        // first line: METHOD /path?query HTTP/1.1
        let firstLine = head.components(separatedBy: "\r\n").first ?? "GET / HTTP/1.1"
        let comps = firstLine.split(separator: " ")
        let method = comps.count > 0 ? String(comps[0]) : "GET"
        let urlPart = comps.count > 1 ? String(comps[1]) : "/"

        let pq = urlPart.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let path = pq[0]
        var query: [String: String] = [:]
        if pq.count > 1 {
            for pair in pq[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }

        return SimpleRequest(method: method, path: path, query: query, bodyData: body)
    }
}
