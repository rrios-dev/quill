import os

/// The intervals ARCHITECTURE §11 budgets, as signposts (PLAN P5-T4): visible in
/// Instruments' os_signpost track and in `log show --signpost`, category `performance`.
/// They carry no user text.
public enum QuillSignposts {
    public static let signposter = OSSignposter(subsystem: QuillLog.subsystem, category: "performance")

    /// Hot key → picker visible (capture included).
    public static let capture: StaticString = "capture-to-picker"
    /// Generation start → first streamed token.
    public static let firstToken: StaticString = "first-token"
    /// Return → replacement done.
    public static let replace: StaticString = "replace"
}
