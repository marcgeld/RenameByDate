# Agent Instructions

All project documentation — purpose, CLI usage, design, file responsibilities, extraction heuristics, and roadmap — lives in [README.md](README.md). Read it before making changes; it is the single source of truth for both humans and agents.

Quick pointers:

- Date/label recognition is tuned via `goodLabels` and `badLabelPattern` in `RenameByDate/DateExtraction.swift`.
- All file access in the engine goes through the `FileSystem` protocol; keep it that way so the tests' `MockFileSystem` still covers new behavior.
- Add tests to `RenameByDateTests/` (Swift Testing framework) for any new pattern or rename scenario.
