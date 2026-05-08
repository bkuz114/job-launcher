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

# theme name user selects from the theme dropdown (if they make a selection)
# need to prevent group switching JSON from overriding their selection
$script:UserSelectedTheme = $null

# Built-in default theme (always available)
$script:DefaultTheme = @{
    form_background   = "#F0F0F0"
    toolbar_background = "#F0F0F0"
    toolbar_text      = "#000000"
    list_background   = "#FFFFFF"
    list_text         = "#000000"
    panel_background  = "#F0F0F0"
    button            = "#DCE6F0"
    button_hover      = "#C8D7E6"
    button_text       = "#000000"
    button_running    = "#FFC107"
    kill_button       = "#DCE6F0"
    kill_button_text  = "#000000"
    output_background = "#314158"
    #output_background = "#1E1E1E"
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
$script:HasCategories = $false              # If Parsed JSON has top level "categories"
$script:Settings = $null                    # Parsed JSON settings object
$script:OutputTextBox = $null               # Reference to UI control
$script:StatusLabel = $null                 # Reference to UI control
$script:JobButtons = @{}                    # Dictionary mapping job name to button control
$script:KillButton = $null                  # Reference to Kill button
$script:MainForm = $null                    # Reference to main window

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

<#
.SYNOPSIS
    Updates the state and appearance of job buttons and kill button based on whether a job is running.

.DESCRIPTION
    When a job is running ($Running = $true):
        - All job buttons are disabled (preventing concurrent jobs)
        - Job buttons retain their normal background color
        - Kill button is enabled (allowing user to kill the running job)

    When no job is running ($Running = $false):
        - All job buttons are enabled (ready to start new jobs)
        - The button that was running (if any) gets a special "running" background color as a visual indicator
        - Kill button is disabled (nothing to kill)

.PARAMETER Running
    $true when a job is currently running, $false when no job is running.
    This parameter determines the state transition for all buttons.

.NOTES
    Depends on $script:JobButtons (hashtable of job name to button control)
    Depends on $script:CurrentRunningJob (contains 'Button' key when a job is running)
    Depends on $script:KillButton (the kill button control)
    Uses Get-ThemeColor for color values "button" and "button_running"
#> 
function Update-ButtonStates {
    param([bool]$Running)
    Write-Host "DEBUG: Update-ButtonStates $Running"

    $UI_Color_Button = Get-ThemeColor -PropertyName "button"
    $UI_Color_ButtonRunning = Get-ThemeColor -PropertyName "button_running"

    foreach ($btn in $script:JobButtons.Values) {
        # disable job buttons if job running
        $btn.Enabled = (-not $Running)
        if (-not $Running) {
            # Restore original color for all buttons
            $btn.BackColor = $UI_Color_Button
        } elseif ($Running -and $script:CurrentRunningJob -and $script:CurrentRunningJob.ContainsKey('Button')) {
            # Only change color for the currently running job's button
            $runningButton = $script:CurrentRunningJob['Button']
            if ($btn -eq $runningButton) {
                $btn.BackColor = $UI_Color_ButtonRunning
            }
        }
    }

    if ($script:KillButton) {
        # KillButtn should be opposite of job buttons: enable when jobs running, gray out otherwise
        Update-KillButton -KillButton $script:KillButton -Enable $Running
    }
}

function Invoke-JobAndManageUI {
    param([hashtable]$Job, [System.Windows.Forms.Button]$JobButton)

    $UI_Color_StatusError = Get-ThemeColor -PropertyName "status_error"
    $UI_Color_StatusOk = Get-ThemeColor -PropertyName "status_ok"
    $UI_Color_Background = Get-ThemeColor -PropertyName "form_background" 

    # Disable all job buttons
    Write-Host "DEBUG: Invoke-JobAndManageUI - About to disable job buttons (kill button should enable)"
    Update-ButtonStates -Running $true
    Write-Host "DEBUG: Invoke-JobAndManageUI - After Update-ButtonStates call"

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
    Update-ButtonStates -Running $false
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
        Update-ButtonStates -Running $false
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
        Update-ButtonStates -Running $false
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

<#
.SYNOPSIS
    Loads and validates a hierarchical configuration with categories, groups, and jobs.

.DESCRIPTION
    Processes the JSON configuration when it contains a "categories" array.
    Each category contains a "groups" array, and each group contains a "jobs" array.

    Builds $script:ListItems with two item types:
    - Type "category" for category headers (non-selectable, visual separation)
    - Type "group" for selectable groups (stores original group object in .Group)

    Throws terminating errors for any missing required fields or empty collections.

.PARAMETER Config
    The PSCustomObject from ConvertFrom-Json containing the full configuration.

.EXAMPLE
    Load-HierarchicalConfig -Config $config

.NOTES
    Sets $script:ListItems. Caller is responsible for setting $script:HasCategories = $true.
    Does NOT set $script:Settings – that is handled separately in Load-Configuration.
#>
function Load-HierarchicalConfig {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Config
    )

    if (-not $config.categories) { throw "Missing 'categories' array" }
    if ($config.categories.Count -eq 0) { throw "No categories defined" }

    $script:ListItems = @()

    foreach ($category in $config.categories) {
        # Validate category has name
        if ([string]::IsNullOrWhiteSpace($category.name)) { throw "Category missing 'name' field" }
        if (-not $category.groups) { throw "Category '$($category.name)' missing 'groups' array" }

        # Add divider for category
        $script:ListItems += @{
            Type = "category"
            Label = $category.name
            Category = $category
        }

        # Validate each group has name and jobs
        foreach ($group in $category.groups) {
            if ([string]::IsNullOrWhiteSpace($group.name)) { throw "Group missing 'name' in category '$($category.name)'" }
            if (-not $group.jobs) { throw "Group '$($group.name)' missing 'jobs' array" }
            if ($group.jobs.Count -eq 0) { throw "Group '$($group.name)' has no jobs defined" }

            # Validate each job in the group
            foreach ($job in $group.jobs) {
                if ([string]::IsNullOrWhiteSpace($job.name)) { throw "Job missing 'name' field in group '$($group.name)'" }
                if ([string]::IsNullOrWhiteSpace($job.command)) { throw "Job '$($job.name)' missing 'command' field" }
            }

            $script:ListItems += @{
                Type = "group"
                Label = $group.name
                Group = $group
            }
        }
    }
}

<#
.SYNOPSIS
    Loads and validates a flat configuration with groups and jobs (no categories).

.DESCRIPTION
    Processes the JSON configuration when it contains a "groups" array (and no "categories").
    Validates each group has a name, a non-empty jobs array, and each job has a name and command.

    Stores the validated groups in $script:GroupsData for use by Populate-FlatList.

.PARAMETER Config
    The PSCustomObject from ConvertFrom-Json containing the full configuration.

.EXAMPLE
    Load-FlatConfig -Config $config

.NOTES
    Sets $script:GroupsData. Caller is responsible for setting $script:HasCategories = $false.
    Does NOT set $script:Settings – that is handled separately in Load-Configuration.
#>
function Load-FlatConfig {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Config
    )

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
    $script:GroupsData = $config.groups
}

