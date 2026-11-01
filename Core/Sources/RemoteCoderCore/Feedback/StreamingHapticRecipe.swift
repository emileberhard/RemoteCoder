struct StreamingHapticRecipe {
    static let wordCount = 6
    static let sharpnessVariation: Range<Float> = 0.2..<0.4

    let intensity: Float
    let sharpness: Float

    init(punch: Float, variation: Float) {
        intensity = 0.9 * punch
        sharpness = variation + 0.1 * punch
    }

    static func punch(at index: Int) -> Float {
        precondition((0..<wordCount).contains(index))
        return 0.2 + (1 - Float(index) / Float(wordCount - 1)) * 0.8
    }
}
