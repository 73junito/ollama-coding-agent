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
    Generate stable command ID from purpose, command array, and working directory
    #>
    param(
        [string]$Purpose,
        [string[]]$CommandArray,
        [string]$WorkingDirectory
    )

    $commandStr = $CommandArray -join " "
    $seed = "{0}#{1}#{2}" -f $Purpose, $commandStr, $WorkingDirectory

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
    Detect unsafe shell constructs and patterns in command array
    #>
    param(
        [string[]]$CommandArray,
        [ref]$Diagnostics
    )

    $unsafeShellOperators = @('&&', '||', ';', '|', '>', '>>', '<', '<<<', '&')
    $unsafePatterns = @('\$\(', '`', '\$\{', '<(', '>(')

    foreach ($i = 0; $i -lt $CommandArray.Count; $i++) {
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
        if ($i -eq 0 -and $arg -match '^(sh|bash|cmd|powershell|pwsh)$' -and $i + 1 -lt $CommandArray.Count) {
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

        # Check for unresolved variables
        if ($arg -match '^\$\w+' -or $arg -match '\$\{') {
            $Diagnostics.Value += @{
                type = "unresolved_path"
                severity = "high"
                message = "Unresolved variable detected; cannot verify path"
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
    }

    return $true
}

# ============================================================================
# COMMAND EVALUATION
# ============================================================================

function Evaluate-CommandStatus {
    <#
    .SYNOPSIS
    Classify command into status: ready, blocked, ambiguous, or unsafe
    #>
    param(
        [object]$Command,
        [hashtable]$ToolAvailability,
        [ref]$Diagnostics
    )

    # Extract command properties
    $commandArray = $Command.command_array
    $requiredTool = $Command.required_tool
    $confidence = $Command.confidence
    $working = $Command.working_directory

    # Check safety first
    $isSafe = Test-CommandSafety -CommandArray $commandArray -Diagnostics $Diagnostics
    if (-not $isSafe) {
        return @{
            status = "unsafe"
            toolAvailable = $false
            requiresApproval = $true
        }
    }

    # Check tool availability
    $toolExists = $ToolAvailability.ContainsKey($requiredTool)

    if (-not $toolExists) {
        $Diagnostics.Value += @{
            type = "tool_unavailable"
            severity = "error"
            message = "Required tool '$requiredTool' not found in machine inventory"
        }

        return @{
            status = "blocked"
            toolAvailable = $false
            requiresApproval = $true
        }
    }

    # Check confidence
    if ($confidence -eq 'low') {
        $Diagnostics.Value += @{
            type = "low_confidence"
            severity = "warning"
            message = "Command has low confidence; requires explicit approval"
        }

        return @{
            status = "ambiguous"
            toolAvailable = $true
            requiresApproval = $true
        }
    }

    # Command is ready
    return @{
        status = "ready"
        toolAvailable = $true
        requiresApproval = $false
    }
}

# ============================================================================
# PLAN ASSEMBLY
# ============================================================================

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

    # Process each detected command
    foreach ($command in $WorkspaceEnvironment.commands) {
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
        }

        # Add diagnostics if present
        if ($diagnostics.Count -gt 0) {
            $plannedCmd.diagnostics = $diagnostics
        } else {
            $plannedCmd.diagnostics = @()
        }

        $plannedCommands += $plannedCmd
    }

    return $plannedCommands | Sort-Object { $_.id }
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
    # Resolve input paths
    $wsEnvPath = Resolve-InputPath -Path $WorkspaceEnvironmentPath -Description "Workspace environment"
    $machInvPath = Resolve-InputPath -Path $MachineInventoryPath -Description "Machine inventory"

    # Create output directory
    $outputDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Load input files
    $wsEnv = Get-Content -LiteralPath $wsEnvPath -Raw | ConvertFrom-Json
    $machInv = Get-Content -LiteralPath $machInvPath -Raw | ConvertFrom-Json

    # Build tool availability map
    $toolAvailability = @{}
    if ($machInv.PSObject.Properties['tools']) {
        foreach ($toolName in $machInv.tools.PSObject.Properties.Name) {
            $toolAvailability[$toolName] = $true
        }
    }

    # Generate plan timestamp
    if (-not $PlannedAt) {
        $PlannedAt = Get-TimestampISO8601
    }

    # Build command plan
    $plannedCommands = Build-CommandPlan -WorkspaceEnvironment $wsEnv -ToolAvailability $toolAvailability
    $approvalSummary = Build-ApprovalSummary -Commands $plannedCommands

    # Assemble plan object
    $plan = @{
        schema_version = "1.0.0"
        workspace_path = $wsEnv.workspace_path
        machine_inventory_path = $MachineInventoryPath
        workspace_environment_path = $WorkspaceEnvironmentPath
        planned_at = $PlannedAt
        commands = $plannedCommands
        diagnostics = @()
        approval_summary = $approvalSummary
    }

    # Serialize and output
    $planJson = $plan | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $OutputPath -Value $planJson

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
