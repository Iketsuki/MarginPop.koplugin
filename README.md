# MarginPop

MarginPop adds editable, searchable annotations to PDF, EPUB, and TXT books in
KOReader. Notes can include text, an OpenMoji face, or both. Text-based anchors
follow the book through reflow; PDF notes can also be embedded as standard PDF
highlight/comment annotations for use in other readers.

The plugin folder and internal settings/actions retain the legacy
`marginpop` name for compatibility with existing KOReader gesture
bindings and saved data. The user-facing plugin name is MarginPop.

## Add and edit annotations

- **Annotation Mode** in the MarginPop menu, or the dispatcher action
  **MarginPop: Add Annotation**, enables one-shot placement. Tap a location in
  PDF, EPUB, or TXT; the editor opens and the mode exits when the annotation is
  saved or canceled. Bind the dispatcher action to any KOReader gesture.
- For EPUB/TXT, MarginPop anchors to a nearby text position. Fixed-layout PDF
  notes store their page position; reflowed PDF notes use a native PDF
  position when it can be resolved, or a page-relative fallback when OCR/text
  positioning is unavailable. PDF placement can be configured to use the
  nearest text item or its right margin.
- Use **Add annotation** in the text-selection menu to create a note at the
  selection endpoint, including PDF text-layer selections. The selected quote
  is inserted into the note by default. **Annotate Selected Text by Default**
  skips KOReader's selection action menu and opens the annotation editor
  directly; turn it off to restore the normal menu.
- Tap an existing annotation to open a compact action bar at the bottom of the
  screen with its content and **Delete**, **Edit**, **Move**, and **Cancel**.
  Long-press opens the editor directly. **Save & Move** also arms a one-shot
  move: tap the new location to relocate it. The selected emoji is
  contrast-inverted while the move is pending.
- Editors support multiline notes and scrolling. **Fullscreen Annotation
  Editor** toggles the layout from the MarginPop menu or from inside the
  editor. Compact mode is the default; the preference is global.
- The note editor provides inline quick emoji rows, plus the full paged
  OpenMoji picker. The selected face is previewed by name and artwork. Recent
  and favorite rows do not repeat the same face. In the picker, long-press a
  recent emoji to favorite it, or a favorite to remove it. The bundled
  OpenMoji artwork is monochrome SVG.
- There is no separate title prompt. The first editor line is an optional
  Markdown title; start the note on the next line. A selected quote starts
  below the blank title line. Titles can be edited directly in the same editor.
- **Annotation Display Controls** provides compact left/right adjustments for
  emoji size, text size, and text margin width, plus emoji position, text side,
  and visibility controls. Tap the numeric value between the +/- buttons to
  enter an exact number. The **Text on:** row independently toggles EPUB, TXT,
  fixed-page PDF, and PDF reflow. PDF reflow can override the normal emoji
  position with Left, Anchor, or Right. Emoji position and annotation-text side
  are independent: put emoji near the anchored item or in either margin, and
  put the note text in the left or right text margin. Emoji and note text are
  laid out separately to avoid overlap.
  Only the text-margin width reserves page-layout space; emoji do not enlarge
  that margin. Text appears without a separator, grows until the next annotation
  (or the screen edge), and is clipped there to avoid covering the next note.
  Line breaks display as spaces, and clipped notes do not get an ellipsis.
  Emoji on the same line are shown in creation order.
- Annotation text is shown by default in EPUB, TXT, and fixed-page PDF; each
  format can be toggled independently. Text in PDF reflow is separately
  configurable and defaults off. Text size
  defaults to 2 and can be adjusted from 1 to 24; emoji size defaults to 12
  and can be adjusted from 2 to 64. The text
  margin width can be adjusted independently of KOReader's normal
  margins. EPUB/TXT and PDF reflow reserve space on the selected text side when
  KOReader exposes text-layout margins. Fixed-layout PDF margins remain
  adjusted in memory through KOReader's rezoom, then restore the original
  page-margin setting when the document closes; the adjustment does not change
  the global preference. PDF zoom reserves both sides while the text rail
  remains on the chosen side. Setting width to 0 disables extra layout
  reservation but keeps the overlay visible.
