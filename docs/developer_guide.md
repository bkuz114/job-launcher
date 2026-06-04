# Developer README

This document explains design decisions and non-obvious implementation details for the Job Launcher. It is not a user guide — it's for future maintainers (including future-you) who need to understand *why* things work the way they do.

## Table of Contents

- [Object Model: Categories, Groups, and Jobs](#object-model-categories-groups-and-jobs)
  - [The Raw JSON Objects](#the-raw-json-objects)
  - [The Wrapper Objects (Items)](#the-wrapper-objects-items)
  - [Why Two Layers?](#why-two-layers)
  - [Where Each Object Type Lives](#where-each-object-type-lives)
  - [The Critical Rule](#the-critical-rule)
  - [How to Access Raw Config from a Wrapper](#how-to-access-raw-config-from-a-wrapper)
  - [How to Traverse Upward from a Job Item](#how-to-traverse-upward-from-a-job-item)
- [Left Panel Views: TreeView vs. ListBox (Flat View)](#left-panel-views-treeview-vs-listbox-flat-view)
  - [TreeView (Hierarchical View)](#treeview-hierarchical-view)
  - [ListBox with Dividers (Flat View)](#listbox-with-dividers-flat-view)
  - [Flat JSON (No Categories)](#flat-json-no-categories)
  - [Toggle Button](#toggle-button)
  - [Control Storage](#control-storage)
- [Job Execution System](#job-execution-system)
  - [Overview](#overview)
  - [Core Data Flow](#core-data-flow)
  - [The `$result` Object](#the-result-object)
  - [Real-Time Output Streaming](#real-time-output-streaming)
  - [Why `Cleanup-Job` Exists](#why-cleanup-job-exists)
  - [Termination Reason Precedence](#termination-reason-precedence)
  - [Logging Design](#logging-design)
- [Real-Time Output Streaming](#real-time-output-streaming)
  - [Overview](#overview-1)
  - [Why This Approach](#why-this-approach)
  - [Key Files](#key-files)
  - [How It Flows](#how-it-flows)
  - [The `RealTimeOutput` Flag](#the-realtimeoutput-flag)
  - [Feature Flag](#feature-flag)
  - [Common Pitfalls](#common-pitfalls)
  - [Why Events vs. Background Threads](#why-events-vs-background-threads)
  - [Testing Streaming](#testing-streaming)
  - [Future Improvements (if needed)](#future-improvements-if-needed)
---

## Object Model: Categories, Groups, and Jobs

The script defines three levels of objects, each with a "raw" and "wrapped" form. Understanding this distinction is critical for working with the code.

### The Raw JSON Objects

When you run `ConvertFrom-Json` on `launcher_config.json`, PowerShell creates **PSCustomObject** instances for every JSON object. These are the raw config objects:

- **Category** — contains `.name`, `.groups` (array), optional `.theme`, `.working_directory`, `.timeout_seconds`
- **Group** — contains `.name`, `.jobs` (array), optional `.theme`, `.working_directory`, `.timeout_seconds`
- **Job** — contains `.name`, `.command`, optional `.detached`, `.timeout_seconds`, `.working_directory`

These raw objects have **no parent references**. A job cannot tell you which group it belongs to. A group cannot tell you which category it belongs to. They are just data.

### The Wrapper Objects (Items)

Immediately after parsing, the script wraps each raw object in a **wrapper object** (called an "Item") that adds parent references and UI display properties.

**Category Item** (Type = "category")
- Created in `Load-HierarchicalConfig`
- Contains: `.Type`, `.Label`, `.Node` (raw Category)
- Used for: display only (non-selectable, appears as bold divider in flat view)

**Group Item** (Type = "group")
- Created in `Load-HierarchicalConfig` or `Load-FlatConfig`
- Contains: `.Type`, `.Label`, `.Node` (raw Group), `.Parent` (parent Category Item), `.JobItems` (array of Job Items)
- Used for: navigation selection, contains wrapped jobs, inherits theme from parent

**Job Item** (Type = "job")
- Created in `Load-HierarchicalConfig` or `Load-FlatConfig`
- Contains: `.Type`, `.Label`, `.Node` (raw Job), `.ParentGroup` (raw Group), `.ParentCategory` (raw Category or `$null`)
- Used for: execution with parent traversal (working_directory, timeout_seconds)

### Why Two Layers?

**Raw objects** — keep the original JSON intact. Never modified. Safe to pass to functions that only need the config data.

**Wrapper objects** — add behavior (parent references) without polluting the raw JSON. Enable upward traversal for settings inheritance.

### Where Each Object Type Lives

| Object | Created In | Stored In | Accessed Via |
|--------|-----------|-----------|---------------|
| Raw Category | `ConvertFrom-Json` | `$config.categories` | Not directly used after wrapping |
| Category Item | `Load-HierarchicalConfig` | `$script:NavigationItems` | Left panel (flat view) or TreeView |
| Raw Group | `ConvertFrom-Json` | `$config.groups` (flat) or `$category.groups` (hierarchical) | Not directly used after wrapping |
| Group Item | `Load-HierarchicalConfig` or `Load-FlatConfig` | `$script:NavigationItems` | Left panel selection, passed to `Update-ButtonsForGroup` |
| Raw Job | `ConvertFrom-Json` | `$group.jobs` | Stored inside Job Item's `.Node` |
| Job Item | `Load-HierarchicalConfig` or `Load-FlatConfig` | `$GroupItem.JobItems` | Passed to `Invoke-Job`, `Get-JobWorkingDirectory`, `Get-JobTimeout` |

### The Critical Rule

> **If a function needs parent traversal (working_directory, timeout_seconds, theme), it receives a wrapper Item (Category Item, Group Item, or Job Item).**
>
> **If a function only needs config data (command, name), it receives the raw PSCustomObject from `.Node`.**

This keeps responsibilities clear and prevents accidental coupling.

### How to Access Raw Config from a Wrapper

```powershell
# Given a Job Item
$rawJob = $JobItem.Node          # Returns PSCustomObject with .name, .command, etc.
$rawGroup = $GroupItem.Node      # Returns PSCustomObject with .name, .jobs, etc.
$rawCategory = $CategoryItem.Node # Returns PSCustomObject with .name, .groups, etc.
```

### How to Traverse Upward from a Job Item

```powershell
# Inside Get-JobWorkingDirectory or Get-JobTimeout
$rawJob = Get-JobConfig -JobItem $JobItem  # same as $JobItem.Node with validation

# Parent group (raw JSON)
if ($JobItem.ParentGroup.working_directory) { ... }

# Parent category (raw JSON, may be $null for flat configs)
if ($JobItem.ParentCategory -and $JobItem.ParentCategory.working_directory) { ... }
```

---

## Left Panel Views: TreeView vs. ListBox (Flat View)

The left panel can display the same navigation data in two different ways, depending on the `view` setting in JSON or user toggle.

### TreeView (Hierarchical View)

- **Used when:** `"view": "tree"` in JSON or user toggles to Tree View
- **Rendered by:** `Populate-TreeView`
- **Control:** `System.Windows.Forms.TreeView`
- **Behavior:** Categories are expandable/collapsible parent nodes. Groups are child nodes. Clicking a group selects it.

### ListBox with Dividers (Flat View)

- **Used when:** `"view": "flat"` in JSON (default) or user toggles to List View
- **Rendered by:** `Populate-ListWithDividers`
- **Control:** `System.Windows.Forms.ListBox` with owner-draw enabled
- **Behavior:** Categories appear as bold, centered, non-selectable dividers. Groups appear as normal selectable items below their category divider.

### Flat JSON (No Categories)

- **Used when:** JSON has no `categories` key (only `groups` array)
- **Rendered by:** `Populate-FlatList`
- **Control:** `System.Windows.Forms.ListBox` (simple, not owner-draw)
- **Behavior:** Groups appear as selectable items. No category dividers. No toggle button (only one possible view).

### Toggle Button

- **Appears only when:** JSON has categories (hierarchical structure)
- **Created by:** `Create-ToggleButton`
- **Stored in:** `$script:FormControls.ToggleButton`
- **Behavior:** Switches between TreeView and ListBox views. User preference persists via `$script:FormControls.ToggleButton.Tag` and overrides JSON `view` setting.

### Control Storage

After population, the active control is always stored in `$script:FormControls` under either `.TreeView` or `.ListBox`. This allows other functions (theming, selection) to work with whichever view is active without knowing which one.

```powershell
# Theme application handles both
if ($script:FormControls.TreeView) {
    # Apply colors to TreeView
}
if ($script:FormControls.ListBox) {
    # Apply colors to ListBox
}
```

## Job Execution System

### Overview

The job execution system runs external processes (jobs) with timeout enforcement, output capture, logging, and UI feedback. It supports both blocking jobs (wait for completion) and detached jobs (fire-and-forget).

The system is designed around a single `Invoke-Job` function that orchestrates everything, with helper functions handling specific concerns.

### Core Data Flow

```
Invoke-Job
    │
    ├─→ Create $result object (accumulates all job state)
    │
    ├─→ Start process
    │
    ├─→ Poll loop (timeout checking + UI responsiveness)
    │       │
    │       └─→ Process real-time output (if enabled)
    │
    ├─→ Determine exit code and termination reason
    │
    └─→ finally: Cleanup-Job
              │
              ├─→ Kill process if still running
              ├─→ Finalize-JobLog (writes footer)
              ├─→ Display output (if not already streamed)
              ├─→ Update UI status
              └─→ Dispose resources
```

### The `$result` Object

All job state flows through this object. Defined in `Invoke-Job`, consumed by `Cleanup-Job`.

| Field | Purpose | Set By |
|-------|---------|--------|
| `Success` | Final job outcome | `Invoke-Job` |
| `ExitCode` | Process exit code (or -1 for timeout) | `Invoke-Job` |
| `TerminationReason` | "Completed", "Timeout", "Exception", "KillRequested" | Multiple (conditional) |
| `StdOut` / `StdErr` | Captured process output | Streaming or `Cleanup-Job` |
| `LauncherMessage` | User-facing summary (displayed in UI, appended to log) | `Invoke-Job` |
| `StatusMessage` | Short status bar text | `Invoke-Job` |
| `RealTimeOutput` | Whether streaming was active | `Invoke-Job` |
| `LogFile` | Path to job's log file | `Initialize-JobLog` |

### Real-Time Output Streaming

**Why it exists:** Long-running jobs provide no feedback until completion. Streaming shows output as it's produced.

**How it works:** Uses .NET's `BeginOutputReadLine()` with event handlers. Lines are added to a thread-safe `ConcurrentQueue`, then drained during the main polling loop and displayed via `Invoke-UIThread`.

**The `RealTimeOutput` flag:** Prevents duplicate output. When `$true`, `Cleanup-Job` skips the final `--- Job Output ---` block because streaming already showed the output live.

**Fallback:** If `$EnableRealTimeOutput = $false` or stdout redirects aren't enabled, the system falls back to `ReadToEnd()` (all output at completion).

**Implementation note:** The streaming logic lives in `JobOutputStreamReader.ps1` to keep `Invoke-Job` focused on orchestration. Event `-Action` blocks run in background jobs; errors there fail silently. Use the optional `-DebugLog` parameter for troubleshooting.

**For more details:** See the [Real-Time Output Streaming](#real-time-output-streaming) section below for a deeper dive into architecture, common pitfalls, and testing.

### Why `Cleanup-Job` Exists

Originally, cleanup tasks (killing processes, writing logs, updating UI, disposing resources) were scattered throughout `Invoke-Job`. This led to:
- Duplicate working directory validation
- Missing `Process.Dispose()` calls
- Inconsistent early return behavior

`Cleanup-Job` centralizes all termination logic. Every exit path — normal completion, timeout, exception, early return — calls the same cleanup code, ensuring consistent behavior.

### Termination Reason Precedence

Termination reasons can be set by multiple code paths:

| Source | Sets `TerminationReason` to |
|--------|------------------------------|
| `Stop-CurrentJob` (kill button) | `"KillRequested"` |
| Timeout detection | `"Timeout"` |
| Working directory failure | `"Working Directory Failure"` |
| Exception handler | `"Exception"` |
| Normal exit | `"Completed"` |

**Important:** Later code checks `if (!$result.TerminationReason)` before setting a default. This preserves `"KillRequested"` or `"Timeout"` instead of overwriting with `"Completed"`.

### Logging Design

Each job writes to a separate log file: `logs/<JobName>_<timestamp>.log`

**Three log sections:**

1. **Header** (`Initialize-JobLog`): Timestamp, command, working directory, timeout
2. **Timeline** (`Append-JobLog`): Timestamped events (PID, kill, timeout, launcher messages)
3. **Footer** (`Finalize-JobLog`): Exit code, termination reason, full stdout/stderr

**Why immediate `Append-JobLog` calls?** Each launcher message (timeout, kill, exception) is written to the log immediately when it occurs. This ensures accurate timestamps and guarantees the message is logged even if cleanup is interrupted.

## Real-Time Output Streaming

### Overview

Long-running jobs now display stdout/stderr line-by-line as they're produced, rather than all at once at the end. This provides immediate feedback for operations like backups, builds, or deployments that take minutes to complete.

The system uses .NET's asynchronous event model (`BeginOutputReadLine` / `OutputDataReceived`) to avoid blocking the UI. Lines are passed through a thread-safe queue and processed during the main polling loop.

### Why This Approach

| Requirement | Why It Matters |
|-------------|----------------|
| Non-blocking | UI must remain responsive while job runs |
| Thread-safe | Events fire on background threads; WinForms requires UI updates on main thread |
| No duplicate output | Streaming shows lines live; final output block suppressed |
| Log completeness | Final log still contains full stdout/stderr (accumulated during streaming) |

### Key Files

- **JobOutputStreamReader.ps1** – Contains all streaming logic. Separate file keeps `JobLauncher.ps1` focused on orchestration.
- **JobLauncher.ps1** – `Invoke-Job` integrates streaming; `Cleanup-Job` respects `$result.RealTimeOutput` flag.

### How It Flows

```
1. Process starts
   ↓
2. Start-JobOutputStreamReader registers OutputDataReceived events
   ↓
3. Process writes output → event fires → line added to ConcurrentQueue
   ↓
4. Main polling loop calls Process-JobOutputQueue → drains queue
   ↓
5. Each line: displayed via Invoke-UIThread + accumulated into $result.StdOut/Err
   ↓
6. Process exits → final drain → Stop-JobOutputStreamReader cleans up events
   ↓
7. Cleanup-Job sees RealTimeOutput = $true → skips duplicate output display
```

### The `RealTimeOutput` Flag

`$result.RealTimeOutput` is set to `$true` when streaming starts. `Cleanup-Job` checks this flag to decide whether to display the final `--- Job Output ---` block.

**Without this flag:** Streaming would show lines live, then `Cleanup-Job` would show them all again at the end. The flag prevents this duplication.

### Feature Flag

```powershell
$EnableRealTimeOutput = $true  # Set to $false to disable globally
```

Disabled fallback: original `ReadToEnd()` behavior (all output at job completion).

### Common Pitfalls

| Pitfall | Why It Happens | Fix |
|---------|----------------|-----|
| No output appears | Process doesn't write to stdout/stderr, or `$EnableRealTimeOutput = $false` | Check job command; enable flag |
| Output appears twice | `RealTimeOutput` flag not set correctly | Verify `$result.RealTimeOutput = $true` when streaming starts |
| Event errors don't appear | Event `-Action` blocks run in background jobs; exceptions are silent | Add debug logging to `-Action` block (see `-DebugLog` parameter in `Start-JobOutputStreamReader`) |
| UI freezes during high-frequency output | Too many `Invoke` calls saturate message queue | Unlikely for typical job output; reduce polling frequency if needed |

### Why Events vs. Background Threads

The event-based approach (`Register-ObjectEvent`) is the .NET standard for this scenario. Background threads with manual `ReadLine()` loops were attempted but failed due to PowerShell's threading model. Events are more reliable once working, though harder to debug.

### Testing Streaming

Use a test job that outputs slowly:

```json
{
    "name": "Streaming Test",
    "command": "powershell -Command \"1..30 | ForEach-Object { Write-Output \\\"Line $_\\\"; Start-Sleep -Seconds 1 }\""
}
```

Each line should appear every second, not all at once at the end.

### Future Improvements (if needed)

- **Per-job opt-out** – Add `"streaming": false` to job config for jobs that should use old behavior
- **Debug logging** – Add `-DebugLog` parameter to `Start-JobOutputStreamReader` for troubleshooting
- **Buffer size tuning** – Adjust polling interval (`$TimeoutPollIntervalMs`) for different output frequencies

---

## Future Sections (Placeholders)

- [ ] Configuration System (flat vs hierarchical, inheritance rules)
- [ ] Theme System (color/font resolution)
- [ ] UI Architecture (form creation, event handling)
- [ ] Testing Patterns

