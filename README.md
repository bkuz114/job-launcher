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