- The **Book**, **Chapter**, and **Page** buttons immediately insert context at
  the text cursor. Long-press a button to configure its global insertion
  format, using `{title}`, `{chapter}`, and `{page}` placeholders. Insertions
  do not add line breaks unless the chosen format includes one. Page-number
  offset is configurable per book; the inserted number is the current/displayed
  page plus that offset. A PDF page number falls back to the current PDF page.

## Search and export

Open **Annotation List** from the MarginPop menu or use the dispatcher action
**MarginPop: Annotation List** to open the results directly. **Search
Annotations** opens a separate search form for note text with an optional
emoji filter. The full-screen scrollable list uses plain text rows without emoji
artwork; use the emoji picker on the search page to filter by a face. PDF
legacy-marker indexing runs in small background batches rather than blocking
the reader; the first results include sidecar and visible-page annotations,
and the list can be reopened after indexing finishes. Results are left-aligned
and can be selected individually or in bulk. Long-press a result to filter by
its emoji.
Results can be selected individually or in bulk, opened at their anchor, or
exported as Markdown.

Export supports one combined Markdown file or separate files. The path field
starts at `<KOReader folder>/popupExport`; enter an absolute folder path.
The target folder is created if its parent exists, and existing files are not
overwritten. The export dialog has global include/omit controls for book,
chapter, and page metadata. Exported page numbers use that book's saved page
offset. Emoji metadata includes the readable name, OpenMoji code, and a
`#tag`.

**Export All History Annotations** can split Markdown files by book, by book
and chapter, or into one file per annotation. It reads MarginPop sidecar
annotations from KOReader's reading history and includes legacy PDF marker
entries when their lightweight marker index is already cached; it does not
open every historical PDF to scan uncached legacy markers.

## PDF embedding

New sidecar annotations on PDFs are also staged as standard PDF highlight
annotations with comment text. The comment contains an `@KOPOP_EMOJI` code
when an emoji is selected, a readable hashtag, and the note text. It does not
use MarginPop's legacy `KOPOPZH2`, `@KOPOP_POS`, or emoji-size payload.

**Embed Notes in PDF on Close** is enabled by default for each PDF and can be
disabled per book. Changes are journaled in the KOReader book sidecar while
reading, then batched into one PDF write when the document closes normally.
Edits, moves, and deletions are synchronized with the embedded comments. If
the PDF is read-only or writing fails, the sidecar remains the recoverable
copy and MarginPop reports the failure. Disabling automatic embedding does
not remove comments already written to the PDF; edits or deletions made while
embedding is disabled are not synchronized to existing PDF comments.

The PDF embedding option applies to MarginPop sidecar annotations; it does not
convert or remove existing legacy PDF markers. Existing `KOPOPZH1` and
`KOPOPZH2` markers remain readable and editable with their original behavior.
Legacy `KOPOPZH2` marker position changes also use the plugin's sidecar
journal and batched, clean-close PDF writeback.

## Storage and compatibility

- EPUB/TXT annotations, PDF sidecar anchors, emoji history/favorites, and
  per-book page offsets are stored in KOReader's document sidecar.
- PDF sidecar annotations retain their anchor and PDF-export snapshot in that
  sidecar so edits and deletes can be reconciled with the native PDF comment.
- The searchable index of legacy PDF markers is cached in the book sidecar,
  so reopening the annotation list does not rescan every PDF page.
- PDF marker position changes and pending additions/deletions are journaled
  before PDF writeback. The plugin avoids repeated writes to an open MuPDF
  document and verifies the saved PDF before clearing its pending journal.
- The visible-page and all-page reset actions restore legacy PDF marker
  overlays to their original positions; they do not move sidecar annotations.
- Existing gesture bindings and settings are retained under the legacy
  `marginpop` identifiers.

## Limitations

- PDF text anchoring depends on KOReader/MuPDF page-position and text/OCR data.
  If no text item can be resolved, MarginPop uses a page-relative anchor where
  possible; this preserves placement but is less semantically stable than a
  text anchor.
- Embedded PDF comments are written on normal document close, not immediately
  after each edit. Keep the KOReader sidecar with the book until that write
  succeeds.
- Color emoji artwork is not bundled. The included OpenMoji faces are
  monochrome.

The bundled OpenMoji artwork is attributed in [OPENMOJI.md](./OPENMOJI.md).
