# Job Launcher

A PowerShell GUI tool that runs CLI jobs defined in a JSON manifest.

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
- **Automatic logging** – Every run saves stdout/stderr to a timestamped log file
- **Visual feedback** – Button flashes green on success, red on failure; status bar updates
- **No admin required** – Runs with user permissions only

## Quick Start

1. Edit `launcher_config.json` with your jobs
2. Run `JobLauncher.ps1` (double-click the shortcut)

## Configuration

Edit `launcher_config.json`. Minimal example:

```json
{
  "settings": {
    "default_timeout_seconds": 60
  },
  "jobs": [
    {
      "name": "Build Project",
      "command": "msbuild.exe MyProject.sln /p:Configuration=Release",
      "group": "Build"
    },
    {
      "name": "Deploy to Staging",
      "command": "robocopy C:\\source \\\\server\\share /MIR",
      "group": "Deploy",
      "timeout_seconds": 300
    }
  ]
}
```

See `launcher_config.json` in the repo for a complete example with test commands.

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

## Requirements

- Windows PowerShell 5.1 or later
- No administrative privileges required

## Running the Launcher

### One-time PowerShell execution policy bypass

PowerShell's default execution policy may block running scripts. Run this command in PowerShell **once per session** or per script execution:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

This only affects the current PowerShell window and requires no administrator privileges.

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

## License

MIT
