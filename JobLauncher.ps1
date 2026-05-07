# =============================================================================
# Job Launcher GUI - PowerShell WinForms Application
# =============================================================================
# Purpose: Dynamically generates a GUI from a JSON manifest to run CLI jobs
# Author: Collaborative design
# Dependencies: PowerShell 5.1 or later (Windows Forms)
# =============================================================================

# =============================================================================
# IMPORTS AND SETUP - MUST LOAD ASSEMBLIES BEFORE COLOR REFERENCES
# =============================================================================

# Required assemblies for GUI and process management
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Strict mode catches undefined variables and other common mistakes
Set-StrictMode -Version Latest

# Default error action: Stop makes try/catch work predictably
$ErrorActionPreference = 'Stop'

# Will hold hashtable from $Script:Themes
$script:CurrentTheme = $null
$script:CurrentThemePalette = $null

$script:FormControls = $null

$script:KillRequested = $false

# Built-in default theme (always available)
$script:DefaultTheme = @{
    form_background   = "#F0F0F0"
    list_background   = "#FFFFFF"
    list_text         = "#000000"
    panel_background  = "#F0F0F0"
    button            = "#DCE6F0"
    button_hover      = "#C8D7E6"
    button_text       = "#000000"
    button_running    = "#FFC107"
    kill_button       = "#DCE6F0"
    kill_button_text  = "#000000"
    output_background = "#1E1E1E"
    output_text       = "#E0E0E0"
    status_text       = "#000000"
    status_ok         = "#28A745"
    status_error      = "#DC3545"
    status_running    = "#FFC107"
}

# =============================================================================
# USER CONFIGURABLE SETTINGS
# =============================================================================

# --- UI Fonts ---
$UI_Font_Family = "Segoe UI"
$UI_Font_Size_Normal = 9
$UI_Font_Size_Output = 8.5
$UI_Font_OutputMonospaced = $true

# --- UI Dimensions ---
$UI_Window_Width = 900
$UI_Window_Height = 700
$UI_LeftPanel_Width = 180
$UI_Button_Height = 35
$UI_Button_Margin = 4
$UI_Output_Height = 200

# --- Behavior ---
$UI_ShowKillPromptOnClose = $true
$UI_ClearOutputBeforeEachJob = $true
$ConfirmKillJob = $true
$FlashButtonOnComplete = $true
$FlashDurationMs = 300
$ShowFullCommandInOutput = $true
$ShowTimestampsInOutput = $true

# --- Process Execution ---
$KillProcessTree = $true
$KillTimeoutGraceSeconds = 5
$TimeoutPollIntervalMs = 1000

# --- Housekeeping ---
$LogRetentionDays = 30
$LogIncludeEnvironmentInfo = $true

# --- Default Paths ---
$DefaultConfigPath = "launcher_config.json"
$DefaultLogsDirectoryName = "Logs"  # Name of default log folder (relative to script; used if JSON doesn't specify) 
$DefaultLogsDirectory = Join-Path -Path (Split-Path -Path $script:MyInvocation.MyCommand.Path -Parent) -ChildPath $DefaultLogsDirectoryName

# =============================================================================
# END USER CONFIGURABLE SETTINGS
# =============================================================================

# =============================================================================
# GLOBAL STATE (minimized and controlled)
# =============================================================================

# Script-scoped variables (not global scope, but accessible to functions defined below)
$script:CurrentRunningJob = $null           # Hashtable with: Process, JobName, Button, StartTime
$script:GroupsData = $null                  # Parsed JSON groups array
$script:Settings = $null                    # Parsed JSON settings object
$script:OutputTextBox = $null               # Reference to UI control
$script:StatusLabel = $null                 # Reference to UI control
$script:JobButtons = @{}                    # Dictionary mapping job name to button control
$script:KillButton = $null                  # Reference to Kill button
$script:MainForm = $null                    # Reference to main window
$script:GroupListBox = $null                # Reference to groups ListBox

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

<#
.SYNOPSIS
    Converts a hexadecimal color string to a System.Drawing.Color object.

.DESCRIPTION
    Takes a hex color string in formats "#RRGGBB" or "RRGGBB" and returns
    the corresponding Drawing.Color object. Returns $null if the input
    is invalid or empty.

.PARAMETER HexColor
    Hexadecimal color string. Accepts "#RRGGBB" or "RRGGBB" format.
    Example values: "#FFC107", "28A745", "#1E1E1E"

.EXAMPLE
    $color = Convert-HexColorToDrawingColor -HexColor "#3C6E71"

.EXAMPLE
    $color = Convert-HexColorToDrawingColor "DC3545"

