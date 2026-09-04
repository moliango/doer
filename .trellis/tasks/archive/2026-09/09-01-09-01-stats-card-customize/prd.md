# Fix Me stats card customization

## Problem

Tapping **自定义** on the Me dashboard stats card opens the editor, but toggling metrics does nothing. The table is locked in editing mode for reorder handles, UIKit therefore:

1. Ignores row taps (`allowsSelectionDuringEditing` defaults to `false`)
2. Hides `accessoryType` checkmarks, so selected metrics are indistinguishable from hidden ones

Users cannot add or remove stats. Reorder of already-selected items still works, which makes the screen look functional while customization is dead.

## Scope

- Restore tap-to-toggle and visible checkmarks in `ProfileStatsEditorViewController`
- Keep reorder, minimum-two guard, layout switch, reset, and persistence
- Keep the Me card customize button tappable above the horizontal stats strip

## Acceptance

- Logged-in Me stats card **自定义** opens the editor
- Tapping a row adds or removes that metric and the checkmark updates immediately
- At least two metrics remain; attempting to drop below two shows the existing alert
- Dragging reorder handles still changes order among selected metrics
- Layout (网格 / 横向) and 重置 still persist and update the card
- Returning to Me shows the chosen metrics and layout
