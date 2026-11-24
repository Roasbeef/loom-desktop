//// What the inbox has open, and the rules that decide when it changes.
////
//// Only the owner's clicks move what is open. A refresh may reorder rows, add
//// rows or remove them, and none of those changes the thread in the reading
//// pane. The pane is a function of one value, `InboxOpening`, which the model
//// holds and the list's selection is bound to, so the row highlighted and the
//// thread shown cannot disagree.
////
//// ## Flow
////
//// `InboxRule.settle` runs after every refresh. `InboxRule.open` and
//// `InboxRule.narrow` run on the owner's own choices, a click on a row and a
//// click on a folder.

import Foundation

/// What the inbox has selected: one of the rule's threads, or a machine that is
/// not healthy, which only this app lists.
public enum InboxSelection: Hashable, Sendable {
    case thread(InboxSubject)
    case machine(String)
}

/// Where the owner is, as far as the inbox's selection cares: looking at the list,
/// or somewhere else in the app.
public enum InboxPlace: Sendable {
    case inbox
    case elsewhere
}

/// The open thread, with the last row that listed it.
///
/// A resolved thread leaves the list, and the pane still has to say which thread
/// it was. `held` is that row, kept from the last refresh that listed it.
public struct InboxOpening: Equatable, Sendable {
    public var selection: InboxSelection?
    /// The thread's row as the last refresh listed it. Nil for a machine.
    public var held: InboxRow?
    /// True once a refresh no longer lists the open thread or machine. The pane then
    /// says it is resolved and stays until the owner picks something else.
    public var isResolved: Bool

    public static let none = InboxOpening(selection: nil, held: nil, isResolved: false)

    public init(selection: InboxSelection?, held: InboxRow?, isResolved: Bool) {
        self.selection = selection
        self.held = held
        self.isResolved = isResolved
    }
}

extension InboxRule {
    /// The rows a selection can name: every thread's row, not the folded quiet line,
    /// which holds names and not threads.
    public static func selectable(_ sections: [InboxSection]) -> [InboxRow] {
        sections.filter { $0.group != .quiet }.flatMap(\.rows)
    }

    /// The opening after a refresh. The choice stands whatever the rows did:
    ///
    /// - a listed thread stays open, and its row is taken again so the pane reads
    ///   the newest;
    /// - a thread that is no longer listed stays open, marked resolved, when it was
    ///   open before; a machine that is no longer listed is the same;
    /// - only when nothing is open, or the choice was never listed (so there is no
    ///   row to keep showing), and only while the owner is on the Inbox, the first
    ///   thread opens, or the first machine when no thread is listed.
    ///
    /// Off the Inbox nothing is opened for the owner, because they have not looked
    /// at the list: a first fallback taken at launch would freeze whatever row was
    /// listed first, and a later approval could never take the pane. A resolved
    /// opening is also dropped there, since "resolved" is a note to someone looking
    /// at the pane, and a first visit would otherwise read about a thread the owner
    /// never opened.
    ///
    /// `rows` come from every section, not only the folder the list draws, because
    /// a thread outside the folder is still the one the pane reads.
    public static func settle(
        _ opening: InboxOpening, rows: [InboxRow], machines: [String], place: InboxPlace = .inbox
    ) -> InboxOpening {
        let kept = keep(opening, rows: rows, machines: machines)
        switch place {
        case .inbox:
            return kept ?? first(rows: rows, machines: machines)
        case .elsewhere:
            guard let kept, !kept.isResolved else { return .none }
            return kept
        }
    }

    /// The opening with the refresh applied, or nil when nothing is open or the
    /// choice has no row to show.
    private static func keep(_ opening: InboxOpening, rows: [InboxRow], machines: [String]) -> InboxOpening? {
        switch opening.selection {
        case .thread(let subject)?:
            if let row = rows.first(where: { $0.subject == subject }) {
                return InboxOpening(selection: opening.selection, held: row, isResolved: false)
            }
            if let held = opening.held, held.subject == subject {
                return InboxOpening(selection: opening.selection, held: held, isResolved: true)
            }
            return nil
        case .machine(let id)?:
            return InboxOpening(selection: opening.selection, held: nil, isResolved: !machines.contains(id))
        case nil:
            return nil
        }
    }

    /// The owner chose `selection`. A selection that is not listed has no row to
    /// show, so the current opening stands: the choice can be stale when a row
    /// resolves while a menu that offered it is open.
    public static func open(
        _ selection: InboxSelection, from opening: InboxOpening = .none, rows: [InboxRow], machines: [String]
    ) -> InboxOpening {
        let chosen = InboxOpening(selection: selection, held: nil, isResolved: false)
        return keep(chosen, rows: rows, machines: machines).flatMap { $0.isResolved ? nil : $0 } ?? opening
    }

    /// The owner chose a folder, whose list draws `visible`. An open thread the
    /// folder does not draw would leave the pane and the highlight disagreeing, so
    /// the folder's first thread opens, which is the owner's own click moving it. A
    /// machine is listed under every folder and stays open.
    public static func narrow(_ opening: InboxOpening, visible: [InboxRow], rows: [InboxRow], machines: [String]) -> InboxOpening {
        guard case .thread(let subject)? = opening.selection else { return opening }
        if visible.contains(where: { $0.subject == subject }) { return opening }
        guard let next = visible.first else { return opening }
        return open(.thread(next.subject), rows: rows, machines: machines)
    }

    private static func first(rows: [InboxRow], machines: [String]) -> InboxOpening {
        if let row = rows.first { return InboxOpening(selection: .thread(row.subject), held: row, isResolved: false) }
        if let machine = machines.first { return InboxOpening(selection: .machine(machine), held: nil, isResolved: false) }
        return .none
    }
}
