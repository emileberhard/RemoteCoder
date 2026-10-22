import CoreGraphics

struct TranscriptReadingLayoutCache<Environment: Equatable> {
    private struct Entry {
        let environment: Environment
        let columnWidth: CGFloat
        let layout: TranscriptReadingLayout
    }

    private var entry: Entry?

    mutating func layout(environment: Environment, columnWidth: CGFloat,
                         prepare: () -> TranscriptReadingLayout) -> TranscriptReadingLayout {
        if let entry, entry.environment == environment, entry.columnWidth == columnWidth { return entry.layout }
        let layout = prepare()
        entry = Entry(environment: environment, columnWidth: columnWidth, layout: layout)
        return layout
    }
}
