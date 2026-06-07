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

# File for streaming stdout / stderr in output area
. (Join-Path $PSScriptRoot "JobOutputStreamReader.ps1")

# Required assemblies for GUI and process management
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Strict mode catches undefined variables and other common mistakes
Set-StrictMode -Version Latest

# Default error action: Stop makes try/catch work predictably
$ErrorActionPreference = 'Stop'

# Marker to appear in dropdowns
$DropdownMarker = "✓ "

# Will hold hashtable from $Script:Themes
$script:CurrentTheme = $null
$script:CurrentThemePalette = $null

$script:FormControls = $null

$script:KillRequested = $false
# Used as a hack to programatically set the theme dropdown
# without triggering a change event (which would then trigger
# a user override which will theme updates from group/category
# changes impossible)
$script:SuppressThemeDropdownEvent = $false

# theme name user selects from the theme dropdown (if they make a selection)
# need to prevent group switching JSON from overriding their selection
$script:UserSelectedTheme = $null

# Built-in fallback theme (always available)
$script:FallbackTheme = @{
    form_background   = "#F0F0F0"
    toolbar_background = "#F0F0F0"
    toolbar_text      = "#000000"
    list_background   = "#FFFFFF"
    list_text         = "#000000"
    list_background_selected = "#DCE6F0"
    list_text_selected = "#000000"
    list_text_divider = "#A0A0A0"
    panel_background  = "#F0F0F0"
    button            = "#DCE6F0"
    button_hover      = "#C8D7E6"
    button_text       = "#000000"
    button_running    = "#FFC107"
    kill_button       = "#DCE6F0"
    kill_button_text  = "#000000"
    output_background = "#F5F5F5"
    output_text       = "#1E1E1E"
    status_text       = "#000000"
    status_ok         = "#28A745"
    status_error      = "#DC3545"
    status_running    = "#FFC107"
}

# name for this fallback theme
# (will be added into theme dropdown;
# can also be specified in JSON config)
$script:FallbackThemeName = "default"

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
$EnableRealTimeOutput = $true # real-time output streaming (experimental)

# --- Process Execution ---
$KillProcessTree = $true
$KillTimeoutGraceSeconds = 5
$TimeoutPollIntervalMs = 1000

# --- Logging ---
$LogRetentionDays = 30
$LogIncludeEnvironmentInfo = $true
$LogTimestampEntries = $true

# --- Default Values ---
$DefaultSettingsPath = Join-Path $PSScriptRoot "launcher_settings.json" # Path to launcher settings
$DefaultJobConfigsDirectory = Join-Path $PSScriptRoot "job_configs" # default dir for job JSON files (can be overwritten in launcher_settings.json)
$DefaultLogsDirectoryName = "Logs"  # Name of default log folder (relative to script; used if JSON doesn't specify) 
$DefaultLogsDirectory = Join-Path -Path (Split-Path -Path $script:MyInvocation.MyCommand.Path -Parent) -ChildPath $DefaultLogsDirectoryName
$DefaultTimeoutSeconds = 30
$AppIcon = Join-Path $PSScriptRoot "assets\favicon.ico" # App icon
$AppBranding = Join-Path $PSScriptRoot "assets\branding.png" # Image to display in toolbar

# =============================================================================
# END USER CONFIGURABLE SETTINGS
# =============================================================================

# =============================================================================
# GLOBAL STATE (minimized and controlled)
# =============================================================================

# Script-scoped variables (not global scope, but accessible to functions defined below)
$script:CurrentRunningJob = $null           # Hashtable with: Process, JobName, Button, StartTime
$script:CurrentItem = $null                 # Curr selected group or category (for preserving through view toggles)
$script:HasCategories = $false              # If Parsed JSON has top level "categories"
$script:LauncherSettings = $null            # Parsed JSON settings object from launcher config
$script:Settings = $null                    # Parsed JSON settings object from currently selected config
$script:OutputTextBox = $null               # Reference to UI control
$script:StatusLabel = $null                 # Reference to UI control
$script:JobButtons = @{}                    # Dictionary mapping job name to button control
$script:KillButton = $null                  # Reference to Kill button
$script:ThemeMenuItem = $null               # Theme dropdown
$script:MainForm = $null                    # Reference to main window
$script:NavigationItems = $null             # Collection of all categories/groups from parsed JSON config.
                                            # Each item has .Type ("category" or "group"), .Label (display name),
                                            # .Node (original JSON object), and .Parent (for groups only).
                                            # Used as the data source for BOTH TreeView (hierarchical) and
                                            # ListBox (flat) left panel views.
$script:CurrentDisplayedGroup = $null       # currently display group (group whos jobs are in right panel).
                                            # Used to revert when a category is clicked.
                                            # This is NOT redundant to CurrentItem as it could be a category

# =============================================================================
# GLOBAL STATE FOR CONFIG MANAGEMENT
# =============================================================================

$script:AvailableConfigs = @{}        # Hashtable of parsed configs (key = config name)
$script:CurrentConfigName = $null     # Currently active config name
$script:ConfigMenuItem = $null        # Reference to config dropdown control

# =============================================================================
# ERROR HINTS
# =============================================================================

# list of common errors failed jobs might dispaly, and helpful hints to dispaly in logs/console

$script:ErrorHints = @{
    "The system cannot find the file specified" = @"


HINT: Check the 'command' field for this job in the JSON configuration file.
The first word must be an executable in your PATH or a full path to an .exe.

Example: "cmd.exe /c echo hello" (good)
Instead of: "echo hello" (bad — 'echo' is a shell built-in, not an executable)

"@
}

# =============================================================================
# JSON LOADING
# =============================================================================

<#
.SYNOPSIS
    Reads and parses the launcher settings JSON file.

.DESCRIPTION
    Loads launcher_settings.json from the specified path, parses it into
    a PSCustomObject, and returns it. Displays a message box and returns
    $false if the file is missing or invalid.

.PARAMETER ConfigPath
    Full path to the launcher_settings.json file.

.OUTPUTS
    [PSCustomObject] - Parsed settings on success.
    [bool] $false - If the file is missing or parsing fails.

.EXAMPLE
    $settings = Load-LauncherSettings -ConfigPath ".\launcher_settings.json"
    if ($settings -eq $false) { exit 1 }

.NOTES
    The caller is responsible for validating required fields and providing
    default values. This function only performs file I/O and JSON parsing.
#>
function Load-LauncherSettings {
    param(
        [Parameter(Mandatory = $true)]
        [String]$ConfigPath
    )

    # If ConfigPath relative, resolve rel script dir
    if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
        $resolvedPath = $ConfigPath
    } else {
        $resolvedPath = Join-Path -Path $PSScriptRoot -ChildPath $ConfigPath
    }

    # Ensure launcher settings JSON exists
    if (-not (Test-Path -Path $resolvedPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Configuration file not found: $resolvedPath`n`nPlease ensure launcher_settings.json exists in the script directory.",
            "Configuration Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return $false
    }

    try {
        $jsonContent = Get-Content -Path $resolvedPath -Raw -Encoding UTF8
        $config = $jsonContent | ConvertFrom-Json
        return $config
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to parse launcher configuration file: $resolvedPath`n`nError: $($_.Exception.Message)",
            "Configuration Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

<#
.SYNOPSIS
    Scans a directory and loads all valid job configuration files.

.DESCRIPTION
    Reads the job_configs_directory from launcher settings, scans for .json
    files, and attempts to load each using Load-Configuration. Valid configs
    are stored in a hashtable keyed by config name (from the config's internal
    "name" field or filename). Invalid configs are skipped with warnings.

.PARAMETER ConfigDir (string)
    The directory to look for JSON files in.

.OUTPUTS
    [hashtable] - Keys are config names, values are hashtables containing:
        - Name (string)
        - FilePath (string)
        - Settings (PSCustomObject from config.settings)
        - NavigationItems (array of category/group items)
        - HasCategories (bool)

.EXAMPLE
    $configs = Discover-JobConfigs -ConfigDir ".\\json"

.NOTES
    This function does NOT modify globals. It returns a hashtable that the
    caller can store in $script:AvailableConfigs.
#>
function Discover-JobConfigs {
    param(
        [Parameter(Mandatory = $true)]
        [String]$ConfigDir
    )

    $availableConfigs = @{}

    if (-not (Test-Path $ConfigDir)) {
        throw "Job configs directory not found: $ConfigDir"
    }

    # PowerShell will return a scalar (not one-element array) if only one file found,
    # so you must force this into an array via @( ) to ensure an array
    $jsonFiles = @(Get-ChildItem -Path $ConfigDir -Filter "*.json" -File)

    if ($jsonFiles.Count -eq 0) {
        throw "WARNING: No JSON files found in $ConfigDir"
    }

    # Call Load-Configuration for each JSON file discovered
    foreach ($file in $jsonFiles) {
        try {
            $config = Load-Configuration -ConfigPath $file.FullName -Silent $true

            if ($config) {
                $errorContext = "Discover-JobConfigs: property missing from config hash returned from Load-Configuration"
                $settings = Get-HashTableProperty -Hashtable $config -Key "settings" -FailIfMissing -ErrorContext $errorContext
                $hasCategories = Get-HashTableProperty -Hashtable $config -Key "HasCategories" -FailIfMissing -ErrorContext $errorContext
                $items = Get-HashTableProperty -Hashtable $config -Key "items" -FailIfMissing -ErrorContext $errorContext
                $configName = Get-PSObjectProperty -Object $settings -Property "name"

                if (-not $configName) {
                    $configName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
                }

                $availableConfigs[$configName] = @{
                    Name = $configName
                    FilePath = $file.FullName
                    Settings = $settings
                    NavigationItems = $items
                    HasCategories = $hasCategories
                }
                Write-Host "DEBUG: Loaded config '$configName' from $($file.Name)"
            } else {
                throw "Discover-JobConfigs: result from Load-Configuration was null"
            }
        }
        catch {
            Write-Host "WARNING: Failed to load $($file.Name): $($_.Exception.Message)"
        }
    }

    return $availableConfigs
}

<#
.SYNOPSIS
    Finds a config key in AvailableConfigs by matching against name or file path.

.DESCRIPTION
    Searches $script:AvailableConfigs for a config that matches the given identifier.
    Match priority:
        1. Exact key match (fast path)
        2. File path match (full path, relative path, or filename)
        3. Filename without extension match

    Returns the config key (string) if found, otherwise $null.

.PARAMETER AvailableConfigs
    Hashtable of available configs (keys are config names, values are hashtables
    with at least 'Name' and 'FilePath' properties).

.PARAMETER Config
    The config identifier to search for. Can be a config name, filename, file path,
    or filename without extension.

.EXAMPLE
    $key = Find-Config -AvailableConfigs $script:AvailableConfigs -Config "a.json"
    # Returns "myjson" if a.json contains a name field, otherwise returns "a"

.EXAMPLE
    $key = Find-Config -AvailableConfigs $script:AvailableConfigs -Config "myjson"
    # Returns "myjson" (exact key match)

.EXAMPLE
    $key = Find-Config -AvailableConfigs $script:AvailableConfigs -Config "nonexistent"
    # Returns $null
#>
function Find-Config {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$AvailableConfigs,
        [Parameter(Mandatory = $true)]
        [string]$Config
    )

    # Fast path: exact key match
    if ($AvailableConfigs.ContainsKey($Config)) {
        return $Config
    }

    # Search through all configs
    foreach ($key in $AvailableConfigs.Keys) {
        $configInfo = $AvailableConfigs[$key]

        # each config should have a FilePath attribute
        if (-not $configInfo.ContainsKey('FilePath')) {
            throw "Find-Config: AvailableConfigs entry '$key' missing required 'FilePath' field; can not proceed with finding a config. (Hint: was the way configs are loaded into `$script:AvailableConfigs` within Discover-JobConfigs changed?)"
        }
        $filePath = $configInfo.FilePath
        $fileName = Split-Path $filePath -Leaf
        $fileNameWithoutExt = [System.IO.Path]::GetFileNameWithoutExtension($fileName)

        # Match against full file path
        if ($filePath -eq $Config) {
            return $key
        }

        # Match against filename (e.g., "a.json")
        if ($fileName -eq $Config) {
            return $key
        }

        # Match against filename without extension (e.g., "a")
        if ($fileNameWithoutExt -eq $Config) {
            return $key
        }
    }

    return $null
}

<#
.SYNOPSIS
    Determines which job configuration to load on startup.

.DESCRIPTION
    Checks launcher settings for a 'default_config' field. If present and
    valid (exists in $script:AvailableConfigs), returns that config name.
    Otherwise, falls back to the first config alphabetically.

    Throws an error if $script:AvailableConfigs is empty or not defined.

.OUTPUTS
    [string] - The name of the default config to load.

.EXAMPLE
    $defaultConfig = Get-DefaultConfig

.NOTES
    This function relies on $script:AvailableConfigs and
    $script:LauncherSettings being already populated.
#>
function Get-DefaultConfig {
    # Validate AvailableConfigs exists and has entries
    if (-not $script:AvailableConfigs -or $script:AvailableConfigs.Keys.Count -eq 0) {
        throw "Get-DefaultConfig: No available configs found. Cannot determine default config."
    }

    # Validate LauncherSettings exists
    if (-not $script:LauncherSettings) {
        throw "Get-DefaultConfig: LauncherSettings is not loaded. Cannot determine default config."
    }

    # Check launcher settings for default_config
    $defaultConfig = $null
    if ($script:LauncherSettings.PSObject.Properties['default_config'] -and $script:LauncherSettings.default_config) {
        $defaultConfig = $script:LauncherSettings.default_config

        # Validate default_config exists, or fall back to first config alphabetically

        # IMPORTANT: Keys in AvailableConfigs are config NAMES (e.g., a 'name' field from JSON
        # or the filename without extension), NOT file paths. A user specifying 'default_config'
        # will intuitively supply a filename or path, not a config name. Therefore, a simple
        # ContainsKey() check is insufficient. Use Find-Config instead.

        $matchingKey = Find-Config -AvailableConfigs $script:AvailableConfigs -Config $defaultConfig
        if ($matchingKey) {
            return $matchingKey
        } else {
            Write-Host "WARNING: 'default_config' from launcher settings ('$defaultConfig') not found in available configs. Using first config alphabetically."
        }
    } else {
        Write-Host "DEBUG: No 'default_config' field specified in launcher settings. Using first config alphabetically."
    }

    # return first config found, alphabetically.

    # Force array before indexing:
    # - $script:AvailableConfigs has only one key, .Keys returns that single key (not an array)
    #   and [0] would return the first character.
    # - The @() wrapper ensures a one-element array.
    return @($script:AvailableConfigs.Keys | Sort-Object)[0]
}

<#
.SYNOPSIS
    Loads and validates a hierarchical configuration with categories, groups, and jobs.

.DESCRIPTION
    Processes the JSON configuration when it contains a "categories" array.
    Each category contains a "groups" array, and each group contains a "jobs" array.

    Returns an array of items representing the navigation structure:
    - Type "category" for category headers (non-selectable, visual separation)
    - Type "group" for selectable groups (stores original group object in .Node)

    Throws terminating errors for any missing required fields or empty collections.

.PARAMETER Config
    The PSCustomObject from ConvertFrom-Json containing the full configuration.

.EXAMPLE
    $items = Load-HierarchicalConfig -Config $config

.NOTES
    Caller is responsible for setting $script:HasCategories = $true.
#>
function Load-HierarchicalConfig {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Config
    )

    if (-not $config.categories) { throw "Missing 'categories' array" }
    if ($config.categories.Count -eq 0) { throw "No categories defined" }

    $items = @()

    foreach ($category in $config.categories) {
        # Validate category has name
        if ([string]::IsNullOrWhiteSpace($category.name)) { throw "Category missing 'name' field" }
        if (-not $category.groups) { throw "Category '$($category.name)' missing 'groups' array" }

        # Add divider for category
        $categoryItem = [PSCustomObject]@{
            Type = "category"
            Label = $category.name
            Node = $category
        }
        $categoryItem | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Label } -Force
        $items += $categoryItem

        # Validate each group has name and jobs
        foreach ($group in $category.groups) {
            if ([string]::IsNullOrWhiteSpace($group.name)) { throw "Group missing 'name' in category '$($category.name)'" }
            if (-not $group.jobs) { throw "Group '$($group.name)' missing 'jobs' array" }
            if ($group.jobs.Count -eq 0) { throw "Group '$($group.name)' has no jobs defined" }

            # Validate each job in the group and wrap in Job Item
            $wrappedJobs = @()
            foreach ($job in $group.jobs) {
                if ([string]::IsNullOrWhiteSpace($job.name)) { throw "Job missing 'name' field in group '$($group.name)'" }
                if ([string]::IsNullOrWhiteSpace($job.command)) { throw "Job '$($job.name)' missing 'command' field" }

                # Create Job Item with parent references
                $jobItem = [PSCustomObject]@{
                    Type           = "job"
                    Label          = $job.name
                    Node           = $job
                    ParentGroup    = $group
                    ParentCategory = $category
                }
                $jobItem | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Label } -Force
                $wrappedJobs += $jobItem
            }

            # add group to global ListItems
            $groupItem = [PSCustomObject]@{
                Type = "group"
                Label = $group.name
                Node = $group
                JobItems = $wrappedJobs # add wrapped jobs 
                Parent = $category  # add parent category to retrieve theme from
            }
            $groupItem | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Label } -Force
            $items += $groupItem
        }
    }

    return $items
}

