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
  positioning is unavailable.
- Use **Add annotation** in the text-selection menu to create a note at the
  selection endpoint, including PDF text-layer selections. The selected quote
  is inserted into the note by default. **Annotate Selected Text by Default**
  skips KOReader's selection action menu and opens the annotation editor
  directly; turn it off to restore the normal menu.
- Tap an existing annotation to open a compact action bar at the bottom of the
  screen with its content and **Delete**, **Edit**, **Move**, and **Cancel**.
  The bar spans the screen width, preserves line breaks, and stays within half
  the screen height. It does not scroll; long previews are shortened with an
  ellipsis, while the full note remains available in the editor. Long-press
  opens the editor directly. **Save & Move** also arms a one-shot
  move: tap the new location to relocate it. The selected emoji is
  contrast-inverted while the move is pending.
- Editors support multiline notes and scrolling. **Fullscreen Annotation
  Editor** toggles the layout from the MarginPop menu or from inside the
  editor. Compact mode is the default and provides three visible lines in the
  editing area; the preference is global.
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
**MarginPop: Annotation List** to open the results directly. Use **Search
Annotations** in the menu or bind the **MarginPop: Search Annotations**
dispatcher action to a gesture to open a separate search form for note text
with an optional emoji filter. The full-screen list uses plain text rows
without emoji artwork and shows 20 results per page; use the emoji picker on
the search page to filter by a face. PDF legacy-marker indexing runs in small
background batches so it does not block the reader. Sidecar annotations and
any cached PDF markers appear
immediately; if indexing is needed, the open list refreshes when it finishes
(reopen it if you closed it before then). Results are left-aligned and can be
selected individually or in bulk. Long-press a result to filter by its emoji.
Selected results can be edited, deleted, or exported as Markdown.

Export supports one combined Markdown file or separate files. The path field
starts at `<KOReader folder>/popupExport`; enter an absolute folder path.
The target folder is created if its parent exists, and existing files are not
overwritten. Selected-annotation exports have global include/omit controls for
book, chapter, and page metadata. History exports have a separate **History
Export Fields** settings page for Book, Chapter, Source, Page, Emoji, Emoji
code, Tags, and Timestamp. Source and Emoji are omitted by default; the other
fields are included by default. Each toggle saves and refreshes immediately.
The selected-annotation export controls also refresh immediately when toggled.
Exported page numbers use that book's saved page offset. Timestamp metadata is
formatted as `YYYY-MM-DD HH:MM:SS`.

**Export All History Annotations** can split Markdown files by book, by book
and chapter, or into one file per annotation. It reads MarginPop sidecar
annotations from KOReader's reading history and includes legacy PDF marker
entries when their lightweight marker index is already cached; it does not
open every historical PDF to scan uncached legacy markers. Grouped filenames
use `YYMMDD-book.md` or `YYMMDD-book-chapter.md`; per-annotation filenames use
the annotation's `YYMMDDhhmmss` creation time. Older sidecar annotations use
the timestamp in their ID. Legacy PDF markers without a creation time use the
export time for the filename.

## PDF embedding

New sidecar annotations on PDFs are also staged as standard PDF highlight
annotations with comment text. The comment contains an `@KOPOP_EMOJI` code
when an emoji is selected, a readable hashtag, and the note text. It does not
use MarginPop's legacy `KOPOPZH2`, `@KOPOP_POS`, or emoji-size payload.

**Embed Notes in PDF on Close** appears directly in the MarginPop menu for PDF
books. It is enabled by default and can be disabled per book. Changes are
journaled in the KOReader book sidecar while reading, then batched into one PDF
write when the document closes normally.
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

## Book notebook

MarginPop synchronizes annotations with KOReader's per-book notebook text
file. **Open Book Notebook** is available from the MarginPop menu and from the
dispatcher action **MarginPop: Open Book Notebook**, which can be assigned to
a gesture. It opens the native text editor when available and reconciles
changes after the editor closes.

Annotation edits are reflected in the notebook, and text added or edited
there is attached to the annotation nearest the current reading position. If
the book has no annotations, notebook text creates one at the current
position. PDF marker updates are journaled for KOReader's normal PDF writeback.
The notebook contains readable note blocks separated by `--- MarginPop ---`;
stable matching IDs stay in the book sidecar and are not shown in the text.
Each managed annotation block includes its page context using the global Page
insertion format and the book's page offset. The built-in notebook editor adds
**Chapter** and **Page** buttons; tapping inserts the current chapter/page at
the cursor, and long-press opens the same global format editor used by the
annotation editor. Long-pressing **Page** also provides the per-book offset
setting. The generated Page line is sync metadata, not annotation body text;
typing before or after it updates the note without rendering the Page line in
the book margin.
Text already present in a notebook before its first MarginPop sync is preserved
as free text. To add a separate notebook note later, start a new block with the
`--- MarginPop ---` divider; it will be attached to the nearest annotation (or
to a new annotation at the current position if none exists).

The **Book Notebook** submenu also provides **Append missing annotations**,
**Append all PDF annotations**, **List orphaned notebook blocks**, and
**Clear synced notebook blocks**. PDF-wide indexing runs in small background
batches only when explicitly requested; opening the notebook uses the cached
index and visible PDF pages to keep resource use low. Removing a synced block
from the notebook unlinks it without deleting its annotation. Deleting an
annotation leaves its notebook block as an orphan. Clearing synced blocks
preserves free notebook text and annotations; use **Append missing
annotations** to add linked blocks again.

The MarginPop menu keeps **Embed Notes in PDF on Close** (for PDFs) and
**Annotate Selected Text by Default** directly at the first level. Annotation
list/search and creation controls are under **Annotations**, editor size and
display options under **Editor & Display**, and notebook and history-export
controls in their own submenus.

## Storage and compatibility

- EPUB/TXT annotations, PDF sidecar anchors, emoji history/favorites, and
  per-book page offsets are stored in KOReader's document sidecar.
- Notebook reconciliation records and unlink state are stored in that same
  per-book sidecar; notebook text itself remains a plain text file.
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
