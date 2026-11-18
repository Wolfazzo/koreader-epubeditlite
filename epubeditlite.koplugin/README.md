# epubeditlite

epubeditlite is a lightweight EPUB editor for KOReader. It lets you correct text, adjust XHTML tags and edit stylesheets while reading, using a simple interface suited to e-ink screens.

Select a passage in the book and open **Edit EPUB** from the selection menu. The plugin opens the XHTML file containing that passage and provides a **CSS** tab for switching to a stylesheet. Changes remain in the editor until you choose **Save and return**. KOReader then reloads the book and returns to the reading position when it can locate it.

## Installation

Copy the entire `epubeditlite.koplugin` folder into KOReader's `plugins` directory, then restart KOReader. Open an EPUB, select some text and choose **Edit EPUB** from the selection menu.

The editor follows the language selected in KOReader. It loads the matching bundled catalog at startup and uses KOReader's translations for shared controls. Missing translations fall back to English.

## Editing XHTML and CSS

The XHTML tab opens the original source file for the selected passage. You can correct text and edit tags and attributes, including `<span>`, `class` and `style`.

Tap **CSS** to open a stylesheet associated with the passage. When the EPUB has multiple stylesheets, use **Stylesheets** in the CSS editor to choose another one. You can add or edit CSS rules, then return to **XHTML** and apply a class. The editor keeps your drafts and cursor positions as you switch tabs. All changed files are saved together.

The editor includes KOReader's navigation and search controls. If the selected passage cannot be located uniquely in the XHTML source, use **Find** to locate it manually.

## Quick edits

Quick edits operate on the passage selected **in the book**, before opening the editor. To use them, select text on the reading page, choose **Edit EPUB**, then open **Quick edits** in the XHTML tab.

- **Remove `<span>` tags** removes eligible span tags while keeping their text.
- **Remove class from `<span>`** removes the `class` attribute from eligible spans.
- **Remove style from paragraphs** removes the `style` attribute from paragraphs touched by the selection. Other paragraph attributes are kept.
- **Apply CSS class** wraps the selected text in spans with the class name you enter. You can define the class in the CSS tab during the same editing session.

For example, if the source contains `<span class="italic">one two three</span>` and you select **two** in the book, removing the span produces `<span class="italic">one </span>two<span class="italic"> three</span>`. The surrounding words keep their original formatting.

When a selection covers an entire span, the plugin can remove its opening and closing tags. For a partial selection, it can split a simple span containing plain text. More complex or ambiguous selections may need to be edited by hand. If the selected passage appears more than once and the surrounding context does not identify it uniquely, the plugin asks you to locate or edit it manually. To apply a quick edit to a different passage, return to the book and make a new selection.

## Saving and reading data

On **Save and return**, epubeditlite checks the edited XHTML and builds a temporary EPUB in the book's directory. It compresses the changed files and copies the other ZIP entries in their existing compressed form. It verifies the temporary archive and its changed resources before KOReader closes the book and replaces the original file. The temporary file is removed after a successful save or a handled error. A leftover temporary file from an interrupted save is cleaned up when the book is opened again.

Tap **Cancel** while the temporary EPUB is being prepared to stop saving and keep your draft open.

KOReader reloads the book using the same file path and preserves the stored book identity used by its reading statistics. A change in formatting can alter pagination. Changes to the XHTML structure can also affect reading positions, highlights and bookmarks, which depend on positions in the document. The plugin attempts to restore the reading position after the reload.

The save clears the edited book’s rendering cache so KOReader can lay out the updated EPUB. If you use Bookshelf or CoverBrowser, the plugin tells it to refresh the cached cover for that book.

If embedded styles are disabled or **Ignore publisher font sizes** is active, a formatting edit can be saved to the EPUB while KOReader's reading settings still override it. On saving a formatting edit, choose **Use EPUB styles** to adjust those settings for this book or **Save as is** to keep your reading settings.

## Current limits

- Each XHTML or CSS resource can be up to 512 KiB, with up to 1 MiB of edited source text saved in one operation.
- XHTML must use UTF-8 or ASCII and pass the plugin's XML checks. CSS is checked for valid text encoding; its syntax is not validated.
- The CSS tab edits existing stylesheets in the EPUB. It does not create or link new stylesheet files.
- EPUBs with ZIP64, split archives, ZIP-encrypted entries, a rights file or digital signatures are not supported.
- KOReader's hash-based book metadata location is not supported. Store book metadata by path to keep the book's reading data associated with it.
- The temporary EPUB requires free space in the book's directory. Save time depends on the EPUB size and the device's storage speed.

The archive and editing logic have been tested with generated EPUBs. The interface, save times and reading-position recovery still need to be verified on the target e-ink device.