<#
.SYNOPSIS
    Loads and validates the launcher configuration from a JSON file.

.DESCRIPTION
    Reads launcher_config.json from the script directory, parses it, and validates
    the required structure. Determines whether the configuration uses a hierarchical
    structure (categories containing groups) or a flat structure (groups only).

    Dispatches to either Load-HierarchicalConfig or Load-FlatConfig for
    detailed validation and data loading. Stores the settings section globally.

.PARAMETER ConfigPath
    Full path to the launcher_config.json file.

.EXAMPLE
    $success = Load-Configuration -ConfigPath "C:\JobLauncher\launcher_config.json"

.NOTES
    Returns $true on success, $false on failure (with error message displayed).

    On success, sets:
    - $script:Settings from config.settings
    - $script:HasCategories = $true (if categories used) or $false (if groups used)
    - $script:ListItems (hierarchical mode) or $script:GroupsData (flat mode)

    On failure, shows a MessageBox error and returns $false.
    Does NOT exit the script – caller should handle the failure.
#>
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

        if ($config.PSObject.Properties['categories']) {
            # JSON has high level "categories" field -- hierarchical structure
            Load-HierarchicalConfig -Config $config
            $script:HasCategories = $true
            # set flat GroupsData to null
            $script:GroupsData = $null
        } elseif ($config.PSObject.Properties['groups']) {
            # JSON has high level "groups" field -- flat structure
            Load-FlatConfig -Config $config
            $script:HasCategories = $false
            # set hierarchical data to null
            $script:ListItems = $null
        } else {
            throw "JSON must have either 'categories' or 'groups' array"
        }

        # Store globally
        $script:Settings = $config.settings
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
    Updates the visual appearance of the kill button based on its logical enabled state.