<#
.SYNOPSIS
    Loads and validates a flat configuration with groups and jobs (no categories).

.DESCRIPTION
    Processes the JSON configuration when it contains a "groups" array (and no "categories").
    Validates each group has a name, a non-empty jobs array, and each job has a name and command.

    Returns an array of group items, each containing .Label, .JobItems (array of wrapped job objects),
    and .Node (original group object). Group items include a custom ToString method for ListBox display.

.PARAMETER Config
    The PSCustomObject from ConvertFrom-Json containing the full configuration.

.EXAMPLE
    $items = Load-FlatConfig -Config $config

.NOTES
    Caller is responsible for setting $script:HasCategories = $false.
#>
function Load-FlatConfig {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Config
    )

    if (-not $config.groups) { throw "Missing 'groups' array" }
    if ($config.groups.Count -eq 0) { throw "No groups defined in configuration" }

    $items = @()

    # Validate each group has name and jobs
    foreach ($group in $config.groups) {
        if ([string]::IsNullOrWhiteSpace($group.name)) { throw "Group missing 'name' field" }
        if (-not $group.jobs) { throw "Group '$($group.name)' missing 'jobs' array" }
        if ($group.jobs.Count -eq 0) { throw "Group '$($group.name)' has no jobs defined" }

        # Validate each job in the group and wrap in Job Item
        $wrappedJobs = @()
        foreach ($job in $group.jobs) {
            if ([string]::IsNullOrWhiteSpace($job.name)) { throw "Job missing 'name' field in group '$($group.name)'" }
            if ([string]::IsNullOrWhiteSpace($job.command)) { throw "Job '$($job.name)' missing 'command' field" }

            # Create Job Item with parent references (no category in flat config)
            $jobItem = [PSCustomObject]@{
                Type           = "job"
                Label          = $job.name
                Node           = $job
                ParentGroup    = $group
                ParentCategory = $null
            }
            $jobItem | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Label } -Force
            $wrappedJobs += $jobItem
        }

        # add entry with custom ToString function
        # (will be needed for when adding to ListBox
        # so it will know what to draw without having
        # to attach some complicated Add_Draw event)
        $groupItem = [PSCustomObject]@{
            Type = "group"
            Label = $group.name
            JobItems = $wrappedJobs # add wrapped jobs 
            Node = $group
        }
        # DO NOT REMOVE THIS. It's what allows you to add these items to $script:FormControls.ListBox
        # and the system will know what to "draw", without having to add a Draw event which screws up
        # width. And you NEED to add the entire group object (Rather than just the name) into the ListBox
        # so that the ListBox data structure will be uniform across both hierarchical and flat case
        # (instead of strings in one, and objects in another)
        $groupItem | Add-Member -MemberType ScriptMethod -Name ToString -Value { $this.Label } -Force
        $items += $groupItem
    }

    return $items
}

<#
.SYNOPSIS
    Loads and validates the launcher configuration from a JSON file, returning a hashtable with the parsed data.

.DESCRIPTION
    Reads launcher_config.json from the script directory, parses it, and validates
    the required structure. Determines whether the configuration uses a hierarchical
    structure (categories containing groups) or a flat structure (groups only).

    Dispatches to either Load-HierarchicalConfig or Load-FlatConfig for
    detailed validation and data loading.

.PARAMETER ConfigPath
    Full path to the launcher_config.json file.

.EXAMPLE
    $configData = Load-Configuration -ConfigPath "C:\JobLauncher\launcher_config.json"
    if ($configData) {
        $script:Settings = $configData.settings
        $script:HasCategories = $configData.hasCategories
        $script:NavigationItems = $configData.items
    }

.NOTES
    Returns a hashtable with the following keys on success:
    - hasCategories: [bool] $true if hierarchical, $false if flat
    - items: [array] Navigation items from Load-HierarchicalConfig or Load-FlatConfig
    - settings: [PSCustomObject] The parsed settings section from the JSON

    Returns $null on failure (with error message displayed via MessageBox).
    Caller should check the return value and handle failure appropriately.
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
        return $null
    }

    try {
        $jsonContent = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $config = $jsonContent | ConvertFrom-Json

        # Validate required structure (nested format)
        if (-not $config.settings) { throw "Missing 'settings' section" }

        if ($config.PSObject.Properties['categories']) {
            # JSON has high level "categories" field -- hierarchical structure
            $items = Load-HierarchicalConfig -Config $config
            $hasCategories = $true
        } elseif ($config.PSObject.Properties['groups']) {
            # JSON has high level "groups" field -- flat structure
            $items = Load-FlatConfig -Config $config
            $hasCategories = $false
        } else {
            throw "JSON must have either 'categories' or 'groups' array"
        }

        return @{
            hasCategories = $hasCategories
            items         = $items
            settings      = $config.settings
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Failed to parse configuration file: $ConfigPath`n`nError: $($_.Exception.Message)",
            "Configuration Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return $null
    }
}

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

<#
.SYNOPSIS
    Generates a unique log filename for a job based on its name and current timestamp.

.DESCRIPTION
    Creates a filename in the format: sanitized_jobname_YYYYMMDD_HHMMSS[-suffix].log
    Sanitizes the job name by replacing non-alphanumeric characters with underscores.
    If a suffix is provided, it is appended before the .log extension.

.PARAMETER JobName
    The name of the job. Must not be null or empty.

.PARAMETER Suffix
    Optional suffix to add before the .log extension (e.g., "detached").
    If provided, the format becomes: name_timestamp-suffix.log

.EXAMPLE
    Generate-JobLogFilename -JobName "My Job" -> "My_Job_20250101_120000.log"
    Generate-JobLogFilename -JobName "My Job" -Suffix "detached" -> "My_Job_20250101_120000-detached.log"
    Generate-JobLogFilename -JobName "My Job - (version B)" -> "My_Job_version_B_20250101_120000.log"
    Generate-JobLogFilename -JobName "___" -> "20250101_120000.log"

.NOTES
    Throws an error if JobName is null or empty.
#>
function Generate-JobLogFilename {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [string]$Suffix = ""
    )

    if ([string]::IsNullOrWhiteSpace($JobName)) {
        throw "Generate-JobLogFilename: JobName cannot be null or empty"
    }

    # Replace any non-alphanumeric character with underscore
    $safeName = $JobName -replace '[^a-zA-Z0-9]', '_'

    # Collapse multiple consecutive underscores into one
    $safeName = $safeName -replace '_+', '_'

    # Trim _ chars
    $safeName = $safeName.Trim('_')

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    # Handle edge case where safeName is empty after trimming
    if ([string]::IsNullOrEmpty($safeName)) {
        $safeName = $timestamp
    } else {
        $safeName = "${safeName}_${timestamp}"
    }

    if ($Suffix) {
        return "${safeName}-${Suffix}.log"
    } else {
        return "${safeName}.log"
    }
}

<#
.SYNOPSIS
    Determines the log directory by testing candidate locations in priority order.

.DESCRIPTION
    Tests each candidate directory in priority order:
    1. JSON settings.logs_directory (if provided and valid)
    2. $DefaultLogsDirectory (script default, relative to script location)
    3. Windows TEMP directory (ultimate fallback: %TEMP%\JobLauncherLogs)

    For each candidate, attempts to create the directory if it doesn't exist.
    Returns the first candidate that is successfully created or already exists.

    If all candidates fail, throws a fatal error with the last exception.

.OUTPUTS
    [string] - The full path to the usable log directory.

.EXAMPLE
    $logRoot = Resolve-LogDirectory

.NOTES
    Throws a terminating error if no candidate directory is usable.
    Does not modify $script:Settings or any global state.
    The TEMP fallback is always writable by the current user.
#>
function Resolve-LogDirectory {

    # Determine log directory: JSON setting if provided, otherwise use configured default

    # Check if the 'settings > logs_directory' property exists in JSON and has a value
    $jsonLogDir = $null
    if ($script:Settings -and $script:Settings.PSObject.Properties['logs_directory']) {
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
        if (-not $candidate) { continue }  # Skip empty/null candidates

        try {
            if (-not (Test-Path -Path $candidate)) {
                New-Item -Path $candidate -ItemType Directory -Force | Out-Null
            }
            # If we get here, success
            $logRoot = $candidate
            break
        } catch {
            $lastError = $_
            Write-Host "DEBUG: Error trying to create logdir! Will proceed to next candidate. Errored dir: $candidate"
            Write-OutputWithTimestamp "Warning: Cannot use '$candidate' - $($_.Exception.Message)" -IsError $true
            # Continue to next candidate
            continue
        }
    }

    # After loop, check if we found a working directory
    if (-not $logRoot) {
        $errorMsg = "FATAL: Could not determine log directory using any candidate location."
        if ($lastError) {
            $errorMsg += "`r`nLast error: $($lastError.Exception.Message)"
        }
        throw $errorMsg
    }

    Write-Host "DEBUG: Log dir determined as = $logRoot"
    return $logRoot
}

<#
.SYNOPSIS
    Generates a file path for a job log file.
.DESCRIPTION
    Creates a full file path for a job log by resolving the log directory,
    generating a filename from the job name and optional suffix, and joining them.
    Optionally creates the log directory if requested.
    Throws an error if the log directory cannot be resolved.
.PARAMETER JobName
    Name of the job used to generate the filename. Mandatory parameter.
.PARAMETER Suffix
    Optional suffix to append to the filename before the extension. Default is empty string.
.PARAMETER Create
    If $true, creates the log directory if it does not exist. Uses -Force to prevent errors if already exists.
.EXAMPLE
    $path = Generate-JobLogFilepath -JobName "BackupJob" -Create $true
.EXAMPLE
    $path = Generate-JobLogFilepath -JobName "BackupJob" -Suffix "retry3" -Create $false
.NOTES
    Requires Resolve-LogDirectory and Generate-JobLogFilename functions.
    Outputs debug message using Write-Host.
    Throws terminating error if Resolve-LogDirectory returns invalid path.
#>
function Generate-JobLogFilepath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobName,
        [string]$Suffix = "",
        [boolean]$Create = $false
    )

    $logRoot = Resolve-LogDirectory

    if (-not $logRoot -or -not (Test-Path -Path $logRoot)) {
        throw "Generate-JobLogFilepath: Failed to resolve valid log directory. Resolve-LogDirectory returned: '$logRoot'"
    }

    $filename = Generate-JobLogFilename -JobName $JobName -Suffix $Suffix
    $fullPath = Join-Path -Path $logRoot -ChildPath $filename
    Write-Host "DEBUG: filepath generated $fullPath"

    # Create directory if requested (-Force prevents error if dir already exists)
    if ($Create) {
        New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
    }

    return $fullPath
}

<#
.SYNOPSIS
    Initializes a new job log file with header information.
.DESCRIPTION
    Creates a new log file for a job including job details from the job object,
    timestamp, command line, working directory, timeout, detached state, and status.
    Optionally includes OS and PowerShell version information if globally configured.
    Returns the path to the created log file.
.PARAMETER Job
    The raw job configuration object (PSCustomObject) parsed from JSON.
    Created during JSON loading in Load-FlatConfig or Load-HierarchicalConfig.
    Contains what JSON contains: .name and .command properties, plus optional
    .detached, .timeout_seconds, and .working_directory.
.PARAMETER WorkingDirectory
    The working directory where the job will execute.
.PARAMETER TimeoutSeconds
    The timeout value in seconds for the job.
.PARAMETER Suffix
    Optional suffix to add before the .log extension (e.g., "detached").
    If provided, the format becomes: name_timestamp-suffix.log
.EXAMPLE
    $logPath = Initialize-JobLog -Job $jobObject -WorkingDirectory "C:\temp" -TimeoutSeconds 300
.EXAMPLE
    $logPath = Initialize-JobLog -Job $jobObject -WorkingDirectory "C:\temp" -TimeoutSeconds 60 -TerminationReason "Starting"
.NOTES
    Requires Get-JobProperty and Generate-JobLogFilepath functions.
    Uses global variable $LogIncludeEnvironmentInfo if defined.
    Uses Write-OutputWithTimestamp function (defined elsewhere in script).
#>
function Initialize-JobLog {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Job,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds,
        [string]$Suffix = ""
    )

    # to hold log content
    $logContent = ""

    # job details to put in header
    $jobName = Get-JobProperty -Job $Job -Property "name" -FailIfMissing # throw error if no job name found
    $jobCommand = Get-JobProperty -Job $Job -Property "command" -FailIfMissing # throw error if can't find command
    $jobDetachedState = switch (Get-JobProperty -Job $Job -Property "detached" -Default $null) {
        $true { "yes" }
        $false { "no" }
        $null { "unknown (detached property not present)" }
    }

    # generate a safe filepath and create parent directory
    $logPath = Generate-JobLogFilepath -JobName $JobName -Suffix $Suffix -Create $true

$header = @"
================================================================================
JOB LOG
================================================================================
Job Name:          $jobName
Start Time:        $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Command Line:      $jobCommand
Working Directory: $WorkingDirectory
Timeout (seconds): $TimeoutSeconds
Detached:          $jobDetachedState
================================================================================

"@

    $logContent += $header

    # Add environment info if configured globally
    if ($LogIncludeEnvironmentInfo) {
        $osVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
        $psVersion = $PSVersionTable.PSVersion.ToString()
        $envInfo = @"
OS Version:        $osVersion
PowerShell Version: $psVersion
"@
        $logContent = $envInfo + "`r`n" + $logContent
    }

    # Write log content to disk
    $logContent | Out-File -FilePath $logPath -Encoding UTF8

    Write-OutputWithTimestamp "Log written to: $logPath"

    return $logPath
}

<#
.SYNOPSIS
    Generates a formatted timestamped header line for log entries.
.DESCRIPTION
    Creates a header line in the format: "--- [YYYY-MM-DD HH:MM:SS] Summary ---"
    If Summary is empty or null, produces: "--- [timestamp] ---"
.PARAMETER Summary
    Optional summary text to display between the timestamp and closing dashes.
    Default is empty string.
.EXAMPLE
    Generate-JobLogHeaderLine -Summary "Job execution started"
    Returns: "--- [2026-06-01 04:12:15] Job execution started ---"
.EXAMPLE
    Generate-JobLogHeaderLine
    Returns: "--- [2026-06-01 04:12:15] ---"
.NOTES
    Does not add newline characters. Caller is responsible for newline handling.
#>
function Generate-JobLogHeaderLine {
    param(
        [string]$Summary = ""
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    if ([string]::IsNullOrWhiteSpace($Summary)) {
        return "--- [$timestamp] ---"
    } else {
        return "--- [$timestamp] $Summary ---"
    }
}

<#
.SYNOPSIS
    Appends content to an existing job log file with optional timestamped header.
.DESCRIPTION
    Adds additional content to the end of a job log file.
    If TimestampHeader is $true, writes a timestamped header line before the content.
    Throws a terminating error if the log file does not exist.
.PARAMETER Path
    Full path to the log file.
.PARAMETER Content
    The text content to append to the log file.
.PARAMETER TimestampHeader
    If $true, writes a timestamped header line before the content.
    If $false (default), writes content only.
.PARAMETER HeaderSummary
    Optional summary text for the timestamp header. Only used if TimestampHeader is $true.
    Default is empty string.
.EXAMPLE
    Append-JobLog -Path "C:\logs\job.log" -Content "Additional output here"
.EXAMPLE
    Append-JobLog -Path "C:\logs\job.log" -Content "Starting process" -TimestampHeader $true -HeaderSummary "Job execution started"
.NOTES
    Throws terminating error if log file not found.
#>
function Append-JobLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [boolean]$TimestampHeader = $LogTimestampEntries,

        [string]$HeaderSummary = ""
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Append-JobLog: Log file not found: $Path"
    }

    $output = ""

    if ($TimestampHeader) {
        $output += Generate-JobLogHeaderLine -Summary $HeaderSummary
        $output += "`r`n"
    }

    if ($HeaderSummary -and -not $TimestampHeader) {
        throw "Append-JobLog: HeaderSummary provided but TimestampHeader is \$false. Set TimestampHeader to \$true or remove HeaderSummary."
    }

    $output += $Content

    $output | Out-File -FilePath $Path -Encoding UTF8 -Append
}

