# Forge — Native Mac Code Editor

Read `PLAN.md` for the full architecture, component design, and implementation phases.

## Quick Reference

- **Language**: Swift, AppKit (no SwiftUI for window chrome)
- **Text engine**: TextKit 2 (NSTextView)
- **Syntax**: tree-sitter (C library, Swift wrapper)
- **Intelligence**: SourceKit-LSP (subprocess via `xcrun sourcekit-lsp`)
- **Build**: SPM — `swift build` / `swift run`
- **No Xcode project** — we're building the replacement, not using the thing we're replacing

## Build & Run

```bash
cd ~/Developer/Forge
swift build
swift run Forge
# or
swift run Forge ~/Developer/ios   # open a project directory
```

## Architecture

AppKit window with NSSplitView. Four panel positions:
- **Left**: File navigator (NSOutlineView)
- **Center**: Editor (TextKit 2 NSTextView) with tab bar above
- **Right**: Inspector (optional — Pepper, Quick Help)
- **Bottom**: Claude terminal, build log, search results

## Keyboard Shortcuts (Xcode-compatible)

Navigation: ⇧⌘O (Open Quickly), ⌘⇧J (reveal in navigator), ⌃⌘←/→ (back/forward)
Tabs: ⌘⇧[ / ⌘⇧] (prev/next), ⌘W (close), ⌘⇧T (reopen)
Panels: ⌘0 (navigator), ⌘⌥0 (inspector), ⌘⇧Y (bottom)
Build: ⌘B (build), ⌘R (run), ⌘. (stop)

## Implementation Phases

Phases 0-1 are **COMPLETE**. Currently working on: **Phase 2+ polish and Phase 3**

See PLAN.md for full phase breakdown. Short version:
0. ~~Window + text view + tabs (basic skeleton)~~ ✓
1. ~~tree-sitter syntax highlighting~~ ✓ (SwiftTreeSitter + Xcode Dark theme + current line highlight)
2. File navigator (basic version done — needs .gitignore, file watching)
3. SourceKit-LSP integration
4. Open Quickly (⇧⌘O)
5. Build system (xcodebuild)
6. Terminal / Claude panel
7. Pepper / Hub integration

## Autonomous Development Mode

When Stuart says "keep going", "continue", "start phase N", or similar — work autonomously through the phases above. Follow this loop:

### The Loop
1. **Pick the next incomplete item** from the phase list above, or fix the most impactful bug/UX issue
2. **Read the relevant PLAN.md section** for design context
3. **Implement it** — write the code, keep it minimal and correct
4. **Build it** — run `swift build` and fix all errors before moving on
5. **Test it** — launch briefly with `swift run Forge ~/Developer/Forge &` to verify it starts, then kill it
6. **Update CLAUDE.md** — mark completed items, update "currently working on"
7. **Commit** — commit with a clear message describing what was added
8. **Repeat** — go to step 1

### Priorities (what matters most)
- **Correctness over features** — a working subset beats a broken superset
- **Feel native** — if it doesn't feel like a Mac app, fix that before adding features
- **Dark theme** — Xcode Default Dark colors everywhere, no bright white panels
- **Keyboard-driven** — every action should have a shortcut, mouse is optional
- **Performance** — no spinning beachball, ever. Lazy-load everything, async for I/O

### What to work on when between phases
- Polish existing UX (scroll behavior, resize handles, selection highlighting)
- Fix any visual glitches (misaligned gutters, clipped text, wrong colors)
- Add missing keyboard shortcuts from the PLAN.md table
- Improve file navigator (icons, expand/collapse state, scroll to reveal)
- Harden edge cases (empty files, binary files, huge files, missing directories)

### Don't
- Don't ask for permission between items — just keep building
- Don't add SwiftUI for window chrome — AppKit only
- Don't add dependencies unless PLAN.md calls for them (tree-sitter, SwiftTerm)
- Don't refactor working code unless it's blocking the next feature
- Don't write tests yet — the API is still changing too fast

## Code Style

- AppKit naming conventions (delegate, dataSource, etc.)
- Swift concurrency (async/await) for LSP and subprocess I/O
- No force unwraps except IBOutlet-style patterns
- Trailing commas in multi-line argument lists

## Key Files

```
Sources/Forge/
├── App/           — AppDelegate, ForgeProject, Preferences
├── Window/        — MainWindowController, MainSplitViewController
├── Editor/        — ForgeTextView (NSTextView subclass), GutterView, ForgeDocument
├── Tabs/          — TabBar, TabManager
├── Navigator/     — FileNavigator (NSOutlineView), FileNode
├── JumpBar/       — JumpBar, OpenQuickly
├── LSP/           — LSPClient, JSONRPCConnection
├── Syntax/        — TreeSitterClient, SyntaxHighlighter, Theme
├── Build/         — BuildSystem, BuildOutputParser
├── Bottom/        — BottomPanelController, ClaudePanel
└── Util/          — KeyboardShortcuts, NavigationHistory, FuzzyMatch
```