.DESCRIPTION
    The kill button is kept always enabled in order to style it (disabled buttons
    can't be styled, and become unreadable against certain color themes), and its
    visual state is changed when no jobs running to simulate a disabled state.

    This function updates that visual state of the kill button:
    - When job running: Uses theme colors for kill button + hand curosr
    - When no job: Uses grayed-out colors + block cursor

    Call this function whenever the kill button's logical state changes or when
    the theme is changed (to update colors).

.PARAMETER KillButton
    The button control that functions as the kill button.
    Must have a .Tag property containing a boolean value ($true = job running).

.PARAMETER Enable
    Optional. If provided, force button state to enabled regardless if job running

.EXAMPLE
    # Update appearance based on current Tag value
    Update-KillButton -KillButton $script:KillButton

.NOTES
    Requires Get-ThemeColor function to exist (for theme color retrieval).
    Grayed out colors are hardcoded to System.Drawing.Color.LightGray and DarkGray.
#>
function Update-KillButton {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$KillButton,

        [Parameter(Mandatory = $false)]
        [bool]$Enable
    )

    # initialize to if there's a job marked as running
    $enableButton = [bool]$script:CurrentRunningJob

    # if user specified a certain state, that overrides
    if ($PSBoundParameters.ContainsKey('Enable')) {
        $enableButton = $Enable
    }

    if ($enableButton) {
        $KillButton.BackColor = Get-ThemeColor -PropertyName "kill_button"
        $KillButton.ForeColor = Get-ThemeColor -PropertyName "kill_button_text"
        $KillButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    } else {
        $KillButton.BackColor = [System.Drawing.Color]::LightGray
        $KillButton.ForeColor = [System.Drawing.Color]::DarkGray
        $KillButton.Cursor = [System.Windows.Forms.Cursors]::No
    }
}

<#
.SYNOPSIS
    Creates and configures a TreeView control for category/group navigation.

.DESCRIPTION
    Returns a TreeView with HideSelection = false (so selected group remains visible).
    No event handlers attached here – those go in Populate-GUI.
#>
function Initialize-CategoryTreeView {
    $treeView = New-Object System.Windows.Forms.TreeView
    $treeView.Dock = "Fill"
    $treeView.Font = New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Normal)
    $treeView.HideSelection = $false
    $treeView.BorderStyle = "None"
    return $treeView
}

<#
.SYNOPSIS
    Creates and configures the ListBox with owner-draw support for dividers.
.DESCRIPTION
    Sets DrawMode to OwnerDrawFixed and attaches the DrawItem event handler.
    Returns the configured ListBox control.
.PARAMETER Parent
    The container control where the ListBox will be placed (caller adds it).

.NOTES
    The DrawItem event handles:
    - Dividers: bold font, centered text, gray color, RectangleF with StringFormat
    - Groups: normal font, left-aligned, colors from current theme, PointF positioning
    - Selection: highlights text color based on selected/unselected state
