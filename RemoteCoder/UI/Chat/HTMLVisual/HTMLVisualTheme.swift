import Foundation

extension HTMLVisualTheme {
    nonisolated var variables: [String: String] {
        ["--rc-font-family": "-apple-system, system-ui, sans-serif",
         "--rc-font-size": "\(fontSize)px", "--rc-text": text,
         "--rc-secondary-text": secondaryText, "--rc-background": background,
         "--rc-surface": surface, "--rc-accent": accent,
         "--rc-color-scheme": isDark ? "dark" : "light"]
    }

    nonisolated static let baseCSS = """
        html { height: auto !important; min-height: 0 !important; background: transparent !important; overflow: clip !important; }
        body { display: flow-root; height: auto !important; min-height: 0 !important; margin: 0;
          background: transparent !important; color: var(--rc-text);
          font-family: var(--rc-font-family); font-size: var(--rc-font-size);
          color-scheme: var(--rc-color-scheme); }
        *, *::before, *::after { box-sizing: border-box; }
        input, button, select, textarea { font: inherit; accent-color: var(--rc-accent); }
        a { color: var(--rc-accent); }
        img, video:not([controls]) { cursor: pointer; -webkit-tap-highlight-color: transparent; }
        """
}
