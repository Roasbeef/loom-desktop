//// The commands a person can give a thread of the inbox, defined once.
////
//// The Inbox menu, the context menu on an inbox row and the context menu on a
//// Mission Control row all draw from `InboxAction`, and `InboxCommands.state`
//// decides which of them are on offer and which can be pressed for a given
//// thread. A view only maps an action to a button, so the three surfaces cannot
//// disagree about what a stuck strand or a find allows.
////
//// ## Flow
////
//// `InboxCommands.menu` lists the actions the Inbox menu draws, in its order.
//// `InboxCommands.contextMenu` lists the ones a row's context menu draws, which
//// is the same list without navigation and without anything that decides an
//// approval (the native pass's ruling 4: a decision is made only beside its
//// evidence). `InboxCommands.state` answers, for one action and one
//// `InboxCommandContext`, whether it is `enabled`, `disabled` or `absent`.
//// `InboxCommands.neighbor` is next and previous over the list as it is drawn.

import Foundation

/// A command on a thread.
public enum InboxAction: Sendable, CaseIterable, Hashable {
    case next, previous
    case openSession, openInWindow
    case retry, closeFind, message
    case allow, allowForSession, deny

    /// Whether the action decides an approval. A decision is made beside its
    /// evidence and after the arming delay, so a context menu never offers one and
    /// the menu enables one only while an armed card is in the focused window.
    public var decides: Bool {
        switch self {
        case .allow, .allowForSession, .deny: return true
        default: return false
        }
    }

    /// Whether the action acts on the thread in place, which the owner has opened and
    /// read. A row's context menu can name a thread the owner has not opened, so it
    /// offers neither a retry nor a close; the Inbox menu and the pane do.
    public var actsInPlace: Bool { self == .retry || self == .closeFind }

    /// Whether the action moves through the list. A row's context menu has no
    /// "next", since a row is not the list's position.
    public var navigates: Bool { self == .next || self == .previous }

    /// The menu's words. An approval's tool is named, and a tool is the daemon's own
    /// identifier, which the caller has capped.
    public func title(tool: String? = nil) -> String {
        switch self {
        case .next: return "Next Thread"
        case .previous: return "Previous Thread"
        case .openSession: return "Open Session"
        case .openInWindow: return "Open in New Window"
        case .retry: return "Retry Stuck Strand"
        case .closeFind: return "Close Find"
        case .message: return "Message Session"
        case .allow: return "Allow " + (tool ?? "Request")
        case .allowForSession: return "Allow " + (tool ?? "Request") + " for This Session"
        case .deny: return "Deny " + (tool ?? "Request")
        }
    }

    /// The key chord that runs the action from the menu bar, if it has one.
    public var shortcut: InboxShortcut? {
        switch self {
        case .next: return InboxShortcut(key: "]")
        case .previous: return InboxShortcut(key: "[")
        case .openInWindow: return InboxShortcut(key: "o", modifiers: [.option])
        case .retry: return InboxShortcut(key: "r", modifiers: [.option])
        case .message: return InboxShortcut(key: "l")
        case .allow: return InboxShortcut(key: "a", modifiers: [.shift])
        case .allowForSession: return InboxShortcut(key: "a", modifiers: [.shift, .option])
        case .deny: return InboxShortcut(key: "d", modifiers: [.shift])
        case .openSession, .closeFind: return nil
        }
    }
}

/// A command-key chord. Command is always held, so only the others are named.
public struct InboxShortcut: Sendable, Equatable {
    public enum Modifier: Sendable, Hashable { case shift, option }

    public let key: Character
    public let modifiers: Set<Modifier>

