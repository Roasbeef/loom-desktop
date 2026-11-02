import LoomKit
import SwiftUI

/// A question put to the model on the side while the strand keeps working.
///
/// The daemon freezes the strand's latest request when the first question is
/// asked and answers from that, with no tools, writing nothing to the
/// transcript. Follow-ups keep that base until Refresh. The exchanges belong to
/// this window's attachment and are forgotten when it disconnects, so the panel
/// says so rather than implying a record exists.
struct SideQuestionPanel: View {
    let controller: SessionController
    @State private var question = ""
    @FocusState private var isFocused: Bool

    private var board: SideBoard? { SideBoard(controller.surfaces["btw"]?["board"]) }
    private var isRunning: Bool { board?.isRunning ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("Side question").font(Theme.label)
                if let model = board?.model, !model.isEmpty {
                    Text(PanelWords.modelName(model)).font(Theme.meta).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { send("refresh") }
                    .help("Take a fresh base from the strand's latest request")
                if isRunning {
                    Button("Cancel") { send("cancel") }
                }
                Button("Clear") { send("clear") }
                    .disabled(board?.exchanges.isEmpty ?? true)
                IconButton(symbol: "xmark", label: "Close Side Question") {
                    controller.showsSideQuestion = false
                }
            }
            .controlSize(.small)

            if let board {
                if board.exchanges.isEmpty {
                    Quiet(board.notice.isEmpty ? "Ask anything. The strand keeps working." : board.notice)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(board.exchanges) { exchange in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(exchange.question).font(.system(size: 12, weight: .semibold))
                                    if exchange.answer.isEmpty {
                                        Quiet(isRunning ? "Thinking…" : "No answer.")
                                    } else {
                                        Text(exchange.answer).font(Theme.body).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                if !board.notice.isEmpty, !board.exchanges.isEmpty {
                    Quiet(board.notice)
                }
            } else if let error = controller.readFailures["btw"] {
                Quiet("Side questions are not available here: \(error)")
            }

            HStack(spacing: 8) {
                TextField("Ask on the side…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(ask)
                    .accessibilityLabel("Side question")
                Button("Ask", action: ask)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isRunning)
            }
            .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.radius))
        .onAppear { send("read") }
        // Focus moves after the panel has been laid out, since the composer below
        // claims it when it appears and a same-frame request loses to it.
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            isFocused = true
        }
        // A running answer is read again until it settles, once a second.
        .task(id: isRunning) {
            while isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if isRunning { controller.read("btw", body: body("read")) }
            }
        }
    }

    private func body(_ action: String, text: String = "") -> JSONValue {
        ["strand": .string(controller.focusedStrand), "action": .string(action), "text": .string(text)]
    }

    private func send(_ action: String) {
        controller.run("btw", body: body(action))
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        controller.run("btw", body: body("ask", text: text))
        question = ""
    }
}