#>
function Initialize-ListBox {
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Dock = "Fill"
    $listBox.Font = New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Normal)
    $listBox.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    $defaultHeight = $listBox.Font.Height
    $padding = 1
    $listBox.ItemHeight = $defaultHeight + $padding
    $listBox.IntegralHeight = $false

    # Attach draw event
    $listBox.Add_DrawItem({
        param($sender, $e)

        $index = $e.Index
        if ($index -lt 0 -or $index -ge $sender.Items.Count) { return }

        $item = $sender.Items[$index]
        $bounds = $e.Bounds
        $e.DrawBackground()

        if ($item.Type -eq "category") {
            # Divider styling
            $font = New-Object System.Drawing.Font($sender.Font, [System.Drawing.FontStyle]::Bold)
            $brush = [System.Drawing.Brushes]::Gray
            $format = New-Object System.Drawing.StringFormat
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rectF = New-Object System.Drawing.RectangleF($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)
            $e.Graphics.DrawString($item.Label, $font, $brush, $rectF, $format)

            # Prevent selection highlight
            $e.DrawFocusRectangle()

            $font.Dispose()
            $format.Dispose()
        } else {

            # Create brush based on selection state
            $textColor = Get-ThemeColor -PropertyName "list_text"
            $selectedTextColor = "White"

            if (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) {
                $brush = New-Object System.Drawing.SolidBrush($selectedTextColor)
            } else {
                $brush = New-Object System.Drawing.SolidBrush($textColor)
            }

            # Draw the text using $brush
            $rectF = New-Object System.Drawing.RectangleF($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)
            $format = New-Object System.Drawing.StringFormat
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $e.Graphics.DrawString($item.Label, $sender.Font, $brush, $rectF, $format)
            $format.Dispose()

            # Dispose after use
            $brush.Dispose()

            if (($e.State -band [System.Windows.Forms.DrawItemState]::Focus) -ne 0) {
                $e.DrawFocusRectangle()
            }
        }
    })

    return $listBox
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
    $toolbar = New-Object System.Windows.Forms.TableLayoutPanel
    $toolbar.RowCount = 1
    $toolbar.RowStyles.Clear()
    $null = $toolbar.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $toolbar.Dock = "Top"
    #$toolbar.AutoSize = $true
    $toolbar.AutoSize = $false
    #$toolbar.AutoSizeMode = "GrowAndShrink"
    $toolbar.ColumnCount = 3
    $toolbar.ColumnStyles.Clear()
    $null = $toolbar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $toolbar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $toolbar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))

    # === Column 0: Theme selector ===
    $themePanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $themePanel.AutoSize = $true
    $themePanel.FlowDirection = "LeftToRight"
    $themePanel.Margin = New-Object System.Windows.Forms.Padding(5, 0, 5, 0)

    $themeLabel = New-Object System.Windows.Forms.Label
    $themeLabel.Text = "Theme:"
    $themeLabel.AutoSize = $true

    $themeCombo = New-Object System.Windows.Forms.ComboBox
    $themeCombo.DropDownStyle = "DropDownList"
    $themeCombo.Width = 100
    $themeCombo.DropDownHeight = 400
    $themeCombo.IntegralHeight = $false

    foreach ($themeName in $Script:Themes.Keys | Sort-Object) {
        $null = $themeCombo.Items.Add($themeName)
    }
    $themeCombo.SelectedItem = $script:CurrentThemeName

    $themeCombo.Add_SelectedIndexChanged({
        $selected = $this.SelectedItem.ToString()
        Apply-Theme -themeName $selected
        # set user selected theme so group switching won't override it
        $script:UserSelectedTheme = $this.SelectedItem.ToString()
    })

    $null = $themePanel.Controls.Add($themeLabel)
    $null = $themePanel.Controls.Add($themeCombo)
    $null = $toolbar.Controls.Add($themePanel, 0, 0)

    # === Column 1: Spacer ===
    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = "Fill"
    #$spacer.Margin = New-Object System.Windows.Forms.Padding(0)
    $null = $toolbar.Controls.Add($spacer, 1, 0)

    # === Column 2: Kill button ===
    $killButton = New-Object System.Windows.Forms.Button
    $killButton.Text = "Kill Current Job"
    $killButton.AutoSize = $true
    $killButton.AutoSizeMode = "GrowAndShrink"
    $killButton.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)
    $killButton.FlatStyle = "Flat"
    $killButton.Margin = New-Object System.Windows.Forms.Padding(5, 5, 5, 5)
    # keep killButton always enabled and simulate disabled state
    # via styling + returning from click event if no job running.
    # Reason:
    # disabled state doesn't allow for color styling, and the button
    # becomes unreadable.
    $killButton.Enabled = $true
    $killButton.Add_Click({
        if ($script:CurrentRunningJob) {
            Stop-CurrentJob
        }
    })
    # set initial styling
    Update-KillButton -KillButton $killButton -Enable $false

    $null = $toolbar.Controls.Add($killButton, 2, 0)
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
    #$null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Toolbar
    # following line that's commented out: when i actually add the toolbar, the height is excessive. the solution is to get rid of
    # audoSize and instead use this fixed height. Since I'm not actually adding the toolbar in, I'm using AutoSize so that it doesn't take space
    $null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))  # Toolbar
    $null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) # Content

    # =========================================================================
    # TOOLBAR (Row 0)
    # =========================================================================
    $toolbar = Initialize-Toolbar
    $null = $rootTable.Controls.Add($toolbar, 0, 0)

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
    $leftPanel = New-Object System.Windows.Forms.Panel
    $leftPanel.Dock = "Fill"
    $null = $splitContainer.Panel1.Controls.Add($leftPanel)

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
    $script:MainForm = $form
    $script:ButtonPanel = $buttonPanel

    # =========================================================================
    # RETURN CONTROLS FOR FUNCTIONS THAT NEED THEM
    # =========================================================================
    $formControls = @{
        SplitContainer = $splitContainer
        Form           = $form
        LeftPanel      = $leftPanel
        ButtonPanel    = $buttonPanel
        RightPanel     = $rightPanel
        Toolbar        = $toolbar
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
            Update-ButtonStates -Running $true

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
            Update-ButtonStates -Running $false
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

    # Button colors
    $buttonColor = Get-ThemeColor -PropertyName "button"
    $buttonTextColor = Get-ThemeColor -PropertyName "button_text"

    # === Apply colors to each UI element ===

    # Main window background
    if ($script:FormControls.Form) {
        $color = Get-ThemeColor -PropertyName "form_background"
        $script:FormControls.Form.BackColor = $color
    }

    # Toolbar
    if ($script:FormControls.Toolbar) {
        $color = Get-ThemeColor -PropertyName "toolbar_background"
        $script:FormControls.Toolbar.BackColor = $color

        $textColor = Get-ThemeColor -PropertyName "toolbar_text"
        $script:FormControls.Toolbar.ForeColor = $textColor
    }

    # Left button panel (group list)

    # Option 1: TreeView was set up
    if ($script:FormControls.ContainsKey('TreeView') -and $script:FormControls.TreeView) {
        # TreeView exists and is not null
        $color = Get-ThemeColor -PropertyName "list_background"
        $script:FormControls.TreeView.BackColor = $color

        $textColor = Get-ThemeColor -PropertyName "list_text"
        $script:FormControls.TreeView.ForeColor = $textColor
    }

    # Option 2: ListBox was set up
    if ($script:FormControls.ContainsKey('ListBox') -and $script:FormControls.ListBox) {
        $color = Get-ThemeColor -PropertyName "list_background"
        $script:FormControls.ListBox.BackColor = $color

        $textColor = Get-ThemeColor -PropertyName "list_text"
        $script:FormControls.ListBox.ForeColor = $textColor

        $script:FormControls.ListBox.Invalidate()
    }

    # Toggle Button
    if ($script:FormControls.ContainsKey('ToggleButton') -and $script:FormControls.ToggleButton) {
        $script:FormControls.ToggleButton.BackColor = $buttonColor
        $script:FormControls.ToggleButton.ForeColor = $buttonTextColor
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
        # use function for styling kill button based on current running jobs
        Update-KillButton -KillButton $script:KillButton
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
    foreach ($btn in $script:JobButtons.Values) {
        $btn.BackColor = $buttonColor
        $btn.ForeColor = $buttonTextColor
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
    The group object containing optional .theme property.

.EXAMPLE
    $themeName = Get-GroupTheme -Group $selectedGroup

.NOTES
    Returns a string. Does not modify global state. Caller should pass
    the returned name to Set-Theme.
#>
function Get-GroupTheme {
    param([PSObject]$Group)

    # User override takes highest priority
    if ($script:UserSelectedTheme) {
        return $script:UserSelectedTheme
    }

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
    The target group object. Contains .name, .jobs,
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

<#
.SYNOPSIS
    Calculates the maximum pixel width required to display all TreeView node labels.

.DESCRIPTION
    Recursively measures category and group node text using the TreeView's font.
    Returns the width of the widest node plus 10px padding.
#>
function Measure-TreeViewMaxWidth {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.TreeView]$TreeView
    )

    $maxWidth = 0
    $font = $TreeView.Font

    foreach ($categoryNode in $TreeView.Nodes) {
        $categorySize = [System.Windows.Forms.TextRenderer]::MeasureText($categoryNode.Text, $font)
        $categoryWidth = $categorySize.Width
        if ($categoryWidth -gt $maxWidth) { $maxWidth = $categoryWidth }

        foreach ($groupNode in $categoryNode.Nodes) {
            $groupSize = [System.Windows.Forms.TextRenderer]::MeasureText($groupNode.Text, $font)
            # get group text width, but account for offset to right of parent category
            $groupWidth = $groupSize.Width + 10
            if ($groupWidth  -gt $maxWidth) { $maxWidth = $groupWidth }
        }
    }

    # account for tree structure to left of text starting
    return $maxWidth + 15
}

<#
.SYNOPSIS
    Calculates the maximum pixel width required to display all items in a ListBox.

.DESCRIPTION
    Measures the text width of each item in the ListBox using the control's font.
    Returns the width of the widest item. Useful for auto-sizing parent containers
    like SplitContainer panels.

.PARAMETER ListBox
    The ListBox control whose items will be measured.

.EXAMPLE
    $maxWidth = Measure-ListBoxMaxWidth -ListBox $listBox
    $splitContainer.SplitterDistance = $maxWidth + 20

.NOTES
    Returns 0 if the ListBox has no items. Uses TextRenderer.MeasureText
    for accurate pixel measurement.
#>
function Measure-ListBoxMaxWidth {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ListBox]$ListBox
    )

    $maxWidth = 0
    $font = $ListBox.Font
    foreach ($item in $ListBox.Items) {
        $size = [System.Windows.Forms.TextRenderer]::MeasureText($item.ToString(), $font)
        if ($size.Width -gt $maxWidth) { $maxWidth = $size.Width }
    }
    return $maxWidth
}

