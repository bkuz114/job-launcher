# Job Launcher

A PowerShell GUI tool that transforms a JSON manifest into a clickable dashboard for your CLI tools.

## Why this exists

You have command-line tools with long, hard-to-remember arguments. Right now you probably:
- Keep a notepad file of copy-paste commands
- Scroll through terminal history
- Retype lengthy paths and flags

Job Launcher solves this: declare your commands once in JSON, then launch any of them with a single click. No terminal. No copy-paste. No typos.

## Features

- **Declarative config** – JSON manifest maps job names to CLI commands
- **Dynamic UI** – Buttons auto-generate from your config; switch between job categories
- **One-click execution** – Click a button, watch output appear
- **Timeout & kill** – Jobs that hang get terminated (process tree killed)
- **Kill Button** - Kill button allows you to stop running jobs without waiting for a timeout. Terminates the job's process tree (main process and all child processes) using `taskkill /T`.
- **Automatic logging** – Every run saves stdout/stderr to a timestamped log file
- **Visual feedback** – Button flashes green on success, red on failure; status bar updates
- **Themes** - Color themes that can be selected via a dropdown or configured via JSON
- **No admin required** – Runs with user permissions only

## Quick start

### One-time PowerShell setup

PowerShell's default execution policy may block running scripts. Run this command in PowerShell **once per session** or per script execution:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### Run from PowerShell console

```powershell
cd C:\path\to\job-launcher
.\JobLauncher.ps1
```

### Create a desktop shortcut (one‑click launch)

1. Right‑click on desktop → **New** → **Shortcut**
2. In the location field, enter:

```
powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\full\path\to\JobLauncher.ps1"
```

3. Click **Next**, name it `Job Launcher`, click **Finish**
4. (Optional) Right‑click the new shortcut → **Properties** → **Change Icon** → browse to `%SystemRoot%\System32\imageres.dll` for Windows icons

Now double‑click the shortcut to launch – no console window, no admin prompt.

## Configuration

Edit `launcher_config.json` to define your jobs, groups, and categories. The configuration supports two structures: **flat** (groups only) or **hierarchical** (categories containing groups).

### Flat Structure (Groups Only)

Use this when you have a simple set of jobs without category organization.

```json
{
  "settings": {
    "default_timeout_seconds": 60,
    "default_working_directory": "C:\\scripts",
    "theme": "default"
  },
  "groups": [
    {
      "name": "Build Tools",
      "jobs": [
        {
          "name": "Build Project",
          "command": "msbuild.exe MyProject.sln /p:Configuration=Release"
        },
        {
          "name": "Run Tests",
          "command": "dotnet test",
          "timeout_seconds": 120
        }
      ]
    },
    {
      "name": "Deployment",
      "working_directory": "C:\\deploy",
      "jobs": [
        {
          "name": "Deploy to Staging",
          "command": "robocopy C:\\source \\\\server\\share /MIR"
        }
      ]
    }
  ]
}
```

### Hierarchical Structure (Categories + Groups)

Use this when you want to organize groups under category headers. Categories appear in the left panel as bold, centered dividers (in `"list"` view) or as expandable parent nodes (in `"tree"` view).

```json
{
  "settings": {
    "default_timeout_seconds": 60,
    "theme": "dark",
    "view": "list"
  },
  "categories": [
    {
      "name": "Development",
      "theme": "ocean",
      "groups": [
        {
          "name": "Build Tools",
          "jobs": [
            {
              "name": "Build Project",
              "command": "msbuild.exe MyProject.sln"
            }
          ]
        }
      ]
    },
    {
      "name": "Operations",
      "working_directory": "C:\\ops",
      "groups": [
        {
          "name": "Backup",
          "jobs": [
            {
              "name": "Full Backup",
              "command": "robocopy C:\\data D:\\backup /MIR"
            }
          ]
        }
      ]
    }
  ]
}
```

---

