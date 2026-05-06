# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-01-15

### Added

- Initial release
- Dynamic GUI generation from JSON manifest (`launcher_config.json`)
- Flat job list with `group` field for categorization
- Category switching via left panel ListBox
- One-click job execution with visual feedback (button flash, status bar)
- Per-job timeout enforcement with process tree termination (`taskkill /T`)
- Per-job working directory override (falls back to global default)
- Automatic logging to `Logs/` directory with timestamped filenames
- Log content includes: command line, working directory, timeout, exit code, stdout/stderr, termination reason
- Kill button to terminate running job (with confirmation dialog)
- Graceful shutdown: prompts to kill running job if window closed during execution
- User-configurable settings at script top (colors, fonts, dimensions, behavior toggles)
- Example `launcher_config.json` with safe test commands

### Fixed

- None (initial release)

### Changed

- None (initial release)

### Deprecated

- None (initial release)

### Removed

- None (initial release)

### Security

- No elevation required (runs without administrator privileges)
- Execution policy bypass scoped to process only

[1.0.0]: https://github.com/bkuz114/job-launcher/releases/tag/v1.0.0