<#
.SYNOPSIS
    Populates the left panel with a flat ListBox of groups (no categories).

.DESCRIPTION
    Used when the JSON configuration contains a "groups" array (flat structure)
    or when no categories are present. Creates a standard ListBox (not owner-draw)
    with one item per group. Does NOT support category dividers or collapsible sections.

    This is the original pre-category behavior, preserved for backward compatibility
    and for users who prefer a simple, flat group list.

    Sets $script:FormControls.ListBox and binds selection to SetGroup.
    Auto-sizes the left panel width based on the widest group name.

.NOTES
    Called by Populate-GUI when $script:HasCategories = $false.
    Requires $script:GroupsData to be populated (by Load-FlatConfig).
    Requires $script:FormControls.LeftPanel to exist (created in Build-GUI).
#>
function Populate-FlatList {

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Dock = "Fill"
    $listBox.Font = New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Normal)
    $listBox.IntegralHeight = $false
    $null = $script:FormControls.LeftPanel.Controls.Add($listBox)
    $script:FormControls.ListBox = $listBox

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

    # Update width of left panel appropriately
    $maxWidth = Measure-ListBoxMaxWidth -ListBox $listBox
    if ($script:FormControls.SplitContainer) {
        $script:FormControls.SplitContainer.SplitterDistance = $maxWidth + 20  # Add padding
    }
}

