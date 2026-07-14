import SwiftUI

/// Dialog shown above the dog when Claude Code asks a multiple-choice question
/// (the `AskUserQuestion` tool). Questions are shown one at a time; answering
/// the last one sends every answer back to the waiting hook.
struct QuestionDialogView: View {
    let question: PendingQuestion
    let accent: Color
    let onSubmit: ([String: PetAnswer]) -> Void
    let onSkip: () -> Void

    /// Answers collected so far, keyed by question text.
    @State private var answers: [String: PetAnswer] = [:]
    /// Index of the question currently on screen.
    @State private var index = 0
    /// Options ticked for the current multi-select question.
    @State private var selected: Set<String> = []
    /// Whether the free-form "Khác…" field is showing for the current question.
    @State private var showCustom = false
    @State private var customText = ""

    private var current: PetQuestion { question.questions[index] }
    private var isLast: Bool { index == question.questions.count - 1 }
    private var total: Int { question.questions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Claude hỏi")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if total > 1 {
                    Text("\(index + 1)/\(total)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let header = current.header, !header.isEmpty {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(current.question)
                .font(.system(size: 14, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(current.options, id: \.label) { option in
                        optionButton(option)
                    }
                    customRow
                }
            }
            .frame(maxHeight: 240)

            // Explicit confirm: picking an option only highlights it; nothing is
            // sent until the user presses this button.
            Button {
                submitCurrent()
            } label: {
                Text(isLast ? "Gửi" : "Tiếp").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasAnswer)

            Button { onSkip() } label: {
                Text("Bỏ qua (trả lời trong terminal)").frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.cancelAction)
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 288)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent, lineWidth: 2)
        )
        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
    }

    // MARK: - Rows

    @ViewBuilder
    private func optionButton(_ option: PetQuestionOption) -> some View {
        let isSelected = selected.contains(option.label)
        Button {
            if current.multiSelect {
                if isSelected { selected.remove(option.label) }
                else { selected.insert(option.label) }
            } else {
                // Select only; submission happens via the confirm button.
                selected = isSelected ? [] : [option.label]
                showCustom = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                if let desc = option.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.22) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var customRow: some View {
        if showCustom {
            TextField("Câu trả lời của bạn", text: $customText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.top, 2)
        } else {
            Button {
                showCustom = true
                if !current.multiSelect { selected = [] }
            } label: {
                Text("Khác…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Flow

    private var trimmedCustom: String {
        customText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The current question has something selectable to send.
    private var hasAnswer: Bool {
        !selected.isEmpty || (showCustom && !trimmedCustom.isEmpty)
    }

    /// Builds the answer from the current selection (plus free text) and records it.
    private func submitCurrent() {
        if current.multiSelect {
            var labels = Array(selected)
            if showCustom && !trimmedCustom.isEmpty { labels.append(trimmedCustom) }
            guard !labels.isEmpty else { return }
            record(.multi(labels))
        } else if showCustom && !trimmedCustom.isEmpty {
            record(.single(trimmedCustom))
        } else if let label = selected.first {
            record(.single(label))
        }
    }

    /// Stores the answer for the current question and advances, or submits when
    /// the last question is done.
    private func record(_ answer: PetAnswer) {
        var next = answers
        next[current.question] = answer
        if isLast {
            onSubmit(next)
            return
        }
        answers = next
        index += 1
        selected = []
        showCustom = false
        customText = ""
    }
}
