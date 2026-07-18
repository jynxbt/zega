# zega roadmap (Code Bubbles / Bubbles.pdf)

Based on Bragdon et al., *Code Bubbles* (ICSE 2010), and the current zega codebase.

## Done (core metaphor)

- [x] Infinite pan/zoom virtual canvas
- [x] Bubbles as editable fragments (light chrome)
- [x] No overlap / bubble spacer
- [x] Working-set proximity groups + color halos
- [x] File-halos (group by document) + project folder open
- [x] Folder icons + breadcrumb navigate-in-place
- [x] Horizontal reflow (view-only)
- [x] Document-backed Zig/Rust fragments, outline → bubbles
- [x] Edit, save, undo; JetBrains Mono; syntax highlight
- [x] Hover scale; blank-canvas context menu (create new file)
- [x] **Draw connections (orthogonal arrows, paper 1-M)**

---

## Phase 1 — Navigation & relationships (§2, §5–6)

Paper: open callee next to caller; rectilinear arrows; find references → bubble stacks.

- [x] **Draw connections** (orthogonal arrows, paper 1-M)
- [ ] Open definition (click call → new bubble + link)
- [ ] Find all references → stack bubble; expand in place
- [ ] Popup project search (substring over symbols/files)
- [ ] Keyboard focus cycle between bubbles
- [ ] Hover preview of containing method

## Phase 2 — Bubble UX completeness (§5–6.1)

- [ ] Vertical code elision (collapse / expand blocks)
- [ ] Resize bubble (border drag) → live reflow
- [ ] Breadcrumb bar (module · type · symbol; peer navigation)
- [ ] Bud new function/method into a growing bubble
- [ ] Close / pin bubbles; polish empty & new-file UX
- [ ] Expand context menu (open file, open def, note, …)

## Phase 3 — Working sets & interruption recovery (§6.3–6.4)

- [ ] Name working sets; explicit split/merge
- [ ] Persist/reload groups (workspace file)
- [ ] Workspace bar (bird’s-eye map, pan to region)
- [ ] Labeled task sections on the bar
- [ ] Task shelf (save / close / reopen layouts)
- [ ] Search groups by name or contents

## Phase 4 — Language services (Zig / Rust)

Paper used Eclipse; zega targets **zls** + **rust-analyzer**.

- [ ] Robust outline (tree-sitter or equivalent)
- [ ] Goto-def / references / hover via LSP
- [x] Diagnostics (error box under bubble; structure + `zig ast-check`)
- [x] Bracket pair colorization (nested rainbow + active pair at caret)
- [x] Completions v1 (local keywords/builtins/symbols; file + working-set)
- [ ] Completions via zls (LSP)
- [ ] Format (`zig fmt`, `rustfmt`)

## Phase 5 — Heterogeneous bubbles (§6.2)

- [ ] Note bubbles (richer edit, sticky)
- [ ] Flag bubbles (icons / labels)
- [ ] Docs bubbles (markdown / doc comments)
- [x] Mini terminal bubbles (PTY/zsh, context menu, many independent)
- [ ] Optional: web / issue bubbles later

## Phase 6 — Debugging with bubbles (§6.5)

- [ ] Debug channel layout (session strip + mini map)
- [ ] Break / stop → code bubble + stack bubbles
- [ ] Step in → new callee bubble + arrow
- [ ] Data-structure bubbles; tear-out fields
- [ ] Console / log bubbles
- [ ] Save/reload debug sessions

## Phase 7 — Sharing (§6.6)

- [ ] Export workspace (layout + notes) to JSON/XML
- [ ] Import shared workspace
- [ ] PDF / image snapshot of a working set

## Phase 8 — Scale & polish (§7–8)

- [ ] Spatial index (hit-test / spacer / cull)
- [ ] Dirty-region / LOD when zoomed out
- [ ] Large projects; minimap performance
- [ ] Themes, keybindings, multi-selection

---

## Suggested order

| # | Focus | Why |
|---|--------|-----|
| 1 | Navigation & arrows | Completes the paper’s main loop |
| 2 | Elision + resize + breadcrumb | Core reading UX |
| 3 | Working sets + workspace bar | Multitasking / interruption |
| 4 | LSP | Real navigation for Zig/Rust |
| 5 | Notes / flags / docs | Heterogeneous sets |
| 6 | Debugging | High impact, large effort |
| 7 | Share/export | After layout is stable |
| 8 | Scale & polish | As bubble count grows |

## Deprioritize (paper-specific)

- Java/Eclipse-only tooling, Bugzilla, full Javadoc browser  
- Email-as-attachment share (use file export instead)  
- Full IDE refactoring parity  
