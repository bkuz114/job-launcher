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

# =============================================================================
# USER CONFIGURABLE SETTINGS
# =============================================================================

# --- UI Colors ---
$UI_Color_Background = [System.Drawing.Color]::FromArgb(240, 240, 240)
$UI_Color_Panel = [System.Drawing.Color]::White
$UI_Color_Button = [System.Drawing.Color]::FromArgb(220, 230, 240)
$UI_Color_ButtonHover = [System.Drawing.Color]::FromArgb(200, 215, 230)
$UI_Color_ButtonRunning = [System.Drawing.Color]::FromArgb(255, 200, 100)
$UI_Color_OutputBackground = [System.Drawing.Color]::FromArgb(30, 30, 30)
$UI_Color_OutputText = [System.Drawing.Color]::FromArgb(220, 220, 220)
$UI_Color_StatusOk = [System.Drawing.Color]::FromArgb(40, 180, 60)
$UI_Color_StatusError = [System.Drawing.Color]::FromArgb(220, 60, 50)
$UI_Color_StatusRunning = [System.Drawing.Color]::FromArgb(240, 180, 0)

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
            if ($process.HasExited) {
                break
            }
            Start-Sleep -Milliseconds $TimeoutPollIntervalMs
            $elapsedMs += $TimeoutPollIntervalMs
        }

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
        $script:CurrentRunningJob = $null
    }
}

function Set-JobButtonsEnabled {
    param([bool]$Enabled)

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
    }
}

function Invoke-JobAndManageUI {
    param([hashtable]$Job, [System.Windows.Forms.Button]$JobButton)

    # Disable all job buttons
    Set-JobButtonsEnabled -Enabled $false

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
        Set-JobButtonsEnabled -Enabled $true
        Update-Status "Ready" $UI_Color_Background
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

function Build-GUI {
    # --- Main Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Job Launcher"
    $form.Width = $UI_Window_Width
    $form.Height = $UI_Window_Height
    $form.StartPosition = "CenterScreen"
    $form.BackColor = $UI_Color_Background
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $true

    # --- Left Panel (Groups ListBox) ---
    $leftPanel = New-Object System.Windows.Forms.Panel
    $leftPanel.Width = $UI_LeftPanel_Width
    $leftPanel.Height = $form.ClientSize.Height - 10
    $leftPanel.Location = New-Object System.Drawing.Point(5, 5)
    $leftPanel.BackColor = $UI_Color_Panel
    $leftPanel.BorderStyle = "FixedSingle"

    # Groups ListBox
    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Dock = "Fill"
    $listBox.Font = New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Normal)
    $listBox.IntegralHeight = $false

    $null = $leftPanel.Controls.Add($listBox)
    $null = $form.Controls.Add($leftPanel)

    # --- Right Panel Container ---
    $rightPanel = New-Object System.Windows.Forms.Panel
    $rightPanel.Left = $UI_LeftPanel_Width + 10
    $rightPanel.Width = $form.ClientSize.Width - $UI_LeftPanel_Width - 20
    $rightPanel.Height = $form.ClientSize.Height - 10
    $rightPanel.Top = 5
    $rightPanel.BackColor = $UI_Color_Background

    # --- FlowLayoutPanel for Job Buttons ---
    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = "Fill"
    $buttonPanel.FlowDirection = "TopDown"
    $buttonPanel.WrapContents = $true
    $buttonPanel.AutoScroll = $true
    $buttonPanel.BackColor = $UI_Color_Background
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding(5)

    # --- Output TextBox (at bottom, but inside right panel we need split layout) ---
    $rightTable = New-Object System.Windows.Forms.TableLayoutPanel
    $rightTable.Dock = "Fill"
    $rightTable.RowCount = 2
    $rightTable.ColumnCount = 1
    $rightTable.RowStyles.Clear()

    $rowStyle1 = New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)
    $rowStyle2 = New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $UI_Output_Height)

    $null = $rightTable.RowStyles.Add($rowStyle1)
    $null = $rightTable.RowStyles.Add($rowStyle2)

    # Add button panel to first row
    $null = $rightTable.Controls.Add($buttonPanel, 0, 0)

    # Output textbox with scrollable area
    $outputTextBox = New-Object System.Windows.Forms.RichTextBox
    $outputTextBox.Dock = "Fill"
    $outputTextBox.BackColor = $UI_Color_OutputBackground
    $outputTextBox.ForeColor = $UI_Color_OutputText
    $outputTextBox.ReadOnly = $true
    $outputTextBox.BorderStyle = "FixedSingle"

    $outputFont = if ($UI_Font_OutputMonospaced) {
        New-Object System.Drawing.Font("Consolas", $UI_Font_Size_Output)
    } else {
        New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Output)
    }
    $outputTextBox.Font = $outputFont

    $null = $rightTable.Controls.Add($outputTextBox, 0, 1)
    $null = $rightPanel.Controls.Add($rightTable)
    $null = $form.Controls.Add($rightPanel)

    # --- Status Bar at bottom of main form ---
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = "Ready"
    $statusLabel.ForeColor = $UI_Color_Background
    $null = $statusStrip.Items.Add($statusLabel)
    $null = $form.Controls.Add($statusStrip)

    # --- Kill Job Button (on main form toolbar area) ---
    $killButton = New-Object System.Windows.Forms.Button
    $killButton.Text = "Kill Current Job"
    $killButton.Width = 120
    $killButton.Height = 30
    $killButton.Left = $form.ClientSize.Width - 130
    $killButton.Top = $statusStrip.Top - 35
    $killButton.BackColor = $UI_Color_Button
    $killButton.FlatStyle = "Flat"
    $killButton.Enabled = $false
    $killButton.Add_Click({
        Stop-CurrentJob
    })
    $null = $form.Controls.Add($killButton)

    # Store references in script scope
    $script:OutputTextBox = $outputTextBox
    $script:StatusLabel = $statusLabel
    $script:KillButton = $killButton
    $script:MainForm = $form
    $script:GroupListBox = $listBox

    # Build and explicitly return the hashtable
    $result = @{
        Form = $form
        ListBox = $listBox
        ButtonPanel = $buttonPanel
    }

    # Explicit return
    return $result
}

