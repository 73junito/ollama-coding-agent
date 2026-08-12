#!/usr/bin/env pwsh

<#
.SYNOPSIS
Command Planner: Read-only command planning service

.DESCRIPTION
Consumes machine inventory and workspace environment data to produce deterministic
command plans without executing any commands. Classifies commands into states
(ready, blocked, ambiguous, unsafe) and marks approval requirements.

.PARAMETER WorkspaceEnvironmentPath
Path to workspace-environment.json (contains detected commands)

.PARAMETER MachineInventoryPath
Path to machine-inventory.json (contains tool availability)

.PARAMETER OutputPath
Path where command-plan.json will be written

.PARAMETER PlannedAt
ISO8601 timestamp for plan generation (optional; defaults to now)

.EXAMPLE
.\tools\command-planner.ps1 `
    -WorkspaceEnvironmentPath ".\output\workspace-environment.json" `
    -MachineInventoryPath ".\output\machine-inventory.json" `
    -OutputPath ".\output\command-plan.json"

.NOTES
PowerShell 7.0 or later is required.
#>

#Requires -Version 7.0

param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceEnvironmentPath,

    [Parameter(Mandatory = $true)]
    [string]$MachineInventoryPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$PlannedAt
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# UTILITIES
# ============================================================================

function Get-TimestampISO8601 {
    [CmdletBinding()]
    param()

    [DateTime]::UtcNow.ToString('o')
}

function Test-ISO8601Format {
    <#
    .SYNOPSIS
    Validate ISO 8601 timestamp format
    #>
    param([string]$Timestamp)

    # Basic ISO 8601 check: YYYY-MM-DDTHH:MM:SSZ or with microseconds
    $timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?$'
}

function Test-OutputPath {
    <#
    .SYNOPSIS
    Validate OutputPath and ensure parent directory can be created
    #>
    param([string]$Path)

    if ($Path -match '^[^\\/:]+$') {
        throw "Error: OutputPath must include a directory component (not bare filename): $Path"
    }

    $Path
}

function Resolve-InputPath {
    param(
        [string]$Path,
        [string]$Description
    )

    $resolved = $Path | Resolve-Path -ErrorAction SilentlyContinue

    if ($null -eq $resolved) {
        throw @{
            type = "missing_input"
            path = $Path
            message = "$Description not found: $Path"
        } | ConvertTo-Json
    }

    return $resolved.Path
}

# ============================================================================
# COMMAND ID GENERATION
# ============================================================================

function Get-CommandID {
    <#
    .SYNOPSIS
    Generate stable command ID from purpose, command array, and working directory.
    Uses null-byte delimiters to avoid collisions between different argument arrays.
    #>
    param(
        [string]$Purpose,
        [string[]]$CommandArray,
        [string]$WorkingDirectory
    )

    # Join with null byte to prevent collisions
    $parts = @(
        $Purpose
        ($CommandArray -join "`0")
        $WorkingDirectory
    )
    $seed = $parts -join "`0"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
    $hash = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $hash.ComputeHash($bytes)
    $hashStr = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    return "cmd-$($hashStr.Substring(0, 8))"
}

# ============================================================================
# SAFETY DETECTION
# ============================================================================

function Test-CommandSafety {
    <#
    .SYNOPSIS
    Detect unsafe shell constructs and patterns in command array.
    Returns diagnostics array and safety boolean.
    #>
    param(
        [string[]]$CommandArray,
        [ref]$Diagnostics
    )

    $unsafeShellOperators = @('&&', '||', ';', '|', '>', '>>', '<', '<<<', '&')

    for ($i = 0; $i -lt $CommandArray.Count; $i++) {
        $arg = $CommandArray[$i]

        # Check for shell operators as array elements
        if ($arg -in $unsafeShellOperators) {
            $Diagnostics.Value += @{
                type = "unsafe_shell_construct"
                severity = "high"
                message = "Shell operator '$arg' detected in command; requires shell interpretation"
                pattern = $arg
                argument_index = $i
            }
            return $false
        }

        # Check for shell invocation (sh, bash, cmd, powershell with -c)
        if ($i -eq 0 -and $arg -match '^(sh|bash|cmd|powershell|pwsh)$') {
            if ($i + 1 -lt $CommandArray.Count) {
                if ($CommandArray[$i + 1] -eq '-c' -or $CommandArray[$i + 1] -eq '/c') {
                    $Diagnostics.Value += @{
                        type = "unsafe_shell_construct"
                        severity = "high"
                        message = "Command uses shell invocation with -c flag; script injection risk"
                        pattern = "$($CommandArray[0]) $($CommandArray[1])"
                        argument_index = 0
                    }
                    return $false
                }
            }
        }

        # Check for unresolved variables
        if ($arg -match '^\$[\w\{]' -or $arg -match '\$\{') {
            $Diagnostics.Value += @{
                type = "unresolved_path"
                severity = "high"
                message = "Unresolved variable detected; cannot verify path or argument"
                pattern = $arg
                argument_index = $i
            }
            return $false
        }

        # Check for globbing patterns
        if ($arg -match '[\*\?\[]') {
            $Diagnostics.Value += @{
                type = "unresolved_path"
                severity = "medium"
                message = "Globbing pattern detected; argument expansion cannot be validated"
                pattern = $arg
                argument_index = $i
            }
            return $false
        }

        # Check for path traversal
        if ($arg -match '\.\.\\|\.\./' -or $arg -eq '..') {
            $Diagnostics.Value += @{
                type = "unresolved_path"
                severity = "high"
                message = "Path traversal (..) detected in argument; cannot validate working directory containment"
                pattern = $arg
                argument_index = $i
            }
            return $false
        }
    }

    return $true
}

