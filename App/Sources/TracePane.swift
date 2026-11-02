import LoomKit
import SwiftUI

/// The programs the focused strand ran with `code_mode`, in order.
///
/// Each shows its state, the wall budget it asked for, whether the vetting that
/// precedes a run passed, a bounded excerpt of its result and the capability
/// calls it made. A program still running has no result and no calls yet, and a
/// result that carries no call record lists none, which the pane says rather
/// than implying the program made none.
struct TracePane: View {
    let controller: SessionController

    var body: some View {
        let trace = controller.trace
        VStack(alignment: .leading, spacing: 10) {
            Text("Programs").font(.headline)
            if trace.programs.isEmpty {
                Quiet("No program has run on this strand. A program appears here when the agent runs code.")
            }
            if trace.omitted > 0 {
                Quiet("\(trace.omitted) earlier programs are not shown.")
            }
            ForEach(trace.programs) { ProgramCard(program: $0) }
        }
    }
}

private struct ProgramCard: View {
    let program: TraceBoard.Program
    @State private var showsCalls = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(program.label).font(.system(size: 12, weight: .medium).monospaced()).lineLimit(2)
                Spacer(minLength: 6)
                Text(program.state.word)
                    .font(Theme.caption)
                    .foregroundStyle(program.state.isFailure ? Theme.failure : Color.secondary)
            }
            Quiet("\(program.budget) · \(program.vetting)")
            if let detail = program.detail {
                Text(detail).font(Theme.code).foregroundStyle(Theme.failure).textSelection(.enabled)
            } else if let excerpt = program.excerpt, !excerpt.isEmpty {
                Text(excerpt).font(Theme.code).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            if let summary = program.callSummary {
                DisclosureGroup(isExpanded: $showsCalls) {
                    ForEach(program.calls) { call in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(call.capability).font(Theme.code)
                            Text(call.status).font(Theme.caption)
                                .foregroundStyle(call.status == "ok" ? Color.secondary : Theme.failure)
                            Spacer()
                            Text("\(call.durationMs) ms").font(Theme.meta).foregroundStyle(.tertiary)
                        }
                    }
                } label: {
                    Text(summary).font(Theme.caption)
                }
            } else if program.state != .running {
                Quiet("This result carries no record of the calls it made.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
        .accessibilityElement(children: .contain)
    }
}
