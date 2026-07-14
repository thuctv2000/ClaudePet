import Foundation
import Network

/// Minimal loopback HTTP server that receives hook events from `pet-hook.sh`
/// and forwards them to `PetState`. Bound to the loopback interface only and
/// gated by a per-launch token, so no other machine can reach it.
final class HookServer: AskResolver, @unchecked Sendable {
    private let petState: PetState
    private let token: String
    private let queue = DispatchQueue(label: "com.desktoppet.hookserver")
    private var listener: NWListener?

    /// Continuations for in-flight `/ask` requests, keyed by request id.
    /// Only touched on `queue`, so access is serialized.
    private var pending: [String: CheckedContinuation<PetDecision, Never>] = [:]

    /// Continuations for in-flight `/question` requests. The response is the
    /// full JSON body to send back (empty `Data` means "let the terminal ask").
    /// Only touched on `queue`.
    private var pendingQuestions: [String: CheckedContinuation<Data, Never>] = [:]

    /// Raw `tool_input.questions` JSON per pending question id, kept so the
    /// answer response can echo the questions back verbatim. Touched on `queue`.
    private var pendingQuestionPayloads: [String: Data] = [:]

    /// How long to wait for the user before defaulting to deny.
    private let askTimeout: TimeInterval = 300

    /// How long to hold a question open before returning empty (below the
    /// hook's own 600s timeout, so the script still exits cleanly).
    private let questionTimeout: TimeInterval = 570

    init(petState: PetState, token: String) {
        self.petState = petState
        self.token = token
    }

    /// Starts listening on an OS-assigned loopback port. `onReady` is called
    /// with the bound port once the listener is up.
    func start(onReady: @escaping @Sendable (UInt16) -> Void) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port {
                onReady(port.rawValue)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(buffer) {
                self.process(request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func process(_ request: HTTPRequest, on connection: NWConnection) {
        guard request.headers["x-pet-token"] == token else {
            respond(connection, status: "401 Unauthorized")
            return
        }

        switch request.path {
        case "/event":
            if let event = try? JSONDecoder().decode(HookEvent.self, from: request.body) {
                let petState = self.petState
                Task { @MainActor in petState.apply(event) }
            }
            respond(connection)
        case "/ask":
            handleAsk(request, on: connection)
        case "/question":
            handleQuestion(request, on: connection)
        case "/debug/state":
            handleDebugState(on: connection)
        default:
            respond(connection, status: "404 Not Found")
        }
    }

    /// Holds the connection open until the user decides on the pet (or a
    /// timeout defaults to deny), then returns the decision as JSON.
    private func handleAsk(_ request: HTTPRequest, on connection: NWConnection) {
        let event = (try? JSONDecoder().decode(HookEvent.self, from: request.body)) ?? HookEvent.empty
        let id = UUID().uuidString

        // Await the decision, then respond. The continuation is stored on `queue`.
        Task {
            let decision = await withCheckedContinuation { continuation in
                self.queue.async { self.pending[id] = continuation }
            }
            let body = (try? JSONEncoder().encode(decision)) ?? Data()
            self.respond(connection, body: body)
        }

        // Safety timeout → deny.
        queue.asyncAfter(deadline: .now() + askTimeout) { [weak self] in
            guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
            let petState = self.petState
            Task { @MainActor in petState.cancelAsk(id: id) }
            continuation.resume(returning: PetDecision(decision: "deny", text: nil))
        }

        // Present the request on the pet.
        let petState = self.petState
        Task { @MainActor in petState.presentAsk(id: id, event: event) }
    }

    /// Holds the connection open until the user answers the `AskUserQuestion`
    /// (or a timeout returns an empty body), then responds with the full
    /// `hookSpecificOutput` JSON the script prints verbatim.
    private func handleQuestion(_ request: HTTPRequest, on connection: NWConnection) {
        let event = (try? JSONDecoder().decode(HookEvent.self, from: request.body)) ?? HookEvent.empty
        let id = UUID().uuidString

        // Keep the questions exactly as sent so the answer can echo them back.
        let rawQuestions: Data? = {
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let toolInput = object["tool_input"] as? [String: Any],
                  let questions = toolInput["questions"]
            else { return nil }
            return try? JSONSerialization.data(withJSONObject: questions)
        }()

        Task {
            let body = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                self.queue.async {
                    self.pendingQuestions[id] = continuation
                    self.pendingQuestionPayloads[id] = rawQuestions
                }
            }
            self.respond(connection, body: body)
        }

        // Safety timeout → empty body (script exits silently, terminal asks).
        queue.asyncAfter(deadline: .now() + questionTimeout) { [weak self] in
            guard let self, let continuation = self.pendingQuestions.removeValue(forKey: id) else { return }
            self.pendingQuestionPayloads.removeValue(forKey: id)
            let petState = self.petState
            Task { @MainActor in petState.cancelQuestion(id: id) }
            continuation.resume(returning: Data())
        }

        let petState = self.petState
        Task { @MainActor in petState.presentQuestion(id: id, event: event) }
    }

    /// Read-only introspection used by automated tests (no computer-use access
    /// to this accessory app's borderless panel is possible, so tests assert
    /// on exact state here instead of screenshots). Same token gate as every
    /// other route; never mutates anything.
    private func handleDebugState(on connection: NWConnection) {
        let petState = self.petState
        Task { @MainActor in
            let body = (try? JSONEncoder().encode(petState.debugSnapshot())) ?? Data()
            self.respond(connection, body: body)
        }
    }

    // MARK: - AskResolver

    func resolveAsk(id: String, decision: PetDecision) {
        queue.async { [weak self] in
            guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
            continuation.resume(returning: decision)
        }
    }

    func resolveQuestion(id: String, answers: [String: PetAnswer]?) {
        queue.async { [weak self] in
            guard let self, let continuation = self.pendingQuestions.removeValue(forKey: id) else { return }
            let raw = self.pendingQuestionPayloads.removeValue(forKey: id)

            // No answers (skipped) or missing payload → empty body.
            guard let answers,
                  let raw,
                  let questions = try? JSONSerialization.jsonObject(with: raw)
            else {
                continuation.resume(returning: Data())
                return
            }

            var answerObject: [String: Any] = [:]
            for (key, value) in answers {
                switch value {
                case let .single(text): answerObject[key] = text
                case let .multi(items): answerObject[key] = items
                }
            }

            let output: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": ["questions": questions, "answers": answerObject],
                ]
            ]
            let body = (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
            continuation.resume(returning: body)
        }
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", body: Data = Data()) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Bare-bones HTTP request parser. Returns `nil` while the request is still
/// incomplete (headers not fully received, or body shorter than Content-Length).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        self.headers = headers

        let available = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        let expected = headers["content-length"].flatMap { Int($0) } ?? 0
        guard available.count >= expected else { return nil }
        body = available.prefix(expected)
    }
}