# ============================================================================
# COMMAND EVALUATION
# ============================================================================

function Evaluate-CommandStatus {
    <#
    .SYNOPSIS
    Classify command into status: ready, blocked, ambiguous, or unsafe.
    Returns status, actual tool availability, and approval requirement.
    #>
    param(
        [object]$Command,
        [hashtable]$ToolAvailability,
        [ref]$Diagnostics
    )

    $commandArray = $Command.command_array
    $requiredTool = $Command.required_tool
    $confidence = $Command.confidence

    # STEP 1: Check safety (independent from tool availability)
    $isSafe = Test-CommandSafety -CommandArray $commandArray -Diagnostics $Diagnostics
    if (-not $isSafe) {
        # Unsafe command: check tool availability separately
        $toolIsAvailable = $ToolAvailability.ContainsKey($requiredTool)

        return @{
            status = "unsafe"
            toolAvailable = $toolIsAvailable
            requiresApproval = $true
        }
    }

    # STEP 2: Check tool availability (independent from safety)
    $toolIsAvailable = $ToolAvailability.ContainsKey($requiredTool)

    if (-not $toolIsAvailable) {
        $Diagnostics.Value += @{
            type = "tool_unavailable"
            severity = "error"
            message = "Required tool '$requiredTool' not found in machine inventory"
        }

        # Blocked commands: tool unavailable but NOT unsafe
        # Approval cannot make an unavailable tool available, but we still mark for review
        return @{
            status = "blocked"
            toolAvailable = $false
            requiresApproval = $true
        }
    }

    # STEP 3: Check confidence level
    # Only HIGH confidence + tool available = ready without approval
    # Medium/Low confidence = ambiguous, requires approval
    if ($confidence -ne 'high') {
        $Diagnostics.Value += @{
            type = "low_confidence"
            severity = "warning"
            message = "Command has $confidence confidence; requires explicit approval"
        }

        return @{
            status = "ambiguous"
            toolAvailable = $true
            requiresApproval = $true
        }
    }

    # STEP 4: Command is ready (high confidence + tool available + safe)
    return @{
        status = "ready"
        toolAvailable = $true
        requiresApproval = $false
    }
}

# ============================================================================
# PLAN ASSEMBLY
# ============================================================================

function Merge-DetectedCommands {
    <#
    .SYNOPSIS
    Merge test_commands and build_commands arrays from workspace environment
    Supports both new format (test_commands/build_commands) and legacy format (commands)
    #>
    param([object]$WorkspaceEnvironment)

    $merged = @()

    # Support new format (preferred)
    if ($WorkspaceEnvironment.PSObject.Properties['test_commands']) {
        $merged += @($WorkspaceEnvironment.test_commands)
    }

    if ($WorkspaceEnvironment.PSObject.Properties['build_commands']) {
        $merged += @($WorkspaceEnvironment.build_commands)
    }

    # Support legacy format for backward compatibility
    if ($WorkspaceEnvironment.PSObject.Properties['commands'] -and $merged.Count -eq 0) {
        $merged = @($WorkspaceEnvironment.commands)
    }

    return $merged
}

function Build-ToolAvailabilityMap {
    <#
    .SYNOPSIS
    Build tool availability map by inspecting the .available property of each tool.
    #>
    param([object]$MachineInventory)

    $map = @{}

    if ($MachineInventory.PSObject.Properties['tools']) {
        foreach ($toolName in $MachineInventory.tools.PSObject.Properties.Name) {
            $tool = $MachineInventory.tools.$toolName

            # Check if tool.available is true
            if ($tool.PSObject.Properties['available'] -and $tool.available -eq $true) {
                $map[$toolName] = $true
            }
        }
    }

    return $map
}

