# AI Agent Handoff: Book Annotations

## Goal

Extend this KOReader plugin from PDF translation markers into a persistent,
editable annotation feature for PDF, EPUB, and text books. Treat this document
as the feature brief for the next implementation agent. Inspect the current
plugin and the KOReader APIs available in the target checkout before coding;
do not assume that PDF page-coordinate behavior can be reused for reflowable
documents.

## Current plugin behavior

- [`main.lua`](./main.lua) supports editable sidecar annotations on PDF, EPUB,
  and TXT, anchored to text positions or PDF page coordinates as available.
  Selection-menu notes include the selected quote.
- PDF sidecar annotations can be mirrored to standard PDF highlight comments
  on clean close. Embedding defaults on per PDF and is configurable per book;
  the sidecar remains the journal and recovery copy.
- Legacy `KOPOPZH1`/`KOPOPZH2` PDF markers remain readable and editable.
  Existing marker position changes use a sidecar journal and batched PDF
  writeback. Do not use the legacy marker payload for new portable comments.
- The gesture actions **MarginPop: Add Annotation** and **MarginPop: Annotation
  List** provide one-shot placement and list/search access.
- The annotation UI supports multiline notes, inline emoji quick rows, a
  paged OpenMoji picker, context insertion, and a global fullscreen preference
  that defaults to compact mode. The editor can toggle layout without losing
  its draft. OpenMoji artwork is monochrome SVG, not a general full-color emoji
  set.
- The editor previews the selected emoji by artwork and readable name; recent
  and favorite quick rows avoid duplicate entries. The first line of the note
  editor is the optional Markdown title; the note body starts on the next line.
  Context buttons insert immediately; line breaks are added only when present
  in the configured insertion format.
- **Annotation Display Controls** uses compact left/right adjustments for
  emoji size, text size, and text margin width, plus placement/visibility
  choices. Tapping the numeric value between the +/- controls opens an exact
  number prompt. The **Text on:** row has separate EPUB, TXT, fixed PDF, and
  PDF reflow toggles. PDF reflow has an independent emoji placement override
  (same as normal, left, anchor, or right). Annotation text side and emoji
  position are separate settings. Emoji may be near the anchor or in either
  margin; note text is independently placed in the left or right text rail.
  The text size is numeric (default 2), and emoji size
  is numeric (default 12). Only the text rail reserves layout width; there is
  no separator line. Reflowable text margins, including PDF reflow when
  typesetting margins are available, use KOReader's `SetPageMargins` event.
  **Annotation Display Controls** groups emoji size/position, text size, text
  margin width/side, and text visibility in one panel. Fixed-layout PDF margins
  remain adjusted in memory through KOReader's rezoom and restore the original
  page-margin value on close; they do not overwrite the global preference.
- Tapping an annotation opens a bottom-anchored action bar with its content and
  Delete/Edit/Move/Cancel actions. Long-press still opens the editor directly.
- Margin text is grouped by anchor line and flows only up to the next annotation
  (or screen edge). Same-line emoji render in sidecar creation order, with
  per-group hit targets cached for tap/edit/move consistency.
- Selection actions are registered before KOReader opens its selection menu,
  including for PDF text-layer selections. A global preference can instead
  make annotation creation the default selection action.
- Annotation text is enabled by default in EPUB, TXT, and fixed-page PDF; PDF
  reflow text visibility is separate and defaults off. EPUB, TXT, PDF, and PDF
  reflow visibility are independently persisted. Margin-note line breaks are
  normalized to spaces, and clipped notes have no ellipsis.
- The **Annotation List** dispatcher/menu action opens results directly.
  **Search Annotations** is a separate input flow. Retain the working backup
  behavior: close the search input and show results directly, without a delayed
  input-dialog-to-results transition. Keep the cached PDF marker index and
  background indexing; do not restore the backup's synchronous scan of every
  PDF page.
- Search supports text/title and emoji filtering, multi-selection, and
  Markdown export. The full-screen scrollable result list uses plain text
  without emoji artwork; emoji filtering is done from the emoji picker, and a
  result can also be long-pressed to filter by its face. Export metadata
  includes the readable emoji name, OpenMoji code, tag, and page number
  adjusted by the per-book offset. Book/chapter/page metadata can be globally
  included or omitted in the export dialog.
