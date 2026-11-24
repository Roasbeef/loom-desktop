import Foundation

// When an approval card's Allow and Deny are live.
//
// A card that appears under a person's hands must not take the click they meant for
// something else, so its buttons wait 600 ms. A card also moves when another one
// leaves: decided from the Inbox or by another client, or dropped when the turn
// aborts. The card above slides into the place of the one that left, and a pointer
// aimed at that place would land on a live Allow. So the wait restarts for every card
// still shown whenever the set of cards changes, and not only for a new card.
//
// The same holds when what sits above the cards changes size. The Inbox's pane loads
// an approval's evidence and the session's recent messages above "Decide" after the
// card has appeared, which can finish while the card is already armed and pushes the
// card down. `above` carries the sizes of those sections, so the wait restarts then.

public enum ApprovalArming {
    /// How long a card's buttons stay dead after it appears or moves.
    public static let delayMs = 600

    /// The identity of one card's armed period. It changes when the card changes and
    /// when the set of cards shown with it does, so a view that restarts its wait on
    /// this key re-arms exactly then.
    public static func key(card: String, shown: [String], above: [Int] = []) -> String {
        card + "|" + shown.joined(separator: ",") + "|" + above.map(String.init).joined(separator: ",")
    }
}