<#
.SYNOPSIS
    Finalizes a job log with exit information and output.
.DESCRIPTION
    Appends a footer to an existing job log containing exit code, termination reason,
    and optional output sections for general messages, STDOUT, and STDERR.
    Creates a formatted footer with clear section separators.
.PARAMETER Path
    Full path to the log file as a string. Mandatory parameter.
.PARAMETER ExitCode
    The exit code returned by the job process. Mandatory parameter.
.PARAMETER TerminationReason
    The reason the job terminated (e.g., "Completed", "Timeout", "Error"). Mandatory parameter.
.PARAMETER StdOut
    Optional STDOUT content from the job process. Default is $null.
.PARAMETER StdErr
    Optional STDERR content from the job process. Default is $null.
.EXAMPLE
    Finalize-JobLog -Path $logPath -ExitCode 0 -TerminationReason "Completed" -StdOut $outputData
.EXAMPLE
    Finalize-JobLog -Path $logPath -ExitCode 1 -TerminationReason "Timeout"
.NOTES
    Parameters StdOut, and StdErr default to $null.
    Only non-null values are appended to the log.
#>
function Finalize-JobLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $true)]
        [string]$TerminationReason,

        $StdOut = $null,
        $StdErr = $null
    )

$footer = @"

================================================================================
Stop Time:         $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
================================================================================
Exit Code:         $ExitCode
Exit Reason:       $TerminationReason
================================================================================
"@

    if ($StdOut -ne $null) {
        $footer += "`r`nSTDOUT:`r`n$StdOut"
    }
    if ($StdErr -ne $null) {
        $footer += "`r`nSTDERR:`r`n$StdErr"
    }

$footer += @"
================================================================================
END OF LOG
================================================================================
"@

    $footer | Out-File -FilePath $Path -Encoding UTF8 -Append
}

<#
.SYNOPSIS
    Writes a timestamped message to the output textbox with optional error formatting.

.DESCRIPTION
    Appends a message to the script's global output RichTextBox control.
    Adds a timestamp prefix (if $ShowTimestampsInOutput is $true) and an
    "ERROR: " prefix (if $IsError is $true). Automatically scrolls to the
    bottom after appending.

.PARAMETER Text
    The message text to write to the output box.

.PARAMETER IsError
    If $true, prefixes the message with "ERROR: " for visual distinction.
    Defaults to $false.
#>
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

<#
.SYNOPSIS
    Updates the status label text and color in the main window's status strip.

.DESCRIPTION
    Sets the Text and ForeColor properties of the global $script:StatusLabel
    control. This label resides in the StatusStrip at the bottom of the main
    form and provides real-time feedback to the user (e.g., "Ready", "Running",
    "Success", "Failed").

.PARAMETER Text
    The status message to display.

.PARAMETER Color
    A System.Drawing.Color object specifying the text color. Common values
    are obtained via Get-ThemeColor (e.g., status_ok, status_error).
#>
function Update-Status {
    param([string]$Text, [System.Drawing.Color]$Color)

    $script:StatusLabel.Text = $Text
    $script:StatusLabel.ForeColor = $Color
    # No Refresh needed - ToolStripStatusLabel updates automatically
}

# =============================================================================
# JOB SPECIFIC FUNCTIONS
# =============================================================================

<#
.SYNOPSIS
    Extracts the raw job configuration from a Job Item.
    (e.g. the raw json data that's stored in the .Node attr of a Job Item)

.DESCRIPTION
    If the input is a Job Item (has .Node property), returns .Node.
    Throws a terminating error if .Node is missing or null.

.PARAMETER JobItem
    A wrapped Job Item object created during JSON loading.

.OUTPUTS
    The raw job configuration object (PSCustomObject from original JSON).

.EXAMPLE
    $JobConfig = Get-JobConfig -JobItem $JobItem

.NOTES
    This function does not accept raw JobConfig objects. Callers must
    ensure they pass a proper Job Item. This strictness ensures parent
    references (ParentGroup, ParentCategory) are always available when
    needed for upward traversal.
#>
function Get-JobConfig {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$JobItem
    )

    if (-not ($JobItem.PSObject.Properties['Node'] -and $JobItem.Node)) {
        throw "Get-JobConfig: Input is not a valid Job Item (missing .Node property)."
    }

    return $JobItem.Node
}

<#
.SYNOPSIS
    Safely retrieves a property value from a job object.

.DESCRIPTION
    Returns a property value from a job object if the property exists, otherwise returns a default value.
    Handles missing properties without errors.

    The function automatically prepends "Get-JobProperty" to the ErrorContext parameter before passing
    it to Get-PSObjectProperty, creating a lightweight call stack trace for debugging.

.PARAMETER Job
    The raw job configuration object (PSCustomObject) parsed from JSON.
    Created during JSON loading in Load-FlatConfig or Load-HierarchicalConfig.
    Contains what JSON contains: .name and .command properties, plus optional
    .detached, .timeout_seconds, and .working_directory.

.PARAMETER Property
    The name of the property to retrieve from the job object.

.PARAMETER Default
    Value to return if the property does not exist. Defaults to $null.

.PARAMETER FailIfMissing
    If specified, throws a terminating error when the property does not exist.
    Overrides -Default.

.PARAMETER ErrorContext
    Optional caller-provided context string included in the error message for traceability.
    This value is appended after "Get-JobProperty" in the final error context.

.EXAMPLE
    Get-JobProperty -Job $Job -Property "name" -Default "unknown"
    Returns the value of property "name" or "unknown" if not found.

.EXAMPLE
    Get-JobProperty -Job $Job -Property "detached" -FailIfMissing
    Throws an error if the "detached" property does not exist.

.EXAMPLE
    Get-JobProperty -Job $Job -Property "missing" -Default $false -ErrorContext "ValidateJob"
    Returns $false (default). If -FailIfMissing were also used, error would show:
    "Get-PSObjectProperty: Property 'missing' not found... [Context: Get-JobProperty -> ValidateJob]"

.EXAMPLE
    # Positional parameters (backward compatible)
    Get-JobProperty $Job "name"
    Returns the value of property "name" or $null if not found.

.EXAMPLE
    # $null job object passes through to Get-PSObjectProperty for custom error handling
    Get-JobProperty -Job $null -Property "name" -FailIfMissing -ErrorContext "LoadConfig"
    Throws custom error from Get-PSObjectProperty with context: "Get-JobProperty -> LoadConfig"
#>
function Get-JobProperty {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [object]$Job,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Property,

        [Parameter(Mandatory = $false)]
        [object]$Default = $null,

        [Parameter(Mandatory = $false)]
        [switch]$FailIfMissing,

        [Parameter(Mandatory = $false)]
        [string]$ErrorContext = $null
    )

    # Build enhanced context
    $enhancedContext = "Get-JobProperty"
    if (-not [string]::IsNullOrWhiteSpace($ErrorContext)) {
        $enhancedContext = "Get-JobProperty -> $ErrorContext"
    }

    # Validate Job is not $null
    if ($Job -eq $null) {
        throw "Get-JobProperty: Job object cannot be null [Context: $enhancedContext]"
    }

    # Validate Property is not null or empty
    if ([string]::IsNullOrWhiteSpace($Property)) {
        throw "Get-JobProperty: Property name cannot be null or empty [Context: $enhancedContext]"
    }

    return Get-PSObjectProperty -Object $Job -Property $Property -Default $Default -FailIfMissing:$FailIfMissing -ErrorContext $enhancedContext
}

<#
.SYNOPSIS
    Safely retrieves a property value from a job result object.

.DESCRIPTION
    Returns a property value from a job result object if the property exists, otherwise returns a default value.
    Handles missing properties without errors.

    The function automatically prepends "Get-JobResultProperty" to the ErrorContext parameter before passing
    it to Get-PSObjectProperty, creating a lightweight call stack trace for debugging.

.PARAMETER JobResult
    The job result object set during Invoke-Job to help manage job state.
    Contains properties: .Success, .ExitCode, .TerminationReason, .StdOut, .StdErr, etc.

.PARAMETER Property
    The name of the property to retrieve from the job result object.

.PARAMETER Default
    Value to return if the property does not exist. Defaults to $null.

.PARAMETER FailIfMissing
    If specified, throws a terminating error when the property does not exist.
    Overrides -Default.

.PARAMETER ErrorContext
    Optional caller-provided context string included in the error message for traceability.
    This value is appended after "Get-JobResultProperty" in the final error context.

.EXAMPLE
    Get-JobResultProperty -JobResult $Result -Property "ExitCode" -Default -1
    Returns the value of property "ExitCode" or -1 if not found

.EXAMPLE
    Get-JobResultProperty -JobResult $Result -Property "StdErr" -FailIfMissing
    Throws an error if the "StdErr" property does not exist.
#>
function Get-JobResultProperty {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [object]$JobResult,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Property,

        [Parameter(Mandatory = $false)]
        [object]$Default = $null,

        [Parameter(Mandatory = $false)]
        [switch]$FailIfMissing,

        [Parameter(Mandatory = $false)]
        [string]$ErrorContext = $null
    )

    # Build enhanced context once
    $enhancedContext = "Get-JobResultProperty"
    if (-not [string]::IsNullOrWhiteSpace($ErrorContext)) {
        $enhancedContext = "Get-JobResultProperty -> $ErrorContext"
    }

    # Validate JobResult is not $null
    if ($JobResult -eq $null) {
        throw "Get-JobResultProperty: JobResult object cannot be null [Context: $enhancedContext]"
    }

    # Validate Property is not null or empty
    if ([string]::IsNullOrWhiteSpace($Property)) {
        throw "Get-JobResultProperty: Property name cannot be null or empty [Context: $enhancedContext]"
    }

    return Get-PSObjectProperty -Object $JobResult -Property $Property -Default $Default -FailIfMissing:$FailIfMissing -ErrorContext $enhancedContext
}

<#
.SYNOPSIS
    Safely sets a property value on a job result object.

.DESCRIPTION
    Sets a property on a job result object. If the property doesn't exist and
    -FailIfMissing is omitted (default), the property is created automatically.
    If -FailIfMissing is specified, validates existence before setting and throws
    if the property is missing.

    This function is the counterpart to Get-JobResultProperty, maintaining
    type agnosticism so future changes (e.g., switching from PSCustomObject to
    Hashtable) require updating only the underlying Get/Set helpers.

.PARAMETER JobResult
    The job result object set during Invoke-Job to help manage job state.
    Contains properties: .Success, .ExitCode, .TerminationReason, .StdOut, .StdErr, etc.

.PARAMETER Property
    The name of the property to set.

.PARAMETER Value
    The value to assign to the property.

.PARAMETER FailIfMissing
    If specified, throws an error when the property does not exist on the object.
    If omitted (default), creates the property if it doesn't exist.

.PARAMETER ErrorContext
    Optional caller-provided context string included in error messages for traceability.
    Automatically prefixed with "Set-JobResultProperty -> " before passing downstream.

.EXAMPLE
    Set-JobResultProperty -JobResult $result -Property "Status" -Value "Completed"
    Sets Status property (creates it if missing)

.EXAMPLE
    Set-JobResultProperty -JobResult $result -Property "ExitCode" -Value 0 -FailIfMissing
    Throws if ExitCode property doesn't exist

.EXAMPLE
    Set-JobResultProperty -JobResult $null -Property "Status" -Value "Failed" -ErrorContext "UpdateResults"
    Throws: "Set-JobResultProperty: JobResult object cannot be null [Context: Set-JobResultProperty -> UpdateResults]"

.EXAMPLE
    Set-JobResultProperty -JobResult $result -Property "" -Value "data" -FailIfMissing
    Throws: "Set-JobResultProperty: Property name cannot be null or empty"
#>
function Set-JobResultProperty {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [object]$JobResult,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Property,

        [Parameter(Mandatory = $true, Position = 2)]
        [object]$Value,

        [Parameter(Mandatory = $false)]
        [switch]$FailIfMissing,

        [Parameter(Mandatory = $false)]
        [string]$ErrorContext = $null
    )

    # Build enhanced context once
    $enhancedContext = "Set-JobResultProperty"
    if (-not [string]::IsNullOrWhiteSpace($ErrorContext)) {
        $enhancedContext = "Set-JobResultProperty -> $ErrorContext"
    }

    # Validate JobResult is not $null
    if ($JobResult -eq $null) {
        throw "Set-JobResultProperty: JobResult object cannot be null [Context: $enhancedContext]"
    }

    # Validate Property is not null or empty
    if ([string]::IsNullOrWhiteSpace($Property)) {
        throw "Set-JobResultProperty: Property name cannot be null or empty [Context: $enhancedContext]"
    }

    # Check if property exists when FailIfMissing is specified
    if ($FailIfMissing) {
        # Delegate existence check to Get-JobResultProperty so that function is agnostic to which type of object Job results are
        $null = Get-JobResultProperty -JobResult $JobResult -Property $Property -FailIfMissing -ErrorContext $enhancedContext
    }

    # Set the property (creates new property if it doesn't exist and FailIfMissing is false)
    $JobResult.$Property = $Value
}

<#
.SYNOPSIS
    Creates a Process object for a blocking (normal) job.

.DESCRIPTION
    Parses the command string into executable and arguments.
    Configures ProcessStartInfo with:
    - Working directory (assumes $workingDir is in scope)
    - stdout/stderr redirection enabled
    - No console window
    - UTF8 encoding for output streams

.PARAMETER Job
    The raw job configuration object (PSCustomObject) parsed from JSON.
    Created during JSON loading in Load-FlatConfig or Load-HierarchicalConfig.
    Contains what JSON contains: .name and .command properties, plus optional
    .detached, .timeout_seconds, and .working_directory.

.NOTES
    The first word of .command must be an executable in PATH or a full path.

    WorkingDirectory is currently optional. The function does not validate
    the directory or throw if missing — that responsibility falls to the
    caller (Invoke-Job). Whether WorkingDirectory should be mandatory is
    an open architectural question: the process will use the calling
    process's working directory if not specified, which may be acceptable
    for some jobs but could cause silent failures for others.
    TODO: Revisit this decision. Consider making mandatory or adding
    validation with a meaningful error message.
#>
function Get-JobProcessBlocking {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Job,
        [string]$WorkingDirectory
    )

    # Parse command into executable and arguments
    # Simple split on first space - handles quoted paths poorly but sufficient for cmd/powershell patterns
    $parts = $Job.command -split ' ', 2
    $executable = $parts[0]
    $arguments = if ($parts.Count -gt 1) { $parts[1] } else { "" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $executable
    $psi.Arguments = $arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false           # Required for redirection
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true             # No console window popping up
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    return $process
}

<#
.SYNOPSIS
    Creates a Process object for a detached job.

.DESCRIPTION
    Wraps the user's command in a powershell.exe -Command Start-Process cmd -ArgumentList '/c ...' -WindowStyle Hidden.
    Working directory is set on the outer powershell.exe process.

.PARAMETER Job
    The raw job configuration object (PSCustomObject) parsed from JSON.
    Created during JSON loading in Load-FlatConfig or Load-HierarchicalConfig.
    Contains what JSON contains: .name and .command properties, plus optional
    .detached, .timeout_seconds, and .working_directory.

.PARAMETER WorkingDirectory
    The resolved working directory for the job. Must be a valid, existing path.

.NOTES
    The returned process exits almost immediately; the user's command runs independently.

    WorkingDirectory is currently optional. The function does not validate
    the directory or throw if missing — that responsibility falls to the
    caller (Invoke-Job). Whether WorkingDirectory should be mandatory is
    an open architectural question: the process will use the calling
    process's working directory if not specified, which may be acceptable
    for some jobs but could cause silent failures for others.
    TODO: Revisit this decision. Consider making mandatory or adding
    validation with a meaningful error message.
