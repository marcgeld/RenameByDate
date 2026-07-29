# RenameByDate

RenameByDate is a macOS command-line tool that renames PDF documents (invoices, receipts, statements) so they sort chronologically. It finds the document's own date — in the filename or inside the PDF text — and renames the file to:

```
YYYYMMDD Vendor Reference.pdf
```

For example, `Acme invoice 12345.pdf` containing "Fakturadatum: 2024-03-05" becomes `20240305 Acme AB 12345.pdf`. The date prefix format is configurable with `--prefix`.

This file is the single source of truth for what the project does and how it is designed. It is written for both humans and coding agents; `AGENTS.md` simply redirects here.

## Usage

```bash
rbdate <folder>                 # rename files
rbdate --dryrun <folder>        # print what would be renamed without changing files
rbdate --recursive ~/Documents/Invoices
```

| Flag | Effect |
|------|--------|
| `--dryrun` | Show planned renames without changing any files. Without this flag, renames are applied. |
| `--recursive` | Process subfolders too. |
| `--set-date` | Also stamp the file's creation/modification dates with the extracted document date. |
| `--out <dir>` | Copy renamed files into `<dir>` instead of renaming in place. Created if missing. |
| `--prefix <format>` | Date prefix format (default `YYYYMMDD`). Accepts macOS DateFormatter patterns (`yyyyMMdd`), uppercase variants (`YYYY-MM-DD`), or unix strftime tokens (`%Y%m%d`). Also usable as `-prefix`. |
| `--verbose` | Print each planned rename during applied runs and print each skipped file. Dry runs always print planned renames. |
| `--showpath` | Print full paths for planned renames. By default, only the old and new file names are printed. |
| `--disallowed <chars>` | Characters not allowed in generated file names; every listed character is removed. By default (option omitted), only letters, digits, space, and `( ) - _ .` are kept. Space runs left behind by removed characters are collapsed. |

Files are skipped when they already start with a date prefix (`YYYY-MM-DD` or `YYYYMMDD`) or when no date can be found at all. A run reports planned, skipped, failed, and stamped counts.

## How it decides on a name

For each `.pdf` file, in order:

1. **Date from the filename** — a plausible `YYYY-MM-DD` or `YYYYMMDD` anywhere in the name wins. Eight-digit numbers that are not real dates (order numbers, phone numbers) are rejected, as are years outside 1990–2099.
2. **Date from the PDF text** — otherwise the text is scanned line by line. A date on a line with a *good label* (`invoice date`, `fakturadatum`, `datum`, …) is preferred; lines matching the *bad label pattern* (`due date`, `förfallodatum`, `betaldatum`, …) are ignored; failing both, the first remaining date in the text is used. The label lists live in `DateExtraction.swift` (`goodLabels`, `badLabelPattern`) — start there when tuning recognition. Recognized date formats: `2024-03-05`, `20240305`, slash dates like `6/23/2018` (month-first preferred, day-first accepted when it is the only valid reading), dotted European dates like `23.6.2018` (day-first preferred), two-digit years like `23.6.18` or `6/23/18` (00–49 → 2000s, 50–99 → 1900s), and month names in English or Swedish like `January 25, 2016` or `25 januari 2016`.
3. **Vendor** — a short line near the top of the PDF text ending in a company suffix (AB, Inc, Ltd, GmbH, …), falling back to the filename with the date removed.
4. **Reference** — an invoice/OCR number found after a known label (`invoice no`, `fakturanummer`, `ocr`, `ref`, …).
5. **Collision handling** — if the target name is taken, `-1`, `-2`, … is appended before the extension. "Taken" means the name exists on disk *or* was already planned earlier in the same run, compared case-insensitively (macOS volumes are case-insensitive by default), so dry runs and batch renames never plan duplicate targets.

## Design

The code separates decision-making from side effects so the logic is testable without touching real files:

| File | Responsibility |
|------|----------------|
| `Sources/RenameByDate/RenameByDateCommand.swift` | CLI entry point (swift-argument-parser). Parses flags, builds a `RenameByDateConfig`, runs the engine, prints the result. |
| `Sources/RenameByDate/RenameByDateEngine.swift` | Orchestration: enumerates files, plans renames, applies them, handles collisions. All file access goes through the `FileSystem` protocol (`DefaultFileSystem` in production, a mock in tests). |
| `Sources/RenameByDate/DateExtraction.swift` | Pure extraction logic: PDF text via PDFKit, date/label matching, vendor and reference heuristics. Text-based functions take strings, not paths, so tests need no PDF fixtures. |
| `Tests/RenameByDateTests/RenameByDateTests.swift` | Swift Testing suite: date/label extraction cases plus engine behavior (dry run, skips, collisions, apply + stamping) against an in-memory `MockFileSystem`. |

The project is a Swift package (`Package.swift`). Build and test from the command line, or open the package folder in Xcode to edit, run, and debug (schemes are generated automatically; set run arguments via Product → Scheme → Edit Scheme):

```bash
swift build                 # debug build
swift test                  # run the test suite
swift build -c release      # release binary at .build/release/rbdate
```

### Logging

The engine and the extraction logic log to the macOS unified logging system under the subsystem `se.redseven.RenameByDate` (categories `engine` and `extraction`). Info-level entries cover run start/finish and failures; per-file decisions (skips, planned renames, which date/reference was chosen and why) are logged at debug level. Watch a run live with:

```bash
log stream --predicate 'subsystem == "se.redseven.RenameByDate"' --level debug
```

## Planned

- **OCR fallback** for scanned PDFs with no text layer (Vision framework), so paper invoices can be renamed too.
- **Configurable labels** — load `goodLabels` / `badLabelPattern` and the naming template from a config file instead of hardcoding them.
- **Undo log** — write a manifest of applied renames so a run can be reverted.
- **Broader file types** beyond PDF (images with EXIF dates, plain text).

These are direction, not commitments — check git history for what has actually landed.
