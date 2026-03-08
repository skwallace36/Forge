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
Edit: ⌘/ (toggle comment), ⌘⌥[/] (move line up/down), ⌃Space (completion), ⌃I (re-indent)
Edit: ⌃⇧K (delete line), ⌘↩ (insert line below), ⌘⇧↩ (insert line above), ⌘D (duplicate line)
Edit: ⌘L (go to line), ⌃⌘E (rename symbol), ⌘⌥S (save all)
Build: ⌘B (build), ⌘R (run), ⌘⇧K (clean), ⌘. (stop)
Search: ⌘F (find in file), ⌘⌥F (find & replace), ⌘⇧F (find in project w/ regex)
View: ⇧⌘P (command palette), ⌘+/⌘- (zoom in/out), ⌃⌘M (toggle minimap), ⌘, (settings)
Mouse: ⌘-click (jump to definition), ⌥-click (Quick Help hover)
Navigator: Enter (rename), Delete (trash)
Escape: dismiss bottom panel and focus editor

## Implementation Phases

Phases 0-6 are **COMPLETE**. Editor polish pass is **IN PROGRESS**. Phase 7 pending.

See PLAN.md for full phase breakdown. Short version:
0. ~~Window + text view + tabs (basic skeleton)~~ ✓
1. ~~tree-sitter syntax highlighting~~ ✓ (Swift via tree-sitter, 12+ languages via regex)
2. ~~File navigator~~ ✓ (icons, FSEvents watcher, context menu, reveal ⌘⇧J)
3. ~~SourceKit-LSP integration~~ ✓ (diagnostics, completion, jump-to-def, hover)
4. ~~Open Quickly (⇧⌘O)~~ ✓
5. ~~Build system~~ ✓ (⌘B build, ⌘R run, ⌘⇧K clean, ⌘. stop, clickable errors)
6. ~~Terminal / Claude panel~~ ✓ (SwiftTerm, shell + claude tabs)
7. Pepper / Hub integration

### Editor Polish (done)
- Minimap code overview (toggleable ⌃⌘M)
- Occurrence highlighting (word under cursor)
- Bracket matching
- Tab drag-to-reorder, middle-click to close, dynamic width, file type icons
- Gutter click-to-select-line
- Binary file detection
- External file change detection
- Large file performance (skip highlighting > 1MB)
- Window state persistence (frame + open tabs)
- Find & Replace (⌘⌥F), Re-indent (⌃I), Delete line (⌃⇧K)
- Insert line above/below (⌘⇧↩/⌘↩), Duplicate line (⌘D)
- Navigator context menu (New File, Rename, Delete, Reveal in Finder, Copy Path)
- 30+ file type icons
- Indent guides (vertical lines at indentation levels)
- Column ruler (configurable: 80, 100, 120 columns)
- Preferences window (⌘,) — font, tab width, view options, save behavior
- Auto-save on app deactivation
- Trailing whitespace trim and trailing newline on save
- Find in Project: regex toggle, case sensitivity, match highlighting
- Save All (⌘⌥S)
- Font size zoom persisted across sessions
- Right inspector panel (⌘⌥0) — file info + LSP Quick Help
- Select Enclosing Brackets (context menu + ⌃⇧⌘→)
- Fuzzy matching in completion popup (camelCase matching)
- Dynamic gutter width for large files (auto-expands for 10K+ lines)
- Error alerts on failed file operations (create, rename, delete, duplicate)
- Save prompts on Close Others/All/Right tab actions
- Command Palette (⇧⌘P) — fuzzy-searchable access to 60+ commands
- Build completion notifications (Glass/Basso sounds, dock bounce, subtitle progress)
- Bracket pair colorization (6 cycling colors, configurable, UTF-16 optimized)
- Copy Relative Path in tab context menu
- Image preview for binary files (inline with dimensions)
- Navigator keyboard shortcuts (Delete=trash, Enter=rename)

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
├── App/           — AppDelegate, ForgeProject, Preferences, PreferencesWindowController
├── Window/        — MainWindowController, MainSplitViewController, EditorContainerViewController
├── Editor/        — ForgeEditorManager, ForgeLayoutManager, GutterView, MinimapView, ForgeDocument, StatusBar, CompletionWindow
├── Tabs/          — TabBar, TabManager
├── Navigator/     — NavigatorViewController (NSOutlineView), FileNode
├── Inspector/     — InspectorViewController (file info + Quick Help)
├── JumpBar/       — JumpBar, OpenQuicklyWindowController, CommandPaletteWindowController
├── LSP/           — LSPClient, JSONRPCConnection, LSPTypes
├── Syntax/        — SyntaxHighlighter (tree-sitter), SimpleHighlighter (regex), Theme
├── Build/         — BuildSystem
├── Bottom/        — BottomPanelViewController, TerminalPanelView, SearchResultsView
└── Util/          — NavigationHistory, FuzzyMatch, FileSystemWatcher
```
