# Translating Selway

Selway ships in English, German (`de`), Spanish (`es`), French (`fr`), Italian (`it`)
and Japanese (`ja`). Translations are welcome, both to keep these up to date and to
add new languages.

Each language is one XLIFF file in [`Localizations/`](../Localizations), such as
`Localizations/de.xliff`. You translate that file and attach it to an issue; the
maintainer reviews it and builds it into the app. You don't need Xcode or a Mac.

## Sending a translation

1. Download `Localizations/<language>.xliff` from this repository. For a language that
   has no file yet, open an [issue](https://github.com/toddbartholow/selway/issues)
   asking for one. (With Xcode installed, `./scripts/l10n-export.sh <language>` makes
   it from a clone.)
2. Translate it in an XLIFF editor or a plain text editor (see
   [The file](#the-file) below).
3. Open an issue named for the language, such as "German translation", and attach the
   file. GitHub doesn't accept every file type as an attachment, so zip it first.

The maintainer loads the file into the project's own translation server for review,
and it ships in a release once every string in it is translated. A partial
translation is still useful: it's kept and finished later.

## The file

Each string is a `<trans-unit>` with the English in `<source>`, a note on where it
appears in `<note>`, and the translation in `<target>`:

```xml
<trans-unit id="Other" xml:space="preserve">
  <source>Other</source>
  <target state="translated">Andere</target>
  <note>File extension grouping section for items without an extension</note>
</trans-unit>
```

- Write the translation in `<target>` and set its `state` to `translated`. Add a
  `<target>` where there is none.
- A unit marked `translate="no"` (the app's name, for example) stays as it is.
- `state="needs-review-translation"` means the English changed after the string was
  translated. Check the translation against the new English, fix it if needed, and set
  `state="translated"`.
- Plural forms are separate units whose ids end in `|==|plural.one`,
  `|==|plural.other` and so on (`|==|substitutions.<name>.plural.<form>` inside longer
  sentences). Translate each form for its count. A form may leave out the number it's
  counted by ("ein Element").

## Rules

- **Placeholders must survive.** Every `%@`, `%lld` or `%1$@` in the English must
  appear in the translation with the same type. Numbered placeholders (`%2$@ … %1$@`)
  may change order. Some strings have unnumbered placeholders in English
  (`"%lld of %lld"`, `"%@ · %@"`); a translation may still reorder them by numbering
  them, as in `%2$lld … %1$lld`.
- **Read the notes.** Every string has a note saying where it appears and what its
  placeholders hold.
- **Default names become file names.** "New Folder", "untitled", "Archive" and the like
  can't contain `/` or `:` or start with a dot. Selway falls back to English if they
  do.
- **Some things stay English:** `CHANGELOG.md`, the release notes shown with updates,
  the README and the other docs, and the controls of the code editor's search box and
  command palette.