### Settings Object

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `default_timeout_seconds` | integer | Required | Default timeout (seconds) for jobs that don't specify their own |
| `default_working_directory` | string | Script directory | Default working directory for jobs without a path defined |
| `theme` | string | `"default"` | Name of the theme to use (must match a key in `themes.json`) |
| `view` | string | `"flat"` | Left panel presentation for hierarchical JSON. Values: `"tree"` (TreeView), `"list"` (ListBox with category dividers), `"flat"` (groups only, no categories). Ignored for flat JSON. |
| `logs_directory` | string | `".\Logs"` | Directory where job logs are written. Falls back to `%TEMP%\JobLauncherLogs` if inaccessible. |

---

### Schema Reference

**Allowed nodes and their properties:**

| Node Type | Allowed Fields | Required |
|-----------|----------------|----------|
| **Job** | `name`, `command`, `working_directory`, `timeout_seconds`, `detached` | `name`, `command` |
| **Group** | `name`, `jobs`, `working_directory`, `timeout_seconds`, `theme` | `name`, `jobs` |
| **Category** | `name`, `groups`, `working_directory`, `timeout_seconds`, `theme` | `name`, `groups` |

- `name` — Display name (string)
- `command` — Command line to execute (string). First word must be an executable in PATH or a full path.
- `working_directory` — Directory where the command runs (string)
- `timeout_seconds` — Maximum runtime before job is killed (integer)
- `theme` — Theme name that applies to this node and its children (string)
- `detached` — If `true`, runs the command without waiting for completion (boolean). Default `false`.
- `jobs` — Array of job objects (array)
- `groups` — Array of group objects (array)

---

### Inheritance Hierarchy

Settings cascade from most specific to least specific. For `working_directory`, `timeout_seconds`, and `theme`:

1. **Job** — defined directly on the job (highest priority)
2. **Parent Group** — defined on the containing group
3. **Parent Category** — defined on the containing category (hierarchical JSON only)
4. **Settings** — defined in the `settings` object
5. **Fallback** — script default (working directory = script directory, timeout = `default_timeout_seconds`, theme = `"default"`)

**Example of inheritance:**

```json
{
  "settings": {
    "default_working_directory": "C:\\global",
    "default_timeout_seconds": 60
  },
  "categories": [
    {
      "name": "Database",
      "working_directory": "C:\\db",
      "groups": [
        {
          "name": "Backup",
          "timeout_seconds": 300,
          "jobs": [
            {
              "name": "Full Backup",
              "command": "backup.exe --full"
            }
          ]
        }
      ]
    }
  ]
}
```

In this example:
- "Full Backup" runs in `C:\db` (from category), with a 300-second timeout (from group)
- The `default_working_directory` and `default_timeout_seconds` are overridden at higher levels

---

### Left Panel Views (Hierarchical JSON Only)

The `view` setting controls how categories and groups appear:

| View | Appearance | Toggle Button |
|------|------------|----------------|
| `"tree"` | TreeView with expandable/collapsible categories | Yes (switches to `"list"`) |
| `"list"` | ListBox with bold, centered category dividers | Yes (switches to `"tree"`) |
| `"flat"` | ListBox with groups only (categories hidden) | No |

For flat JSON (no `categories` key), the left panel always shows a simple ListBox with groups. The `view` setting is ignored.

## Logs

Every job run creates a log file in the `Logs/` folder (next to the script). File naming:

```
JobName_20260115_143022.log
```

Each log contains:
- Command line executed
- Working directory
- Timeout value
- Exit code
- Full stdout + stderr output
- Termination reason (Completed / Timeout / KilledByUser / DirectoryNotFound)

Logs older than 30 days are automatically deleted. Retention period is configurable at the top of `JobLauncher.ps1`.

## Detached Jobs

Detached jobs run independently in the background. The launcher does not wait for them to complete – it starts the process and immediately returns control to the UI. This is ideal for GUI applications, long‑running background tasks, or any command you do not need to monitor or wait for.

### Usage

Add `"detached": true` to any job definition. Timeouts are ignored for detached jobs (the launcher exits the wrapper process after ~1 second).

### Command Syntax Rules

The `command` field must follow these rules due to the nested wrapper (`powershell.exe → Start-Process cmd → cmd.exe → your command`):

