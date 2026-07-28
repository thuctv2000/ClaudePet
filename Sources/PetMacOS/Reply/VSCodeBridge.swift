import Foundation

/// Delivers into a Claude Code session running in VS Code's integrated terminal
/// by asking VS Code itself to do it.
///
/// ## Why this exists when `DesktopAX` already reaches that terminal
///
/// It reaches it by driving the window: bring VS Code to the front, send ⌃` to
/// move keyboard focus, read the accessibility tree to confirm the right
/// terminal took it, then synthesize keystrokes. Every step of that is a
/// guess about the UI, it interrupts whatever the user was doing, and it
/// cannot work at all while the window is minimised — macOS stops rendering a
/// minimised window, so keyboard focus will not go into it.
///
/// VS Code's own extension API has none of those problems:
///
///     Terminal.sendText(text, shouldExecute)
///     // "The text is written to the stdin of the underlying pty process"
///
/// Straight into the pty. No focus, no window, no activation. The catch is
/// that it can only be called from inside VS Code, so the pet ships a small
/// extension (`vscode-extension/`) that exposes it on a loopback port and
/// writes `~/.petmacos/vscode-<pid>.json` for this side to find.
///
/// ## Identifying the terminal
///
/// By process id, not by name. The pet knows the session's tty; the shell on
/// that tty is the process VS Code spawned, which is exactly what
/// `Terminal.processId` returns. Every other surface here has to match a title
/// and refuse when it is ambiguous — this one cannot pick the wrong terminal.
enum VSCodeBridge {
    enum SendError: Error, Equatable {
        /// No window has the bridge extension running (not installed, or VS
        /// Code has not been reloaded since it was).
        case noBridge
        /// The tty has no shell process, so there is nothing to match against.
        case noShellProcess(String)
        /// Every window answered, none owns a terminal with that pid.
        case terminalNotFound(pid_t)
        case transportFailed(String)
    }

    /// Sends `text` (with a Return) to the terminal attached to `tty`.
    static func send(_ text: String, toTty tty: String) -> Result<String, SendError> {
        guard let shell = shellProcess(onTty: tty) else {
            return .failure(.noShellProcess(tty))
        }
        let bridges = availableBridges()
        guard !bridges.isEmpty else { return .failure(.noBridge) }

        var lastTransportError: String?
        for bridge in bridges {
            switch post(text: text, pid: shell, to: bridge) {
            case .success(let name): return .success(name)
            case .failure(.transportFailed(let message)): lastTransportError = message
            case .failure: continue    // this window doesn't own that terminal
            }
        }
        if let lastTransportError { return .failure(.transportFailed(lastTransportError)) }
        return .failure(.terminalNotFound(shell))
    }

    // MARK: - Finding the windows

    private struct Bridge {
        let port: Int
        let token: String
        let path: String
    }

    /// One file per VS Code window, written by the extension when it starts.
    private static func availableBridges() -> [Bridge] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".petmacos")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasPrefix("vscode-") && $0.hasSuffix(".json") }
            .compactMap { name in
                let url = directory.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let port = object["port"] as? Int,
                      let token = object["token"] as? String else { return nil }
                return Bridge(port: port, token: token, path: url.path)
            }
    }

    private static func post(text: String, pid: pid_t, to bridge: Bridge)
        -> Result<String, SendError> {
        guard let url = URL(string: "http://127.0.0.1:\(bridge.port)/send"),
              let body = try? JSONSerialization.data(
                withJSONObject: ["pid": Int(pid), "text": text])
        else { return .failure(.transportFailed("could not build the request")) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 5
        request.setValue(bridge.token, forHTTPHeaderField: "X-Pet-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Synchronous on purpose: this runs on a detached delivery task, and
        // every other surface in this file is sync too.
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<String, SendError> = .failure(.transportFailed("no response"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                // A window that has gone away leaves its file behind; treat a
                // dead port as "not this one" rather than a hard failure.
                outcome = .failure(.transportFailed(error.localizedDescription))
                try? FileManager.default.removeItem(atPath: bridge.path)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                outcome = .failure(.terminalNotFound(pid))
                return
            }
            let name = (try? JSONSerialization.jsonObject(with: data ?? Data()))
                .flatMap { ($0 as? [String: Any])?["name"] as? String } ?? "terminal"
            outcome = .success(name)
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return outcome
    }

    // MARK: - tty -> shell pid

    /// The shell VS Code spawned for `tty`.
    ///
    /// Among the processes on a tty, the shell is the one whose parent is NOT
    /// also on that tty — everything else (claude, and whatever it runs) was
    /// started from within the session. That parent is VS Code's pty host,
    /// which is precisely the process `Terminal.processId` reports.
    static func shellProcess(onTty tty: String) -> pid_t? {
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard let output = run("/bin/ps", ["-t", name, "-o", "pid=,ppid="]) else { return nil }
        var parents: [pid_t: pid_t] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1])
            else { continue }
            parents[pid] = ppid
        }
        let onThisTty = Set(parents.keys)
        let roots = parents.filter { !onThisTty.contains($0.value) }.map(\.key)
        // Exactly one root is the normal shape. Anything else means this tty
        // is not laid out the way the assumption above expects.
        return roots.count == 1 ? roots[0] : nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