- History export reads MarginPop sidecar annotations for KOReader reading
  history and can split files by book, book/chapter, or annotation. Cached
  legacy PDF marker indexes are included when their document fingerprint
  matches; history export intentionally does not scan every PDF file.
- The two marker-position reset actions restore legacy PDF marker overlays to
  their original positions (visible pages only, or all pages); they do not
  affect sidecar annotation anchors.
- A lightweight index of legacy PDF markers is cached in the book's document
  sidecar so subsequent list/search opens avoid rescanning every PDF page.
- If that PDF index is missing or stale, search scans only visible pages
  synchronously and builds the full index in small scheduled batches. Do not
  reintroduce a full-document scan inside the search/list callback; it can
  freeze or crash KOReader on large PDFs.
- When opening results from Search, close the text-entry dialog and show the
  scrollable results directly, following the working backup flow. Keep result
  rows plain text and normalize them with `util.fixUtf8`; do not render emoji
  artwork in the full list or synchronously scan every PDF page.
- [`README.md`](./README.md) is the user-facing feature and storage guide.
  Preserve these behaviors and legacy identifiers unless the user explicitly
  requests a change.

## Requested features

### 1. Annotation mode and placement

- Add an annotation mode that can be activated by a configurable gesture,
  preferably using KOReader's dispatcher/gesture mechanisms already used by
  this plugin.
- Support placement anywhere in a book, including while text is reflowed.
- For TXT and EPUB, associate the annotation with the nearest meaningful text
  item around the tap (the closest item before or after). Persist a semantic
  text anchor/context, not only screen coordinates, so it remains attached
  after reflow or reopening.
- For a non-reflowed PDF, show the annotation at the placed page location.
  Preserve enough text/page anchor information for it to be located when that
  PDF is reflowed. For a reflowed PDF, use the same nearest-text anchoring
  behavior as TXT/EPUB.
- After a placement is completed, exit placement mode.
- Save promptly to the document sidecar. For PDFs, also preserve the existing
  crash-safe journal and safe PDF writeback behavior; do not introduce repeated
  incremental writes to a live MuPDF document.

### 2. Add annotation from a text selection

- Add an annotation action to the text-selection menu.
- Anchor it at the selection endpoint where the user stopped.
- Pre-fill the annotation with the selected quote by default. The quote remains
  editable along with any user-written note.

### 3. Notes, emoji, history, and favorites

- A note can contain ordinary typed text, a simple emoji, or both. Support
  color emoji where KOReader's rendering/assets permit it; do not silently
  render missing emoji as blank.
- Provide a two-row quick-choose bar in the note UI:
  - one row for recently used emoji (history);
  - one row for favorited emoji.
- Long-pressing an emoji in the history row adds it to favorites.
- Long-pressing an emoji in the favorites row removes it from favorites.
- Persist history/favorites appropriately (per user or per book only after
  checking existing KOReader conventions; do not lose them on book close).
- Retain the current PDF emoji picker and any existing emoji data unless a
  compatible replacement is deliberately implemented.

### 4. Annotation interaction and movement

- Tapping an annotation at any time opens its annotation UI, where the user can
  edit, save, or delete it.
- Tapping an annotation opens the bottom action bar; long-press opens its
  editor directly. **Save & Move** saves the note and arms a one-shot move; the
  next tap relocates it to the selected location and saves the new anchor.
- While an emoji annotation is selected for moving, invert its emoji contrast
  so the move state is visibly distinct. Restore normal appearance when the
  move is saved or canceled.
- Keep ordinary reading gestures, including page turns and text selection,
  working outside active annotation/move interactions.

### 5. Annotation search

- Add an annotation search page reachable from the plugin's normal UI.
- Search annotation text and filter by a selected emoji. Support both together
  and independently.
- Selecting a result navigates to and reveals the corresponding annotation,
  including when its text anchor resolves after reflow.

### 6. Insert book context into a note

- In the annotation note UI, provide quick-insert actions for book name,
  chapter, and page number.
- For PDFs without a supplied/usable page number, insert the current PDF page
  number.
- Long-pressing the page-number action configures a per-book global page
  offset (including negative or positive values such as `-1` or `+4`). Define
  and clearly display whether the inserted number is the displayed page plus
  this offset. Persist the offset per book and apply it consistently.