#>
function Get-JobProcessDetached {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Job,
        [string]$WorkingDirectory
    )

    # Create a separate log file to pipe content to
    $logFile = Initialize-JobLog -Job $Job -WorkingDirectory $WorkingDirectory -Suffix "child"

    # Append a hint that this is for the detached child process
    Append-JobLog -Path $logFile -Content "This log is for the child process. stdout and stderr (if any) will be appended below."  -HeaderSummary "Info"

    # Arguments for Windows cmd that will be nested in powershell
    $rawArgs = $Job.command
    $cmdArgs = "$rawArgs >> `"`"`"$logFile`"`"`" 2>&1"
    Write-Host "DEBUG: (Detached job) Arg$cmdArgs"

    # Arguments to send to powershell.exe
    $powerShellArguments = "-Command Start-Process cmd -ArgumentList '/c $cmdArgs' -WindowStyle Hidden"
    Write-Host "DEBUG: (Detached job) Arguments for powershell.exe: $powerShellArguments"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = $powerShellArguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true             # No console window popping up

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    return $process
}

<#
.SYNOPSIS
    Returns a configured Process object for a job based on its 'detached' flag.

.DESCRIPTION
    Dispatches to Get-JobProcessBlocking or Get-JobProcessDetached.
    The returned Process object is ready to .Start().
    ProcessStartInfo is fully configured including working directory, redirection,
    and window behavior.

.PARAMETER Job
    The raw job configuration object (PSCustomObject) parsed from JSON.
    Created during JSON loading in Load-FlatConfig or Load-HierarchicalConfig.
    Contains what JSON contains: .name and .command properties, plus optional
    .detached, .timeout_seconds, and .working_directory.

.PARAMETER WorkingDirectory
    The resolved working directory for the job. Must be a valid, existing path.

.EXAMPLE
    $process = Get-JobProcess -Job $Job
    $process.Start()
.NOTES
    WorkingDirectory is currently optional. The function does not validate
    the directory or throw if missing — that responsibility falls to the
    caller (Invoke-Job). Whether WorkingDirectory should be mandatory is
    an open architectural question: the process will use the calling
    process's working directory if not specified, which may be acceptable
    for some jobs but could cause silent failures for others.
    TODO: Revisit this decision. Consider making mandatory or adding
    validation with a meaningful error message.
#>
function Get-JobProcess {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Job,
        [string]$WorkingDirectory
    )

    # determine 'detached' state (this property might not exist)
    $isDetached = Get-JobProperty -Job $Job -Property "detached" -Default $false

    if ($isDetached -eq $true) {
        return Get-JobProcessDetached -Job $Job -WorkingDirectory $WorkingDirectory
    } else {
        return Get-JobProcessBlocking -Job $Job -WorkingDirectory $WorkingDirectory
    }
}

<#
.SYNOPSIS
    Determines the timeout (in seconds) for a job.

.DESCRIPTION
    Priority:
    1. If job.detached = true → returns 1 (short timeout)
    2. If job.timeout_seconds is set and non-null → returns that value
    3. Otherwise → returns script:Settings.default_timeout_seconds
.PARAMETER JobItem
    The wrapped Job Item object representing a single executable job.

    This is NOT the raw JSON from the config file. It is an enhanced object
    created during JSON loading in either Load-FlatConfig or
    Load-HierarchicalConfig (search for Type = "job").

    The JobItem contains:
    - .Type      = "job" (identifies it as a Job Item)
    - .Node      = raw JobConfig object from the original JSON
                  (contains .name, .command, and optional .detached,
                   .timeout_seconds, .working_directory)
    - .ParentGroup     = reference to the parent Group object
    - .ParentCategory  = reference to the parent Category (may be $null)

    This structure allows upward traversal to resolve settings that may be
    defined at the group or category level (e.g., working_directory,
    timeout_seconds), following the same pattern as Get-ItemTheme.
.PARAMETER WorkingDirectory
    The resolved working directory for the job. Must be a valid, existing path.

.EXAMPLE
    $timeout = Get-JobTimeout -Job $Job
#>
function Get-JobTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$JobItem
    )

    # Get raw job JSON
    $rawJob = Get-JobConfig -JobItem $JobItem

    # 1. Job-level detached flag
    if ($rawJob.PSObject.Properties['detached'] -and $rawJob.detached -eq $true) {
        return 10
    }

    # 2. Job-level timeout_seconds
    if ($rawJob.PSObject.Properties['timeout_seconds'] -and $rawJob.timeout_seconds) {
        return $rawJob.timeout_seconds
    }

    # 3. Parent group-level timeout_seconds
    if ($JobItem.PSObject.Properties['ParentGroup'] -and $JobItem.ParentGroup.PSObject.Properties['timeout_seconds'] -and $JobItem.ParentGroup.timeout_seconds) {
        return $JobItem.ParentGroup.timeout_seconds
    }

    # 4. Parent category-level timeout_seconds
    if ($JobItem.PSObject.Properties['ParentCategory'] -and $JobItem.ParentCategory -and $JobItem.ParentCategory.PSObject.Properties['timeout_seconds'] -and $JobItem.ParentCategory.timeout_seconds) {
        return $JobItem.ParentCategory.timeout_seconds
    }

    # 5. default_timeout_seconds in "settings" of currently selected job configuration JSON
    if ($script:Settings.PSObject.Properties['default_timeout_seconds'] -and $script:Settings.default_timeout_seconds) {
        return $script:Settings.default_timeout_seconds
    }

    # 6. default_timeout_seconds in general launcher configuration JSON
    if ($script:LauncherSettings.PSObject.Properties['default_timeout_seconds'] -and $script:LauncherSettings.default_timeout_seconds) {
        return $script:LauncherSettings.default_timeout_seconds
    }

    # 7. default_timeout_seconds of script
    return $DefaultTimeoutSeconds
}

<#
.SYNOPSIS
    Determines the working directory for a job based on priority order.

.DESCRIPTION
    Returns the working directory for a job by checking the following in order:
    1. Job's 'working_directory' property (if present and non-empty)
    2. Global script setting 'default_working_directory'
    3. Fallback to the script's directory where this function is defined

.PARAMETER JobItem
    The wrapped Job Item object representing a single executable job.

    This is NOT the raw JSON from the config file. It is an enhanced object
    created during JSON loading in either Load-FlatConfig or
    Load-HierarchicalConfig (search for Type = "job").

    The JobItem contains:
    - .Type      = "job" (identifies it as a Job Item)
    - .Node      = raw JobConfig object from the original JSON
                  (contains .name, .command, and optional .detached,
                   .timeout_seconds, .working_directory)
    - .ParentGroup     = reference to the parent Group object
    - .ParentCategory  = reference to the parent Category (may be $null)

    This structure allows upward traversal to resolve settings that may be
    defined at the group or category level (e.g., working_directory,
    timeout_seconds), following the same pattern as Get-ItemTheme.

.EXAMPLE
    $workingDir = Get-JobWorkingDirectory -JobItem $jobObject

.NOTES
    The function does not validate whether the returned directory exists.
    Caller is responsible for existence checking.

    Depends on global variable $script:Settings being defined with
    a 'default_working_directory' property.

    The fallback path uses $PSScriptRoot which represents the directory
    of the script containing this function.
#>
function Get-JobWorkingDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$JobItem
    )

    # Get raw job JSON
    $rawJob = Get-JobConfig -JobItem $JobItem

    # 1. working_directory property directly on job itself
    if ($rawJob.PSObject.Properties['working_directory'] -and $rawJob.working_directory) {
        return $rawJob.working_directory
    }

    # 2. Parent group-level (only if Job is a Job Item with ParentGroup)
    if ($JobItem.PSObject.Properties['ParentGroup'] -and $JobItem.ParentGroup.PSObject.Properties['working_directory'] -and $JobItem.ParentGroup.working_directory) {
        return $JobItem.ParentGroup.working_directory
    }

    # 3. Parent category-level (only if Job is a Job Item with ParentCategory)
    if ($JobItem.PSObject.Properties['ParentCategory'] -and $JobItem.ParentCategory -and $JobItem.ParentCategory.PSObject.Properties['working_directory'] -and $JobItem.ParentCategory.working_directory) {
        return $JobItem.ParentCategory.working_directory
    }

    # 4. default_working_directory in "settings" of currently selected job configuration JSON
    if ($script:Settings.PSObject.Properties['default_working_directory'] -and $script:Settings.default_working_directory) {
        return $script:Settings.default_working_directory
    }

    # 5. default_working_directory in general launcher configuration JSON
    if ($script:LauncherSettings.PSObject.Properties['default_working_directory'] -and $script:LauncherSettings.default_working_directory) {
        return $script:LauncherSettings.default_working_directory
    }

    # 6. Fallback to the script's directory
    return $PSScriptRoot
}

<#
.SYNOPSIS
    Performs complete cleanup, logging, and UI updates for a job execution.

.DESCRIPTION
    Handles all post-job tasks including:
    - Killing the process if still running
    - Capturing stdout/stderr if not already captured
    - Writing the final log file via Finalize-JobLog
    - Displaying output in the UI
    - Updating UI status
    - Disposing the process object
    - Cleaning up script-level variables

    This function is designed to be called from both early return paths (e.g.,
    working directory validation) and the finally block of the main execution.

.PARAMETER Result
    PSCustomObject containing all job state and results with properties:
    - Success (bool)
    - ExitCode (int)
    - TerminationReason (string)
    - StdOut (string)
    - StdErr (string)
    - TimedOut (bool)
    - IsError (bool)
    - StatusMessage (string)
    - LauncherMessage (string)
    - JobName (string)
    - LogFile (string)

.PARAMETER Process
    The System.Diagnostics.Process object. If $null, process-related
    operations are skipped.

.NOTES
    This function is called automatically from Invoke-Job and should not
    typically be called directly by other code.
#>
function Cleanup-Job {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$Result,

        [System.Diagnostics.Process]$Process
    )

    $UI_Color_StatusError = Get-ThemeColor -PropertyName "status_error"
    $UI_Color_StatusOk = Get-ThemeColor -PropertyName "status_ok"

    # === Kill process if still running ===
    if ($Process -and (-not $Process.HasExited)) {
        try { $Process.Kill() } catch { }
    }

    # === Capture output if not already captured and process has exited ===
    if ($Process -and $Process.HasExited) {
        if ([string]::IsNullOrWhiteSpace($Result.StdOut) -and $Process.StandardOutput -ne $null) {
            $Result.StdOut = $Process.StandardOutput.ReadToEnd()
        }
        if ([string]::IsNullOrWhiteSpace($Result.StdErr) -and $Process.StandardError -ne $null) {
            $Result.StdErr = $Process.StandardError.ReadToEnd()
        }
    }

    # === Write log file ===
    if ($Result.LogFile) {
        Finalize-JobLog -Path $Result.LogFile -ExitCode $Result.ExitCode -TerminationReason $Result.TerminationReason -StdOut $Result.StdOut -StdErr $Result.StdErr
    }

    # === Display output if present (and not already streamed) ===

    if (-not $Result.RealTimeOutput) {
        $hasStdOut = (-not [string]::IsNullOrWhiteSpace($Result.StdOut))
        $hasStdErr = (-not [string]::IsNullOrWhiteSpace($Result.StdErr))

        Write-OutputWithTimestamp "--- Job Output ---"

        if ($hasStdOut -or $hasStdErr) {
            if ($hasStdOut) {
                Write-OutputWithTimestamp "[StdOut]"
                Write-OutputWithTimestamp $Result.StdOut.TrimEnd()
            }

            if ($hasStdErr) {
                Write-OutputWithTimestamp "[StdErr]" -IsError $true
                Write-OutputWithTimestamp $Result.StdErr.TrimEnd() -IsError $true
            }
        } else {
            Write-OutputWithTimestamp "[No output captured]"
        }
    }

    # === Update UI status and output message ===
    if ($Result.LauncherMessage) {
        Write-OutputWithTimestamp ""
        Write-OutputWithTimestamp "--- Execution Result ---"
        Write-OutputWithTimestamp $Result.LauncherMessage -IsError $Result.IsError
    }
    Update-Status $Result.StatusMessage $(if ($Result.IsError) { $UI_Color_StatusError } else { $UI_Color_StatusOk })

    # === Clean up process and script variables ===
    if ($Process) {
        $Process.Dispose()
    }
    $script:CurrentRunningJob = $null
}

<#
.SYNOPSIS
    Executes a job (blocking or detached) with timeout, logging, and UI feedback.

.DESCRIPTION
    This is the main entry point for running any job from the launcher.
    Steps performed:
    1. Determine timeout via Get-JobTimeout
    2. Resolve working directory
    3. Create Process object via Get-JobProcess
    4. Start the process
    5. Wait for exit (with polling, DoEvents, kill-request handling)
    6. Capture output (if streams exist)
    7. Write log file
    8. Update UI status (success/failure/timeout)

    For detached jobs, the timeout is very short (1 second) and output capture
    is disabled (stdout/stderr streams are $null). The user's command continues
    running independently after the process exits.

.PARAMETER JobItem
    The wrapped Job Item object representing a single executable job.

    This is NOT the raw JSON from the config file. It is an enhanced object
    created during JSON loading in either Load-FlatConfig or
    Load-HierarchicalConfig (search for Type = "job").

    The JobItem contains:
    - .Type      = "job" (identifies it as a Job Item)
    - .Label     = job name (display string)
    - .Node      = raw JobConfig object from the original JSON
                  (contains .name, .command, and optional .detached,
                   .timeout_seconds, .working_directory)
    - .ParentGroup     = reference to the parent Group object
    - .ParentCategory  = reference to the parent Category (may be $null)

    This structure allows upward traversal to resolve settings that may be
    defined at the group or category level (e.g., working_directory,
    timeout_seconds), following the same pattern as Get-ItemTheme.

    To access the raw job config for execution, use Get-JobConfig -JobItem $JobItem.

.PARAMETER JobButton
    The Button control associated with this job (used for visual feedback).

.EXAMPLE
    Invoke-Job -JobItem $selectedJob -JobButton $jobButton

.NOTES
    Sets and clears $script:CurrentRunningJob and $script:KillRequested.
    Uses Write-OutputWithTimestamp for real-time UI updates.
    Reuses Write-LogFile for persistent logging.
