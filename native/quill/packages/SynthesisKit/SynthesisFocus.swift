import Foundation

/// What a synthesis looks for in a meeting: the sibling of a rewrite profile.
///
/// A rewrite profile tunes register, tone and length of the same text; a focus decides
/// what to extract from a long one, how to lay it out, and how much each role counts
/// for that objective (MEETINGS.md §7). Like a profile, the user can make one and
/// fine-tune it with guidance.
public struct SynthesisFocus: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// What the synthesis is for, in one line ("qué cambia para soporte").
    public var objective: String
    /// What to extract and how to present it: the body of the instructions. Prompt
    /// text, in English like the rest of the prompt; the user never edits it.
    public var guidance: String
    /// The user's fine-tuning, in their own words and language, added to `guidance`.
    public var notes: String
    public var weighting: RoleWeighting

    public init(id: String, name: String, objective: String = "", guidance: String, notes: String = "",
                weighting: RoleWeighting = RoleWeighting()) {
        self.id = id
        self.name = name
        self.objective = objective
        self.guidance = guidance
        self.notes = notes
        self.weighting = weighting
    }

    enum CodingKeys: String, CodingKey { case id, name, objective, guidance, notes, weighting }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        objective = try container.decodeIfPresent(String.self, forKey: .objective) ?? ""
        guidance = try container.decode(String.self, forKey: .guidance)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        weighting = try container.decodeIfPresent(RoleWeighting.self, forKey: .weighting) ?? RoleWeighting()
    }

    /// The base for a focus the user creates: their objective and notes carry it.
    public static let customGuidance = """
    Synthesise the meeting for the objective above, in the structure that serves it best: \
    short headings, bullet points, a table for tasks with owner and date when there are any.
    """
}

extension SynthesisFocus {
    /// Minutes for whoever has to act on the meeting.
    public static let work = SynthesisFocus(
        id: "work",
        name: "Acta de producto",
        objective: "Qué se decidió y quién hace qué",
        guidance: """
        Write the minutes someone will act on. Sections, in this order:
        1. "Decisiones": each decision taken, one line each.
        2. "Tareas": a table with columns Responsable | Tarea | Fecha. Only tasks someone \
        committed to; the owner is the person who said they would do it or was asked and \
        accepted. Write the date as said ("miércoles 15 de octubre"); "sin fecha" if none.
        3. "Riesgos y temas abiertos": what was left unresolved or flagged as a risk.
        4. "Desacuerdos": who disagreed with what, when someone kept a different opinion \
        after a decision. Omit the section if there were none.
        Be brief: no introduction, no conclusion, no restating the agenda.
        """,
        weighting: RoleWeighting(rules: [
            "product-owner": .init(.decides),
            "tech-lead": .init(.decides, scope: "en lo técnico"),
            "support": .init(.context),
            "client": .init(.request),
            "vendor": .init(.minimal),
        ])
    )

    /// For understanding the meeting: positions, arguments, tensions.
    public static let analysis = SynthesisFocus(
        id: "analysis",
        name: "Análisis",
        objective: "Entender las posturas, los argumentos y los riesgos",
        guidance: """
        Analyse the meeting for someone who needs to understand it, not just act on it. \
        For each topic discussed: the options on the table, who defended each and with \
        which argument, what was decided and why. Then a section "Lectura" with the \
        tensions, the risks and the assumptions that went unquestioned. Attribute every \
        position to the person who held it.
        """,
        weighting: RoleWeighting(rules: [
            "product-owner": .init(.decides),
            "tech-lead": .init(.decides, scope: "en lo técnico"),
            "client": .init(.request),
        ])
    )

    /// The meeting in a few lines.
    public static let brief = SynthesisFocus(
        id: "brief",
        name: "Breve",
        objective: "Cinco líneas para quien no estuvo",
        guidance: """
        Summarise the meeting in at most five bullet points: the decisions and the most \
        important pending tasks with their owner. Nothing else.
        """,
        weighting: RoleWeighting(rules: [
            "product-owner": .init(.decides),
            "tech-lead": .init(.decides, scope: "en lo técnico"),
        ], fallback: .minimal)
    )

    public static let builtIns: [SynthesisFocus] = [.work, .analysis, .brief]
}
