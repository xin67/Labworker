# Labworker Engineering & UI Development Rules

These workspace rules apply to all code, UI views, embedded web views, reports, and documentation in the Labworker (`CloneStudio`) repository.

## 1. Mandatory macOS Default System Font Rule (全局强制 macOS 默认字体)
- **Single Font Family**: 100% of Labworker's UI, sequence editors, nucleotide/amino-acid canvases, formula cards, JSON/CSV previews, WebViews, and exported HTML reports MUST use the **macOS default system font** (`SF Pro` / system default sans-serif).
- **Allowed APIs**:
  - **SwiftUI**: `.font(.system(size: ...))` or `.font(.system(size: ..., weight: ...))` only (combine with `.monospacedDigit()` when tabular number alignment is needed).
  - **AppKit**: `NSFont.systemFont(ofSize:)` or `NSFont.systemFont(ofSize:weight:)` only.
  - **HTML / CSS (WebView & Offline Reports)**: `font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;` only.
- **Strictly Forbidden**:
  - Any `design: .monospaced`, `design: .rounded`, or `design: .serif` parameter in `.font(.system(...))` or `.fontDesign(...)`.
  - Any `Font.custom(...)`, `NSFont(name:size:)`, semantic SwiftUI styles like `.font(.caption)`/`.font(.body)`, or hardcoded font names such as `"PingFang SC"`, `"Menlo"`, `"SF Mono"`, `"Courier"`, `"Helvetica"`, or `"Arial"`.
- **Fixed-Column Grid Alignment**: When character-by-character vertical column alignment is required (such as dual-strand DNA sequences, Sanger base-by-base alignment matrices, or ASCII primer secondary-structure pairing diagrams), use a fixed-stride `Canvas` grid (`StudioAlignedCharGridView` or `SequenceRowCanvasView`) drawn with `.font(.system(size: ...))` instead of a monospaced font.

## 2. Responsive Split Layout & Anti-Overlap Rules
- **Single-View Split Children**: Every child slot passed to `StudioResponsiveSplitLayout` MUST resolve to a single container view (e.g., a `VStack` or a single `StudioCard`). Never pass a bare `@ViewBuilder` `switch` or `if` branch emitting multiple sibling views directly into `StudioResponsiveSplitLayout` or `AdaptiveTwoColumnWorkspace`.
- **Responsive Wrapping & Sizing**:
  - Use `LazyVGrid(columns: [GridItem(.adaptive(minimum: ..., maximum: ...))])` instead of fixed-count columns.
  - Place canvas controls outside 3D/image canvases in `StudioFlowLayout` bars.
  - Use `ViewThatFits(in: .horizontal)` for long form rows and data rows containing multiple `StudioMetricBadge` chips.
  - Never hardcode fixed pixel widths on embedded `Canvas` views inside resizable panes.
  - Keep scientific quantitative image canvases (WB / Gel) locked to SDR via `.allowedDynamicRange(.standard)`.

## 3. Bilingual Localization Rule (简体中文 / Academic English)
- **Live Bilingual UI**: All user-visible UI labels, section headers, buttons, tooltips, dialogs, alerts, toasts, chart axis labels, and status messages MUST support live switching between Simplified Chinese (`AppLanguage.zhHans`) and publication-grade academic English (`AppLanguage.english`) via `L10n.t(...)` / `L10n.tr(zh, en)` backed by `Sources/CloneStudioCore/Resources/en_translations.json`.
- **Academic Terminology**: English copy MUST use idiomatic molecular biology and wet-lab academic terminology (e.g., *Homology Arm*, *Inverse PCR*, *Restriction Endonuclease*, *Unique Cutters*, *Annealing Temp. (Tm)*, *Chromatogram*, *Frameshift Indel*, *Reference Gene*, *Rolling-Ball Background Subtraction*, *Isoelectric Point (pI)*, *4PL / 5PL Logistic Curve*, *Below LLOQ / Above ULOQ*).
- **Persistence & Protocol Stability**: NEVER localize persisted `Codable` / `UserDefaults` enum `rawValue`s, `.run.json` schema keys, or commercial vendor Excel template protocol constants (e.g., Sangon/Tsingke dropdown values in `OrderExportView` / `export_order.py`). Translate enum display labels at presentation time via `L10n.t(rawValue)` or a separate `localizedTitle` property.

## 4. Single Source of Truth, Manifest & Verification Gate
- Register every new, renamed, or deleted source, script, test, or resource file in `labworker/ARCHITECTURE.md`.
- Never hardcode personal home directories, real laboratory plasmid records, or private contact details in tracked files.
- Before finalizing any change, run the verification gate from `labworker/`:
  ```bash
  /usr/bin/python3 Tests/vectors/run_python_vectors.py
  /usr/bin/python3 Tests/vectors/run_python_vectors.py --tamper-check
  bash Scripts/check_doc_counts.sh
  bash Scripts/build_app.sh
  ```