function Transform-DetectorCommand {
    <#
    .SYNOPSIS
    Transform detector output format into planner internal format.
    Handles both:
      - Detector format: { command, ecosystem, confidence, evidence, inferred_from }
      - Planner format: { command_array, purpose, required_tool, ... }
    If already in planner format, returns as-is with defaults for missing fields.
    #>
    param([object]$DetectorCommand)

    # Check if already in planner internal format (has command_array)
    if ($DetectorCommand.PSObject.Properties['command_array']) {
        # Already in planner format - ensure it has all required fields
        $result = @{
            command_array = $DetectorCommand.command_array
            working_directory = if ($DetectorCommand.PSObject.Properties['working_directory']) { $DetectorCommand.working_directory } else { '.' }
            purpose = if ($DetectorCommand.PSObject.Properties['purpose']) { $DetectorCommand.purpose } else { 'command' }
            required_tool = if ($DetectorCommand.PSObject.Properties['required_tool']) { $DetectorCommand.required_tool } else { $null }
            confidence = if ($DetectorCommand.PSObject.Properties['confidence']) { $DetectorCommand.confidence } else { 'medium' }
            risk_level = if ($DetectorCommand.PSObject.Properties['risk_level']) { $DetectorCommand.risk_level } else { 'low' }
            evidence = if ($DetectorCommand.PSObject.Properties['evidence']) { $DetectorCommand.evidence } else { @() }
            inferred_from = if ($DetectorCommand.PSObject.Properties['inferred_from']) { $DetectorCommand.inferred_from } else { @() }
        }

        # Copy over any additional properties
        foreach ($prop in $DetectorCommand.PSObject.Properties) {
            if (-not $result.ContainsKey($prop.Name)) {
                $result[$prop.Name] = $prop.Value
            }
        }

        return $result
    }

    # Detector format - transform to planner format
    $commandStr = $DetectorCommand.command
    $commandArray = @($commandStr -split '\s+')

    # Extract tool name (first element)
    $requiredTool = if ($commandArray.Count -gt 0) { $commandArray[0] } else { $null }

    # Build purpose from ecosystem and command
    $purpose = if ($DetectorCommand.PSObject.Properties['ecosystem']) {
        "$($DetectorCommand.ecosystem): $commandStr"
    } else {
        $commandStr
    }

    # Detect if command string contains quoted arguments (legacy tokenization limitation)
    # String splitting with -split '\s+' does not preserve quoted arguments
    # Lower confidence to trigger ambiguous classification
    $confidence = $DetectorCommand.confidence
    if ($commandStr.Contains('"') -or $commandStr.Contains("'")) {
        $confidence = "low"
    }

    # Build planner format command object
    $transformed = @{
        command_array = $commandArray
        working_directory = "."
        purpose = $purpose
        required_tool = $requiredTool
        confidence = $confidence
        risk_level = "low"
        evidence = if ($DetectorCommand.PSObject.Properties['evidence']) { $DetectorCommand.evidence } else { @() }
        inferred_from = if ($DetectorCommand.PSObject.Properties['inferred_from']) { $DetectorCommand.inferred_from } else { @() }
    }

    # Copy additional properties from detector command
    foreach ($prop in $DetectorCommand.PSObject.Properties) {
        if (-not $transformed.ContainsKey($prop.Name)) {
            $transformed[$prop.Name] = $prop.Value
        }
    }

    return $transformed
}

function Build-CommandPlan {
    <#
    .SYNOPSIS
    Transform detected commands into planned commands with classifications
    #>
    param(
        [object]$WorkspaceEnvironment,
        [hashtable]$ToolAvailability
    )

    $plannedCommands = @()
    $allDetectorCommands = Merge-DetectedCommands -WorkspaceEnvironment $WorkspaceEnvironment

    # Process each detected command
    foreach ($detectorCmd in $allDetectorCommands) {
        # Transform detector command to internal format
        $command = Transform-DetectorCommand -DetectorCommand $detectorCmd

        $diagnostics = @()

        # Evaluate command status
        $evaluation = Evaluate-CommandStatus -Command $command -ToolAvailability $ToolAvailability -Diagnostics ([ref]$diagnostics)

        # Generate stable ID
        $commandId = Get-CommandID -Purpose $command.purpose `
            -CommandArray $command.command_array `
            -WorkingDirectory $command.working_directory

        # Determine risk level
        $riskLevel = if ($evaluation.status -eq 'unsafe') { 'high' } `
            elseif ($evaluation.status -eq 'blocked') { 'none' } `
            elseif ($command.PSObject.Properties['risk_level']) { $command.risk_level } `
            else { 'low' }

        # Determine approval requirement
        $requiresApproval = $evaluation.requiresApproval `
            -or ($evaluation.status -eq 'ambiguous') `
            -or ($evaluation.status -eq 'unsafe') `
            -or ($evaluation.status -eq 'blocked') `
            -or ($command.confidence -eq 'low') `
            -or ($riskLevel -eq 'high')

        # Build planned command object
        $plannedCmd = @{
            id = $commandId
            status = $evaluation.status
            command_array = $command.command_array
            working_directory = $command.working_directory
            purpose = $command.purpose
            purpose_category = if ($command.PSObject.Properties['purpose_category']) { $command.purpose_category } else { 'other' }
            required_tool = $command.required_tool
            tool_available = $evaluation.toolAvailable
            confidence = $command.confidence
            risk_level = $riskLevel
            requires_approval = $requiresApproval
            evidence = $command.evidence
            diagnostics = $diagnostics
        }

        $plannedCommands += $plannedCmd
    }

    return $plannedCommands
}