.NOTES
    Returns $null for:
    - Empty or null input
    - Strings not exactly 6 hex digits (after optional #)
    - Invalid hex characters

    Does NOT throw exceptions. Callers should handle $null returns appropriately.
#>
function Convert-HexColorToDrawingColor {
    param([string]$HexColor)

    if (-not $HexColor) { return $null }

    $hex = $HexColor.TrimStart('#')
    if ($hex.Length -eq 6) {
        $r = [Convert]::ToInt32($hex.Substring(0,2), 16)
        $g = [Convert]::ToInt32($hex.Substring(2,2), 16)
        $b = [Convert]::ToInt32($hex.Substring(4,2), 16)
        return [System.Drawing.Color]::FromArgb($r, $g, $b)
    }
    return $null
}

function Write-OutputWithTimestamp {
    param([string]$Text, [bool]$IsError = $false)

    $timestamp = if ($ShowTimestampsInOutput) { "[$(Get-Date -Format 'HH:mm:ss')] " } else { "" }
    $prefix = if ($IsError) { "ERROR: " } else { "" }
    $line = $timestamp + $prefix + $Text

    # Append to output textbox (thread-safe via Control.Invoke if needed, but we're on UI thread)
    $script:OutputTextBox.AppendText($line + "`r`n")

    # Auto-scroll to bottom
    $script:OutputTextBox.SelectionStart = $script:OutputTextBox.TextLength
    $script:OutputTextBox.ScrollToCaret()
}

function Update-Status {
    param([string]$Text, [System.Drawing.Color]$Color)

    $script:StatusLabel.Text = $Text
    $script:StatusLabel.ForeColor = $Color
    # No Refresh needed - ToolStripStatusLabel updates automatically
}

function Write-LogFile {
    param(
        [string]$JobName,
        [string]$CommandLine,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [int]$ExitCode,
        [string]$Output,
        [string]$TerminationReason  # "Completed", "Timeout", "KilledByUser", "DirectoryNotFound", etc.
    )

    # colors for current theme
    $UI_Color_StatusError = Get-ThemeColor -PropertyName "status_error"
    $UI_Color_StatusOk = Get-ThemeColor -PropertyName "status_ok"
    $UI_Color_StatusRunning = Get-ThemeColor -PropertyName "status_running"

    # Determine log directory: JSON setting if provided, otherwise use configured default

    # Check if the 'settings > logs_directory' property exists in JSON and has a value
    $jsonLogDir = $null
    if ($script:Settings.PSObject.Properties['logs_directory']) {
        $jsonLogDir = $script:Settings.logs_directory
    }

    # Define candidate log directories in priority order
    $candidates = @(
        $jsonLogDir,                    # User's JSON setting (may be $null)
        $DefaultLogsDirectory,          # Script default (relative to script)
        (Join-Path -Path $env:TEMP -ChildPath "JobLauncherLogs")  # Ultimate fallback
    )

    $logRoot = $null
    $lastError = $null

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }  # Skip empty candidates

        try {
            if (-not (Test-Path -Path $candidate)) {
                New-Item -Path $candidate -ItemType Directory -Force | Out-Null
            }
            # If we get here, success
            $logRoot = $candidate
            break
        } catch {
            $lastError = $_
            Write-Host "DEBUG: Error trying to create logdir! Will proceed to next candidate. Errored dir: $logRoot"
            Write-OutputWithTimestamp "Warning: Cannot use '$candidate' - $($_.Exception.Message)" -IsError $true
            continue
        }
    }

    # After loop, check if we found a working directory
    if (-not $logRoot) {
        $errorMsg = "FATAL: Could not create log directory in any candidate location. Last error: $($lastError.Exception.Message)"
        Write-OutputWithTimestamp $errorMsg -IsError $true
        Update-Status "Logging failed - cannot continue" $UI_Color_StatusError
        throw $errorMsg
    }

    Write-Host "DEBUG: Log dir determined as = $logRoot"

    # Sanitize job name for filename (replace invalid filesystem chars with underscore)
    $safeJobName = $JobName -replace '[\\/:*?"<>|]', '_'
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $logPath = Join-Path -Path $logRoot -ChildPath "$safeJobName`_$timestamp.log"

    # Build log content
    $logContent = @"
================================================================================
JOB EXECUTION LOG
================================================================================
Job Name:          $JobName
Termination Reason: $TerminationReason
Start Time:        $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Command Line:      $CommandLine
Working Directory: $WorkingDirectory
Timeout (seconds): $TimeoutSeconds
Exit Code:         $ExitCode
================================================================================
OUTPUT (stdout + stderr combined):
================================================================================
$Output
================================================================================
END OF LOG
================================================================================
"@

    # Add environment info if configured
    if ($LogIncludeEnvironmentInfo) {
        $osVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
        $psVersion = $PSVersionTable.PSVersion.ToString()
        $envInfo = @"
OS Version:        $osVersion
PowerShell Version: $psVersion
"@
        $logContent = $envInfo + "`r`n" + $logContent
    }

    # Write to disk
    $logContent | Out-File -FilePath $logPath -Encoding UTF8

    # Optional: Clean up old logs
    if ($LogRetentionDays -gt 0) {
        $cutoffDate = (Get-Date).AddDays(-$LogRetentionDays)
        Get-ChildItem -Path $logRoot -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoffDate } | Remove-Item -Force
    }

    Write-OutputWithTimestamp "Log written to: $logPath"
}