function UpdateButtonsForGroup {
    param($Group, $FormControls)

    # Clear existing buttons
    $FormControls.ButtonPanel.Controls.Clear()
    $script:JobButtons.Clear()

    # Direct access to jobs from the group object (no filtering needed)
    $jobs = $Group.jobs

    foreach ($job in $jobs) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $job.name
        $btn.Height = $UI_Button_Height
        $btn.Width = $FormControls.ButtonPanel.Width - 20
        $btn.TextAlign = "MiddleLeft"
        $btn.BackColor = $UI_Color_Button
        $btn.FlatStyle = "Flat"
        $btn.Margin = New-Object System.Windows.Forms.Padding($UI_Button_Margin)

        # Store job data in button's Tag property
        $btn.Tag = $job

        # Add hover effect
        $btn.Add_MouseEnter({
            if ($this.Enabled) { $this.BackColor = $UI_Color_ButtonHover }
        })
        $btn.Add_MouseLeave({
            if ($this.Enabled) { $this.BackColor = $UI_Color_Button }
        })

        # Click handler - with conversion for compatibility
        $btn.Add_Click({
            # Convert PSCustomObject to Hashtable
            $jobToRun = @{}
            $this.Tag.psobject.Properties | ForEach-Object { $jobToRun[$_.Name] = $_.Value }
            $buttonRef = $this

            # Disable all job buttons immediately
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
            Set-JobButtonsEnabled -Enabled $true
            Update-Status "Ready" $UI_Color_Background
        })

        $null = $FormControls.ButtonPanel.Controls.Add($btn)
        $script:JobButtons[$job.name] = $btn
    }
}

function Populate-GUI {
    param($FormControls)

    # Defensive check
    if (-not $FormControls -or -not $FormControls.ContainsKey('ListBox')) {
        Write-Error "Populate-GUI: Invalid FormControls parameter. Missing ListBox."
        return
    }

    # Get group names directly from GroupsData array
    $groups = $script:GroupsData | ForEach-Object { $_.name }

    # Populate ListBox
    $FormControls.ListBox.Items.Clear()
    foreach ($group in $groups) {
        $null = $FormControls.ListBox.Items.Add($group)
    }

    if ($FormControls.ListBox.Items.Count -gt 0) {
        $FormControls.ListBox.SelectedIndex = 0
    }

    # Bind selection change event
    $FormControls.ListBox.Add_SelectedIndexChanged({
        if ($FormControls.ListBox.SelectedItem -and $script:GroupsData) {
            $selectedIndex = $FormControls.ListBox.SelectedIndex
            $selectedGroup = $script:GroupsData[$selectedIndex]
            UpdateButtonsForGroup -Group $selectedGroup -FormControls $FormControls
        }
    })

    # Trigger initial population
    if ($FormControls.ListBox.Items.Count -gt 0) {
        $selectedGroup = $script:GroupsData[0]
        UpdateButtonsForGroup -Group $selectedGroup -FormControls $FormControls
    }
}

function Initialize-ColorsForControls {
    param($FormControls)

    # Apply colors to existing controls
    if ($FormControls.Form) {
        $FormControls.Form.BackColor = $UI_Color_Background
    }
    if ($FormControls.ListBox) {
        $FormControls.ListBox.BackColor = $UI_Color_Panel
    }
    if ($FormControls.ButtonPanel) {
        $FormControls.ButtonPanel.BackColor = $UI_Color_Background
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

    Write-Host "DEBUG: About to call Build-GUI"

    # Build GUI - this returns a hashtable with Form, ListBox, ButtonPanel
    $formControls = Build-GUI

    Write-Host "DEBUG: Build-GUI returned type: $($formControls.GetType().FullName)"
    Write-Host "DEBUG: Build-GUI returned value: $formControls"

    # Verify we got valid controls
    if ($formControls -isnot [hashtable]) {
        Write-Host "ERROR: Build-GUI did not return a hashtable. Got: $($formControls.GetType().FullName)"
        exit 1
    }

    if (-not $formControls.ContainsKey('Form')) {
        Write-Host "ERROR: Returned hashtable missing 'Form' key"
        exit 1
    }

    Write-Host "DEBUG: GUI built successfully, about to populate"

    # Populate with jobs - pass the entire hashtable
    Populate-GUI -FormControls $formControls

    Write-Host "DEBUG: GUI populated, about to apply colors"

    # Apply colors (after population)
    Initialize-ColorsForControls -FormControls $formControls

    Write-Host "DEBUG: Colors applied, setting up close handler"

    # Handle form closing event to kill running job if needed
    $formControls.Form.Add_FormClosing({
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
    $formControls.Form.ShowDialog() | Out-Null

    Write-Host "DEBUG: Form closed"
}

# Run the application
Main