<#
.SYNOPSIS
    Populates the TreeView with categories and groups from the loaded configuration.

.DESCRIPTION
    Reads $script:ListItems (built by Load-Configuration) and builds a TreeView
    where each category is a parent node and each group is a child node.
    Category nodes have Tag = $null (not selectable). Group nodes have Tag = $group
    object (used by SetGroup). Expands all categories by default, auto-sizes the
    left panel width, and selects the first group node.

.NOTES
    This function is called by Populate-GUI when "view": "tree" is set in JSON.
    Requires $script:FormControls.TreeView to exist (created by Initialize-CategoryTreeView).
    Requires $script:FormControls.SplitContainer for auto-width adjustment.
#>
function Populate-TreeView {

    # Remove existing ListBox if present
    if ($script:FormControls.ContainsKey('ListBox') -and $script:FormControls.ListBox) {
        $script:FormControls.LeftPanel.Controls.Remove($script:FormControls.ListBox)
        $script:FormControls.ListBox.Dispose()
        $script:FormControls.ListBox = $null
    }

    # Create TreeView (to hold groups) using dedicated function
    $treeView = Initialize-CategoryTreeView
    $null = $script:FormControls.LeftPanel.Controls.Add($treeView)
    $script:FormControls.TreeView = $treeView

    # Build TreeView nodes from $script:ListItems
    foreach ($item in $script:ListItems) {
        if ($item.Type -eq "category") {
            # Create category node (parent)
            $categoryNode = New-Object System.Windows.Forms.TreeNode($item.Label)
            # store entire Category object in Tag for use later
            $categoryNode.Tag = @{
                Type = "category"
                Category = $item.Category
            }
            $null = $treeView.Nodes.Add($categoryNode)
        } elseif ($item.Type -eq "group") {
            # This item is a group – add to the last category node
            $groupNode = New-Object System.Windows.Forms.TreeNode($item.Label)
            # store entire Group object in Tag for use later
            $groupNode.Tag = @{
                Type = "group"
                Group = $item.Group
            }
            if ($treeView.Nodes.Count -gt 0) {
                $lastCategory = $treeView.Nodes[$treeView.Nodes.Count - 1]
                $null = $lastCategory.Nodes.Add($groupNode)
            } else {
                # Fallback: no category? Should not happen with valid JSON
                Write-OutputWithTimestamp "Warning: Group '$($item.Label)' has no parent category" -IsError $true
                $null = $treeView.Nodes.Add($groupNode)
            }
        }
    }

    # Expand all categories by default
    $treeView.ExpandAll()

    # Auto-size left panel width
    $maxWidth = Measure-TreeViewMaxWidth -TreeView $treeView
    if ($script:FormControls.SplitContainer) {
        $script:FormControls.SplitContainer.SplitterDistance = $maxWidth + 20
    }

    # Selection event
    $treeView.Add_AfterSelect({
        param($sender, $e)
        $node = $e.Node
        if ($node.Tag -ne $null) {
            switch ($node.Tag.Type) {
                "category" {
                    # for now just return in category case
                    return;
                }
                "group" {
                    SetGroup -Group $node.Tag.Group
                }
            }
        }
    })

    # Select the first group node (first child of first category)
    if ($treeView.Nodes.Count -gt 0 -and $treeView.Nodes[0].Nodes.Count -gt 0) {
        $firstGroupNode = $treeView.Nodes[0].Nodes[0]
        $treeView.SelectedNode = $firstGroupNode
        SetGroup -Group $firstGroupNode.Tag.Group
    }
}