function Invoke-JobWithTimeout {
    param([PSObject]$Job, [System.Windows.Forms.Button]$JobButton)

    $UI_Color_StatusError = Get-ThemeColor -PropertyName "status_error"
    $UI_Color_StatusOk = Get-ThemeColor -PropertyName "status_ok"

    # === Validate working directory ===
    $workingDir = if ($Job.working_directory) {
        $Job.working_directory
    } elseif ($script:Settings.default_working_directory) {
        $script:Settings.default_working_directory
    } else {
        # Fallback to the script's directory
        Split-Path -Path $script:MyInvocation.MyCommand.Path -Parent
    }

    if (-not (Test-Path -Path $workingDir -PathType Container)) {
        $errorMsg = "Working directory does not exist: $workingDir"
        Write-OutputWithTimestamp $errorMsg -IsError $true
        Update-Status "Failed: Directory not found" $UI_Color_StatusError

        # Write minimal log
        Write-LogFile -JobName $Job.name -CommandLine $Job.command -WorkingDirectory $workingDir `
                      -TimeoutSeconds $Job.timeout_seconds -ExitCode -1 -Output $errorMsg `
                      -TerminationReason "DirectoryNotFound"
        return $false
    }

    # === Prepare process startup info ===
    # Parse command into executable and arguments
    # Simple split on first space - handles quoted paths poorly but sufficient for cmd/powershell patterns
    $parts = $Job.command -split ' ', 2
    $executable = $parts[0]
    $arguments = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $executable
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $workingDir
    $psi.UseShellExecute = $false           # Required for redirection
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true             # No console window popping up
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    # === Start process ===
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    Write-OutputWithTimestamp "Starting job: $($Job.name)"
    if ($ShowFullCommandInOutput) {
        Write-OutputWithTimestamp "Command: $($Job.command)"
        Write-OutputWithTimestamp "Working directory: $workingDir"
        if ($Job.timeout_seconds) {
            Write-OutputWithTimestamp "Timeout: $($Job.timeout_seconds) seconds"
        }
    }

    try {
        $process.Start() | Out-Null

        # Record running job state
        $script:CurrentRunningJob = @{
            Process = $process
            JobName = $Job.name
            Button = $JobButton
            StartTime = Get-Date
        }

        # Determine timeout (job-specific or default)
        $timeoutSeconds = if ($Job.timeout_seconds) { $Job.timeout_seconds } else { $script:Settings.default_timeout_seconds }

        # === Wait for exit with timeout polling ===
        $timedOut = $false
        $totalWaitMs = $timeoutSeconds * 1000
        $elapsedMs = 0

        while ($elapsedMs -lt $totalWaitMs) {
            if ($process.HasExited) { break }

            # Let Windows process pending UI events (clicks, resizing, etc.)
            [System.Windows.Forms.Application]::DoEvents()

            # Check if kill button was clicked
            if ($script:KillRequested) {
                Write-OutputWithTimestamp "Kill requested, stopping job" -IsError $true
                break
            }

            Start-Sleep -Milliseconds $TimeoutPollIntervalMs
            $elapsedMs += $TimeoutPollIntervalMs
        }

        $script:KillRequested = $false

        if (-not $process.HasExited) {
            # Timeout reached - kill process
            Write-OutputWithTimestamp "TIMEOUT: Job exceeded $timeoutSeconds seconds" -IsError $true
            Update-Status "TIMEOUT - Killing job" $UI_Color_StatusError

            if ($KillProcessTree) {
                # taskkill /T kills the process tree
                $killProcess = Start-Process -FilePath "taskkill.exe" -ArgumentList "/T /F /PID $($process.Id)" -NoNewWindow -Wait -PassThru
                Start-Sleep -Seconds $KillTimeoutGraceSeconds
            } else {
                $process.Kill()
                Start-Sleep -Milliseconds 500
            }

            $timedOut = $true
            $exitCode = -1  # Custom: timeout
        }

        # === Capture output (must happen after process exits) ===
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $combinedOutput = if ($stderr) { "$stdout`r`n$stderr" } else { $stdout }

        $exitCode = if ($timedOut) { -1 } elseif ($process.HasExited) { $process.ExitCode } else { -2 }

        # Display output in GUI
        if ($combinedOutput.Trim()) {
            Write-OutputWithTimestamp "--- Output ---"
            Write-OutputWithTimestamp $combinedOutput.TrimEnd()
        }

        # Determine termination reason
        $terminationReason = if ($timedOut) { "Timeout" } else { "Completed" }

        # Write log file
        Write-LogFile -JobName $Job.name -CommandLine $Job.command -WorkingDirectory $workingDir `
                      -TimeoutSeconds $timeoutSeconds -ExitCode $exitCode -Output $combinedOutput `
                      -TerminationReason $terminationReason

        # Report success/failure
        if ($timedOut) {
            Update-Status "TIMEOUT: $($Job.name)" $UI_Color_StatusError
            return $false
        } elseif ($exitCode -eq 0) {
            Write-OutputWithTimestamp "Job completed successfully (exit code 0)"
            Update-Status "Success: $($Job.name)" $UI_Color_StatusOk
            return $true
        } else {
            Write-OutputWithTimestamp "Job failed with exit code: $exitCode" -IsError $true
            Update-Status "Failed: $($Job.name) (exit $exitCode)" $UI_Color_StatusError
            return $false
        }
    }
    catch {
        $script:KillRequested = $false
        $errorMsg = "Exception during job execution: $($_.Exception.Message)"
        Write-OutputWithTimestamp $errorMsg -IsError $true
        Update-Status "Error: $($Job.name)" $UI_Color_StatusError

        # Attempt to kill if process is still running
        if ($process -and (-not $process.HasExited)) {
            try { $process.Kill() } catch { }
        }

        Write-LogFile -JobName $Job.name -CommandLine $Job.command -WorkingDirectory $workingDir `
                      -TimeoutSeconds $Job.timeout_seconds -ExitCode -1 -Output $errorMsg `
                      -TerminationReason "Exception"
        return $false
    }
    finally {
        $process.Dispose()
        $script:KillRequested = $false
        $script:CurrentRunningJob = $null
    }
}

function Set-JobButtonsEnabled {
    param([bool]$Enabled)
    Write-Host "DEBUG: Set-JobButtonsEnabled $Enabled"

    $UI_Color_Button = Get-ThemeColor -PropertyName "button"
    $UI_Color_ButtonRunning = Get-ThemeColor -PropertyName "button_running"

    foreach ($btn in $script:JobButtons.Values) {
        $btn.Enabled = $Enabled
        if ($Enabled) {
            # Restore original color for all buttons
            $btn.BackColor = $UI_Color_Button
        } elseif (-not $Enabled -and $script:CurrentRunningJob -and $script:CurrentRunningJob.ContainsKey('Button')) {
            # Only change color for the currently running job's button
            $runningButton = $script:CurrentRunningJob['Button']
            if ($btn -eq $runningButton) {
                $btn.BackColor = $UI_Color_ButtonRunning
            }
        }
    }

    if ($script:KillButton) {
        $script:KillButton.Enabled = (-not $Enabled)  # Kill button enabled only when job running
        Write-Host "DEBUG: Kill button status switched: Current enabled state: $($script:KillButton.Enabled)"
    }
}