#>
function Invoke-Job {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$JobItem,
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$JobButton
    )

    # Extract raw JSON data from Job Item (stored in .Node property)
    $rawJob = Get-JobConfig -JobItem $JobItem

    $UI_Color_StatusError = Get-ThemeColor -PropertyName "status_error"
    $UI_Color_StatusOk = Get-ThemeColor -PropertyName "status_ok"
    $jobName = Get-JobProperty -Job $rawJob -Property "name" -FailIfMissing # throw error if no job name found
    $jobCommand = Get-JobProperty -Job $rawJob -Property "command" -FailIfMissing # throw error if can't find command

    # == Determine Timeout ==

    $timeoutSeconds = Get-JobTimeout -JobItem $JobItem

    # === Get working directory ===

    $workingDir = Get-JobWorkingDirectory -JobItem $JobItem

    # === Initialize logfile with job header ==

    $logFile = Initialize-JobLog -Job $rawJob -WorkingDirectory $workingDir -TimeoutSeconds $TimeoutSeconds

    # === Initialize result object ===

    # This object accumulates job state and is passed to Cleanup-Job
    # which will use it to cleanup once the job completes.
    # Update as you encounter exit conditions (success, timeout, job kill, etc.)
    #
    # Fields:
    #   StdOut/StdErr → captured after process exit
    #   ExitCode → from process or timeout
    #   TerminationReason → "Timeout", "Completed", "Exception", etc.
    #   LauncherMessage → high-level status messages (kill, timeout, exceptions)
    #   StatusMessage/LauncherMessage → displayed in UI
    $result = [PSCustomObject]@{
        Success = $false
        ExitCode = $null
        TerminationReason = ""
        StdOut = $null
        StdErr = $null
        RealTimeOutput = $false # if real-time stdout/stderr enabled for this job
        TimedOut = $false
        IsError = $true
        StatusMessage = ""
        LauncherMessage = ""
        JobName = $jobName
        JobCommand = $jobCommand
        WorkingDirectory = $workingDir
        TimeoutSeconds = $timeoutSeconds
        LogFile = $logFile
    }

    # === Initialize process variable ===

    $process = $null

    # === Real-time output streaming ===
    $outputQueue = $null
    $streamReader = $null

    # === Validate working directory ===

    if (-not (Test-Path -Path $workingDir -PathType Container)) {
        $errorMsg = "Working directory does not exist: $workingDir"
        $result.TerminationReason = "Working Directory Failure"
        $result.ExitCode = -1
        $result.Success = $false
        $result.IsError = $true
        $result.StatusMessage = "Failed: Directory not found"
        $result.LauncherMessage = $errorMsg
        ## FUTURE SELF:
        #
        # - I realize that every time you set a LauncherMessage you are manually calling Append-JobLog
        # - Resist the urge to remove them all and shift to a singular call in Job-Cleanup
        #   (making it always dispaly $Result.LauncherMessage if it was set).
        # - The current approach:
        #   1. makes log messages occur at exact second condition occurs (timestamp granularity)
        #   2. eliminates missing log messages if cleanup doesn't execute
        #   3. allows greater granulairty on what appears in logs (you can set LauncherMessage
        #      -- which always appears in status + output area, but not have it show up in the final
        #      log. Not currently being done, but might at some point.)
        Append-JobLog -Path $Result.logFile -Content $Result.LauncherMessage

        Cleanup-Job -Result $result -Process $process
        return $false
    }

    # === Prepare process ===

    $process = Get-JobProcess -Job $rawJob -WorkingDirectory $workingDir

    try {
        $process.Start() | Out-Null

        # === Start real-time output streaming ===
        if ($EnableRealTimeOutput -and $process.StartInfo.RedirectStandardOutput) {
            $outputQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $streamReader = Start-JobOutputStreamReader -Process $process -OutputQueue $outputQueue
            $result.RealTimeOutput = $true
            Write-OutputWithTimestamp "Real-time output streaming enabled"
        }

        # job pid
        $jobPid = $process.Id

        # === Append PID to job log ==
        Append-JobLog -Path $logFile -Content $jobPid -HeaderSummary "Process PID (ignore if detached)"
        Write-OutputWithTimestamp "Job PID: $jobPid"

        # Record running job state
        $script:CurrentRunningJob = @{
            Process = $process
            Result = $result
            JobName = $jobName
            Button = $JobButton
            StartTime = Get-Date
            LogPath = $logFile
        }

        # === Wait for exit with timeout polling ===
        $totalWaitMs = $timeoutSeconds * 1000
        $elapsedMs = 0

        while ($elapsedMs -lt $totalWaitMs) {
            if ($process.HasExited) { break }

            # === Process real-time output ===
            if ($streamReader -and $outputQueue) {
                # -WriteToUI will write next batch of output to console area
                $null = Process-JobOutputQueue -OutputQueue $outputQueue -ResultObject $result -WriteToUI $true
            }

            # Let Windows process pending UI events (clicks, resizing, etc.)
            [System.Windows.Forms.Application]::DoEvents()

            Start-Sleep -Milliseconds $TimeoutPollIntervalMs
            $elapsedMs += $TimeoutPollIntervalMs
        }

        # === Check for completion or timeout ==
        if ($process.HasExited) {
            $result.ExitCode = $process.ExitCode
            # only set TerminationReason if not set to avoid overwriting KillRequested
            # reason set by Stop-CurrentJob
            if (!$result.TerminationReason) { $result.TerminationReason = "Completed" }
        } else {
            # Timeout reached - kill process
            $result.TimedOut = $true
            $result.ExitCode = -1
            $result.TerminationReason = "Timeout"
            $result.IsError = $true
            $result.StatusMessage = "TIMEOUT: $jobName"
            $result.LauncherMessage = "TIMEOUT: Job exceeded $timeoutSeconds seconds"
            Append-JobLog -Path $Result.logFile -Content $Result.LauncherMessage
        }

        # === Final drain of output queue ===
        if ($streamReader -and $outputQueue) {
            $null = Process-JobOutputQueue -OutputQueue $outputQueue -ResultObject $result -WriteToUI $true
        }

        # Determine success/failure for result object
        $result.Success = ($result.ExitCode -eq 0)

        # Set UI properties for completion or failure
        if ($result.Success) {
            $result.IsError = $false
            $result.StatusMessage = "Success: $jobName"
            $result.LauncherMessage = "Job completed successfully (exit code 0)"
            Append-JobLog -Path $Result.logFile -Content $Result.LauncherMessage
        } elseif (-not $result.TimedOut) {
            $result.IsError = $true
            $result.StatusMessage = "Failed: $jobName (exit $($result.ExitCode))"
            $result.LauncherMessage = "Job failed with exit code: $($result.ExitCode)"
            Append-JobLog -Path $Result.logFile -Content $Result.LauncherMessage
        }
    }
    catch {
        # Exception occurred - set result state
        if ([string]::IsNullOrWhiteSpace($result.TerminationReason)) {
            # only set TerminationReason if not set to avoid overwriting KillRequested
            # reason set by Stop-CurrentJob
            if (!$result.TerminationReason) { $result.TerminationReason = "Exception" }
        }
        if ([string]::IsNullOrWhiteSpace($result.LauncherMessage)) {
            $result.LauncherMessage = "Exception during job execution: $($_.Exception.Message)"

            # check for common errors; add hint if found
            foreach ($errorKey in $script:ErrorHints.Keys) {
                if ($_.Exception.Message.Contains($errorKey)) {
                    $result.LauncherMessage += $script:ErrorHints[$errorKey]
                    break
                }
            }

            Append-JobLog -Path $Result.logFile -Content $Result.LauncherMessage
        }
        if ($result.ExitCode -eq $null) {
            $result.ExitCode = -1
        }
        $result.Success = $false
        $result.IsError = $true
        $result.StatusMessage = "Error: $jobName"
    }
    finally {
        if ($streamReader) {
            Stop-JobOutputStreamReader -ReaderHandle $streamReader
        }
        Cleanup-Job -Result $result -Process $process
    }

    return $result.Success
}

<#
.SYNOPSIS
    Terminates the currently running job and cleans up UI state.

.DESCRIPTION
    Called when the user clicks the Kill button. Sets $script:KillRequested = $true
    to signal the running job's wait loop to exit, then proceeds to kill the
    process tree (or main process) using taskkill or .Kill().
    Prompts for confirmation if $ConfirmKillJob is $true.
    Captures any remaining output, finalizes the job log with "KilledByUser"
    reason, and resets UI button states.

.PARAMETER None
    This function has no parameters. It operates entirely on global script state
    ($script:CurrentRunningJob, $script:KillRequested, etc.).

.NOTES
    Depends on $KillProcessTree and $KillTimeoutGraceSeconds user settings.
    If no job is running, the function returns immediately with a warning message.
#>
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

        # Write to log file if present
        if ($script:CurrentRunningJob.ContainsKey('LogPath')) {
            Append-JobLog -Path $logFile -Content "Killed by user at $(Get-Date -Format 'HH:mm:ss')"
        }
        # Update termination reason for result in cleanup
        if ($script:CurrentRunningJob.ContainsKey('Result')) {
            Set-JobResultProperty -JobResult $script:CurrentRunningJob.Result -Property "TerminationReason" -Value "KillRequested" -FailIfMissing
        }
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

# =============================================================================
# THEMES
# =============================================================================

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
        $script:FallbackThemeName = $script:FallbackTheme
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
    Retrieves a color from the currently active theme palette.

.DESCRIPTION
    Looks up the specified property name in $script:CurrentThemePalette.
    Throws an error if the property is missing or hex conversion fails.

.PARAMETER PropertyName
    The key to look up (e.g., "form_background", "button").
#>
function Get-ThemeColor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

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

    If a group specifies a theme that doesn't exist, falls back to $script:FallbackThemeName
    and logs a warning. Missing color properties within a theme fall back to
    the default theme's values via Get-ThemeColor.

.PARAMETER themeName
    The name of the theme to activate (must be a key in $Script:Themes).

.EXAMPLE
    Apply-Theme -themeName "default"

.NOTES
    This function is called by Set-Item after Update-ButtonsForGroup has created
    the job buttons. It assumes $script:JobButtons is populated with all
    current buttons.

    Defensive checks prevent errors if any UI control is missing.
#>
function Apply-Theme {
    param(
        [Parameter(Mandatory = $true)]
        [string]$themeName
    )

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
    Determines the theme name for a specific item (Category or Group) based on configuration.

.DESCRIPTION
    Evaluates theme selection priority:
        1. User select theme from dropdown
        2. Group 'theme' property (if defined in JSON)
        3. Category 'theme' property (either this ones, if Item is
           a Category, or parent Category's if Item is a Group)
           (if defined in JSON)
        4. Global 'settings.theme' (if defined in JSON)
        5. Falls back to $script:FallbackThemeName

    This function performs validation only to the extent of checking
    property existence in the PSCustomObject from JSON. It does NOT
    verify that the theme name exists in $Script:Themes.

.PARAMETER Item
    The target item. One of the Hashtable in $script:NavigationItems set by Load-Config (which parses JSON)
    Contains .Type, .Label, .Parent (if from a "group" node in JSON), and .Node. .Node is the
    PSObject for the JSON node, which contains .name, .jobs (if Group), .groups (if Category),
    and optionally .theme.

.EXAMPLE
    $themeName = Get-ItemTheme -Item $selectedGroup
    $themeName = Get-ItemTheme -Item $selectedCategory

.NOTES
    - $Item should be one of the hashtables in $script:NavigationItems (populated by Load-Config,
      which parses JSON and creates hashtables for each category or group node found)
      These hashtables have .Node property, which is the PSObject for the JSON data for
      that node. Group nodes also have a .Parent property, which is the PSObject for the JSON
      data for the parent category node. Both .Node and .Parent objects contain the JSON data
      for that node, i.e. "name", "theme" (optionally), others.
    - Returns a string. Does not modify global state. Caller should pass
      the returned name to Set-Theme.
#>
function Get-ItemTheme {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Item
    )

    # User override takes highest priority
    if ($script:UserSelectedTheme) {
        return $script:UserSelectedTheme
    }

    # Resolve theme name (group > category > settings > $script:FallbackThemeName)
    if ($Item.PSObject.Properties["Node"] -and $Item.Node.PSObject.Properties['theme'] -and $Item.Node.theme) {
        # own "theme" property (regardless if Category or Group)
        return $Item.Node.theme
    }
    if ($Item.PSObject.Properties["Parent"] -and $Item.Parent.PSObject.Properties['theme'] -and $Item.Parent.theme) {
        # only Group have Parent property which would be a Category
        return $Item.Parent.theme
    }
    if ($script:Settings.PSObject.Properties['theme'] -and $script:Settings.theme) {
        # JSON global theme in "settings" of currently selected job configuration JSON file
        return $script:Settings.theme
    }
    if ($script:LauncherSettings.PSObject.Properties['theme'] -and $script:LauncherSettings.theme) {
        # JSON global theme in launcher settings (main JSON file for this script)
        return $script:LauncherSettings.theme
    }
    return $script:FallbackThemeName
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
    param(
        [Parameter(Mandatory = $true)]
        [string]$themeName
    )

    # Validate theme exists
    if ($Script:Themes.ContainsKey($themeName)) {
        $script:CurrentThemeName = $themeName
        $script:CurrentThemePalette = $Script:Themes[$themeName]
    } else {
        throw "Can't set theme '$themeName' -- doesn't exist."
    }
}

# =============================================================================
# UI MANAGEMENT: LEFT PANEL: TOGGLE BUTTONS
# =============================================================================

<#
.SYNOPSIS
    Creates the toggle button for switching between List and Tree views.

.DESCRIPTION
    Creates a Button control docked to the bottom of the left panel.
    The button's Tag property stores the current view state:
    - $true  = Tree view (category groups with collapsible nodes)
    - $false = Flat view (list with category dividers)

    The click event flips the state via Set-ToggleButton and triggers
    Populate-LeftPanel to rebuild the left panel with the opposite view.

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
    # state then calls Populate-LeftPanel again
    $button.Add_Click({
        $newState = -not $this.Tag
        Set-ToggleButton -Button $this -State $newState
        Populate-LeftPanel
    })

    return $button
}

<#
.SYNOPSIS
    Set view toggle button tag back to $null to clear user selection.
.DESCRIPTION
    - The left panel has a view toggle button when hierarchical configs are displayed.
    - If user clicks the button, the result saved in button .Tag as boolean
      ($true for TreeView, $false for ListBox)
    - This allows user selected views to persist if the left panel gets re-built
      (which it does any time the view changes e.g. if user switches the view)
    - Issue: need to clear this when a new config is loaded (as want that config's
      "view" setting to take priority over any view that was set for the previous config)

.PARAMETER Button
    The toggle button control to update.
#>
function Clear-ToggleButton {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$Button
    )
    $Button.Tag = $null
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
    Does NOT trigger Populate-LeftPanel. The caller is responsible for rebuilding
    the view after calling this function.
#>
function Set-ToggleButton {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$Button,
        [boolean]$State
    )

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
    Creates and displays job buttons for a selected group in the right panel.

.DESCRIPTION
    Builds job buttons for a selected group in a temporary off-screen panel,
    then swaps it with the existing panel. This eliminates flicker by ensuring
    the new buttons are fully constructed before being displayed.

    For each job, creates a new Button control configured with the job's name,
    hover effects, and a click handler that runs Invoke-Job. Stores each button
    in $script:JobButtons hashtable keyed by job name for later state updates
    (enabling/disabling, color changes).

.PARAMETER GroupItem
    A Group Item object created during JSON loading (in Load-HierarchicalConfig
    or Load-FlatConfig). Contains:
    - .Type     = "group"
    - .Label    = group name (display string)
    - .Node     = raw JSON group object (contains .name, .jobs array, and optional
                  .working_directory, .timeout_seconds, .theme)
    - .Parent   = parent Category Item (if hierarchical JSON, otherwise $null)
    - .JobItems = array of wrapped Job Items belonging to this group

    This is NOT the raw JSON from the config file. It is an enhanced object
    created during JSON loading in either Load-FlatConfig or
    Load-HierarchicalConfig (search for Type = "group").
    The JSON is at the .Node field if you needed.

    This is typically passed from Set-Item as $script:CurrentItem (when the
    selected item has Type = "group").

.EXAMPLE
    Update-ButtonsForGroup -GroupItem $selectedGroup

.NOTES
    - Called by Set-Item when a new group is selected. The button panel reference
      is stored in $script:FormControls.ButtonPanel.
    - a Group Item is needed (wrapped created during json parsing) rather than raw
      group config itself (raw json data), because need access to array of wrapped
      Job Item objects for each job in the group (rather than just the job JSON);
      Invoke-Job requires the Job Item (rather than just the job json) so that calls
      to Get-JobWorkingDirectory, Get-JobTimeout will can traverse parent nodes in
      the json
    - Implements double-buffering: builds buttons in a temporary off-screen panel,
      then swaps with the existing panel to prevent UI flicker.
#>
function Update-ButtonsForGroup {
    param(
        [Parameter(Mandatory = $true)]
        [PSObject]$GroupItem
    )

    # Validate GroupItem has the required .Jobs property
    if (-not ($GroupItem.PSObject.Properties['JobItems'] -and $GroupItem.JobItems)) {
        throw "Update-ButtonsForGroup: GroupItem is missing .Jobs property. Expected a valid Group Item with wrapped Job Items."
    }

    # List of Job Items attached to the Group Item during JSON parsing
    $jobs = $GroupItem.JobItems

    # Create a new panel off-screen (not yet added to parent)
    $newPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $newPanel.Dock = "Fill"
    $newPanel.FlowDirection = "TopDown"
    $newPanel.WrapContents = $true
    $newPanel.AutoScroll = $true
    $newPanel.Padding = New-Object System.Windows.Forms.Padding(5)
    $newPanel.Visible = $false  # hidden until fully built

    # Temporary hashtable for new buttons (to replace $script:JobButtons)
    $newJobButtons = @{}

    foreach ($job in $jobs) {
        # Get raw job JSON
        $rawJob = Get-JobConfig -JobItem $job

        $jobName = $rawJob.name

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $jobName
        $btn.Height = $UI_Button_Height
        $btn.Width = $newPanel.Width - 20
        $btn.TextAlign = "MiddleLeft"
        $btn.FlatStyle = "Flat"
        $btn.Margin = New-Object System.Windows.Forms.Padding($UI_Button_Margin)

        # Store Job Item (contains .Node with raw JSON, plus parent references) in button's Tag property
        # so it can be passed to Invoke-Job on button click
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

            $buttonRef = $this

            # Disable all job buttons immediately
            Write-Host "DEBUG: button click handler: About to disable job buttons (kill button should enable)"
            Update-ButtonStates -Running $true

            if ($UI_ClearOutputBeforeEachJob) {
                $script:OutputTextBox.Clear()
            }

            # Run the job
            $success = Invoke-Job -JobItem $this.Tag -JobButton $buttonRef

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

        $newPanel.Controls.Add($btn)
        $newJobButtons[$jobName] = $btn
    }

    # Get the parent container (the TableLayoutPanel that holds ButtonPanel)
    $parent = $script:FormControls.ButtonPanel.Parent
    if ($parent -eq $null) {
        throw "Update-ButtonsForGroup: ButtonPanel has no parent container. Cannot swap panels."
    }

    # Get the row and column position of the old panel
    $row = $parent.GetRow($script:FormControls.ButtonPanel)
    $col = $parent.GetColumn($script:FormControls.ButtonPanel)

    # Remove old panel and dispose it (free memory)
    $parent.Controls.Remove($script:FormControls.ButtonPanel)
    $script:FormControls.ButtonPanel.Dispose()

    # Add the new fully-built panel
    $parent.Controls.Add($newPanel, $col, $row)
    $newPanel.Visible = $true

    # Update global references
    $script:FormControls.ButtonPanel = $newPanel
    $script:JobButtons = $newJobButtons

    # Adjust button widths after panel is added (now it has a Width)
    foreach ($btn in $script:JobButtons.Values) {
        $btn.Width = $newPanel.Width - 20
    }

    # Apply current theme colors to the new buttons
    $buttonColor = Get-ThemeColor -PropertyName "button"
    $buttonTextColor = Get-ThemeColor -PropertyName "button_text"
    foreach ($btn in $script:JobButtons.Values) {
        $btn.BackColor = $buttonColor
        $btn.ForeColor = $buttonTextColor
    }
}