<#
.SYNOPSIS
    Populates the ListBox with category dividers and groups from the loaded configuration.

.DESCRIPTION
    Reads $script:ListItems (built by Load-Configuration) and builds an owner-draw
    ListBox where category dividers appear as bold, centered, non-selectable items
    and groups appear as standard selectable items. Uses custom drawing for
    dividers and dynamic theme colors for groups.

    This function configures the ListBox's DrawMode, attaches the DrawItem event,
    sets ItemHeight based on font size plus padding, and applies auto-width sizing
    to the left panel.

.NOTES
    This function is called by Populate-GUI when "view": "flat" is set in JSON
    (or when no view setting is present, as flat is the default).

    Requires $script:FormControls.LeftPanel to exist (created in Build-GUI).
    Creates $script:FormControls.ListBox and stores it for later access.
#>
function Populate-ListBox {

    # Remove existing TreeView if present
    if ($script:FormControls.ContainsKey('TreeView') -and $script:FormControls.TreeView) {
        $script:FormControls.LeftPanel.Controls.Remove($script:FormControls.TreeView)
        $script:FormControls.TreeView.Dispose()
        $script:FormControls.TreeView = $null
    }

    # Create ListBox using dedicated function
    $listBox = Initialize-ListBox
    $null = $script:FormControls.LeftPanel.Controls.Add($listBox)
    $script:FormControls.ListBox = $listBox

    # Populate items from $script:ListItems
    foreach ($item in $script:ListItems) {
        $null = $listBox.Items.Add($item)
    }

    # Select first non-divider item and trigger initial population
    for ($i = 0; $i -lt $listBox.Items.Count; $i++) {
        if ($listBox.Items[$i].Type -eq "group") {
            $listBox.SelectedIndex = $i
            SetGroup -Group $listBox.Items[$i].Group
            break
        }
    }

    # Selection event
    $listBox.Add_SelectedIndexChanged({
        param($sender, $e)

        $selectedIndex = $sender.SelectedIndex
        if ($selectedIndex -ge 0) {
            $selectedItem = $sender.Items[$selectedIndex]
            if ($selectedItem.Type -eq "category") {
                $sender.SelectedIndex = -1
            } elseif ($selectedItem.Type -eq "group") {
                SetGroup -Group $selectedItem.Group
            }
        }
    })

    # Update width of left panel appropriately
    $maxWidth = Measure-ListBoxMaxWidth -ListBox $listBox
    if ($script:FormControls.SplitContainer) {
        $script:FormControls.SplitContainer.SplitterDistance = $maxWidth
    }
}

<#
.SYNOPSIS
    Creates the toggle button for switching between List and Tree views.

.DESCRIPTION
    Creates a Button control docked to the bottom of the left panel.
    The button's Tag property stores the current view state:
    - $true  = Tree view (category groups with collapsible nodes)
    - $false = Flat view (list with category dividers)

    The click event flips the state via Set-ToggleButton and triggers
    Populate-GUI to rebuild the left panel with the opposite view.