## Implementation guidance

1. Trace the existing lifecycle and hooks in `main.lua` before changing them.
   The plugin patches reader methods and keeps active instances by UI; avoid
   duplicate hooks and ensure hooks still delegate to KOReader when the plugin
   does not consume an event.
2. Find KOReader's supported cross-format annotation/highlight APIs and anchor
   representations. Prefer native text anchors (with quote/context fallback)
   over view coordinates for reflowable content. Keep PDF page coordinates
   only as the non-reflowed visual placement component.
3. Keep persistence per document/book where appropriate and make saves
   recoverable. Preserve compatibility with existing PDF marker payloads and
   sidecar settings.
4. Keep annotation rendering and hit targets usable on e-ink devices. Test
   redraw/dirty-region behavior, rotation/layout changes, missing assets, and
   reopening after a sidecar save.
5. Add localization strings following existing KOReader gettext conventions.
   Update `README.md` to describe the implemented feature and its limitations.
6. Make focused, incremental changes; do not rewrite the plugin wholesale.

## Acceptance criteria

- The gesture can enter annotation placement mode in PDF, EPUB, and TXT,
  including reflowed layouts; completing an annotation exits that mode.
- A placement in reflowable text resolves to the same nearby text after
  changing reflow/layout and reopening the book. PDF non-reflow placement
  remains at its page location and can be found after switching to reflow.
- Selection-menu annotation starts with the selected quote and uses the
  selection endpoint as its anchor.
- Text and emoji annotations can be created, edited, saved, deleted, moved
  from the editor with a one-shot action, and recovered after reopening.
  Long-press opens the editor; long-presses outside annotations retain normal
  KOReader behavior. Existing PDF `KOPOPZH1`/`KOPOPZH2` behavior remains
  compatible.
- The emoji quick bar has independent history and favorites rows with the
  specified long-press add/remove actions; moving an emoji annotation has a
  visible contrast-inverted state.
- Search supports text and emoji filtering, and opening a result navigates to
  its annotation.
- Book, chapter, and page quick-inserts work; PDF page fallback and per-book
  page offset work for positive and negative offsets.
- Normal navigation and selection behavior remain intact outside active
  annotation interactions. Errors saving or resolving anchors are surfaced
  rather than silently reported as success.

## Verification expected from the implementation agent

- Add or update focused tests where the KOReader test/runtime environment
  supports them. At minimum, verify Lua syntax and exercise the new
  persistence/anchor logic with representative PDF, EPUB, and TXT cases.
- Manually verify gesture dispatch, selection-menu integration, annotation
  redraw, reflow/reopen behavior, sidecar recovery, PDF clean-close writeback,
  and search navigation on a KOReader device or supported test harness.
- Report any KOReader API limitations or unsupported document formats
  explicitly, rather than claiming cross-format support without verifying it.

## Current implementation notes

- New PDF sidecar annotations can be mirrored as standard PDF highlight
  comments. This is enabled by default per PDF, can be disabled per book, and
  is staged for one write at clean document close. Keep the sidecar journal
  until the close-time write is confirmed.
- These portable PDF comments use `@KOPOP_EMOJI` and a readable hashtag when
  applicable; they do not contain the legacy `KOPOPZH2`, position, or emoji
  size payload. Existing `KOPOPZH1`/`KOPOPZH2` markers remain supported.
- The annotation editor's fullscreen preference and Book/Chapter/Page
  insertion formats are global. The fullscreen preference defaults to off.
  Page-number offset remains per book and is applied to insertion and export
  page metadata.
- Inline emoji rows are attached once via `InputDialog:addWidget`; do not also
  insert them through `_added_widgets` or a custom `init` wrapper, as doing so
  duplicates controls when the dialog is reinitialized.
- The legacy PDF marker index is only a lightweight listing cache; full marker
  data is loaded when a result is opened. Its fingerprint uses the PDF path,
  size, and modification time, and marker edits invalidate it.
- Chapter names are captured on new sidecar annotations for later cross-book
  export. Older entries without a saved chapter are grouped as unassigned.
- Prefer the current one-shot **Save & Move** flow. Do not reintroduce a
  persistent move mode or make long-press outside an annotation consume
  KOReader's normal behavior.