import SwiftUI

/// The real settings window: status, pet & sprites, permissions, colours.
/// Text-only UI (no icons), Vietnamese labels.
struct SettingsWindowView: View {
    var delegate: PetAppDelegate
    var state: PetState
    var sprites: SpriteLibrary
    @Bindable var settings: SettingsStore
    var usage: UsageMonitor

    @State private var importMessage: String?
    @State private var logCopyMessage: String?
    /// Ticks periodically so the "last event" relative time and the stale-
    /// connection warning stay fresh while the tab is open (they depend on
    /// `Date()`, which SwiftUI has no other reason to recompute).
    @State private var now = Date()

    var body: some View {
        TabView {
            statusTab
                .tabItem { Text("Trạng thái") }
            petTab
                .tabItem { Text("Pet") }
            permissionsTab
                .tabItem { Text("Quyền") }
            colorsTab
                .tabItem { Text("Màu sắc") }
            diagnosticsTab
                .tabItem { Text("Chẩn đoán") }
        }
        .frame(width: 480, height: 540)
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    // MARK: - Trạng thái

    private var statusTab: some View {
        Form {
            Section("Pet") {
                Toggle("Hiển thị pet", isOn: Binding(
                    get: { delegate.isVisible },
                    set: { delegate.setPetVisible($0) }
                ))
                Toggle("Click-through (chuột xuyên qua pet)", isOn: Binding(
                    get: { delegate.isClickThrough },
                    set: { delegate.setClickThrough($0) }
                ))
            }

            Section("Kết nối Claude Code") {
                LabeledContent("Hooks") {
                    Text(delegate.isConnected ? "Đã cài vào ~/.claude/settings.json" : "Chưa kết nối")
                        .foregroundStyle(delegate.isConnected ? .green : .secondary)
                }
                LabeledContent("Server nội bộ") {
                    if let port = delegate.serverPort {
                        Text("Đang nghe cổng \(String(port))")
                            .foregroundStyle(.green)
                    } else {
                        Text("Không chạy")
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    if delegate.isConnected {
                        Button("Ngắt kết nối") { delegate.disconnectClaudeCode() }
                    } else {
                        Button("Kết nối") { delegate.connectClaudeCode() }
                    }
                    Button("Kiểm tra lại") { delegate.refreshConnectionStatus() }
                    Button("Mở lại hướng dẫn") { delegate.openOnboardingWindow() }
                }
            }

            Section("Mức sử dụng Claude") {
                usageRow("Cửa sổ 5 giờ", usage.fiveHour)
                usageRow("Tuần", usage.sevenDay)
                if let error = usage.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Làm mới") { Task { await usage.refresh() } }
                    if let updated = usage.lastUpdated {
                        Text("Cập nhật \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func usageRow(_ title: String, _ window: UsageMonitor.Window?) -> some View {
        LabeledContent(title) {
            if let window {
                HStack(spacing: 6) {
                    Text("\(Int(window.utilization.rounded()))%").bold().monospacedDigit()
                    if let resets = window.resetsAt {
                        Text("reset \(resets.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("chưa có dữ liệu").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Pet & sprites

    private var petTab: some View {
        Form {
            Section {
                ForEach(SpriteLibrary.states, id: \.self) { stateName in
                    spriteRow(for: stateName)
                }
            } header: {
                Text("Sprites")
            } footer: {
                Text("Bấm Thay… để chọn ảnh PNG trong suốt hoặc GIF động — app tự tách frame, căn giữa và đặt tốc độ.")
            }

            if let message = importMessage {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Button("Mở thư mục sprites") { delegate.openSpritesFolder() }
                    Button("Tải lại sprites") { delegate.reloadSprites() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func spriteRow(for stateName: String) -> some View {
        HStack(spacing: 10) {
            // Thumbnail of the first frame, if any.
            Group {
                if let first = sprites.clip(named: stateName)?.frames.first {
                    Image(nsImage: first)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: stateName))
                if let clip = sprites.clip(named: stateName) {
                    Text("\(clip.frames.count) frame, \(trimmed(clip.fps)) fps\(clip.loops ? ", lặp" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("chưa có")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button("Thay…") { importSprites(for: stateName) }
        }
    }

    /// Opens a file picker and replaces the state's frames with the selection.
    private func importSprites(for stateName: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .gif, .jpeg]
        panel.allowsMultipleSelection = true
        panel.message = "Chọn ảnh PNG trong suốt (nhiều frame) hoặc một file GIF cho \"\(stateName)\""
        panel.prompt = "Nhập"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        do {
            let result = try SpriteImporter.replaceFrames(of: stateName, with: panel.urls)
            delegate.reloadSprites()
            if let fps = result.gifFPS {
                importMessage = "Đã nhập \(result.frameCount) frame cho \(stateName) (GIF, \(trimmed(fps)) fps)."
            } else {
                importMessage = "Đã nhập \(result.frameCount) frame cho \(stateName)."
            }
        } catch {
            importMessage = "Lỗi nhập ảnh: \(error.localizedDescription)"
        }
    }

    private func label(for state: String) -> String {
        switch state {
        case "idle": return "idle — khi rảnh"
        case "click": return "click — bấm vào pet"
        case "thinking": return "thinking — đang suy nghĩ"
        case "working": return "working — đang chạy tool"
        case "talking": return "talking — vừa trả lời"
        case "asking": return "asking — đang xin quyền"
        case "sleep": return "sleep — kết thúc phiên"
        case "error": return "error — một tool vừa thất bại"
        case "happy": return "happy — Claude vừa trả lời xong sạch sẽ"
        default: return state
        }
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - Quyền

    private var permissionsTab: some View {
        Form {
            Section {
                Toggle("Chỉ hỏi tool ghi/chạy", isOn: Binding(
                    get: { delegate.writeToolsOnly },
                    set: { delegate.setWriteToolsOnly($0) }
                ))
                Toggle("Tạm dừng duyệt quyền (tự cho phép)", isOn: Binding(
                    get: { delegate.pauseApprovals },
                    set: { delegate.pauseApprovals = $0 }
                ))
            } header: {
                Text("Duyệt quyền trên pet")
            } footer: {
                Text("Chỉ áp dụng ở chế độ quyền thủ công của Claude Code. Các chế độ auto sẽ chỉ hiển thị thông báo.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Màu sắc

    private var colorsTab: some View {
        Form {
            Section("Border tác vụ đang chạy") {
                colorRow("Suy nghĩ", $settings.thinking)
                colorRow("Chạy tool", $settings.tool)
                colorRow("Chú ý", $settings.notification)
                colorRow("Phiên", $settings.session)
                colorRow("Subagent", $settings.subagent)
                colorRow("Chạy nền", $settings.background)
            }

            Section("Gradient tác vụ hoàn thành") {
                colorRow("Màu 1", $settings.gradient1)
                colorRow("Màu 2", $settings.gradient2)
                colorRow("Màu 3", $settings.gradient3)
                LabeledContent("Xem trước") {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(settings.completedGradient, lineWidth: 3)
                        .frame(width: 120, height: 28)
                }
            }

            Section {
                Button("Khôi phục mặc định") { settings.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    private func colorRow(_ title: String, _ color: Binding<Color>) -> some View {
        HStack {
            ColorPicker(title, selection: color, supportsOpacity: true)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(color.wrappedValue, lineWidth: 3)
                .frame(width: 60, height: 22)
        }
    }

    // MARK: - Chẩn đoán

    private var diagnosticsTab: some View {
        Form {
            Section("Trạng thái") {
                LabeledContent("Hooks") {
                    Text(delegate.isConnected ? "Đã cài vào ~/.claude/settings.json" : "Chưa cài")
                        .foregroundStyle(delegate.isConnected ? .green : .red)
                }
                LabeledContent("Server nội bộ") {
                    if let port = delegate.serverPort {
                        Text("Đang nghe cổng \(String(port))").foregroundStyle(.green)
                    } else {
                        Text("Không chạy").foregroundStyle(.red)
                    }
                }
                LabeledContent("Event cuối cùng") {
                    if let lastEventAt = state.lastEventAt {
                        Text(lastEventAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("chưa nhận event nào").foregroundStyle(.tertiary)
                    }
                }

                if state.isConnectionStale(hooksInstalled: delegate.isConnected, now: now) {
                    Text("Cảnh báo: đã cài hook nhưng lâu rồi không nhận được event nào — pet-hook.sh có thể đang không kết nối được tới app. Bấm \"Kiểm tra kết nối\" để xác nhận, hoặc \"Cài lại hook\" để ghi lại script.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Lỗi gần nhất") {
                if let error = state.lastErrorMessage {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Text("Không có lỗi nào được ghi nhận.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                HStack {
                    Button("Copy log") { copyEventsLog() }
                    Button("Cài lại hook") { delegate.connectClaudeCode() }
                    Button(delegate.diagnosticTestRunning ? "Đang kiểm tra…" : "Kiểm tra kết nối") {
                        delegate.testHookConnection()
                    }
                    .disabled(delegate.diagnosticTestRunning)
                }

                if let message = logCopyMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let result = delegate.diagnosticTestResult {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.message)
                            .font(.callout)
                            .foregroundStyle(result.success ? .green : .orange)
                        Text(result.at.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Hành động")
            } footer: {
                Text("\"Kiểm tra kết nối\" chạy chính script pet-hook.sh đã cài với một event thử, đúng đường đi thật Claude Code dùng — không gọi thẳng server qua HTTP.")
            }
        }
        .formStyle(.grouped)
    }

    /// Copies the contents of `~/.petmacos/events.log` to the clipboard so the
    /// user can paste it into a support request without using the terminal.
    private func copyEventsLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".petmacos/events.log")
        guard let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else {
            logCopyMessage = "Chưa có log (events.log trống hoặc chưa tồn tại)."
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        logCopyMessage = "Đã copy events.log (\(content.utf8.count) byte) vào clipboard."
    }
}
