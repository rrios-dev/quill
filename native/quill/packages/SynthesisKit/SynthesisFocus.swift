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
    /// Whether the synthesis ends with the weighting line. Off for a text meant to be
    /// pasted or read at a glance (a chat message, the user's own to-do list), where the
    /// line is noise; the weighting is still applied and stored with the synthesis.
    public var showsWeighting: Bool

    public init(id: String, name: String, objective: String = "", guidance: String, notes: String = "",
                weighting: RoleWeighting = RoleWeighting(), showsWeighting: Bool = true) {
        self.id = id
        self.name = name
        self.objective = objective
        self.guidance = guidance
        self.notes = notes
        self.weighting = weighting
        self.showsWeighting = showsWeighting
    }

    enum CodingKeys: String, CodingKey { case id, name, objective, guidance, notes, weighting, showsWeighting }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        objective = try container.decodeIfPresent(String.self, forKey: .objective) ?? ""
        guidance = try container.decode(String.self, forKey: .guidance)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        weighting = try container.decodeIfPresent(RoleWeighting.self, forKey: .weighting) ?? RoleWeighting()
        showsWeighting = try container.decodeIfPresent(Bool.self, forKey: .showsWeighting) ?? true
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
        objective: "Qué se decidió, quién hace qué y qué queda en el aire",
        guidance: """
        Write the minutes someone will act on. Sections, in this order:
        1. "Decisiones": each point settled by someone with the authority to settle it, \
        one line each, with who settled it.
        2. "Propuestas sin cerrar": what was proposed or leaned towards but not settled, \
        with who proposed it. Never promote one to a decision.
        3. "Tareas": a table with columns Responsable | Tarea | Fecha | Depende de. Fecha \
        as said ("miércoles 15 de octubre"), "sin fecha" if none. Depende de: the person \
        or thing the task waits on, or "—". A request to a named person that got no \
        answer is a row too, its Responsable written "Name (pedido, sin respuesta)".
        4. "Preguntas abiertas": each unanswered question, with who should answer it when \
        the meeting names someone ("eso lo sabrá mejor X").
        5. "Riesgos": what was flagged as a risk or threatens a decision or a date, \
        including an absence or a holiday that touches a date. A status update is not a risk.
        6. "Desacuerdos": who kept a different opinion after a decision.
        Omit a section with nothing in it. No introduction, no conclusion.
        """,
        weighting: RoleWeighting(rules: [
            "product-owner": .init(.decides),
            "tech-lead": .init(.decides, scope: "en lo técnico"),
            "support": .init(.context),
            "client": .init(.request),
            "vendor": .init(.minimal),
        ])
    )

    /// A status round among peers: who is on what, where their work meets, what blocks it.
    public static let weekly = SynthesisFocus(
        id: "weekly",
        name: "Weekly de equipo",
        objective: "En qué está cada uno, dónde se cruzan y qué bloquea",
        guidance: """
        A status meeting among peers. Small talk is often most of it: leave it out, except \
        a remark that reveals a problem at work (a security hole, a failing system), which \
        counts as an incident. Sections, in this order:
        1. "Estado por persona": for each person who reported, "**Name:**" on its own \
        line, then at most three list items: what they finished, what they are on, what \
        comes next. Facts only.
        2. "Cruces": work of two people in this meeting that overlaps or depends on each \
        other. First, the same kind of thing built twice (two form builders, two \
        importers): compare every pair of reports for it. Then one waiting on the other, \
        and two changes to the same brand, country or system. Name both people and say \
        what joins them; mark "posible" what the meeting did not state outright. Never \
        pad this section with links to people outside the meeting; omit it when there \
        are none.
        3. "Bloqueos e incidencias": what is blocked and on whom or what; incidents and \
        security issues mentioned, open or fixed.
        4. "Tareas": a table with columns Responsable | Tarea | Fecha: what someone said \
        they will do. What someone only hopes to do ("a ver si…") is written with \
        "(intención)", for everyone alike.
        Omit a section with nothing in it.
        """
    )

    /// A meeting with whoever commissions the work.
    public static let client = SynthesisFocus(
        id: "client",
        name: "Cliente y requisitos",
        objective: "Qué pide el cliente, qué le prometimos y qué falta aclarar",
        guidance: """
        A meeting with the people who commission the work; the participants list says who \
        they are. Sections, in this order:
        1. "Qué piden": each need or requirement they stated, with who stated it, in their \
        words where the wording matters. A must-have only when they said so; one person's \
        preference stays that person's.
        2. "Qué prometimos": only what our side committed to towards them — a deliverable, \
        a date, an estimate, a follow-up — and who committed. An explicit refusal to \
        commit ("no podemos dar fecha") goes here, said as such.
        3. "Por aclarar": open questions and assumptions nobody confirmed, each with who \
        should answer it.
        4. "Alcance y riesgos": what widens the scope, conflicts with another request or \
        threatens a promise.
        5. "Siguientes pasos": a table with columns Responsable | Paso | Fecha, for both \
        sides, the client's own commitments included. Concrete actions only: a promise \
        that depends on something stays in "Qué prometimos", and a request our side \
        declined is no step for anyone.
        A client's wish becomes a commitment only when someone on our side accepted it. \
        One line per item; omit a section with nothing in it.
        """,
        weighting: RoleWeighting(rules: [
            "product-owner": .init(.decides),
            "tech-lead": .init(.decides, scope: "en lo técnico"),
            "client": .init(.request),
            "vendor": .init(.minimal),
        ])
    )

    /// Only what concerns the user: their own to-do list from the meeting.
    public static let mine = SynthesisFocus(
        id: "mine",
        name: "Lo mío",
        objective: "Qué me toca, qué me piden y qué espero de otros",
        guidance: """
        Only what concerns the user named in the rules above. They may speak little or \
        not at all: what others ask of them by name still counts. Sections, in this order:
        1. "Me toca": what the user committed to or accepted, with the date as said, as a \
        checklist ("- [ ] ").
        2. "Me piden": what someone asked of the user without a clear yes or no, with who \
        asked — the user may have missed it.
        3. "Espero de": what others committed to that the user needs, with the person and \
        the date.
        4. "Me afecta": decisions, risks or changes that touch the user's work, one line each.
        Omit a section with nothing in it. If nothing concerns the user, say so in one \
        line; if the transcript neither has them speaking nor names them, say that instead.
        """,
        showsWeighting: false
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

    /// The meeting as a message for the team chat.
    public static let brief = SynthesisFocus(
        id: "brief",
        name: "Breve",
        objective: "Un mensaje listo para pegar en el chat del equipo",
        guidance: """
        A message the user can paste into the team chat for whoever missed the meeting: \
        one plain opening line saying what the meeting was and how it ended, then at most \
        five list items with the decisions and the pending tasks that matter most, each \
        task with its owner and its date when one was said. Leave out status with no \
        next step. No headings, no table, no closing line.
        """,
        weighting: RoleWeighting(rules: [
            "product-owner": .init(.decides),
            "tech-lead": .init(.decides, scope: "en lo técnico"),
        ], fallback: .minimal),
        showsWeighting: false
    )

    /// In the order the focus menu lists them: the default first, the meeting kinds,
    /// then the readings.
    public static let builtIns: [SynthesisFocus] = [.work, .weekly, .client, .mine, .brief, .analysis]
}