function Invoke-JobAndManageUI {
    param([hashtable]$Job, [System.Windows.Forms.Button]$JobButton)

    $UI_Color_StatusError = Get-ThemeColor -PropertyName "status_error"
    $UI_Color_StatusOk = Get-ThemeColor -PropertyName "status_ok"
    $UI_Color_Background = Get-ThemeColor -PropertyName "form_background" 

    # Disable all job buttons
    Write-Host "DEBUG: Invoke-JobAndManageUI - About to disable job buttons (kill button should enable)"
    Set-JobButtonsEnabled -Enabled $false
    Write-Host "DEBUG: Invoke-JobAndManageUI - After Set-JobButtonsEnabled call"

    if ($UI_ClearOutputBeforeEachJob) {
        $script:OutputTextBox.Clear()
    }

    # Run the job
    $success = Invoke-JobWithTimeout -Job $Job -JobButton $JobButton

    # Flash button if configured
    if ($FlashButtonOnComplete) {
        $originalColor = $JobButton.BackColor
        $flashColor = if ($success) { $UI_Color_StatusOk } else { $UI_Color_StatusError }
        $JobButton.BackColor = $flashColor
        $JobButton.Refresh()
        Start-Sleep -Milliseconds $FlashDurationMs
        $JobButton.BackColor = $originalColor
        $JobButton.Refresh()
    }

    # Re-enable all job buttons
    Set-JobButtonsEnabled -Enabled $true
    Update-Status "Ready" $UI_Color_Background
}

function Stop-CurrentJob {
    $UI_Color_Background = Get-ThemeColor -PropertyName "form_background" 

    $script:KillRequested = $true

    if (-not $script:CurrentRunningJob) {
        Write-OutputWithTimestamp "No job currently running"
        return
    }

    # Safely extract job name
    $jobName = if ($script:CurrentRunningJob.ContainsKey('JobName')) { 
        $script:CurrentRunningJob['JobName'] 
    } else { 
        "Unknown Job" 
    }

    if ($ConfirmKillJob) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Kill currently running job '$jobName'?", 
            "Confirm Kill", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($result -ne [System.Windows.Forms.DialogResult]::Yes) {
            $script:KillRequested = $false
            return
        }
    }

    Write-OutputWithTimestamp "User requested job termination" -IsError $true

    $process = $script:CurrentRunningJob['Process']
    $jobName = $script:CurrentRunningJob['JobName']
    $jobButton = $script:CurrentRunningJob['Button']

    if (-not $process) {
        Write-OutputWithTimestamp "No process reference found" -IsError $true
        $script:CurrentRunningJob = $null
        $script:KillRequested = $false
        Set-JobButtonsEnabled -Enabled $true
        Update-Status "Ready" $UI_Color_Background
        return
    }

    try {
        if ($KillProcessTree) {
            Write-OutputWithTimestamp "Killing process tree for PID $($process.Id)"
            $null = Start-Process -FilePath "taskkill.exe" -ArgumentList "/T /F /PID $($process.Id)" -NoNewWindow -Wait
            Start-Sleep -Seconds $KillTimeoutGraceSeconds
        } else {
            Write-OutputWithTimestamp "Killing main process only (PID $($process.Id))"
            $process.Kill()
        }

        Write-OutputWithTimestamp "Job '$jobName' killed by user"

        # Capture any remaining output
        $stdout = ""
        $stderr = ""
        try {
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
        } catch {
            # Process may already be fully dead
        }
        $combined = if ($stderr) { "$stdout`r`n$stderr" } else { $stdout }

        Write-LogFile -JobName $jobName -CommandLine "N/A" -WorkingDirectory "N/A" `
                      -TimeoutSeconds 0 -ExitCode -1 -Output "Killed by user at $(Get-Date -Format 'HH:mm:ss')`r`n$combined" `
                      -TerminationReason "KilledByUser"
    }
    catch {
        Write-OutputWithTimestamp "Error killing job: $($_.Exception.Message)" -IsError $true
    }
    finally {
        $script:CurrentRunningJob = $null
        $script:KillRequested = $false
        Set-JobButtonsEnabled -Enabled $true
        Update-Status "Ready" $UI_Color_Background
    }
}

<#
.SYNOPSIS
    Loads user-defined themes from themes.json, falls back to built-in default.
.DESCRIPTION
    Reads themes.json from the script directory. If the file exists and contains
    a valid JSON object, merges those themes into $Script:Themes.
    The built-in default theme is always available as a fallback.
.NOTES
    themes.json format:
    {
        "dark": { "form_background": "#1E1E1E", ... },
        "ocean": { "form_background": "#0A192F", ... }
    }
    A theme named "default" in themes.json will override the built-in default.
#>
function Load-Themes {

    # Initialize themes hashtable with built-in default
    $script:Themes = @{
        "default" = $script:DefaultTheme
    }

    # Path to themes.json
    $scriptDirectory = Split-Path -Path $script:MyInvocation.MyCommand.Path -Parent
    $themesPath = Join-Path -Path $scriptDirectory -ChildPath "themes.json"

    if (-not (Test-Path -Path $themesPath)) {
        Write-Host "No themes.json found. Using built-in default theme."
        return
    }

    try {
        $jsonContent = Get-Content -Path $themesPath -Raw -Encoding UTF8
        $userThemes = $jsonContent | ConvertFrom-Json

        foreach ($themeName in $userThemes.PSObject.Properties) {
            $themeData = @{}
            $themeName.Value.PSObject.Properties | ForEach-Object {
                $themeData[$_.Name] = $_.Value
            }
            $script:Themes[$themeName.Name] = $themeData
            Write-Host "Loaded theme: $($themeName.Name)"
        }
    }
    catch {
        Write-Host "Warning: Failed to load themes.json - $($_.Exception.Message)"
    }
}

