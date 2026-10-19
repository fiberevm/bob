import SwiftUI
import BobCore

/// Lives in the composer dock, so the transcript reserves space for the entire card.
struct UserInputCard: View {
    let request: UserInputRequest
    @ObservedObject private var draft: UserInputDraft

    init(request: UserInputRequest) {
        self.request = request
        self.draft = request.draft
    }
    @FocusState private var otherFocused: Bool

    private var question: UserInputQuestions.Question { request.questions.questions[draft.index] }
    private var values: [String: String] {
        var result = draft.choices
        for id in draft.other { result[id] = draft.custom[id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines) }
        return result
    }
    private var canSubmit: Bool { (try? request.questions.response(values)) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").foregroundStyle(Theme.accent)
                Text(question.header).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(draft.index + 1) of \(request.questions.questions.count)")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                Button(action: request.cancel) { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss questions without answering")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.question).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 4)
                    ForEach(question.options, id: \.label) { option in
                        choiceRow(option.label, detail: option.description,
                                  selected: !draft.other.contains(question.id) && draft.choices[question.id] == option.label) {
                            draft.choices[question.id] = option.label
                            draft.other.remove(question.id); otherFocused = false
                        }
                    }
                    choiceRow("Other", detail: "Write your own answer", selected: draft.other.contains(question.id)) {
                        draft.other.insert(question.id); otherFocused = true
                    }
                    if draft.other.contains(question.id) {
                        TextField("Your answer", text: Binding(get: { draft.custom[question.id, default: ""] }, set: { draft.custom[question.id] = $0 }), axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5)
                            .padding(10).background(Theme.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                            .focused($otherFocused).accessibilityLabel("Other answer for \(question.header)")
                    }
                }
            }.frame(maxHeight: 280)
            HStack {
                if draft.index > 0 {
                    Button("Back") { draft.index -= 1; otherFocused = false }
                }
                Spacer()
                if draft.index + 1 < request.questions.questions.count {
                    Button("Next") { draft.index += 1; otherFocused = false }
                        .disabled(values[question.id, default: ""].isEmpty)
                } else {
                    Button("Submit answers") { request.resolve(values) }
                        .buttonStyle(.borderedProminent).tint(Theme.action).disabled(!canSubmit)
                }
            }.controlSize(.small)
        }
        .padding(16).foregroundStyle(Theme.text)
        .modifier(FloatingGlass(cornerRadius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent needs your input")
    }

    private func choiceRow(_ label: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Theme.muted).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.accent.opacity(0.12) : Theme.raised.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .accessibilityLabel(label + ". " + detail)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
