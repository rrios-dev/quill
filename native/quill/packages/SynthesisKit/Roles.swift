import Foundation

/// A function people have in meetings: Product Owner, Tech Lead, Support… (MEETINGS.md §7).
public struct MeetingRole: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// What the role is responsible for, in one line. Goes to the model as data.
    public var summary: String

    public init(id: String, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }
}

extension MeetingRole {
    /// The catalogue a new install starts with. The user edits it freely.
    public static let defaults: [MeetingRole] = [
        MeetingRole(id: "product-owner", name: "Product Owner", summary: "Prioriza y decide el producto"),
        MeetingRole(id: "tech-lead", name: "Tech Lead", summary: "Responde de la arquitectura"),
        MeetingRole(id: "support", name: "Soporte", summary: "Atiende a los clientes"),
        MeetingRole(id: "engineer", name: "Desarrollo", summary: "Construye el producto"),
        MeetingRole(id: "client", name: "Cliente", summary: "Quien encarga el trabajo"),
        MeetingRole(id: "vendor", name: "Proveedor", summary: "Externo que presta un servicio"),
    ]
}

/// How much a role counts in a synthesis: a closed set, so prompts and tests can rely on
/// its meaning (MEETINGS.md §7.2).
public enum Treatment: String, Codable, CaseIterable, Hashable, Sendable {
    case decides
    case influences
    case context
    case request
    case minimal

    /// What the model is told the treatment means. English: it is part of the prompt.
    var promptMeaning: String {
        switch self {
        case .decides:
            "what they settle or accept is a decision; a proposal from anyone else becomes a decision only when someone who decides accepts it"
        case .influences:
            "their proposals and objections are reported with their name and weigh the reading, but settle nothing alone"
        case .context:
            "summarise what they bring as supporting information; never present it as a decision or as a position to weigh"
        case .request:
            "an outside party: what they ask for is a request, kept apart from internal agreements"
        case .minimal:
            "mention them only when it changes a task, a date or a risk"
        }
    }
}

/// A person in one meeting, as the synthesis sees them.
public struct Participant: Codable, Hashable, Sendable {
    /// The name as it appears in the transcript.
    public var name: String
    public var role: MeetingRole?
    public var treatment: Treatment
    /// A limit on `decides`, in the user's words ("on technical matters").
    public var scope: String?

    public init(name: String, role: MeetingRole?, treatment: Treatment, scope: String? = nil) {
        self.name = name
        self.role = role
        self.treatment = treatment
        self.scope = scope
    }
}

/// How each role counts under one focus (MEETINGS.md §7.1).
public struct RoleWeighting: Codable, Hashable, Sendable {
    public struct Rule: Codable, Hashable, Sendable {
        public var treatment: Treatment
        public var scope: String?

        public init(_ treatment: Treatment, scope: String? = nil) {
            self.treatment = treatment
            self.scope = scope
        }
    }

    /// Role id → rule.
    public var rules: [String: Rule]
    /// For a person without a role, or a role the table does not name.
    public var fallback: Treatment

    public init(rules: [String: Rule] = [:], fallback: Treatment = .influences) {
        self.rules = rules
        self.fallback = fallback
    }

    public func rule(for role: MeetingRole?) -> Rule {
        role.flatMap { rules[$0.id] } ?? Rule(fallback)
    }

    /// Participants for a meeting: each person's role, the treatment this focus gives it,
    /// then any override the user made for this meeting only.
    public func participants(
        _ people: [(name: String, role: MeetingRole?)],
        overrides: [String: Treatment] = [:]
    ) -> [Participant] {
        people.map { person in
            let rule = rule(for: person.role)
            let treatment = overrides[person.name] ?? rule.treatment
            return Participant(
                name: person.name,
                role: person.role,
                treatment: treatment,
                scope: treatment == rule.treatment ? rule.scope : nil
            )
        }
    }
}