function Load-Configuration {
    param([string]$ConfigPath)

    if (-not (Test-Path -Path $ConfigPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Configuration file not found: $ConfigPath`n`nPlease ensure launcher_config.json exists in the script directory.",
            "Configuration Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return $false
    }

    try {
        $jsonContent = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $config = $jsonContent | ConvertFrom-Json

        # Validate required structure (nested format)
        if (-not $config.settings) { throw "Missing 'settings' section" }
        if (-not $config.groups) { throw "Missing 'groups' array" }
        if ($config.groups.Count -eq 0) { throw "No groups defined in configuration" }

        # Validate each group has name and jobs
        foreach ($group in $config.groups) {
            if ([string]::IsNullOrWhiteSpace($group.name)) { throw "Group missing 'name' field" }
            if (-not $group.jobs) { throw "Group '$($group.name)' missing 'jobs' array" }
            if ($group.jobs.Count -eq 0) { throw "Group '$($group.name)' has no jobs defined" }

            # Validate each job in the group
            foreach ($job in $group.jobs) {
                if ([string]::IsNullOrWhiteSpace($job.name)) { throw "Job missing 'name' field in group '$($group.name)'" }
                if ([string]::IsNullOrWhiteSpace($job.command)) { throw "Job '$($job.name)' missing 'command' field" }
            }
        }

        # Store globally
        $script:Settings = $config.settings
        $script:GroupsData = $config.groups

        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to parse configuration file: $ConfigPath`n`nError: $($_.Exception.Message)",
            "Configuration Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return $false
    }
}

<#
.SYNOPSIS
    Creates and configures the toolbar with theme selector and kill button.
.DESCRIPTION
    Returns a TableLayoutPanel configured with three columns:
    - Column 0: Theme label + dropdown (AutoSize)
    - Column 1: Spacer (Percent = 100%, pushes kill button right)
    - Column 2: Kill button (AutoSize)
.PARAMETER Form
    The main form (used for positioning calculations if needed, though TableLayoutPanel handles it).
#>
function Initialize-Toolbar {
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = "Fill"

    # Kill button (right-aligned in toolbar)
    $killButton = New-Object System.Windows.Forms.Button
    $killButton.Text = "Kill Current Job"
    $killButton.Width = 120
    $killButton.Height = 30
    $killButton.Anchor = "Top,Right"
    $killButton.TextAlign = "MiddleCenter"
    $killButton.FlatStyle = "Flat"
    $killButton.Enabled = $false
    $killButton.Add_Click({
        Stop-CurrentJob
    })
    $null = $toolbar.Controls.Add($killButton)

    $script:KillButton = $killButton

    return $toolbar
}

function Build-GUI {
    # --- Main Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Job Launcher"
    $form.Width = $UI_Window_Width
    $form.Height = $UI_Window_Height
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(600, 400)

    # =========================================================================
    # ROOT TABLE LAYOUT (2 rows: toolbar, content)
    # =========================================================================
    $rootTable = New-Object System.Windows.Forms.TableLayoutPanel
    $rootTable.Dock = "Fill"
    $rootTable.AutoSize = $false
    $rootTable.RowCount = 2
    $rootTable.ColumnCount = 1
    $rootTable.RowStyles.Clear()
    $null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Toolbar
    # following line that's commented out: when i actually add the toolbar, the height is excessive. the solution is to get rid of
    # audoSize and instead use this fixed height. Since I'm not actually adding the toolbar in, I'm using AutoSize so that it doesn't take space
    #$null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))  # Toolbar
    $null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) # Content

    # =========================================================================
    # TOOLBAR (Row 0)
    # =========================================================================
    $toolbar = Initialize-Toolbar
    #$null = $rootTable.Controls.Add($toolbar, 0, 0)

    # =========================================================================
    # CONTENT PANEL (Row 1) - Contains SplitContainer for left/right layout
    # =========================================================================
    $contentPanel = New-Object System.Windows.Forms.Panel
    $contentPanel.Dock = "Fill"
    $contentPanel.AutoSize = $false

    # SplitContainer
    $splitContainer = New-Object System.Windows.Forms.SplitContainer
    $splitContainer.Dock = "Fill"
    $splitContainer.Orientation = "Vertical"

    # --- LEFT PANEL (group list) ---
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Dock = "Fill"
    $listBox.Font = New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Normal)
    $listBox.IntegralHeight = $false
    $null = $splitContainer.Panel1.Controls.Add($listBox)

    # --- RIGHT PANEL (job buttons + output area) ---
    $rightPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $rightPanel.Dock = "Fill"
    $rightPanel.RowCount = 2
    $rightPanel.ColumnCount = 1
    $rightPanel.RowStyles.Clear()
    $null = $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $rightPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $UI_Output_Height)))

    # Button flow panel (scrollable)
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = "Fill"
    $buttonPanel.FlowDirection = "TopDown"
    $buttonPanel.WrapContents = $true
    $buttonPanel.AutoScroll = $true
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(5)
    $null = $rightPanel.Controls.Add($buttonPanel, 0, 0)

    # Output textbox
    $outputTextBox = New-Object System.Windows.Forms.RichTextBox
    $outputTextBox.Dock = "Fill"
    $outputTextBox.ReadOnly = $true
    $outputTextBox.BorderStyle = "FixedSingle"

    $outputFont = if ($UI_Font_OutputMonospaced) {
        New-Object System.Drawing.Font("Consolas", $UI_Font_Size_Output)
    } else {
        New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Output)
    }
    $outputTextBox.Font = $outputFont

    $null = $rightPanel.Controls.Add($outputTextBox, 0, 1)
    $null = $splitContainer.Panel2.Controls.Add($rightPanel)
    $null = $contentPanel.Controls.Add($splitContainer)
    $null = $rootTable.Controls.Add($contentPanel, 0, 1)

    # =========================================================================
    # STATUS STRIP (bottom of form, outside TableLayoutPanel)
    # =========================================================================
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.Dock = "Bottom"
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = "Ready"

    # =========================================================================
    # ASSEMBLE THE FORM
    # =========================================================================
    $null = $form.Controls.Add($rootTable)
    #$null = $form.Controls.Add($statusStrip)  # Added last, docks to bottom automatically

    # =========================================================================
    # STORE REFERENCES IN SCRIPT SCOPE (globals for wide access)
    # =========================================================================
    $script:OutputTextBox = $outputTextBox
    $script:StatusLabel = $statusLabel
    $script:GroupListBox = $listBox
    $script:MainForm = $form
    $script:ButtonPanel = $buttonPanel

    # =========================================================================
    # RETURN CONTROLS FOR FUNCTIONS THAT NEED THEM
    # =========================================================================
    $formControls = @{
        Form         = $form
        ListBox      = $listBox
        ButtonPanel  = $buttonPanel
        RightPanel   = $rightPanel
        Toolbar      = $toolbar
    }

    return $formControls
}

