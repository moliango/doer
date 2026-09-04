# Design

## Boundaries

- Kernel: `ExperimentalComposerView` + policies in `ExperimentalComposerDocument.swift`.
- Hosts: Reply / NewTopic / PM only hide/show source; they do not rebuild the kernel.
- Tools: `ComposerMarkdownCoordinator` asks the surface for focused-block raw when replacing polls.

## Contracts

```swift
struct ExperimentalComposerSnapshot: Equatable {
    var markdown: String
    var focusedIndex: Int
    var caret: Int
}

enum ExperimentalComposerHistory {
    static func pushing(_ snapshot: ExperimentalComposerSnapshot, undo: [ExperimentalComposerSnapshot], redo: [ExperimentalComposerSnapshot]) -> (undo: [ExperimentalComposerSnapshot], redo: [ExperimentalComposerSnapshot])
    static func undo(current: ExperimentalComposerSnapshot, undo: [ExperimentalComposerSnapshot], redo: [ExperimentalComposerSnapshot]) -> (current: ExperimentalComposerSnapshot, undo: [ExperimentalComposerSnapshot], redo: [ExperimentalComposerSnapshot])?
}

struct ExperimentalComposerFormatting: Equatable {
    var tools: Set<ComposerMarkdownTool>
}

enum ExperimentalComposerBlockRangePolicy {
    static func markdown(of blocks: [ExperimentalComposerBlock], range: Range<Int>) -> String
    static func replacing(_ blocks: [ExperimentalComposerBlock], range: Range<Int>, with inserted: [ExperimentalComposerBlock]) -> [ExperimentalComposerBlock]
    static func convertingToList(_ blocks: [ExperimentalComposerBlock], range: Range<Int>, ordered: Bool) -> [ExperimentalComposerBlock]
}

enum ExperimentalComposerQuotePolicy {
    static func cycling(_ block: ExperimentalComposerBlock) -> ExperimentalComposerBlock
}
```

## Data flow

1. Structural mutation → push snapshot → mutate `document.blocks` → `rebuild` → restore focus.
2. Typing stays in the live `UITextView` (system undo) until the next structural rebuild.
3. Source toggle: hide experimental, show classic `textView` with current markdown in `.source`; reverse `tryLoad`.
4. Poll: `composerFocusedBlockRaw()` if parseable poll → `composerReplaceFocusedBlock`.

## Compatibility

iOS 15, no SwiftUI pages, `String(localized:)`. Do not change classic editor when the flag is off.