| Scenario | Working Pattern | Example |
|----------|----------------|---------|
| Simple command (no spaces, no quotes) | Write directly | `"command": "notepad.exe"` |
| File path with spaces | Use escaped double quotes around the path | `"command": "notepad.exe \"C:\\Test Folder\\file.txt\""` |
| Nested quotes (e.g., PowerShell `-Command`) | Use escaped double quotes for the outer string and double‑double quotes inside | `"command": "powershell.exe -Command \"Write-Host \"Hello\"\""` |

> **Note:** Single quotes around paths or command arguments will fail. Always use the escaped double‑quote patterns shown above.

### Limitations

- **Kill button has no effect** – Detached processes are not tracked after launch.
- **Logged PID** – The PID shown in the main log belongs to the short‑lived wrapper process, not your command.
- **Output redirection** – stdout/stderr are written to a separate child log file (`*-child.log`). The main job log only contains the launch header.
- **Complex quoting** – The patterns shown above are tested and work; deviations may fail.

### Example

Here is an example of launching argos translator, which could require starting a virtual env and then keeping a continuous console session:

```json
{
  "name": "Detached - venv",
  "command": "argos\\Scripts\\activate && python argos\\Scripts\\argos-translate-gui",
  "detached": true,
  "working_directory": "C:\\Users\\Ivan\\virtual-envs",
  "timeout_seconds": null
},

```

This launches a process in the background which starts the virtual env and starts the argos-translate-gui app, then returns control to the launcher immediately. argso-translate-gui runs independently, and any errors or output are written to the child log file.

### When to Use Detached vs. Blocking

| Use Case | Recommended Job Type |
|----------|---------------------|
| CLI tool that runs and exits | Blocking |
| Script that you need to monitor | Blocking |
| GUI application | Detached |
| Long‑running background task | Detached |
| Command with complex quoting that fails in detached mode | Blocking (or wrap in a `.ps1` script) |

## Command Syntax

The `command` field accepts any string that works as a direct executable (first word must be an executable name or path). For detached jobs only, the command is wrapped in `cmd.exe /c`, so any string that works in `cmd.exe` is also acceptable.

### Basic Rules