    public init(key: Character, modifiers: Set<Modifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// An approval card the focused window shows armed.
public struct InboxApproval: Sendable, Equatable {
    public let tool: String
    public let canAllow: Bool
    public let canRemember: Bool

    public init(tool: String, canAllow: Bool, canRemember: Bool) {
        self.tool = tool
        self.canAllow = canAllow
        self.canRemember = canRemember
    }
}

/// Where a thread's neighbours are in the list as it is drawn.
public struct InboxNeighbors: Sendable, Equatable {
    public let hasPrevious: Bool
    public let hasNext: Bool

    public init(hasPrevious: Bool, hasNext: Bool) {
        self.hasPrevious = hasPrevious
        self.hasNext = hasNext
    }

    /// No list to move through, as in a thread's own window.
    public static let none = InboxNeighbors(hasPrevious: false, hasNext: false)
}

/// Everything `InboxCommands.state` reads. The caller fills it from the model and
/// the focused window, so the rule itself reads nothing.
public struct InboxCommandContext: Sendable, Equatable {
    /// The thread the command is about, or nil when none is open or a machine is.
    public var row: InboxRow?
    /// Whether the connection only watches the session.
    public var isObserver: Bool
    /// Whether the attention feed still lists the row's strand as stuck.
    public var stuckListed: Bool
    /// Whether a retry of the row's strand is already out.
    public var isRetrying: Bool
    /// The armed approval card in the focused window, if any.
    public var approval: InboxApproval?
    public var neighbors: InboxNeighbors
    /// Whether the thread is already in a window of its own.
    public var isInOwnWindow: Bool

    public init(
        row: InboxRow?, isObserver: Bool = false, stuckListed: Bool = false, isRetrying: Bool = false,
        approval: InboxApproval? = nil,
        neighbors: InboxNeighbors = .none, isInOwnWindow: Bool = false
    ) {
        self.row = row
        self.isObserver = isObserver
        self.stuckListed = stuckListed
        self.isRetrying = isRetrying
        self.approval = approval
        self.neighbors = neighbors
        self.isInOwnWindow = isInOwnWindow
    }
}

/// Whether a command is on offer.
public enum InboxCommandState: Sendable, Equatable {
    /// Not drawn: it does not apply to this kind of thread.
    case absent
    /// Drawn and not pressable.
    case disabled
    /// Drawn and pressable.
    case enabled
}

public enum InboxCommands {
    /// The Inbox menu, in the order it draws.
    public static let menu: [InboxAction] = [
        .next, .previous, .openSession, .openInWindow, .retry, .closeFind, .message, .allow, .allowForSession, .deny,
    ]

    /// A row's context menu: the menu without navigation, without a decision and
    /// without what acts on the open thread in place.
    public static let contextMenu: [InboxAction] = menu.filter { !$0.navigates && !$0.decides && !$0.actsInPlace }

    /// The state of `action` for `context`. The menu draws every action and greys
    /// out what cannot run, so its shape does not change as the selection moves; a
    /// context menu drops what is `absent` and what is `disabled`, since it asks
    /// about one row and a grey item there only teaches nothing.
    public static func state(_ action: InboxAction, in context: InboxCommandContext) -> InboxCommandState {
        switch action {
        case .next: return context.neighbors.hasNext ? .enabled : .disabled
        case .previous: return context.neighbors.hasPrevious ? .enabled : .disabled
        // A ticket is not a session, so it has none to open or write to. Its pane
        // carries its own controls.
        case .openSession: return context.row == nil || context.row?.isTicket == true ? .disabled : .enabled
        case .openInWindow: return context.row == nil || context.isInOwnWindow ? .disabled : .enabled
        case .retry:
            guard let kind = context.row?.kind, kind == .stuck else { return .absent }
            return ThreadRule.retryOffer(isObserver: context.isObserver, stuckListed: context.stuckListed, sending: context.isRetrying) == .enabled
                ? .enabled : .disabled
        case .closeFind:
            guard let kind = context.row?.kind, case .find = kind else { return .absent }
            return context.isObserver ? .disabled : .enabled
        case .message:
            guard let kind = context.row?.kind, context.row?.isTicket != true else { return .disabled }

            // A finished session's reply goes through the review's outbox, not the
            // message bar the command focuses.
            return kind == .review || context.isObserver ? .disabled : .enabled
        case .allow: return context.approval?.canAllow == true ? .enabled : .disabled
        case .allowForSession: return context.approval?.canRemember == true ? .enabled : .disabled
        case .deny: return context.approval == nil ? .disabled : .enabled
        }
    }

    /// The actions a row's context menu draws for `context`: those that apply to its
    /// kind and can run now.
    public static func contextActions(for context: InboxCommandContext) -> [InboxAction] {
        contextMenu.filter { state($0, in: context) == .enabled }
    }

    /// Which way a move through the list goes.
    public enum Step: Sendable { case previous, next }

    /// The selection one step from `current` in `drawn`, the selections in the order
    /// the list draws them. It never wraps: past either end there is nothing, and
    /// the menu item is disabled. A selection the list does not draw (a resolved
    /// thread, or one outside the folder) has no place to step from, so a step enters
    /// the list at the end it moves toward.
    public static func neighbor(of current: InboxSelection?, in drawn: [InboxSelection], step: Step) -> InboxSelection? {
        guard let current, let index = drawn.firstIndex(of: current) else {
            return step == .next ? drawn.first : drawn.last
        }
        switch step {
        case .previous: return index > 0 ? drawn[index - 1] : nil
        case .next: return index + 1 < drawn.count ? drawn[index + 1] : nil
        }
    }

    /// Whether each step has somewhere to go.
    public static func neighbors(of current: InboxSelection?, in drawn: [InboxSelection]) -> InboxNeighbors {
        InboxNeighbors(
            hasPrevious: neighbor(of: current, in: drawn, step: .previous) != nil,
            hasNext: neighbor(of: current, in: drawn, step: .next) != nil
        )
    }
}