.OUTPUTS
    System.Windows.Forms.Button - The configured toggle button with no initial state (Tag = $null).

.NOTES
    The caller is responsible for:
    - Adding the button to $script:FormControls.LeftPanel
    - Storing the button reference in $script:FormControls.ToggleButton
    - Initializing the button's state via Set-ToggleButton
#>
function Create-ToggleButton {
    $button = New-Object System.Windows.Forms.Button
    $button.Dock = "Bottom"
    $button.Height = 30
    $button.FlatStyle = "Flat"
    $button.Tag = $null

    # Click event for Toggle Button: updates
    # state then calls Populate-GUI again
    $button.Add_Click({
        $newState = -not $this.Tag
        Set-ToggleButton -Button $this -State $newState
        Populate-GUI
    })

    return $button
}

<#
.SYNOPSIS
    Updates the toggle button's visual state and Tag property.

.DESCRIPTION
    Sets the button's Text and Tag based on the provided boolean state:
    - $true  (Tree view)   -> Text = "Switch to List View", Tag = $true
    - $false (Flat view)   -> Text = "Switch to Tree View", Tag = $false

    The Tag serves as the single source of truth for the current view state,
    independent of JSON settings.

.PARAMETER Button
    The toggle button control to update.

.PARAMETER State
    Boolean indicating the desired view:
    - $true  = Switch to Tree view (button shows "Switch to List View")
    - $false = Switch to Flat view (button shows "Switch to Tree View")

.NOTES
    Does NOT trigger Populate-GUI. The caller is responsible for rebuilding
    the view after calling this function.
#>
function Set-ToggleButton {
    param(
        [System.Windows.Forms.Button]$Button,
        [boolean]$State
    )

    Write-Host "DEBUG: Set-ToggleButton $State"
    # State = True ==> set to tree view
    # State = False ==> set to flat view
    if ($State -eq $true) {
        # Set to flat view
        $Button.Text = "Switch to List View"
    } else {
        $Button.Text = "Switch to Tree View"
    }
    $Button.Tag = $State
}

<#
.SYNOPSIS
    Entry point for populating the left panel based on the configured view.

.DESCRIPTION
    Reads the "view" setting from JSON (defaults to "flat") and dispatches to
    either Populate-ListView (flat groups) or Populate-TreeView (collapsible
    categories). Both views share the same underlying data structure
    ($script:ListItems) built by Load-Configuration.

.NOTES
    "view": "flat"   – Uses ListBox with category dividers (original behavior)
    "view": "tree"   – Uses TreeView with collapsible categories
    No other values are supported; invalid values default to "flat".

    This function assumes $script:FormControls.LeftPanel already exists as
    the container panel created in Build-GUI.
#>
function Populate-GUI {
    # if JSON has "categories" key, create tree or list hierarchy based on "view" setting
    if ($script:HasCategories) {
        # Create toggle button if it doesn't exist
        if (-not $script:FormControls.ContainsKey('ToggleButton') -or -not $script:FormControls.ToggleButton) {
            $toggleButton = Create-ToggleButton
            $null = $script:FormControls.LeftPanel.Controls.Add($toggleButton)
            $script:FormControls.ToggleButton = $toggleButton
        }

        # Determine which view to use (default to "flat")
        $view = "flat"

        # User selection view toggle button always takes priority
        # (ensure state is set: is null initially before user click)
        if ($script:FormControls.ToggleButton -and $script:FormControls.ToggleButton.Tag -ne $null) {
            $view = if ($script:FormControls.ToggleButton.Tag -eq $true) { "tree" } else { "flat" }
        } elseif ($script:Settings.PSObject.Properties['view'] -and $script:Settings.view) {
            $view = $script:Settings.view
        } else {
            $view = "flat"
        }

        $buttonState = $true
        if ($view -eq "tree") {
            Write-Host "will populate tree"
            Populate-TreeView
            $buttonState = $true
        } else {
            Write-Host "will populate flat"
            Populate-ListBox
            $buttonState = $false
        }
        # Update initial button state if null
        if ($script:FormControls.ToggleButton -and $script:FormControls.ToggleButton.Tag -eq $null) {
            Set-ToggleButton -Button $script:FormControls.ToggleButton -State $buttonState
        }
    } else {
        # only groups
        Populate-FlatList
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