| Character | Escaping Rule | Example |
|-----------|---------------|---------|
| Double quote (`"`) | Escape as `\"` | `"command": "echo \"Hello\""` |
| Backslash (`\`) | No escaping needed in JSON | `"command": "C:\\Program Files\\app.exe"` |
| Single quote (`'`) | No escaping needed | `"command": "echo 'Hello'"` |

### Paths with Spaces

When a file path contains spaces, wrap the entire path in escaped double quotes:

```json
"command": "notepad.exe \"C:\\My Documents\\file.txt\""
```

**Do not use single quotes** – they will fail.

### Nested Quotes (PowerShell -Command Example)

When using `powershell.exe -Command` with a quoted string, use the following pattern:

```json
"command": "powershell.exe -Command \"Write-Host \"Hello\"\""
```

This produces the PowerShell command: `Write-Host "Hello"`

### Commands with Multiple Arguments

No special escaping is required for spaces between arguments:

```json
"command": "ping -n 10 127.0.0.1"
```

### Invalid Patterns (Will Fail)

| Pattern | Why It Fails |
|---------|---------------|
| Single quotes around path | `cmd.exe` does not recognize single quotes as path delimiters |
| Unescaped double quotes inside JSON | Invalid JSON syntax |
| Mixing single and double quotes inconsistently | Quote parsing fails in nested wrapper |

# 1. test file with no spaces in the path (success case)

`"command": "notepad.exe C:\\Users\\Boris\\testfolder\\testfile.txt"`

# 2. test file with no spaces in the path, but using single quotes (failure case)

Same will fail if you attempt to put single quotes around it in JSON

`"command": "notepad.exe 'C:\\Users\\Boris\\testfolder\\testfile.txt'"`

# 3. test file with spaces in path, but using single quotes (failure case)

`"command": "notepad.exe 'C:\\Users\\Boris\\test folder\\testfile.txt'"`

# 4. test file with spaces in path (success case) -- use escaped double quotes in JSON

`"command": "notepad.exe \"C:\\Users\\Boris\\test folder\\testfile.txt\""`

### Examples

| Use Case | Working `command` |
|----------|-------------------|
| Simple executable | `"command": "notepad.exe"` |
| Executable with argument | `"command": "ping -n 10 127.0.0.1"` |
| Path with spaces | `"command": "notepad.exe \"C:\\My Folder\\file.txt\""` |
| PowerShell with nested quotes | `"command": "powershell.exe -Command \"Write-Host \"Hello\"\""` |
| cmd.exe built-in command | `"command": "cmd.exe /c echo Hello"` |

### Notes for Detached Jobs

Detached jobs are more sensitive to quoting errors due to the nested wrapper. The patterns above have been tested and work. If a command fails in a detached job but works as a blocking job, the issue is likely quote escaping. Refer to the **Detached Jobs** section for additional guidance.

## Themes

The launcher supports custom color themes. Themes control the appearance of the main window, panels, buttons, output area, and status text. Themes can be switched via a dropdown menu in the toolbar, or can be set via `launcher_config.json`.

### Theme file

Place `themes.json` file in the same directory as `JobLauncher.ps1` to control the available themes. If no file is present, a built-in default theme is used.

A `themes.json` is already included in this repo, but you can modify as desired (remove, add, edit existing, or remove the file entirely). The dropdown will be automatically updated on the next run of the launcher.

### Themes.json format

```json
{
  "dark": {
    "form_background": "#1E1E1E",
    "list_background": "#252525",
    "list_text": "#E0E0E0",
    "panel_background": "#2D2D2D",
    "button": "#3C3C3C",
    "button_hover": "#505050",
    "button_text": "#E0E0E0",
    "button_running": "#FFC107",
    "output_background": "#1A1A1A",
    "output_text": "#C0C0C0",
    "status_text": "#E0E0E0",
    "status_ok": "#28A745",
    "status_error": "#DC3545",
    "status_running": "#FFC107"
  }
}
```

### Available theme properties

| Property | Affects |
|----------|---------|
| `form_background` | Main window background |
| `list_background` | Group list background |
| `list_text` | Group list text color |
| `panel_background` | Right panel background |
| `button` | Job button background (normal) |
| `button_hover` | Job button background (mouse over) |
| `button_text` | Job button text color |
| `button_running` | Currently running job button color |
| `output_background` | Output textbox background |
| `output_text` | Output text color |
| `status_text` | Status bar text color |
| `status_ok` | Success status color |
| `status_error` | Error status color |
| `status_running` | Running status color |

### Selecting a theme

In `launcher_config.json`, set the theme name under `settings` for it to be your default:

```json
{
  "settings": {
    "theme": "dark"
  }
}
```

Themes can also be specified per group:

```json
{
  "groups": [
    {
      "name": "Development",
      "theme": "ocean",
      "jobs": [...]
    }
  ]
}
```

If a group has a theme defined, then switching to that group will change the theme (unless you have selected a theme via the dropdown: this always takes priority)

### Custom themes

Add your own theme by creating a new object in `themes.json`. The name you choose (e.g., `"mytheme"`) becomes available in `launcher_config.json`. All color values are hexadecimal RGB (`#RRGGBB`).

### Available Themes

The following themes are currently available in `themes.json`:

| Theme | Description |
|-------|-------------|
| `dark` | Classic dark theme with neutral gray tones and amber accents for running jobs |
| `ocean` | Deep navy blues with cyan undertones, evoking calm coastal waters |
| `blue_gold` | Dark blue interface with a striking gold toolbar and gold text accents |
| `blue_pink` | Midnight purple-blues with soft pink button text and magenta running indicators |
| `forest` | Earthy green-on-green scheme with subtle contrast, easy on the eyes |
| `sunset` | Warm dusky purples with peach and amber highlights |
| `coffee_break` | Rich brown undertones with creamy beige text — warm and comfortable |
| `amber_glow` | Dark espresso background with glowing amber and gold accents |
| `midnight_ember` | Deep indigo-black canvas with warm ember-orange highlights |
| `sunflower` | Dark theme with vibrant yellow-gold text and accents — bold and cheerful |
| `lavender` | Soft purple-on-indigo palette, elegant and low-strain |
| `cyberpunk` | Neon magenta on dark buttons with cyan text — retro-futuristic and high contrast |

## Requirements

- Windows PowerShell 5.1 or later (built into Windows 10/11)
- No administrator privileges required
- No additional modules or installs

## License

MIT
