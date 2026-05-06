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

See `launcher_config.json` schema in the file itself.

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
