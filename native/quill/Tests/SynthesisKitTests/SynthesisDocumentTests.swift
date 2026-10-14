import Testing

@testable import SynthesisKit

/// Reading a synthesis into sections the window can draw (`SynthesisDocument`).
@Suite("Synthesis document")
struct SynthesisDocumentTests {
    /// The shape Claude Sonnet 5.5 wrote for the "work" focus in S3.
    static let minutes = """
    ## Decisiones

    - Volcado completo el sábado 18 de octubre.
    - Lanzamiento: iOS el 10 de noviembre y Android el 17.

    ## Tareas

    | Responsable | Tarea | Fecha |
    |---|---|---|
    | Lucía | Compartir el runbook | miércoles 15 de octubre |
    | Marta | Pedir la fecha por escrito | hoy |
    | Lucía | Ampliar el disco | sin fecha |

    ## Riesgos y temas abiertos

    - El volcado puede fallar a mitad.

    ## Desacuerdos

    - **Migración:** Andrés sigue pensando que la replicación es más segura.
    """

    @Test("a minutes synthesis becomes decisions, tasks, risks and disagreements")
    func minutesSections() {
        let document = SynthesisDocument(markdown: Self.minutes)
        #expect(document.sections.map(\.kind) == [.decisions, .tasks, .risks, .disagreements])
        #expect(document.count(of: .decisions) == 2)
        #expect(document.count(of: .tasks) == 3)
        #expect(document.count(of: .risks) == 1)
        #expect(document.count(of: .disagreements) == 1)
    }

    @Test("a task table knows which column is the owner and which the date")
    func taskTableColumns() throws {
        let document = SynthesisDocument(markdown: Self.minutes)
        guard case .table(let table) = try #require(document.sections[1].blocks.first) else {
            Issue.record("expected a table")
            return
        }
        #expect(table.header == ["Responsable", "Tarea", "Fecha"])
        #expect(table.ownerColumn == 0)
        #expect(table.dateColumn == 2)
        #expect(table.rows[1] == ["Marta", "Pedir la fecha por escrito", "hoy"])
    }

    @Test("an analysis: title, numbered topics, bold labels as callouts and subheadings")
    func analysisShape() {
        let document = SynthesisDocument(markdown: """
        # Análisis de la reunión

        ## 1. Migración de la base de datos

        **Contexto aportado por Lucía:** la migración está preparada en pruebas.

        **Opciones sobre la mesa**

        | Opción | Defendida por | Argumento |
        |---|---|---|
        | A. Volcado | Lucía | Evita una semana más. |

        **Decisión (propuesta por Yo):** volcado completo el sábado.

        **Compromisos**
        - Lucía: runbook, miércoles 15.

        ## Lectura

        1. La decisión se tomó sin oír a soporte.
        2. Nadie cuestionó la fecha.
        """)
        #expect(document.title == "Análisis de la reunión")
        #expect(document.sections.map(\.title) == ["Migración de la base de datos", "Lectura"])
        #expect(document.sections.map(\.kind) == [.topic, .insight])
        let blocks = document.sections[0].blocks
        #expect(blocks[0] == .callout(.context, label: "Contexto aportado por Lucía", text: "la migración está preparada en pruebas."))
        #expect(blocks[1] == .subheading("Opciones sobre la mesa"))
        if case .table(let table) = blocks[2] { #expect(table.ownerColumn == 1) } else { Issue.record("expected a table") }
        #expect(blocks[3] == .callout(.decision, label: "Decisión (propuesta por Yo)", text: "volcado completo el sábado."))
        #expect(blocks[4] == .subheading("Compromisos"))
        #expect(blocks[5] == .list(["Lucía: runbook, miércoles 15."], ordered: false))
        #expect(document.sections[1].blocks == [.list(["La decisión se tomó sin oír a soporte.", "Nadie cuestionó la fecha."], ordered: true)])
    }

    @Test("a brief with no headings is one untitled section")
    func briefWithoutHeadings() {
        let document = SynthesisDocument(markdown: """
        * **Migración:** se aprobó el volcado completo.
        * **Proveedor:** no se usa la API antigua.
        """)
        #expect(document.sections.count == 1)
        #expect(document.sections[0].title == nil)
        #expect(document.sections[0].itemCount == 2)
    }

    @Test("a word inside another word does not classify a section")
    func wholeWordPrefixes() {
        #expect(SynthesisDocument.kind(of: "Transacciones con el proveedor") == .topic)
        #expect(SynthesisDocument.kind(of: "Acciones") == .tasks)
        #expect(SynthesisDocument.kind(of: "Open questions") == .risks)
        #expect(SynthesisDocument.kind(of: "Opciones") == .topic)
    }
}