# =============================================================================
# UI MANAGEMENT: LIST AND TREE VIEW IN LEFT PANEL
# =============================================================================

<#
.SYNOPSIS
    Removes and disposes the current left panel control (TreeView or ListBox).

.DESCRIPTION
    Checks whether a TreeView or ListBox currently exists in the left panel
    (via $script:FormControls.TreeView and $script:FormControls.ListBox).
    If found, removes it from the panel, disposes it to free resources,
    and clears the corresponding global variable.

    This function is called before populating a new view to ensure only one
    control exists at a time and to prevent memory leaks.

.NOTES
    Both TreeView and ListBox globals are checked because the left panel
    can contain either, but never both simultaneously. The function safely
    handles the case where neither exists.
#>
function Clear-LeftPanel {
    # Remove existing TreeView if present
    if ($script:FormControls.ContainsKey('TreeView') -and $script:FormControls.TreeView) {
        $script:FormControls.LeftPanel.Controls.Remove($script:FormControls.TreeView)
        $script:FormControls.TreeView.Dispose()
        $script:FormControls.TreeView = $null
    }
    # Remove existing ListBox if present
    if ($script:FormControls.ContainsKey('ListBox') -and $script:FormControls.ListBox) {
        $script:FormControls.LeftPanel.Controls.Remove($script:FormControls.ListBox)
        $script:FormControls.ListBox.Dispose()
        $script:FormControls.ListBox = $null
    }
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
    return $maxWidth + 20
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

    Sets $script:FormControls.ListBox and binds selection to Set-Item.
    Auto-sizes the left panel width based on the widest group name.

.NOTES
    Called by Populate-LeftPanel when $script:HasCategories = $false.
    Requires $script:NavigationItems to be populated (by Load-FlatConfig).
    Requires $script:FormControls.LeftPanel to exist (created in Build-GUI).
#>
function Populate-FlatList {

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Dock = "Fill"
    $listBox.Font = New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Normal)
    $listBox.IntegralHeight = $false
    $null = $script:FormControls.LeftPanel.Controls.Add($listBox)
    $script:FormControls.ListBox = $listBox

    # Populate ListBox
    $script:FormControls.ListBox.Items.Clear()
    foreach ($item in $script:NavigationItems) {
        # skip categories; only build groups
        if ($item.Type -eq "group") {
            # You can add the group objects directly as added a custom
            # toString() function on them which makes .Label the string
            # representation of the object. Doing this because when I used
            # Initialize-ListBox to create the ListBox, the Add_Draw event
            # screwed up width and height, and none of it was needed for
            # the flat case anyway.
            $null = $script:FormControls.ListBox.Items.Add($item)
        }
    }

    # Bind selection change event
    $script:FormControls.ListBox.Add_SelectedIndexChanged({
        if ($script:FormControls.ListBox.SelectedItem) {
            $selectedIndex = $script:FormControls.ListBox.SelectedIndex
            $selectedGroup = $script:FormControls.ListBox.Items[$selectedIndex]
            Set-Item -Item $selectedGroup
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
    Populates the TreeView with categories and groups from the loaded configuration.

.DESCRIPTION
    Reads $script:NavigationItems (built by Load-Configuration) and builds a TreeView
    where each category is a parent node and each group is a child node.
    Category nodes have Tag = $null (not selectable). Group nodes have Tag = $group
    object (used by Set-Item). Expands all categories by default, auto-sizes the
    left panel width, and selects the first group node.

.NOTES
    This function is called by Populate-LeftPanel when "view": "tree" is set in JSON.
    Requires $script:FormControls.TreeView to exist (created by Initialize-CategoryTreeView).
    Requires $script:FormControls.SplitContainer for auto-width adjustment.
#>
function Populate-TreeView {

    # throw error if now hierarchical
    if (-not $script:HasCategories) {
        throw "Populate-TreeView: No categories in JSON -- can't populate tree view"
    }

    # Create TreeView (to hold groups) using dedicated function
    $treeView = Initialize-CategoryTreeView
    $null = $script:FormControls.LeftPanel.Controls.Add($treeView)
    $script:FormControls.TreeView = $treeView

    # Build TreeView nodes from $script:NavigationItems
    foreach ($item in $script:NavigationItems) {
        if ($item.Type -eq "category") {
            # Create category node (parent)
            $categoryNode = New-Object System.Windows.Forms.TreeNode($item.Label)
            # store entire Category object in Tag for use later
            $categoryNode.Tag = $item
            $null = $treeView.Nodes.Add($categoryNode)
        } elseif ($item.Type -eq "group") {
            # This item is a group – add to the last category node
            $groupNode = New-Object System.Windows.Forms.TreeNode($item.Label)
            # store entire Group object in Tag for use later
            $groupNode.Tag = $item
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
        # only call if this is a group - not category
        if ($node.Tag -ne $null -and $node.Tag.Type -eq "group") {
            Set-Item -Item $node.Tag
        }
    })
}

<#
.SYNOPSIS
    Populates the ListBox with category dividers and groups from the loaded configuration.

.DESCRIPTION
    Reads $script:NavigationItems (built by Load-Configuration) and builds an owner-draw
    ListBox where category dividers appear as bold, centered, non-selectable items
    and groups appear as standard selectable items. Uses custom drawing for
    dividers and dynamic theme colors for groups.

    This function configures the ListBox's DrawMode, attaches the DrawItem event,
    sets ItemHeight based on font size plus padding, and applies auto-width sizing
    to the left panel.

.NOTES
    This function is called by Populate-LeftPanel when "view": "flat" is set in JSON
    (or when no view setting is present, as flat is the default).

    Requires $script:FormControls.LeftPanel to exist (created in Build-GUI).
    Creates $script:FormControls.ListBox and stores it for later access.
#>
function Populate-ListWithDividers {

    # throw error if now hierarchical
    if (-not $script:HasCategories) {
        throw "Populate-ListWithDividers: No categories in JSON -- can't populate list with dividers"
    }

    # Create ListBox using dedicated function
    $listBox = Initialize-ListBox
    $null = $script:FormControls.LeftPanel.Controls.Add($listBox)
    $script:FormControls.ListBox = $listBox

    # Populate items from $script:NavigationItems
    foreach ($item in $script:NavigationItems) {
        $null = $listBox.Items.Add($item)
    }

    # === Change event for clicking item in list Box ===

    # == Category selection hack (Part 1 of 2) ==
    # == (please read) ===
    #
    # Issue: Want categories to be non-selectable headers, but ListBox
    # has no native concept of non-selectable items. So when a user clicks
    # a category, the ListBox selects and highlights it (triggering this change
    # event), and deselects the previously selected group.
    #
    # We cannot suppress categories from being selected and triggering this event,
    # but we can work around it.
    #
    # Below is part of a two-part strategy to make categories behave like
    # non-selectable headers:
    #
    # 1. Functional (this change event):
    #    If the clicked item is a category, immediately trigger a second change
    #    event to reselect the previously selected group. This prevents the
    #    current group from being deselected.
    #    → Without this, even with the Visual change above, the currently
    #      selected group would lose its highlighting (and with the Visual
    #      change, it would appear like nothing is selected)
    #
    # 2. Visual (in Initialize-ListBox):
    #    Categories are painted with unselected background regardless of
    #    selection state. User never sees a category highlighted.
    #
    # Together, these give the illusion that categories are not selectable.
    # See for more info: https://github.com/bkuz114/job-launcher/issues/9
    #
    # IMPORTANT: This change event is STILL NEEDED even if you no longer want to
    # maintain the illusion that categories aren't selectable, because if a group
    # is clicked, you still need to call Set-Item on it.

    $listBox.Add_SelectedIndexChanged({
        param($sender, $e)
        $selectedItem = $sender.SelectedItem

        # If category selected, immediately revert selection back to
        # last selected group, else that group will be un-highlighted,
        # and nothing will be highlighted (as categories have been
        # styled to never appear highlighted)
        if ($selectedItem.Type -eq "category") {
            # Revert to last selected group if it exists (it should always exist
            # because Initialize-LeftPanel selects the first group on startup).
            if ($script:CurrentDisplayedGroup -ne $null) {
                # trigger another change event to the last group (which has
                # just been de-selected) to re-select it
                $sender.SelectedItem = $script:CurrentDisplayedGroup
            } else {
                throw "No last selected group found when reverting from category selection. This should never happen. Check Initialize-LeftPanel and ensure a group is selected on startup."
            }
        } else {
            # It's a group

            # only update if not currently displayed group to avoid rebuilding right panel
            # Note: categories won't update right panel regardless.
            if ($selectedItem -ne $script:CurrentDisplayedGroup) {
                Set-Item -Item $selectedItem

                # update as currently dispalyed group
                if ($selectedItem.Type -eq "group") {
                    $script:CurrentDisplayedGroup = $selectedItem
                }
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
    Finds a TreeNode in a TreeView by matching its Tag.Label property.
.DESCRIPTION
    Searches all category and group nodes for a node whose Tag.Label equals the specified name.
    Returns the first matching node, or $null if not found.
.PARAMETER Tree
    The TreeView control to search.
.PARAMETER NodeName
    The Label value to match against node.Tag.Label.
.OUTPUTS
    System.Windows.Forms.TreeNode or $null
#>
function Find-MatchingTreeNode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.TreeView]$Tree,
        [Parameter(Mandatory = $false)]
        [String]$NodeName
    )

    for ($i = 0; $i -lt $Tree.Nodes.Count; $i++) {
        if ($Tree.Nodes[$i].Tag.Label -eq $NodeName) {
            # matching category
            return $Tree.Nodes[$i]
        }
        for ($j = 0; $j -lt $Tree.Nodes[$i].Nodes.Count; $j++) {
            if ($Tree.Nodes[$i].Nodes[$j].Tag.Label -eq $NodeName) {
                # matching group
                return $Tree.Nodes[$i].Nodes[$j]
            }
        }
    }
}

<#
.SYNOPSIS
    Selects a Node in TreeView (highlights it via .SelectedNode property and triggers Set-Item.)
.DESCRIPTION
    Called by Initialize-LeftPanel when switching views. Attempts to find a node
    matching the provided Item (by Label). If found, selects it and calls Set-Item.
    If no Item provided, selects the first group node (first child of first category).
.PARAMETER Tree
    The TreeView control to initialize.
.PARAMETER Item
    Optional hashtable (from $script:CurrentItem) representing a specific Item to select.
    If $null, selects the first group node.
#>
function Initialize-TreeViewItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.TreeView]$Tree,
        [Parameter(Mandatory = $false)]
        [PSCustomObject]$Item
    )

    $nodeToSelect = $null
    if ($Item -ne $null) {
        # Find node in tree matching item name
        $nodeToSelect = Find-MatchingTreeNode -Tree $Tree -NodeName $Item.Label
    } else {
        # Item null or not passed
        # Select the first group node (first child of first category)
        if ($Tree.Nodes.Count -gt 0 -and $Tree.Nodes[0].Nodes.Count -gt 0) {
            $nodeToSelect = $Tree.Nodes[0].Nodes[0]
        }
    }

    if ($nodeToSelect -ne $null) {
        # found a match: initialize to this node by highlighting
        # in the panel and setting theme, loading job buttons
        $Tree.SelectedNode = $nodeToSelect
        Set-Item -Item $nodeToSelect.Tag
    } else {
        Write-Host "DEBUG: Could not determine TreeView node to intiailize"
    }
}

<#
.SYNOPSIS
    Selects a Node in ListBox (highlights it via .SelectedNode property and triggers Set-Item.)
.DESCRIPTION
    Called by Initialize-LeftPanel when switching views. Attempts to find an item
    matching the provided Item (by Label). If found, selects it and calls Set-Item.
    If no Item provided, selects the first group item (skipping dividers).
.PARAMETER List
    The ListBox control to initialize.
.PARAMETER Item
    Optional hashtable (from $script:CurrentItem) representing specific node to initialize to.
    If $null, selects the first group item.
#>
function Initialize-ListBoxItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ListBox]$List,
        [Parameter(Mandatory = $false)]
        [PSCustomObject]$Item
    )

    $matchingIndex = -1
    if ($Item -ne $null) {
        # Find node in list matching item name
        for ($i = 0; $i -lt $List.Items.Count; $i++) {
            if ($List.Items[$i].Label -eq $Item.Label) {
                $matchingIndex = $i
                break
            }
        }
    } else {
        # Select first non-divider item
        for ($i = 0; $i -lt $List.Items.Count; $i++) {
            if ($List.Items[$i].Type -eq "group") {
                $matchingIndex = $i
                break
            }
        }
    }

    # If found match, initialize by highlighting, setting theme and loading job buttons
    if ($matchingIndex -gt -1) {
        $List.SelectedIndex = $matchingIndex
        Set-Item -Item $List.Items[$matchingIndex]
    } else {
        Write-Host "DEBUG: Could not determine ListBox node to intiailize"
    }
}

<#
.SYNOPSIS
    Creates and configures a TreeView control for category/group navigation.

.DESCRIPTION
    Returns a TreeView with HideSelection = false (so selected group remains visible).
    No event handlers attached here – those go in Populate-LeftPanel.
#>
function Initialize-CategoryTreeView {
    $treeView = New-Object System.Windows.Forms.TreeView
    $treeView.Dock = "Fill"
    $treeView.Font = New-Object System.Drawing.Font($UI_Font_Family, $UI_Font_Size_Normal)
    $treeView.HideSelection = $false
    $treeView.BorderStyle = "None"
    return $treeView
}

# =============================================================================
# UI MANAGEMENT: BUTTON STATES
# =============================================================================

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

    # Disable config dropdown if job running
    if ($script:ConfigMenuItem) {
        $script:ConfigMenuItem.Enabled = (-not $Running)
    }

    if ($script:KillButton) {
        # KillButtn should be opposite of job buttons: enable when jobs running, gray out otherwise
        Update-KillButton -KillButton $script:KillButton -Enable $Running
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

# =============================================================================
# UI MANAGEMENT: UI SWITCHING
# =============================================================================

<#
.SYNOPSIS
    Switches the UI to display a different job item (group or category).

.DESCRIPTION
    Orchestrates the full UI refresh when a user selects a new item from the
    left panel. This function is the single entry point for item changes.

    Steps performed:
    1. (if item is a group): Recreates all job buttons for the new group (Update-ButtonsForGroup)
    2. Applies color theme to all UI elements (Apply-Theme)

    Separating button recreation from theme application keeps concerns clean
    and allows theme to be reapplied without rebuilding buttons if needed.

.PARAMETER Item
    The target item. One of the Hashtable in $script:NavigationItems set by Load-Config (which parses JSON)
    Contains .Type, .Label, Parent (if from a "group" node in JSON), and .Node. .Node is the
    PSObject for the JSON node, which contains .name, .jobs (if Group), .groups (if Category),
    and optionally .theme.

.EXAMPLE
    Set-Item -Item $selectedGroup
    Set-Item -Item $selectedCategory

.NOTES
    - Currently nothing happening in Category case other than theme set, 
      but lumping in with Groups in Set-Item in case there is other unified
      logic that needs to happen for both.
    - $Item should be one of the hashtables in $script:NavigationItems (populated by Load-Config,
      which parses JSON and creates hashtables for each category or group node found)
      These hashtables have .Node property, which is the PSObject for the JSON data for
      that node. Group nodes also have a .Parent property, which is the PSObject for the JSON
      data for the parent category node. Both .Node and .Parent objects contain the JSON data
      for that node, i.e. "name", "theme" (optionally), others.
    - Should pass $Item when calling Get-ItemTheme, but $Item.Node when calling Update-ButtonsForGroup
      (As it wants the JSON data directly)
    Called from:
    - Populate-LeftPanel (initial load, selects the first group)
    - ListBox SelectedIndexChanged event (user clicks a different group)

    Does not modify the ListBox selection itself - that is handled by the caller
    or user interaction. This function only responds to the selected group.
#>
function Set-Item {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Item
    )

    # ignore category nodes
    if ($Item.Type -ne "group") {
        return
    }

    # update current selected item
    $script:CurrentItem = $Item

    # Get the theme name and set it
    # NOTE: Must call befoe Update-ButtonsForGroup
    # to ensure theme pallette set
    $itemTheme = Get-ItemTheme -Item $Item
    Set-Theme -ThemeName $itemTheme

    # update theme dropdown in MenuBar
    Update-DropdownSelection -Dropdown $script:ThemeMenuItem -SelectedItem $itemTheme

    if ($Item.Type -eq "group") {
        # Create buttons for this group
        Update-ButtonsForGroup -GroupItem $Item
    }

    # Apply theme (panel background, any other UI decorations)
    Apply-Theme -themeName $itemTheme
}

