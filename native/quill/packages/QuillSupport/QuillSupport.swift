/// Leaf utilities shared by every Quill target.
///
/// Depends on nothing, so any target may import it without creating a cycle.
/// `QuillLog` lands here too (ARCHITECTURE §6).
public enum QuillSupport {
    /// The name shown to people. A codename until the product name is chosen
    /// (README Q1); every user-visible mention goes through this constant, so
    /// renaming the product is one edit.
    public static let productName = "Quill"
}
