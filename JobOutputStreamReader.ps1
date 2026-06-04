<#
.SYNOPSIS
    Provides real-time output streaming for background processes using events.
.DESCRIPTION
    This module uses Register-ObjectEvent to capture stdout/stderr line by line
    as it's written. Output is delivered via a thread-safe queue that the main
    thread polls during its execution loop.

    Functions exported:
    - Start-JobOutputStreamReader
    - Process-JobOutputQueue
    - Stop-JobOutputStreamReader
    - Invoke-UIThread
#>

<#
.SYNOPSIS
    Executes a script block on the UI thread.
.DESCRIPTION
    Wrapper around Control.Invoke to safely update WinForms controls from
    background threads.
.PARAMETER Action
    ScriptBlock to execute on the UI thread.
.PARAMETER Form
    Windows Forms control to use for Invoke. Defaults to $script:MainForm.
#>
function Invoke-UIThread {
    param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$Action,
        
        [System.Windows.Forms.Control]$Form = $script:MainForm
    )
    
    if ($Form -and $Form.InvokeRequired) {
        $Form.Invoke($Action)
    } else {
        & $Action
    }
}

<#
.SYNOPSIS
    Starts real-time output capture for a process using event handlers.
.DESCRIPTION
    Registers OutputDataReceived and ErrorDataReceived events that fire each time
    the child process writes a line. Lines are added to a thread-safe queue for
    the main thread to consume.

.PARAMETER Process
    The System.Diagnostics.Process object to monitor. Must have redirects enabled.

.PARAMETER OutputQueue
    A thread-safe ConcurrentQueue[string] that receives lines with "OUT|" or "ERR|" prefixes.

.PARAMETER DebugLog
    Optional path to a debug log file for troubleshooting event errors.

.OUTPUTS
    Returns a hashtable containing event registration objects for cleanup.
#>
function Start-JobOutputStreamReader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        
        [Parameter(Mandatory = $true)]
        [System.Collections.Concurrent.ConcurrentQueue[string]]$OutputQueue,
        
        [string]$DebugLog
    )
    
    # Verify redirects are enabled
    if (-not $Process.StartInfo.RedirectStandardOutput -and -not $Process.StartInfo.RedirectStandardError) {
        Write-Verbose "No streams to redirect. Streaming disabled."
        return $null
    }
    
    # Generate unique source identifiers
    $outputId = "OutputEvent_$([System.Guid]::NewGuid())"
    $errorId = "ErrorEvent_$([System.Guid]::NewGuid())"
    
    # Helper to write debug logs
    $writeDebug = {
        param($Message)
        if ($DebugLog) {
            $timestamp = Get-Date -Format "HH:mm:ss.fff"
            [System.IO.File]::AppendAllText($DebugLog, "[$timestamp] $Message`r`n")
        }
    }
    
    # Register stdout event
    $outputEvent = Register-ObjectEvent -InputObject $Process -EventName OutputDataReceived -SourceIdentifier $outputId -MessageData $OutputQueue -Action {
        $data = $Event.SourceEventArgs.Data
        if ($data -ne $null) {
            $Event.MessageData.Enqueue("OUT|$data")
        }
    }
    
    # Register stderr event
    $errorEvent = Register-ObjectEvent -InputObject $Process -EventName ErrorDataReceived -SourceIdentifier $errorId -MessageData $OutputQueue -Action {
        $data = $Event.SourceEventArgs.Data
        if ($data -ne $null) {
            $Event.MessageData.Enqueue("ERR|$data")
        }
    }
    
    # Start asynchronous reading
    try {
        $Process.BeginOutputReadLine()
        $Process.BeginErrorReadLine()
        & $writeDebug "Stream reading started for PID $($Process.Id)"
    } catch {
        & $writeDebug "ERROR starting stream read: $($_.Exception.Message)"
        # Clean up events if start fails
        Unregister-Event -SourceIdentifier $outputId -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errorId -ErrorAction SilentlyContinue
        throw
    }
    
    return @{
        OutputEvent = $outputEvent
        ErrorEvent = $errorEvent
        OutputId = $outputId
        ErrorId = $errorId
        DebugLog = $DebugLog
    }
}

