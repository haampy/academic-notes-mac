import SwiftUI

struct CaptionLine: Equatable {
    let line: TranscriptLine
    let confirmedText: String?

    init(line: TranscriptLine, confirmedText: String?) {
        self.line = line
        self.confirmedText = confirmedText
    }

    init(_ line: TranscriptLine) {
        self.init(line: line, confirmedText: line.text)
    }
}

struct TranscriptView: NSViewRepresentable {
    @ObservedObject var session: Session
    let typography: CaptionTypography

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 16, height: 13)
            text.textContainer?.lineFragmentPadding = 0
            text.setAccessibilityLabel("字幕")
        }
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator(typography: typography) }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        // Reading AppKit's text layout while SwiftUI is sizing the footer can re-enter layout.
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak text] in
            if let text { coordinator.update(text, session: session, typography: typography) }
        }
    }

    @MainActor final class Coordinator {
        private var transcriptID: UUID?
        private var closedCount = 0
        private var tailStart = 0
        private var visibleTail: [CaptionLine] = []
        private var style: TextStyle

        init(typography: CaptionTypography) {
            style = TextStyle(typography)
        }

        // Tab stops and a hanging indent give each sentence two columns while keeping
        // the whole transcript selectable, including selections spanning several lines.
        private struct TextStyle {
            let body: NSFont
            let timestamp: NSFont
            let paragraph: NSParagraphStyle

            init(_ typography: CaptionTypography) {
                body = .systemFont(ofSize: typography.bodySize)
                timestamp = .monospacedSystemFont(ofSize: typography.timestampSize, weight: .regular)
                let timeWidth = ceil(("0000:00" as NSString).size(withAttributes: [.font: timestamp]).width)
                let textStart = timeWidth + round(8 * typography.scale)
                let paragraph = NSMutableParagraphStyle()
                paragraph.tabStops = [NSTextTab(textAlignment: .right, location: timeWidth),
                                      NSTextTab(textAlignment: .left, location: textStart)]
                paragraph.headIndent = textStart
                paragraph.lineSpacing = 2 * typography.scale
                paragraph.paragraphSpacing = 7 * typography.scale
                paragraph.baseWritingDirection = .leftToRight
                self.paragraph = paragraph
            }
        }

        func update(_ text: NSTextView, session: Session, typography: CaptionTypography) {
            guard let storage = text.textStorage else { return }
            let noteID = session.transcriptID
            let reset = transcriptID != noteID
            let resized = style.body.pointSize != typography.bodySize
            guard reset || resized || closedCount != session.transcript.count || visibleTail != session.captionTail else { return }
            let selection = text.selectedRange()
            let following = selection.length == 0 && text.bounds.maxY - text.visibleRect.maxY < style.body.pointSize * 1.5
            let anchor = resized && !reset && !following ? readingAnchor(in: text) : nil
            if reset {
                transcriptID = noteID
                closedCount = 0
                tailStart = 0
            }

            // Ordinary updates only typeset newly closed lines and the short revisable tail.
            storage.beginEditing()
            if resized {
                let next = TextStyle(typography)
                let closedRange = NSRange(location: 0, length: tailStart)
                storage.enumerateAttribute(.font, in: closedRange) { old, range, _ in
                    let font = (old as? NSFont) == style.timestamp ? next.timestamp : next.body
                    storage.addAttribute(.font, value: font, range: range)
                }
                storage.addAttribute(.paragraphStyle, value: next.paragraph, range: closedRange)
                style = next
            }
            storage.deleteCharacters(in: NSRange(location: tailStart, length: storage.length - tailStart))
            for line in session.transcript.dropFirst(closedCount) {
                append(CaptionLine(line), to: storage)
            }
            tailStart = storage.length
            closedCount = session.transcript.count
            visibleTail = session.captionTail
            for line in visibleTail { append(line, to: storage) }
            storage.endEditing()

            if !reset && selection.length > 0 {
                let start = min(selection.location, storage.length)
                let end = min(NSMaxRange(selection), storage.length)
                let range = NSRange(location: start, length: end - start)
                if text.selectedRange() != range { text.setSelectedRange(range) }
            }
            if reset || following || anchor != nil {
                // Wait for SwiftUI to resize both the footer and the text viewport.
                // TextKit can still be using the old document height during this update.
                DispatchQueue.main.async { [weak self, weak text] in
                    guard let self, let text, self.transcriptID == noteID,
                          self.style.body.pointSize == typography.bodySize else { return }
                    if let anchor {
                        guard let y = self.characterY(anchor.index, in: text) else { return }
                        text.scroll(NSPoint(x: text.visibleRect.minX, y: y - anchor.offset))
                    } else {
                        text.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
                    }
                }
            }
        }

        // Preserve the first visible line when a font change rewraps earlier paragraphs.
        // Pixel offsets alone stop identifying the same passage after a reflow.
        private func readingAnchor(in text: NSTextView) -> (index: Int, offset: CGFloat)? {
            let top = text.visibleRect.minY
            let index = text.characterIndexForInsertion(at: NSPoint(x: text.textContainerOrigin.x, y: top + 1))
            guard let y = characterY(index, in: text) else { return nil }
            return (index, y - top)
        }

        private func characterY(_ index: Int, in text: NSTextView) -> CGFloat? {
            guard let manager = text.textLayoutManager, let content = manager.textContentManager,
                  let location = content.location(content.documentRange.location, offsetBy: index),
                  let end = content.location(location, offsetBy: 1),
                  let range = NSTextRange(location: location, end: end) else { return nil }
            manager.ensureLayout(for: range)
            guard let fragment = manager.textLayoutFragment(for: location),
                  let line = fragment.textLineFragment(for: location, isUpstreamAffinity: false) else { return nil }
            return text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
        }

        private func append(_ row: CaptionLine, to storage: NSTextStorage) {
            let line = row.line
            let start = storage.length
            let stamp = row.confirmedText == nil ? "" : line.time
            let prefix = (start == 0 ? "" : "\n") + "\t" + stamp + "\t"
            storage.append(NSAttributedString(string: prefix + line.text, attributes: [
                .font: style.body, .foregroundColor: NSColor.labelColor, .paragraphStyle: style.paragraph
            ]))
            let bodyStart = start + prefix.utf16.count
            if !stamp.isEmpty {
                storage.addAttributes([.font: style.timestamp,
                                       .foregroundColor: NSColor.secondaryLabelColor],
                                      range: NSRange(location: bodyStart - 1 - stamp.utf16.count, length: stamp.utf16.count))
            }
            if row.confirmedText != line.text {
                let confirmed = row.confirmedText ?? ""
                let length = line.text.hasPrefix(confirmed) ? confirmed.utf16.count : 0
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                     range: NSRange(location: bodyStart + length, length: line.text.utf16.count - length))
            }
        }
    }
}
