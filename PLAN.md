# Forge — Native Mac Code Editor

A native AppKit code editor built around AI-assisted development. Xcode's navigation UX, SourceKit-LSP intelligence, Claude as the primary interaction model. No Electron, no web views, no bullshit.

## Why

Stuart's actual workflow is 95% Claude Code in a terminal, with Xcode running as an expensive indexer in the background. The editor he needs:
- Looks and navigates like Xcode (muscle memory, keyboard shortcuts, layout)
- Has Claude built in as a first-class panel, not a plugin
- Shells out to `xcodebuild` / `simctl` / `sourcekit-lsp` for the heavy lifting
- Integrates Pepper (runtime app inspection), Hub (task tracking), Casey (PR management)
- Doesn't waste 15GB on disk or 32GB of system support files

## Architecture

### Tech Stack

- **Language**: Swift (100%)
- **UI Framework**: AppKit (native, no SwiftUI for the chrome — SwiftUI for leaf views where convenient)
- **Text Engine**: TextKit 2 (NSTextView with NSTextContentStorage + NSTextLayoutManager)
- **Syntax Highlighting**: tree-sitter (via C API, Swift wrapper) — same engine as Zed, Nova, Neovim
- **Language Intelligence**: SourceKit-LSP (Apple's official LSP server, ships with Xcode toolchain)
- **Build System**: shells out to `xcodebuild`
- **Package Management**: SPM (swift package CLI)
- **Process Management**: Foundation.Process for all subprocess work

### Why AppKit, Not SwiftUI

- NSTextView is battle-tested for code editing. SwiftUI's TextEditor is not.
- NSSplitView gives us the exact resizable pane behavior Xcode has.
- NSOutlineView for the file navigator — handles 10k+ files without virtualization hacks.
- NSTabView / custom tab bar — trivial in AppKit, painful in SwiftUI.
- Menu bar, key equivalents, responder chain — all native AppKit concepts.
- SwiftUI can be hosted inside AppKit views (NSHostingView) for individual panels where it makes sense (Hub dashboard, Pepper inspector).

### Window Layout

```
┌─ Toolbar ─────────────────────────────────────────────────────────┐
│ [◀ ▶] [Stop] [Run]        Jump Bar: Fi > Coord > HealthCoord.sw  │
├──────────┬─────────────────────────────────┬──────────────────────┤
│ Navigator│ Tab Bar: [HealthCoord] [HealthVM]│                     │
│          ├─────────────────────────────────┤  Inspector (optional)│
│ ▼ Fi/    │                                 │                     │
│   ▶ Coor │  Editor Area                    │  (Pepper, Quick Help │
│   ▶ Serv │                                 │   file info, etc.)  │
│   ▶ View │  (TextKit 2 NSTextView          │                     │
│ ▼ Health │   with tree-sitter highlighting │                     │
│   ▶ View │   and LSP diagnostics)          │                     │
│   ▶ Mode │                                 │                     │
│          │                                 │                     │
├──────────┴─────────────────────────────────┴──────────────────────┤
│ Bottom Panel                                                       │
│ [Claude] [Terminal] [Build Log] [Search Results]                   │
│                                                                    │
│ > fix the crash in HealthCoordinator                               │
│ Reading HealthCoordinator.swift...                                 │
│ Found the issue — stop() is being called twice...                  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Panel System

Four panel positions, all collapsible and resizable:

| Position | Default Content | Toggle |
|----------|----------------|--------|
| **Left** (Navigator) | File tree, symbol list, find results | ⌘0 |
| **Center** (Editor) | Code editor with tabs | Always visible |
| **Right** (Inspector) | Pepper state, Quick Help, file info | ⌘⌥0 |
| **Bottom** (Console) | Claude, terminal, build log, search | ⌘⇧Y |

## Keyboard Shortcuts (Xcode-Compatible)

### Navigation
| Shortcut | Action |
|----------|--------|
| ⇧⌘O | Open Quickly (fuzzy file/symbol search) |
| ⌘⇧J | Reveal in Navigator |
| ⌃⌘← / ⌃⌘→ | Go back / forward in navigation history |
| ⌘1-5 | Switch navigator tabs (Files, Symbols, Find, Issues, Tests) |
| ⌘0 | Toggle navigator |
| ⌘⌥0 | Toggle inspector |
| ⌘⇧Y | Toggle bottom panel |

### Tabs (browser-style, single row)
| Shortcut | Action |
|----------|--------|
| ⌘⇧[ | Previous tab |
| ⌘⇧] | Next tab |
| ⌘W | Close tab |
| ⌘⇧T | Reopen last closed tab |
| ⌘1-9 (with modifier?) | Jump to tab N (TBD — avoid conflict with nav tabs) |

Tab behavior:
- Single click in navigator → opens/focuses tab for that file
- ⇧⌘O → opens in current tab (⌥ to open in new tab)
- Modified files show dot indicator
- Drag to reorder
- No "ghost" tabs, no "recently opened" phantom tabs
- No window tabs vs editor tabs distinction. One level. That's it.

### Editor
| Shortcut | Action |
|----------|--------|
| ⌃⌘ click / ⌘ click | Jump to definition |
| ⌥ click | Quick Help popup |
| ⌘F | Find in file |
| ⌘⇧F | Find in project (switches to Find navigator) |
| ⌘⌥F | Find and replace in file |
| ⌃⌘E | Edit All in Scope (LSP rename) |
| ⌘/ | Toggle comment |
| ⌘⌥[ / ⌘⌥] | Move line up/down |
| ⌃I | Re-indent selection |
| ⌘⌥← / ⌘⌥→ | Fold/unfold |

### Build & Run
| Shortcut | Action |
|----------|--------|
| ⌘B | Build (xcodebuild) |
| ⌘R | Run (build + launch sim) |
| ⌘. | Stop/cancel |
| ⌘⇧K | Clean build |

## Core Components

### 1. Document Model

```swift
// Each open file is a Document
class ForgeDocument {
    let url: URL
    let language: Language          // tree-sitter language
    var textStorage: NSTextContentStorage
    var syntaxTree: TSTree?         // tree-sitter parse tree
    var isModified: Bool
    var undoManager: UndoManager

    // LSP state for this file
    var diagnostics: [LSPDiagnostic]
    var version: Int                // LSP document version
}
```

### 2. Editor View (TextKit 2)

```swift
class ForgeEditorView: NSView {
    let textView: NSTextView          // TextKit 2 mode
    let gutterView: GutterView        // line numbers, breakpoints, fold markers
    let minimapView: MinimapView?     // optional code overview

    var document: ForgeDocument?
    var completionWindow: CompletionWindow?

    // tree-sitter incremental parsing on every edit
    // LSP didChange notifications debounced (50ms)
    // Diagnostic underlines from LSP publishDiagnostics
}
```

### 3. SourceKit-LSP Client

```swift
class LSPClient {
    let process: Process              // sourcekit-lsp subprocess
    let connection: JSONRPCConnection // stdin/stdout JSON-RPC

    // Core LSP methods we need:
    func initialize(rootURI: URL) async throws -> InitializeResult
    func didOpen(document: ForgeDocument)
    func didChange(document: ForgeDocument, changes: [TextEdit])
    func completion(at: Position) async throws -> [CompletionItem]
    func definition(at: Position) async throws -> [Location]
    func references(at: Position) async throws -> [Location]
    func hover(at: Position) async throws -> HoverResult
    func rename(at: Position, newName: String) async throws -> WorkspaceEdit
    func diagnostics(for: URL) -> [Diagnostic]  // from publishDiagnostics
    func documentSymbols(for: URL) async throws -> [DocumentSymbol]
    func workspaceSymbol(query: String) async throws -> [SymbolInformation]
}
```

### 4. Tab Manager

```swift
class TabManager {
    var tabs: [Tab]                   // ordered list
    var selectedIndex: Int
    var recentlyClosed: [Tab]         // for ⌘⇧T

    struct Tab {
        let document: ForgeDocument
        var title: String             // filename
        var isModified: Bool          // shows dot
        var isPinned: Bool
    }

    func selectPrevious()             // ⌘⇧[
    func selectNext()                 // ⌘⇧]
    func close(at: Int)               // ⌘W
    func reopenLast()                 // ⌘⇧T
    func openOrFocus(url: URL)        // from navigator click or Open Quickly
}
```

### 5. Navigator (File Tree)

```swift
class FileNavigator: NSOutlineView {
    var rootURL: URL                  // project root
    var fileTree: FileNode            // lazy-loaded directory tree

    // Watches filesystem for changes (DispatchSource.makeFileSystemObjectSource)
    // Respects .gitignore
    // Groups by Xcode project structure if .xcworkspace exists
    // Otherwise plain filesystem tree
}
```

### 6. Project Model

```swift
class ForgeProject {
    let rootURL: URL
    let workspaceURL: URL?            // .xcworkspace if it exists

    var openDocuments: [URL: ForgeDocument]
    var tabManager: TabManager
    var lspClient: LSPClient
    var buildSystem: BuildSystem       // wraps xcodebuild
    var navigator: FileNavigator
    var navigationHistory: NavigationHistory  // for ⌃⌘←/→
}
```

### 7. Build System

```swift
class BuildSystem {
    let workspaceURL: URL
    var activeProcess: Process?

    // All methods shell out to xcodebuild
    func build(scheme: String, destination: String) async -> BuildResult
    func run(scheme: String, destination: String) async -> Process
    func clean() async
    func stop()

    // Parse xcodebuild output for:
    // - Compile progress (file counts)
    // - Errors/warnings (file:line:col: error: message)
    // - Link phase
    // - Success/failure
}
```

### 8. Bottom Panel — Claude Integration

```swift
class ClaudePanel: NSView {
    // Embeds Claude Code or communicates with it
    // Options:
    // A) Embed a terminal emulator running `claude` (simplest, most compatible)
    // B) Use Claude API directly (more integrated but loses all the skills/tools)
    // C) Use claude's --output-format and pipe I/O (middle ground)

    // For v1: embed a terminal. SwiftTerm or similar.
    // The terminal runs `claude --dangerously-skip-permissions` in the project dir.
    // Editor can send text to it (e.g., "fix the error on line 42 of {current file}")
}
```

## Implementation Phases

### Phase 0: Skeleton (Day 1, first 2 hours)
**Goal**: Window opens, shows a text file, looks like Xcode.

- [ ] Create Swift Package (not Xcode project — eat our own dogfood)
- [ ] AppDelegate + main window with NSSplitView (3-pane)
- [ ] Left pane: placeholder NSOutlineView
- [ ] Center pane: NSTextView (TextKit 2) with basic text loading
- [ ] Bottom pane: placeholder (empty NSView)
- [ ] Tab bar above editor (custom NSView, not NSTabView)
- [ ] Jump bar above tab bar (breadcrumb path)
- [ ] Open a .swift file and display it
- [ ] Basic keyboard shortcuts (⌘W, ⌘⇧[, ⌘⇧])
- [ ] Window remembers size/position

### Phase 1: Syntax Highlighting (Hours 2-3)
**Goal**: Swift code is colorized.

- [ ] Integrate tree-sitter C library
- [ ] Add tree-sitter-swift grammar
- [ ] Build highlight query for Swift (can port from Zed or Neovim)
- [ ] Apply highlights as NSTextView attributes
- [ ] Incremental re-parse on edit (tree-sitter handles this natively)
- [ ] Line numbers in gutter view
- [ ] Current line highlight
- [ ] Theme system (start with Xcode Default Dark)

### Phase 2: File Navigator (Hours 3-4)
**Goal**: Browse project files, open them in tabs.

- [ ] NSOutlineView with lazy directory loading
- [ ] .gitignore filtering
- [ ] File icons (NSWorkspace.icon(forFile:) or SF Symbols by extension)
- [ ] Single click opens/focuses tab
- [ ] ⌘⇧J reveals current file
- [ ] Filesystem watching for external changes
- [ ] Xcode project group structure (parse .pbxproj for group ordering) — stretch goal

### Phase 3: LSP Integration (Hours 4-6)
**Goal**: Autocomplete, jump to definition, diagnostics.

- [ ] Launch sourcekit-lsp subprocess
- [ ] JSON-RPC over stdin/stdout
- [ ] Initialize with project root
- [ ] textDocument/didOpen, didChange, didClose lifecycle
- [ ] Completion popup (NSWindow positioned near cursor)
- [ ] Jump to definition (⌃⌘ click)
- [ ] Hover for Quick Help (⌥ click)
- [ ] Diagnostic underlines (errors red, warnings yellow)
- [ ] Go back/forward navigation history (⌃⌘←/→)

### Phase 4: Open Quickly (Hour 6)
**Goal**: ⇧⌘O fuzzy search.

- [ ] Modal overlay (like Xcode's Open Quickly)
- [ ] Index all files in project
- [ ] Fuzzy matching algorithm (subsequence match with scoring)
- [ ] Show file path, icon, match highlights
- [ ] Enter opens in current tab, ⌥Enter opens in new tab
- [ ] Also search LSP workspace symbols (functions, classes)

### Phase 5: Build System (Next session)
- [ ] ⌘B triggers xcodebuild in bottom panel
- [ ] Parse output for progress, errors, warnings
- [ ] Click error → jumps to file:line in editor
- [ ] ⌘R builds and launches simulator
- [ ] ⌘. kills build/run

### Phase 6: Terminal / Claude Panel (Next session)
- [ ] Embed terminal emulator (SwiftTerm) in bottom panel
- [ ] Auto-launch claude in project directory
- [ ] Editor → Claude: send selected code, current file context
- [ ] Claude → Editor: open file at line (deep link protocol)

### Phase 7: Pepper / Hub Integration (Future)
- [ ] Right panel shows Pepper runtime state
- [ ] Hub task list in status bar or side panel
- [ ] Build status from Hub

## File Structure

```
Forge/
├── Package.swift
├── Sources/
│   └── Forge/
│       ├── main.swift
│       ├── App/
│       │   ├── AppDelegate.swift
│       │   ├── ForgeProject.swift
│       │   └── Preferences.swift
│       ├── Window/
│       │   ├── MainWindowController.swift
│       │   ├── MainSplitViewController.swift
│       │   └── ToolbarController.swift
│       ├── Editor/
│       │   ├── ForgeEditorView.swift
│       │   ├── ForgeTextView.swift       (NSTextView subclass)
│       │   ├── GutterView.swift
│       │   ├── CompletionWindow.swift
│       │   └── ForgeDocument.swift
│       ├── Tabs/
│       │   ├── TabBar.swift
│       │   ├── TabBarItem.swift
│       │   └── TabManager.swift
│       ├── Navigator/
│       │   ├── FileNavigator.swift
│       │   ├── FileNode.swift
│       │   ├── SymbolNavigator.swift
│       │   └── FindNavigator.swift
│       ├── JumpBar/
│       │   ├── JumpBar.swift
│       │   └── OpenQuickly.swift
│       ├── LSP/
│       │   ├── LSPClient.swift
│       │   ├── JSONRPCConnection.swift
│       │   ├── LSPTypes.swift            (Position, Range, Diagnostic, etc.)
│       │   └── LSPDocumentManager.swift
│       ├── Syntax/
│       │   ├── TreeSitterClient.swift
│       │   ├── SyntaxHighlighter.swift
│       │   ├── Theme.swift
│       │   └── Languages/
│       │       └── SwiftLanguage.swift
│       ├── Build/
│       │   ├── BuildSystem.swift
│       │   └── BuildOutputParser.swift
│       ├── Bottom/
│       │   ├── BottomPanelController.swift
│       │   ├── ClaudePanel.swift
│       │   ├── TerminalPanel.swift
│       │   └── BuildLogPanel.swift
│       └── Util/
│           ├── KeyboardShortcuts.swift
│           ├── NavigationHistory.swift
│           └── FuzzyMatch.swift
├── Resources/
│   ├── Themes/
│   │   └── XcodeDefault.json
│   └── Queries/
│       └── swift-highlights.scm    (tree-sitter highlight queries)
└── Libraries/
    └── (tree-sitter C sources, vendored or as package dep)
```

## Dependencies

| Dependency | Purpose | Integration |
|------------|---------|-------------|
| tree-sitter | Syntax parsing | C library, Swift wrapper (SwiftTreeSitter package exists) |
| tree-sitter-swift | Swift grammar | C library, vendored |
| sourcekit-lsp | Language intelligence | Subprocess (ships with Xcode toolchain at `xcrun sourcekit-lsp`) |
| SwiftTerm | Terminal emulator | SPM package (for Claude/terminal panel) |
| xcodebuild | Build system | Subprocess |

No Electron. No web views. No React. No npm. Pure Swift + AppKit + C (tree-sitter).

## Design Decisions

### Why TextKit 2, not custom rendering?

NSTextView with TextKit 2 gives us:
- Native text input (IME, dictation, accessibility, spell check)
- Undo/redo
- Selection, drag-and-drop
- Find bar (built-in)
- Printing
- RTL text (if ever needed)

The alternative (custom Metal/Core Graphics rendering like Zed) gives better performance for huge files but is 10x the work. TextKit 2 is good enough for files under 100k lines, which is everything in practice.

### Why tree-sitter, not SourceKit for highlighting?

SourceKit semantic highlighting requires compilation. tree-sitter works instantly on the raw text, handles partial/broken code gracefully, and updates incrementally. Use tree-sitter for highlighting, SourceKit-LSP for intelligence (completion, jump-to-def, diagnostics).

### Tab behavior: single-click in navigator

Single click in file navigator → open/focus that file's tab. If the file isn't open, create a new tab. No "preview" or "temporary" tab concept. Every opened file gets a real tab. This is simpler and matches the browser mental model.

### Claude integration: terminal first

v1 embeds a terminal running `claude`. This gets us 100% of existing functionality (all skills, tools, permissions) without reimplementing anything. Later versions can add deeper integration (editor ↔ Claude communication protocol, inline diff review, etc.).

## Open Questions

1. **Project detection**: Open a directory? Open a .xcworkspace? Both? Start with "open directory" and detect workspace automatically.
2. **Multiple windows**: One window per project? Or single-window with project switcher? Start with one window per project.
3. **Settings/preferences**: Where to store? `~/Library/Application Support/Forge/` seems right. Start minimal — just theme and font size.
4. **Icon**: Need an app icon. Anvil? Hammer? Forge flame?
5. **Name**: "Forge" — good? Available? (Not on Mac App Store but we're not shipping there anyway.)

## Success Criteria (End of Day 1)

A window that:
- Opens `~/Developer/ios`
- Shows the file tree in the left pane
- Opens .swift files in tabs with syntax highlighting
- Has working ⌘⇧[, ⌘⇧], ⌘W for tabs
- Has ⇧⌘O for fuzzy file search
- Has a bottom panel (even if just a placeholder)
- Feels fast and native

That's enough to start replacing Xcode for code reading. LSP intelligence comes next and makes it usable for editing.
