import QuartzCore

@MainActor
final class ComposerWaveformRenderer {
    let layer = CALayer()
    private let scroll = CALayer()
    private lazy var bars: [CALayer] = {
        (0..<WaveformSamples.capacity).map { _ in
            let bar = CALayer()
            bar.cornerRadius = 1
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            self.scroll.addSublayer(bar)
            return bar
        }
    }()
    private var samples = WaveformSamples()
    private var newest: Int
    private var offset: CGFloat = 0

    init() {
        newest = samples.values.count - 1
        layer.masksToBounds = true
        layer.addSublayer(scroll)
    }

    func layout(size: CGSize, color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bars.forEach { $0.backgroundColor = color }
        if layer.bounds.size != size {
            stop()
            layer.frame = CGRect(origin: .zero, size: size)
            scroll.position.x = size.width - offset - 3
            for age in bars.indices {
                let bar = bars[(newest - age + bars.count) % bars.count]
                bar.isHidden = age >= samples.values.count
                guard !bar.isHidden else { continue }
                let sample = samples.values[samples.values.count - age - 1]
                bar.bounds.size = CGSize(width: 2, height: max(3, sample * size.height * 0.95))
                bar.position = CGPoint(x: offset - CGFloat(age) * 3, y: size.height / 2)
            }
        }
        CATransaction.commit()
    }

    func append(_ level: Float, interval: Duration, glides: Bool) {
        samples.append(level)
        var start = scroll.presentation()?.position.x ?? scroll.position.x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        offset += 3
        if offset >= CGFloat(bars.count) * 3 {
            let distance = CGFloat(bars.count) * 3
            offset -= distance
            start += distance
            bars.forEach { $0.position.x -= distance }
        }
        newest = (newest + 1) % bars.count
        let bar = bars[newest]
        let height = max(3, samples.values[samples.values.count - 1] * layer.bounds.height * 0.95)
        bar.bounds.size = CGSize(width: 2, height: height)
        bar.position = CGPoint(x: offset, y: layer.bounds.height / 2)
        bar.isHidden = false
        let end = layer.bounds.width - offset - (glides ? 3 : 0)
        scroll.position.x = end
        scroll.removeAnimation(forKey: "scroll")
        if glides {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = start
            animation.toValue = end
            animation.duration = interval / .seconds(1)
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            scroll.add(animation, forKey: "scroll")
        }
        CATransaction.commit()
    }

    func stop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let position = scroll.presentation()?.position { scroll.position = position }
        scroll.removeAnimation(forKey: "scroll")
        CATransaction.commit()
    }
}