function UpdateButtonsForGroup {
    param($Group)

    # Clear existing buttons
    $script:FormControls.ButtonPanel.Controls.Clear()
    $script:JobButtons.Clear()

    # Direct access to jobs from the group object (no filtering needed)
    $jobs = $Group.jobs

    foreach ($job in $jobs) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $job.name
        $btn.Height = $UI_Button_Height
        $btn.Width = $script:FormControls.ButtonPanel.Width - 20
        $btn.TextAlign = "MiddleLeft"
        $btn.FlatStyle = "Flat"
        $btn.Margin = New-Object System.Windows.Forms.Padding($UI_Button_Margin)

        # Store job data in button's Tag property
        $btn.Tag = $job

        # Add hover effect
        $btn.Add_MouseEnter({
            if ($this.Enabled) { $this.BackColor = Get-ThemeColor -PropertyName "button_hover" }
        })

        $btn.Add_MouseLeave({
            if ($this.Enabled) { $this.BackColor = Get-ThemeColor -PropertyName "button" }
        })

        # Click handler - with conversion for compatibility
        $btn.Add_Click({
            $UI_Color_StatusOk = Get-ThemeColor -PropertyName "status_ok" 
            $UI_Color_StatusError = Get-ThemeColor -PropertyName "status_error" 
            $UI_Color_Background = Get-ThemeColor -PropertyName "form_background"

            # Convert PSCustomObject to Hashtable
            $jobToRun = @{}
            $this.Tag.psobject.Properties | ForEach-Object { $jobToRun[$_.Name] = $_.Value }
            $buttonRef = $this

            # Disable all job buttons immediately
            Write-Host "DEBUG: button click handler: About to disable job buttons (kill button should enable)"
            Set-JobButtonsEnabled -Enabled $false

            if ($UI_ClearOutputBeforeEachJob) {
                $script:OutputTextBox.Clear()
            }

            # Run the job
            $success = Invoke-JobWithTimeout -Job $jobToRun -JobButton $buttonRef

            # Flash button if configured
            if ($FlashButtonOnComplete) {
                $originalColor = $buttonRef.BackColor
                $flashColor = if ($success) { $UI_Color_StatusOk } else { $UI_Color_StatusError }
                $buttonRef.BackColor = $flashColor
                $buttonRef.Refresh()
                Start-Sleep -Milliseconds $FlashDurationMs
                $buttonRef.BackColor = $originalColor
                $buttonRef.Refresh()
            }

            # Re-enable all job buttons
            Write-Host "DEBUG: button click handler: About to re-enable job buttons (kill button should disable)"
            Set-JobButtonsEnabled -Enabled $true
            Update-Status "Ready" $UI_Color_Background
        })

        $null = $script:FormControls.ButtonPanel.Controls.Add($btn)
        $script:JobButtons[$job.name] = $btn
    }
}

<#
.SYNOPSIS
    Retrieves a color from the currently active theme palette.

.DESCRIPTION
    Looks up the specified property name in $script:CurrentThemePalette.
    Throws an error if the property is missing or hex conversion fails.

.PARAMETER PropertyName
    The key to look up (e.g., "form_background", "button").
#>
function Get-ThemeColor {
    param([string]$PropertyName)

    if (-not $script:CurrentThemePalette) {
        throw "No current theme palette set. Call Set-Theme first."
    }

    $hexValue = $script:CurrentThemePalette[$PropertyName]
    if (-not $hexValue) {
        throw "Property '$PropertyName' not found in current theme '$script:CurrentThemeName'"
    }

    $color = Convert-HexColorToDrawingColor -HexColor $hexValue
    if (-not $color) {
        throw "Property '$PropertyName' has invalid hex value: '$hexValue'"
    }

    return $color
}

<#
.SYNOPSIS
    Applies color theme to all UI elements based on the selected group.

.DESCRIPTION
    Resolves the theme name from the group (or global settings), retrieves the
    corresponding color palette from $Script:Themes, and applies colors to:
    - Main window background
    - Group list (ListBox) background and text
    - Button panel background
    - Kill button background and text
    - Output textbox background and text
    - Status label text
    - All job buttons (background, text, and hover states)

    If a group specifies a theme that doesn't exist, falls back to "default"
    and logs a warning. Missing color properties within a theme fall back to
    the "default" theme's values via Get-ThemeColor.