<#
.SYNOPSIS
    Drains the output queue and processes lines on the UI thread.
.DESCRIPTION
    Called during Invoke-Job's polling loop to consume any pending output
    lines from the event handlers.

.PARAMETER OutputQueue
    The ConcurrentQueue populated by Start-JobOutputStreamReader.

.PARAMETER StdOut
    Reference to variable that accumulates stdout (passed as [ref]).

.PARAMETER StdErr
    Reference to variable that accumulates stderr (passed as [ref]).

.PARAMETER WriteToUI
    If $true, writes output to UI via Write-OutputWithTimestamp. Default $true.

.OUTPUTS
    Returns $true if any output was processed, $false otherwise.
#>
function Process-JobOutputQueue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Concurrent.ConcurrentQueue[string]]$OutputQueue,
        
        [Parameter(Mandatory = $true)]
        [PSObject]$ResultObject,
        
        [bool]$WriteToUI = $true
    )
    
    $hadOutput = $false
    $line = $null
    
    while ($OutputQueue.TryDequeue([ref]$line)) {
        $hadOutput = $true
        
        # Parse line format: "TYPE|content"
        $separatorIdx = $line.IndexOf('|')
        if ($separatorIdx -le 0) { continue }
        
        $type = $line.Substring(0, $separatorIdx)
        $content = $line.Substring($separatorIdx + 1)
        
        # Update UI if requested
        if ($WriteToUI) {
            $isErrorLine = ($type -eq "ERR")
            Invoke-UIThread {
                Write-OutputWithTimestamp $content -IsError $isErrorLine
            }
        }

        # Append to result object for final log
        # NOTE: StdOut and StdErr properties are expected to already exist on ResultObject
        if ($type -eq "OUT") {
            $currentStdOut = Get-JobResultProperty -JobResult $ResultObject -Property "StdOut" -FailIfMissing
            $ResultObject.StdOut = "$currentStdOut$content`r`n"
        } elseif ($type -eq "ERR") {
            $currentStdErr = Get-JobResultProperty -JobResult $ResultObject -Property "StdErr" -FailIfMissing
            $ResultObject.StdErr = "$currentStdErr$content`r`n"
        }
    }
    
    return $hadOutput
}
        
<#
.SYNOPSIS
    Stops the stream reader and cleans up event registrations.
.DESCRIPTION
    Unregisters events and disposes resources. Should be called in finally block.

.PARAMETER ReaderHandle
    The hashtable returned by Start-JobOutputStreamReader.
#>
function Stop-JobOutputStreamReader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ReaderHandle
    )
    
    if (-not $ReaderHandle) { return }
    
    $debugLog = $ReaderHandle.DebugLog
    
    $writeDebug = {
        param($Message)
        if ($debugLog) {
            $timestamp = Get-Date -Format "HH:mm:ss.fff"
            [System.IO.File]::AppendAllText($debugLog, "[$timestamp] $Message`r`n")
        }
    }
    
    try {
        # Unregister events
        if ($ReaderHandle.OutputId) {
            Unregister-Event -SourceIdentifier $ReaderHandle.OutputId -ErrorAction SilentlyContinue
            & $writeDebug "Unregistered output event: $($ReaderHandle.OutputId)"
        }
        if ($ReaderHandle.ErrorId) {
            Unregister-Event -SourceIdentifier $ReaderHandle.ErrorId -ErrorAction SilentlyContinue
            & $writeDebug "Unregistered error event: $($ReaderHandle.ErrorId)"
        }
    } catch {
        & $writeDebug "ERROR during cleanup: $($_.Exception.Message)"
    }
}