function Set-JobConfig {
    param([string]$ConfigName)
    if (-not $script:AvailableConfigs.ContainsKey($ConfigName)) {
        throw "Apply-JobConfig: Config '$ConfigName' not found in AvailableConfigs"
    }

    $config = $script:AvailableConfigs[$ConfigName]

    # Set globals
    $script:Settings = $config.Settings
    $script:NavigationItems = $config.NavigationItems
    $script:HasCategories = $config.HasCategories

    # Clear any user selection of left panel views
    # (this should be done before left panel is re-built for the new config!)
    if ($script:FormControls -and $script:FormControls.ContainsKey("ToggleButton") -and $script:FormControls.ToggleButton) {
        Clear-ToggleButton -Button $script:FormControls.ToggleButton
    }

    # Reset UI-dependent globals
    $script:CurrentItem = $null
    $script:CurrentDisplayedGroup = $null
    $script:CurrentConfigName = $ConfigName
}

<#
.SYNOPSIS
    Applies a previously loaded config to the UI.

.DESCRIPTION
    Takes a config object from $script:AvailableConfigs and sets all
    globals to its values, then refreshes the left panel and theme.

.PARAMETER ConfigName
    The key name of the config in $script:AvailableConfigs.
#>
function Apply-JobConfig {
    param([string]$ConfigName)

    if (-not $script:AvailableConfigs.ContainsKey($ConfigName)) {
        throw "Apply-JobConfig: Config '$ConfigName' not found in AvailableConfigs"
    }

    # Set as current config
    # MUST CALL BEFORE REFRESHING UI
    # (among other reasons, the left panel view toggle button
    # must be cleared, else user's view selection from the
    # previous config will override the new config's view setting)
    Set-JobConfig -ConfigName $ConfigName

    # update config dropdown in MenuBar
    Update-DropdownSelection -Dropdown $script:ConfigMenuItem -SelectedItem $ConfigName

    # Refresh UI
    Populate-LeftPanel
}

# =============================================================================
# UI MANAGEMENT: MAIN UI RENDERING
# =============================================================================

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

        # == colors to use in left panel == #

        $listBackgroundColor = Get-ThemeColor -PropertyName "list_background" # bg color of actual left panel
        $selectedItemBackgroundColor = Get-ThemeColor -PropertyName "list_background_selected" # highlighting color behind selected text
        $textColor = Get-ThemeColor -PropertyName "list_text" # text color of group items in left panel
        $textColorDivider = Get-ThemeColor -PropertyName "list_text_divider"  # text color of divider (category items) in left panel
        $selectedTextColor = Get-ThemeColor -PropertyName "list_text_selected" # text color of selected item

        $index = $e.Index
        if ($index -lt 0 -or $index -ge $sender.Items.Count) { return }

        $item = $sender.Items[$index]
        $bounds = $e.Bounds
        $e.DrawBackground()

        # check if item is selected
        $isSelected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0

        # == Category selection hack (Part 2 of 2) ==
        #
        # Issue: Want to make Categories non-selectable, but ListBox provides
        # no way to do this, and no way to suppress click events.
        #
        # - Part 1 is in Populate-ListWithDividers (SelectedIndexChanged event)
        #   It reverts selection back to the last selected group when a category is clicked. So:
        #   - a category is briefly selected (and this DrawItem event is called)
        #   - group is de-selected
        #   - then the group is selected back (and this DrawItem event is called again)
        # - Part 2 (this):
        #   a. Categories are painted with unselected background regardless of selection state.
        #      (to appear unselected during that brief selection state)
        #   b. If a group is the currently displayed one (e.g. group highlighted before
        #      the category is clicked) - highlight it. (this avoids a UI flicker
        #      when the group is briefly de-selected before it is selected back)
        #
        # See the long comment there for full explanation, or reference GitHub issue:
        # https://github.com/bkuz114/job-launcher/issues/9
        #
        # Note:
        # - The if/else structure is still required for normal styling of both categories and groups.
        #   Do not remove it.
        #   The hack-specific part is painting categories with unselected background even when selected.

        if ($item.Type -eq "category") {

            # Divider styling
            $font = New-Object System.Drawing.Font($sender.Font, [System.Drawing.FontStyle]::Bold)
            $brush = New-Object System.Drawing.SolidBrush($textColorDivider)
            $format = New-Object System.Drawing.StringFormat
            $format.Alignment = [System.Drawing.StringAlignment]::Center
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rectF = New-Object System.Drawing.RectangleF($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)

            # paint bg color to match Left Panel bg color
            # even when selected, to give illusion that
            # not selected.
            # Note: MUST CALL BEFORE PAINTING TEXT COLOR.
            $bgBrush = New-Object System.Drawing.SolidBrush($listBackgroundColor)
            $e.Graphics.FillRectangle($bgBrush, $bounds)
            $bgBrush.Dispose()

            # paint text color
            $e.Graphics.DrawString($item.Label, $font, $brush, $rectF, $format)

            # Prevent selection highlight
            $e.DrawFocusRectangle()

            $font.Dispose()
            $format.Dispose()
        } else {

            # Create brush based on selection state
            $bgBrush = $null
            if ($isSelected -or $item -eq $script:CurrentDisplayedGroup) {
                $brush = New-Object System.Drawing.SolidBrush($selectedTextColor)
                $bgBrush = New-Object System.Drawing.SolidBrush($selectedItemBackgroundColor)
            } else {
                $brush = New-Object System.Drawing.SolidBrush($textColor)
                $bgBrush = New-Object System.Drawing.SolidBrush($listBackgroundColor)
            }

            # paint background
            $e.Graphics.FillRectangle($bgBrush, $bounds)
            $bgBrush.Dispose()

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
    Initializes the left panel by selecting the first selectable item (group).

.DESCRIPTION
    Called after Populate-LeftPanel creates either a TreeView or ListBox.
    Determines which control exists, selects the first group (not divider or category),
    and triggers Set-Item to load the corresponding jobs and apply theme.

    This function replaces the scattered initialization logic that was duplicated
    across Populate-TreeView, Populate-ListWithDividers, and Populate-FlatList.

.NOTES
    - TreeView: selects the first child node of the first category node.
      Expects Tag to be a hashtable with .Node property containing the group object.
    - ListBox: iterates items and selects the first item with Type = "group".
      Uses .SelectedIndex = $i (not .SelectedItem) to avoid type confusion.
    - Throws if neither TreeView nor ListBox exists (should not happen in normal operation).
#>
function Initialize-LeftPanel {
    param(
        [Parameter(Mandatory = $false)]
        [PSCustomObject]$Item
    )

    if ($script:FormControls.ContainsKey('TreeView') -and $script:FormControls.TreeView) {
        Initialize-TreeViewItem -Tree $script:FormControls.TreeView -Item $Item
    } elseif ($script:FormControls.ContainsKey('ListBox') -and $script:FormControls.ListBox) {
        Initialize-ListBoxItem -List $script:FormControls.ListBox -Item $Item
    } else {
        throw "Can't initialize LeftPanel: no TreeView or ListBox were created"
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
    $toolbar = New-Object System.Windows.Forms.TableLayoutPanel
    $toolbar.RowCount = 1
    $toolbar.Dock = "Top"
    $toolbar.AutoSize = $true
    $toolbar.AutoSizeMode = "GrowAndShrink"
    $toolbar.ColumnCount = 2
    $toolbar.ColumnStyles.Clear()
    $null = $toolbar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Col 0: Logo
    $null = $toolbar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) # Col 1: Kill button

    # === Column 0: Logo ===

    $logoBox = New-Object System.Windows.Forms.PictureBox
    if (Test-Path $AppBranding) {
        $logoBox.Width = 64
        $logoBox.Height = 64
        $logoBox.SizeMode = "Zoom"
        $logoBox.Image = [System.Drawing.Image]::FromFile($AppBranding)
    } else {
        Write-Host "WARNING: App branding image not found at $AppBranding"
    }
    $logoBox.Margin = New-Object System.Windows.Forms.Padding(8, 5, 8, 5)
    $logoBox.Anchor = "Left"

    # === Column 1: Kill button (right-aligned) ===
    $killButton = New-Object System.Windows.Forms.Button
    $killButton.Text = "Kill Current Job"
    $killButton.AutoSize = $true
    $killButton.AutoSizeMode = "GrowAndShrink"
    $killButton.Anchor = "Right"  # Align to the right side of the panel
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

    $script:KillButton = $killButton

    # === Assemble Toolbar ===

    $null = $toolbar.Controls.Add($logoBox, 0, 0)
    $null = $toolbar.Controls.Add($killButton, 1, 0)

    $toolbar.Margin = New-Object System.Windows.Forms.Padding(0)

    return $toolbar
}

<#
.SYNOPSIS
    Creates the Theme menu item for the menu bar.

.DESCRIPTION
    Builds a ToolStripMenuItem named "Theme" populated with all available
    theme names from $Script:Themes. Each theme name is added as a submenu
    item with a click handler that calls Apply-Theme and sets
    $script:UserSelectedTheme.

    A separator and a "Reset" item are also added. Reset clears the user
    theme override and reapplies the theme from the currently selected item.

.OUTPUTS
    [System.Windows.Forms.ToolStripMenuItem] - The configured Theme menu item.

.EXAMPLE
    $themeMenu = Create-ThemeMenuItem
    $menuStrip.Items.Add($themeMenu)

.NOTES
    Does not add a checkmark indicator for the currently active config.
#>
function Create-ThemeMenuItem {
    $themeMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $themeMenu.Text = "&Theme"  # Alt+C shortcut

    # Regular themes
    foreach ($themeName in $Script:Themes.Keys | Sort-Object) {
        $menuItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $menuItem.Text = $themeName
        $menuItem.Add_Click({
            # Get raw text (strip out any marker)
            $selectedText = $this.Text.replace($DropdownMarker, "")

            # Regular user selection: apply theme and indicate user selection
            Apply-Theme -themeName $selectedText
            # set user selected theme so group switching won't override it
            $script:UserSelectedTheme = $selectedText

            # update the dropdown to show this selection
            Update-DropdownSelection -Dropdown $this.OwnerItem -SelectedItem $selectedText
        })
        $null = $themeMenu.DropDownItems.Add($menuItem)
    }

    # Separator
    $null = $themeMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    # Reset item
    $resetItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $resetItem.Text = "Reset"
    $resetItem.Add_Click({
        # Reset global boolean UserSelectedTheme
        # (Get-ItemTheme checks this boolean and if set it
        # won't update Group / Category themes when selected)
        $script:UserSelectedTheme = $null
        $themeToApply = Get-ItemTheme -Item $script:CurrentItem
        Apply-Theme -themeName $themeToApply
        Update-DropdownSelection -Dropdown $this.OwnerItem
    })
    $null = $themeMenu.DropDownItems.Add($resetItem)

    return $themeMenu
}

<#
.SYNOPSIS
    Creates the Config menu item for the menu bar.

.DESCRIPTION
    Builds a ToolStripMenuItem named "Config" populated with all available
    job configuration names from $script:AvailableConfigs. Each config name
    is added as a submenu item with a click handler that calls Apply-JobConfig.

    The menu is dynamically populated based on discovered configs at runtime.

.OUTPUTS
    [System.Windows.Forms.ToolStripMenuItem]

.NOTES
    Does not add a checkmark indicator for the currently active config.
#>
function Create-ConfigMenuItem {
    $configMenu = New-Object System.Windows.Forms.ToolStripMenuItem
    $configMenu.Text = "&Config"  # Alt+C shortcut

    # Populate with available configs
    foreach ($configName in ($script:AvailableConfigs.Keys | Sort-Object)) {
        $menuItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $menuItem.Text = $configName
        $menuItem.Add_Click({
            # Apply the config (remove checkmark from the name)
            Apply-JobConfig -ConfigName $this.Text.Replace($DropdownMarker, "")

            # WARNING: Do NOT call Update-DropdownSelection to update the checkmark
            # - Apply-JobConfig already calls Update-DropSelection
            # - As a result, after Apply-JobConfig, $this.Text will now have a checkmark
            # - Thus, if you send $this.Text to Update-DropdownSelection it will fail
            #   due to having a checkmark
        })
        $null = $configMenu.DropDownItems.Add($menuItem)
    }
    return $configMenu 
}

<#
.SYNOPSIS
    Creates the main menu bar for the application.
.DESCRIPTION
    Builds a MenuStrip with extensible menu items. Currently includes
    a "Config" menu populated with available job configurations.
    Additional menus can be added by following the same pattern.
.OUTPUTS
    [System.Windows.Forms.MenuStrip] - Configured menu strip.
#>
function Create-MenuStrip {
    $menuStrip = New-Object System.Windows.Forms.MenuStrip

    # === Config Menu ===

    $configMenu = Create-ConfigMenuItem
    $script:ConfigMenuItem = $configMenu

    # === Theme Menu ===

    $themeMenu = Create-ThemeMenuItem
    $script:ThemeMenuItem = $themeMenu

    # === Construct MenuStrip ===

    $null = $menuStrip.Items.Add($configMenu)
    $null = $menuStrip.Items.Add($themeMenu)

    $menuStrip.Padding = New-Object System.Windows.Forms.Padding(0)
    $menuStrip.Margin = New-Object System.Windows.Forms.Padding(0)

    return $menuStrip
}

<#
.SYNOPSIS
    Creates and configures all main UI controls for the Job Launcher window.

.DESCRIPTION
    Constructs the main form, root TableLayoutPanel (toolbar + content panel),
    SplitContainer (left group list + right job/output panels), button flow panel,
    output RichTextBox, and status strip. Stores references to critical controls
    in script-scoped variables ($script:OutputTextBox, $script:StatusLabel,
    $script:MainForm, $script:ButtonPanel).

    Returns a hashtable containing references to key controls (SplitContainer,
    Form, LeftPanel, ButtonPanel, RightPanel, Toolbar) for later use by
    Populate-LeftPanel and theme application functions.

.OUTPUTS
    [hashtable] - Contains the following keys:
        - SplitContainer: The vertical SplitContainer control
        - Form: The main System.Windows.Forms.Form
        - LeftPanel: Panel for group list (TreeView or ListBox)
        - ButtonPanel: FlowLayoutPanel that holds job buttons
        - RightPanel: TableLayoutPanel containing button panel and output box
        - Toolbar: TableLayoutPanel with theme selector and kill button

.EXAMPLE
    $script:FormControls = Build-GUI

.NOTES
    Does NOT populate the left panel with groups or categories — that is
    handled separately by Populate-LeftPanel after this function returns.
    Uses user-configurable settings ($UI_Window_Width, $UI_Output_Height, etc.)
    defined at the top of the script.
#>
function Build-GUI {
    # --- Main Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Job Launcher"
    $form.Width = $UI_Window_Width
    $form.Height = $UI_Window_Height
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(600, 400)

    # --- Set icon ---
    if (Test-Path $AppIcon) {
        $form.Icon = New-Object System.Drawing.Icon($AppIcon)
    } else {
        Write-Host "WARNING: App icon not found at $AppIcon"
    }

    # =========================================================================
    # ROOT TABLE LAYOUT (2 rows: toolbar, content)
    # =========================================================================
    $rootTable = New-Object System.Windows.Forms.TableLayoutPanel
    $rootTable.Dock = "Fill"
    $rootTable.AutoSize = $false
    $rootTable.RowCount = 3
    $rootTable.ColumnCount = 1
    $rootTable.RowStyles.Clear()
    $null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Menu bar
    $null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))  # Toolbar
    $null = $rootTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) # Content

    # =========================================================================
    # MENU STRIP (Row 0)
    # =========================================================================
    $menuStrip = Create-MenuStrip

    # =========================================================================
    # TOOLBAR (Row 1)
    # =========================================================================
    $toolbar = Initialize-Toolbar

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

    # =========================================================================
    # CONSTRUCT ROOT PANEL
    # =========================================================================

    $null = $rootTable.Controls.Add($menuStrip, 0, 0)
    $null = $rootTable.Controls.Add($toolbar, 0, 1)
    $null = $rootTable.Controls.Add($contentPanel, 0, 2)

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