function Sort-CommandsByStatusThenId {
    <#
    .SYNOPSIS
    Sort commands by status group, then by ID within each group
    #>
    param([object[]]$Commands)

    # Define status order (by priority for execution)
    $statusOrder = @{
        'ready' = 0
        'ambiguous' = 1
        'unsafe' = 2
        'blocked' = 3
    }

    $sorted = $Commands | Sort-Object { $statusOrder[$_.status] }, { $_.id }

    # Ensure we always return an array, even if empty (prevents null from ConvertTo-Json)
    return @($sorted)
}

function Build-ApprovalSummary {
    <#
    .SYNOPSIS
    Calculate approval requirement statistics
    #>
    param([object[]]$Commands)

    $readyWithoutApproval = @($Commands | Where-Object { $_.status -eq 'ready' -and $_.requires_approval -eq $false }).Count
    $requiresApproval = @($Commands | Where-Object { $_.requires_approval -eq $true }).Count
    $blocked = @($Commands | Where-Object { $_.status -eq 'blocked' }).Count
    $ambiguous = @($Commands | Where-Object { $_.status -eq 'ambiguous' }).Count
    $unsafe = @($Commands | Where-Object { $_.status -eq 'unsafe' }).Count

    return @{
        ready_without_approval = $readyWithoutApproval
        requires_approval = $requiresApproval
        blocked = $blocked
        ambiguous = $ambiguous
        unsafe = $unsafe
    }
}

# ============================================================================
# MAIN
# ============================================================================

try {
    # Validate parameters
    $OutputPathResolved = Test-OutputPath -Path $OutputPath

    # Validate PlannedAt format if provided
    if ($PlannedAt -and -not (Test-ISO8601Format -Timestamp $PlannedAt)) {
        throw "Error: PlannedAt must be ISO 8601 format (e.g., '2026-08-12T20:00:00Z'), got: $PlannedAt"
    }

    # Resolve input paths
    $wsEnvPath = Resolve-InputPath -Path $WorkspaceEnvironmentPath -Description "Workspace environment"
    $machInvPath = Resolve-InputPath -Path $MachineInventoryPath -Description "Machine inventory"

    # Create output directory
    $outputDir = Split-Path -Parent $OutputPathResolved
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Load input files
    $wsEnv = Get-Content -LiteralPath $wsEnvPath -Raw | ConvertFrom-Json
    $machInv = Get-Content -LiteralPath $machInvPath -Raw | ConvertFrom-Json

    # Build tool availability map (checking .available property)
    $toolAvailability = Build-ToolAvailabilityMap -MachineInventory $machInv

    # Generate plan timestamp
    if (-not $PlannedAt) {
        $PlannedAt = Get-TimestampISO8601
    }

    # Build command plan
    $plannedCommands = Build-CommandPlan -WorkspaceEnvironment $wsEnv -ToolAvailability $toolAvailability
    $sortedCommands = Sort-CommandsByStatusThenId -Commands $plannedCommands
    $approvalSummary = Build-ApprovalSummary -Commands $sortedCommands

    # Assemble plan object
    $plan = @{
        schema_version = "1.0.0"
        workspace_path = $wsEnv.workspace_path
        machine_inventory_path = $MachineInventoryPath
        workspace_environment_path = $WorkspaceEnvironmentPath
        planned_at = $PlannedAt
        commands = @($sortedCommands)  # Ensure empty arrays stay as arrays in JSON
        diagnostics = @()
        approval_summary = $approvalSummary
    }

    # Serialize and output
    $planJson = $plan | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $OutputPathResolved -Value $planJson

    Write-Host "✓ Command plan generated: $OutputPath"
    Write-Host "  - Ready (no approval): $($approvalSummary.ready_without_approval)"
    Write-Host "  - Requires approval: $($approvalSummary.requires_approval)"
    Write-Host "  - Blocked: $($approvalSummary.blocked)"
    Write-Host "  - Ambiguous: $($approvalSummary.ambiguous)"
    Write-Host "  - Unsafe: $($approvalSummary.unsafe)"
}
catch {
    Write-Error $_
    exit 1
}