.PARAMETER themeName
    The name of the theme to activate (must be a key in $Script:Themes).

.EXAMPLE
    Apply-Theme -themeName "default"

.NOTES
    This function is called by SetGroup after UpdateButtonsForGroup has created
    the job buttons. It assumes $script:JobButtons is populated with all
    current buttons.

    Defensive checks prevent errors if any UI control is missing.
#>
function Apply-Theme {
    param([string]$themeName)

    # Set the theme globally first
    Set-Theme -themeName $ThemeName

    # === Apply colors to each UI element ===

    # Main window background
    if ($script:FormControls.Form) {
        $color = Get-ThemeColor -PropertyName "form_background"
        $script:FormControls.Form.BackColor = $color
    }

    # Left button panel (group list)
    if ($script:FormControls.ListBox) {
        $color = Get-ThemeColor -PropertyName "list_background"
        $script:FormControls.ListBox.BackColor = $color

        $textColor = Get-ThemeColor -PropertyName "list_text"
        $script:FormControls.ListBox.ForeColor = $textColor
    }

    # Right panel background (the container holding ButtonPanel)
    if ($script:FormControls.RightPanel) {
        $color = Get-ThemeColor -PropertyName "panel_background"
        $script:FormControls.RightPanel.BackColor = $color
    }

    # Button panel background
    if ($script:FormControls.ButtonPanel) {
        $color = Get-ThemeColor -PropertyName "panel_background"
        $script:FormControls.ButtonPanel.BackColor = $color
    }

    # Kill button
    if ($script:KillButton) {
        Write-OutputWithTimestamp "DEBUG: Coloring Kill button. Current enabled state: $($script:KillButton.Enabled)"
        $color = Get-ThemeColor -PropertyName "kill_button"
        $script:KillButton.BackColor = $color

        $textColor = Get-ThemeColor -PropertyName "kill_button_text"
        $script:KillButton.ForeColor = $textColor
    }

    # Output textbox
    if ($script:OutputTextBox) {
        $color = Get-ThemeColor -PropertyName "output_background"
        $script:OutputTextBox.BackColor = $color

        $textColor = Get-ThemeColor -PropertyName "output_text"
        $script:OutputTextBox.ForeColor = $textColor
    }

    # Status label
    if ($script:StatusLabel) {
        $color = Get-ThemeColor -PropertyName "status_text"
        $script:StatusLabel.ForeColor = $color
    }

    # Job buttons
    $buttonColor = Get-ThemeColor -PropertyName "button"
    $textColor = Get-ThemeColor -PropertyName "button_text"

    foreach ($btn in $script:JobButtons.Values) {
        $btn.BackColor = $buttonColor
        $btn.ForeColor = $textColor
    }
}

<#
.SYNOPSIS
    Initializes the global theme at script startup using settings.theme from JSON.

.DESCRIPTION
    Called once from Main() before building the UI. Reads the global
    settings.theme property (if present) and activates it via Set-Theme.
    If no theme is specified in JSON, defaults to "default".

    This function does not return a value. It sets $script:CurrentThemeName
    and $script:CurrentThemePalette globally.

.EXAMPLE
    Initialize-Theme

.NOTES
    Uses Set-Theme to apply the theme. Throws an error if the specified
    theme name does not exist in $Script:Themes.
#>
function Initialize-Theme {
    # Resolve theme name (group > settings > "default")
    $initialThemeName = "default"

    if ($script:Settings.PSObject.Properties['theme'] -and $script:Settings.theme) {
        $initialThemeName = $script:Settings.theme
    }

    # Validate theme exists
    if ($Script:Themes.ContainsKey($initialThemeName)) {
        Set-Theme $initialThemeName
        Write-Host "DEBUG: initial theme set to: $initialThemeName"
    } else {
        Write-Host "WARNING: Theme '$initialThemeName' not found. Fallback to default."
        Set-Theme "default"
    }
}

<#
.SYNOPSIS
    Determines the theme name for a specific group based on configuration.

.DESCRIPTION
    Evaluates theme selection priority:
        1. Group's own 'theme' property (if defined in JSON)
        2. Global 'settings.theme' (if defined in JSON)
        3. Falls back to "default"

    This function performs validation only to the extent of checking
    property existence in the PSCustomObject from JSON. It does NOT
    verify that the theme name exists in $Script:Themes.

.PARAMETER Group
    The group object (from $script:GroupsData) containing optional .theme property.

.EXAMPLE
    $themeName = Get-GroupTheme -Group $selectedGroup

.NOTES
    Returns a string. Does not modify global state. Caller should pass
    the returned name to Set-Theme.
#>
function Get-GroupTheme {
    param([PSObject]$Group)

    # Resolve theme name (group > settings > "default")
    if ($Group.PSObject.Properties['theme'] -and $Group.theme) {
        return $Group.theme
    }
    if ($script:Settings.PSObject.Properties['theme'] -and $script:Settings.theme) {
        return $script:Settings.theme
    }
    return "default"
}

<#
.SYNOPSIS
    Activates a named theme by setting global theme variables.

.DESCRIPTION
    Updates $script:CurrentThemeName and $script:CurrentThemePalette
    for the specified theme. All subsequent Get-ThemeColor calls will
    use this palette.

    If the requested theme name does not exist in $Script:Themes, the
    function throws a terminating error. This is intentional to prevent
    silent failures and inconsistent UI coloring.

.PARAMETER themeName
    The name of the theme to activate (must be a key in $Script:Themes).

.EXAMPLE
    Set-Theme -themeName "dark"

.EXAMPLE
    Set-Theme "ocean"