<#
.SYNOPSIS
    Populates the left panel based on JSON structure and user view preference.

.DESCRIPTION
    Handles three distinct scenarios:

    1. Flat JSON (no categories, only groups)
       - Always uses a simple ListBox
       - No toggle button
       - Function: Populate-FlatList

    2. Hierarchical JSON with Tree View (user selected or default)
       - Uses TreeView with collapsible categories
       - Toggle button shows "Switch to List View"
       - Function: Populate-TreeView

    3. Hierarchical JSON with Flat/List View (user selected)
       - Uses owner-draw ListBox with bold, centered category dividers
       - Toggle button shows "Switch to Tree View"
       - Function: Populate-ListWithDividers

    The control reference is always stored in $script:FormControls under
    either .TreeView or .ListBox, depending on which view is active.
    (Case 1 also stores its ListBox under .ListBox.)

    To be more specific on how to determine which scenario will be populated:
    the function looks at two things:
    (1) "view" setting from JSON (defaults to "flat")
    (2) presence of "categories" key (without it, only scenario 1. is possible)
.NOTES
    This function assumes $script:FormControls.LeftPanel already exists as
    the container panel created in Build-GUI.
#>
function Populate-LeftPanel {

    # save initial state
    $currSelectedItem = $script:CurrentItem

    # == hierarchical view button              == #
    # == (button for toggling list, tree mode) == #

    $buttonExists = $script:FormControls.ContainsKey('ToggleButton')
    $showButton = $false
    $buttonState = $true

    # == determine view to display == #

    # set default value

    $view = "flat"
    if ($script:HasCategories) {
        # if has categories, default to hierarchical list
        $view = "list"
    }

    # User selection view toggle button always takes priority
    # (ensure state is set: is null initially before user click)
    # Note: should be cleared when a new config is loaded, else
    # the user's selection during previous config will over-write
    # the new config's "view" setting)
    if ($buttonExists -and $script:FormControls.ToggleButton -and $script:FormControls.ToggleButton.Tag -ne $null) {
        $view = if ($script:FormControls.ToggleButton.Tag -eq $true) { "tree" } else { "list" }
    } elseif ($script:Settings.PSObject.Properties['view'] -and $script:Settings.view) {
        # user JSON setting
        $view = $script:Settings.view
    }

    # if no categories, overwrite any configuration with flat view
    if (-not $script:HasCategories) {
        $view = "flat"
    }

    # == Clear existing left panel controls == #

    Clear-LeftPanel

    # == Build left panel based on view detected == #

    switch ($view) {
        "tree" {
            Populate-TreeView
            $showButton = $true
            $buttonState = $true
        }
        "list" {
            Populate-ListWithDividers
            $showButton = $true
            $buttonState = $false
        }
        "flat" {
            Populate-FlatList
            $showButton = $false
        }
        default {
            # defensive only; should not get here.
            throw "Populate-LeftPanel: Invalid view detected. Check JSON coniguration file; view can only be `"tree`", `"list`", or `"flat`""
        }
    }

    # == Create and/or update hierarchical view button == #

    if ($showButton) {
        # Create toggle button if it doesn't exist
        if (-not $buttonExists -or -not $script:FormControls.ToggleButton) {
            $toggleButton = Create-ToggleButton
            $null = $script:FormControls.LeftPanel.Controls.Add($toggleButton)
            $script:FormControls.ToggleButton = $toggleButton
        }
        # update button only if hierarchical view is present and state is null
        if ($script:FormControls.ToggleButton -and $script:FormControls.ToggleButton.Tag -eq $null) {
            Set-ToggleButton -Button $script:FormControls.ToggleButton -State $buttonState
        }
        Set-ButtonVisibility -Button $script:FormControls.ToggleButton -Visible $true
    } else {
        Set-ButtonVisibility -Button $script:FormControls.ToggleButton -Visible $false
    }

    Initialize-LeftPanel -Item $currSelectedItem
}

# =============================================================================
# GENERAL HELPER FUNCTIONS
# =============================================================================

<#
.SYNOPSIS
    Sets the visibility state of a button control.

.DESCRIPTION
    Safely sets a button's Visible property. If the button does not exist,
    the function returns without error.

.PARAMETER Button
    The button control to modify.

.PARAMETER Visible
    $true to show the button, $false to hide it.

.EXAMPLE
    Set-ButtonVisibility -Button $script:FormControls.ToggleButton -Visible $false
#>
function Set-ButtonVisibility {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$Button,
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    if ($Button) {
        $Button.Visible = $Visible
    }
}

<#
.SYNOPSIS
    Updates checkmark indicators in a dropdown menu to show the currently selected item.

.DESCRIPTION
    Removes the checkmark prefix from all items in the specified dropdown menu.
    If a selected item name is provided, adds a checkmark prefix to the matching item.

    This function is used by both the Config and Theme menus to provide visual
    feedback of the current selection. The checkmark marker is defined globally
    as $script:DropdownMarker (default "✓ ").

.PARAMETER Dropdown
    The ToolStripMenuItem that serves as the parent dropdown menu (e.g., the Config
    or Theme menu). Its DropDownItems collection will be scanned for items to update.

.PARAMETER SelectedItem
    The text of the item that should receive the checkmark. If omitted or $null,
    all checkmarks are cleared from the dropdown (useful for Reset operations).

.EXAMPLE
    # Clear all checkmarks from the Config menu
    Update-DropdownSelection -Dropdown $configMenu

.EXAMPLE
    # Mark "work" as selected in the Config menu
    Update-DropdownSelection -Dropdown $configMenu -SelectedItem "work"

.EXAMPLE
    # Inside a menu item click handler
    $menuItem.Add_Click({
        Update-DropdownSelection -Dropdown $this.OwnerItem -SelectedItem $this.Text
        Apply-JobConfig -ConfigName $this.Text
    })

.NOTES
    This function modifies the Text property of menu items in place. It does not
    rebuild the menu or create new objects.
#>
function Update-DropdownSelection {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ToolStripMenuItem]$Dropdown,
        [Parameter(Mandatory = $false)]
        [string]$SelectedItem = $null
    )

    if ($null -eq $Dropdown.DropDownItems) {
        throw "Update-DropdownSelection: Dropdown.DropDownItems is null. The menu item may not be properly initialized."
    }

    # Remove checkmark from all items in this menu
    $found = $false
    foreach ($item in $Dropdown.DropDownItems) {
        if ($item.Text.StartsWith($DropdownMarker)) {
            $item.Text = $item.Text.Substring(2)
        }

        # Add checkmark to desired item (if one passed; else will be cleared)
        if ($SelectedItem -and $item.Text -eq $SelectedItem) {
            $found = $true
            $item.Text = $DropdownMarker + $item.Text
        }
    }

    # throw error if never found this selection
    if ($SelectedItem -and -not $found) {
        throw "Update-DropdownSelection: Selected item '$SelectedItem' not found in dropdown menu. This may indicate an issue with menu population logic."
    }
}

<#
.SYNOPSIS
    Safely retrieves a property value from any object using PSObject property inspection.

.DESCRIPTION
    Retrieves a named property from an object without throwing if the property doesn't exist.
    Uses PSObject.Properties to check existence before access. Works on PSCustomObject,
    PSObject, regular .NET objects, and primitive types.

.PARAMETER Object
    The object from which to retrieve the property.

.PARAMETER Property
    The name of the property to retrieve.

.PARAMETER Default
    Value to return if the property does not exist. Defaults to $null.

.PARAMETER FailIfMissing
    If specified, throws a descriptive error when the property does not exist.
    Overrides -Default.

.PARAMETER ErrorContext
    Optional caller-provided context string (e.g., function name) included in the error message.

.EXAMPLE
    $obj = [PSCustomObject]@{ Name = "Alice"; Age = 30 }
    Get-PSObjectProperty -Object $obj -Property "Name"
    Returns "Alice"

.EXAMPLE
    $obj = [PSCustomObject]@{ Name = "Alice" }
    Get-PSObjectProperty -Object $obj -Property "Missing" -Default "Unknown"
    Returns "Unknown" (property doesn't exist, so returns Default value)

.EXAMPLE
    $obj = [PSCustomObject]@{ Name = "Alice" }
    Get-PSObjectProperty -Object $obj -Property "Missing" -FailIfMissing -ErrorContext "ValidateUser"
    Throws: "Get-PSObjectProperty: Property 'Missing' not found on object of type 'System.Management.Automation.PSCustomObject' [Context: ValidateUser]"

.EXAMPLE
    $obj = Get-Process -Id $pid
    Get-PSObjectProperty -Object $obj -Property "ProcessName"
    Returns the process name string (e.g., "powershell" or "pwsh")

.EXAMPLE
    $obj = "simple string"
    Get-PSObjectProperty -Object $obj -Property "Length" -FailIfMissing
    Returns 14 (string has Length property)
#>
function Get-PSObjectProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [object]$Object,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Property,

        [Parameter(Mandatory = $false)]
        [object]$Default = $null,

        [Parameter(Mandatory = $false)]
        [switch]$FailIfMissing,

        [Parameter(Mandatory = $false)]
        [string]$ErrorContext = $null
    )

    # Validate Object is not $null
    if ($Object -eq $null) {
        $contextMsg = if ([string]::IsNullOrWhiteSpace($ErrorContext)) { "" } else { " [Context: $ErrorContext]" }
        throw "Get-PSObjectProperty: Object cannot be null$contextMsg"
    }

    # Validate Property is not null or empty
    if ([string]::IsNullOrWhiteSpace($Property)) {
        $contextMsg = if ([string]::IsNullOrWhiteSpace($ErrorContext)) { "" } else { " [Context: $ErrorContext]" }
        throw "Get-PSObjectProperty: Property name cannot be null or empty$contextMsg"
    }

    $propertyExists = $Object.PSObject.Properties.Name -contains $Property

    if (-not $propertyExists) {
        if ($FailIfMissing) {
            $contextMsg = if ($ErrorContext) { " [Context: $ErrorContext]" } else { "" }
            throw "Get-PSObjectProperty: Property '$Property' not found on object of type '$($Object.GetType().FullName)'$contextMsg"
        }
        return $Default
    }

    return $Object.$Property
}

<#
.SYNOPSIS
    Safely retrieves a value from a hashtable by key.

.DESCRIPTION
    Retrieves a value for the specified key from a hashtable without throwing if the key doesn't exist.
    Uses .ContainsKey() method to check existence before access, avoiding ambiguity between missing keys
    and keys that explicitly store $null.

.PARAMETER Hashtable
    The hashtable from which to retrieve the value.

.PARAMETER Key
    The key to look up in the hashtable.

.PARAMETER Default
    Value to return if the key does not exist. Defaults to $null.

.PARAMETER FailIfMissing
    If specified, throws a descriptive error when the key does not exist.
    Overrides -Default.

.PARAMETER ErrorContext
    Optional caller-provided context string (e.g., function name) included in the error message.

.EXAMPLE
    $ht = @{ Name = "Bob"; Age = 25 }
    Get-HashTableProperty -Hashtable $ht -Key "Name"
    Returns "Bob"

.EXAMPLE
    $ht = @{ Name = "Bob" }
    Get-HashTableProperty -Hashtable $ht -Key "Missing" -Default ""
    Returns "" (empty string, because key doesn't exist)

.EXAMPLE
    $ht = @{ Name = "Bob" }
    Get-HashTableProperty -Hashtable $ht -Key "Missing" -FailIfMissing -ErrorContext "GetConfig"
    Throws: "Get-HashTableProperty: Key 'Missing' not found in hashtable [Context: GetConfig]"

.EXAMPLE
    $ht = @{ Status = $null }
    Get-HashTableProperty -Hashtable $ht -Key "Status"
    Returns $null (key exists, value is $null - returns actual stored value, not Default)

.EXAMPLE
    $ht = @{}
    Get-HashTableProperty -Hashtable $ht -Key "AnyKey" -Default "Not Found"
    Returns "Not Found" (key doesn't exist, returns Default)
#>
function Get-HashTableProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [hashtable]$Hashtable,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Key,

        [Parameter(Mandatory = $false)]
        [object]$Default = $null,

        [Parameter(Mandatory = $false)]
        [switch]$FailIfMissing,

        [Parameter(Mandatory = $false)]
        [string]$ErrorContext = $null
    )

    # Validate Hashtable is not $null
    if ($Hashtable -eq $null) {
        $contextMsg = if ([string]::IsNullOrWhiteSpace($ErrorContext)) { "" } else { " [Context: $ErrorContext]" }
        throw "Get-HashTableProperty: Hashtable cannot be null$contextMsg"
    }

    # Validate Key is not null or empty
    if ([string]::IsNullOrWhiteSpace($Key)) {
        $contextMsg = if ([string]::IsNullOrWhiteSpace($ErrorContext)) { "" } else { " [Context: $ErrorContext]" }
        throw "Get-HashTableProperty: Key name cannot be null or empty$contextMsg"
    }

    # Check if key exists
    $keyExists = $Hashtable.ContainsKey($Key)

    if (-not $keyExists) {
        if ($FailIfMissing) {
            $contextMsg = if ($ErrorContext) { " [Context: $ErrorContext]" } else { "" }
            throw "Get-HashTableProperty: Key '$Key' not found in hashtable$contextMsg"
        }
        return $Default
    }

    # Key exists — retrieve value
    return $Hashtable[$Key]
}

<#
.SYNOPSIS
    Programmatically sets a ComboBox's SelectedItem without triggering its event handler.

.DESCRIPTION
    Uses a global suppression flag ($script:SuppressThemeDropdownEvent) to temporarily
    prevent the SelectedIndexChanged event from firing while the value is changed.
    The event handler should check this flag at its beginning and return if true.

.PARAMETER Dropdown
    The ComboBox control whose selection will be changed.

.PARAMETER NewValue
    The value to set as the SelectedItem. Must be an item already present in the
    Dropdown's Items collection.

.EXAMPLE
    Set-Dropdown -Dropdown $themeCombo -NewValue "dark"

.NOTES
    Requires $script:SuppressThemeDropdownEvent to be defined (initialized to $false).
    The event handler must include:
        if ($script:SuppressThemeDropdownEvent) { return }

    This pattern prevents recursive or unintended event firing during programmatic updates.
#>
function Set-Dropdown {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.ComboBox]$Dropdown,
        [Parameter(Mandatory = $true)]
        [String]$NewValue
    )
    $script:SuppressThemeDropdownEvent = $true
    $Dropdown.SelectedItem = $NewValue
    $script:SuppressThemeDropdownEvent = $false
}

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

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

function Main {

    # === Read and set launcher settings JSON ==

    $script:LauncherSettings = Load-LauncherSettings -ConfigPath $DefaultSettingsPath

    # === Determine dir for discovering config files ==

    $configDir = $DefaultJobConfigsDirectory
    if ($script:LauncherSettings.PSObject.Properties['job_configs_directory'] -and $script:LauncherSettings.job_configs_directory) {
        $configDir = $script:LauncherSettings.job_configs_directory
    }
    # resolve path (relative to script location)
    if (-not [System.IO.Path]::IsPathRooted($ConfigDir)) {
        $configDir = Join-Path -Path $PSScriptRoot -ChildPath $configDir
    }

    # === Discover and set all job configs ==

    $script:AvailableConfigs = Discover-JobConfigs -ConfigDir $configDir

    if ($script:AvailableConfigs.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No valid job configurations found.`n`nPlease check your job_configs_directory in launcher_settings.json",
            "Configuration Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit 1
    }

    # === Determine default config ==

    $defaultConfig = Get-DefaultConfig
    Write-Host "DEBUG: Default job config: '$defaultConfig'"

    # Load themes from themes.json (or use built-in default)
    Load-Themes

    Write-Host "DEBUG: About to call Build-GUI"

    # Build GUI - this returns a hashtable with Form, ListBox, ButtonPanel
    $script:FormControls = Build-GUI

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

    # Apply the default config (this also populates the left panel)
    Apply-JobConfig -ConfigName $defaultConfig

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

# Only run GUI if script is executed directly, not when dot-sourced
if ($MyInvocation.InvocationName -ne '.') {
    # Run the application
    Main
}