.NOTES
    This function does NOT update any UI elements. Call Apply-Theme
    separately to refresh the interface after changing the theme.
#>
function Set-Theme {
    param([string]$themeName)

    # Validate theme exists
    if ($Script:Themes.ContainsKey($themeName)) {
        $script:CurrentThemeName = $themeName
        $script:CurrentThemePalette = $Script:Themes[$themeName]
    } else {
        throw "Can't set theme '$themeName' -- doesn't exist."
    }
}

<#
.SYNOPSIS
    Switches the UI to display a different job group.

.DESCRIPTION
    Orchestrates the full UI refresh when a user selects a new group from the
    left panel. This function is the single entry point for group changes.

    Steps performed:
    1. Recreates all job buttons for the new group (UpdateButtonsForGroup)
    2. Applies color theme to all UI elements (Apply-Theme)

    Separating button recreation from theme application keeps concerns clean
    and allows theme to be reapplied without rebuilding buttons if needed.

.PARAMETER Group
    The target group object from $script:GroupsData. Contains .name, .jobs,
    and optionally .theme.

.EXAMPLE
    SetGroup -Group $selectedGroup

.NOTES
    Called from:
    - Populate-GUI (initial load, selects the first group)
    - ListBox SelectedIndexChanged event (user clicks a different group)

    Does not modify the ListBox selection itself - that is handled by the caller
    or user interaction. This function only responds to the selected group.
#>
function SetGroup {
    param($Group)

    # Create buttons for this group
    UpdateButtonsForGroup -Group $Group

    # Get the theme name and set it
    $groupTheme = Get-GroupTheme -Group $Group

    # Apply theme (panel background, any other UI decorations)
    Apply-Theme -themeName $groupTheme
}

function Populate-GUI {

    # Defensive check
    #
    if (-not $script:FormControls -or -not $script:FormControls.ContainsKey('ListBox')) {
        Write-Error "Populate-GUI: Invalid FormControls parameter. Missing ListBox."
        return
    }

    # Get group names directly from GroupsData array
    $groups = $script:GroupsData | ForEach-Object { $_.name }

    # Populate ListBox
    $script:FormControls.ListBox.Items.Clear()
    foreach ($group in $groups) {
        $null = $script:FormControls.ListBox.Items.Add($group)
    }

    if ($script:FormControls.ListBox.Items.Count -gt 0) {
        $script:FormControls.ListBox.SelectedIndex = 0
    }

    # Bind selection change event
    $script:FormControls.ListBox.Add_SelectedIndexChanged({
        if ($script:FormControls.ListBox.SelectedItem -and $script:GroupsData) {
            $selectedIndex = $script:FormControls.ListBox.SelectedIndex
            $selectedGroup = $script:GroupsData[$selectedIndex]
            SetGroup -Group $selectedGroup
        }
    })

    # Trigger initial population
    if ($script:FormControls.ListBox.Items.Count -gt 0) {
        $selectedGroup = $script:GroupsData[0]
        SetGroup -Group $selectedGroup
    }
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

function Main {
    # Determine config path
    $scriptDirectory = Split-Path -Path $script:MyInvocation.MyCommand.Path -Parent
    $configPath = Join-Path -Path $scriptDirectory -ChildPath $DefaultConfigPath

    Write-Host "DEBUG: Config path = $configPath"

    # Load configuration
    $loadResult = Load-Configuration -ConfigPath $configPath
    Write-Host "DEBUG: Load-Configuration returned: $loadResult (type: $($loadResult.GetType().FullName))"

    if (-not $loadResult) {
        Write-Host "DEBUG: Configuration load failed, exiting"
        exit 1
    }

    # Load themes from themes.json (or use built-in default)
    Load-Themes

    # Set intial theme
    Initialize-Theme

    Write-Host "DEBUG: About to call Build-GUI"

    # Build GUI - this returns a hashtable with Form, ListBox, ButtonPanel
    $script:FormControls = Build-GUI

    Write-Host "DEBUG: Build-GUI returned type: $($script:FormControls.GetType().FullName)"
    Write-Host "DEBUG: Build-GUI returned value: $script:FormControls"

    # Verify we got valid controls
    if ($script:FormControls -isnot [hashtable]) {
        Write-Host "ERROR: Build-GUI did not return a hashtable. Got: $($script:FormControls.GetType().FullName)"
        exit 1
    }

    if (-not $script:FormControls.ContainsKey('Form')) {
        Write-Host "ERROR: Returned hashtable missing 'Form' key"
        exit 1
    }

    Write-Host "DEBUG: GUI built successfully, about to populate"

    # Populate with jobs - pass the entire hashtable
    Populate-GUI

    Write-Host "DEBUG: GUI built, setting up close handler"

    # Handle form closing event to kill running job if needed
    $script:FormControls.Form.Add_FormClosing({
        param($sender, $e)

        if ($script:CurrentRunningJob -and $UI_ShowKillPromptOnClose) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "A job is currently running. Kill it and exit?",
                "Job In Progress",
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )

            switch ($result) {
                ([System.Windows.Forms.DialogResult]::Yes) {
                    Stop-CurrentJob
                }
                ([System.Windows.Forms.DialogResult]::No) {
                    $e.Cancel = $true
                    [System.Windows.Forms.MessageBox]::Show(
                        "Cannot exit while job is running. Please kill the job first or select Yes.",
                        "Job Still Running",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )
                }
                ([System.Windows.Forms.DialogResult]::Cancel) {
                    $e.Cancel = $true
                }
            }
        }
    })

    Write-Host "DEBUG: Starting form dialog"

    # Show the form
    $script:FormControls.Form.ShowDialog() | Out-Null

    Write-Host "DEBUG: Form closed"
}

# Run the application
Main
