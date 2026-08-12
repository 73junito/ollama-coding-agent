#Requires -Version 7.0
<#
.SYNOPSIS
    Analyzes a workspace to detect ecosystems, manifests, virtual environments, and inferred commands.

.DESCRIPTION
    Workspace Environment Detector discovers project configuration and inference of available commands
    within an explicit workspace path. Produces deterministic, schema-compliant JSON output.

.PARAMETER WorkspacePath
    Explicit filesystem path to analyze. Resolves relative to caller's current directory.
    Must be an existing directory.

.PARAMETER MachineInventoryPath
    Optional path to machine-inventory.json for tool availability checking.

.PARAMETER OutputPath
    Destination file for workspace-environment.json output.

.PARAMETER MaxDepth
    Maximum recursion depth for manifest discovery. Default: 2.
    Depth 1 = root only; Depth 2 = root + immediate subdirectories.

.PARAMETER AnalyzedAt
    Optional ISO 8601 timestamp override for deterministic testing.
    If omitted, current timestamp is used.

.EXAMPLE
    .\tools\workspace-environment.ps1 -WorkspacePath "C:\myproject" -OutputPath "output.json"
#>

param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$MachineInventoryPath,

    [int]$MaxDepth = 2,

    [string]$AnalyzedAt
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Utility Functions
# ============================================================================

function Resolve-WorkspacePath {
    param([string]$Path)

    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        Write-Error "Workspace path does not exist or is not a directory: $resolved" -ErrorAction Stop
    }

    return (Resolve-Path -LiteralPath $resolved).Path
}

function Get-TimestampISO8601 {
    if ($script:AnalyzedAt) {
        return $script:AnalyzedAt
    }
    # Format as ISO 8601 with Z suffix: 2026-08-11T12:00:00Z
    $utcNow = (Get-Date).ToUniversalTime()
    return $utcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Get-ExcludedDirs {
    return @('.git', 'node_modules', '.venv', 'venv', 'vendor', 'target', 'dist', 'build', '.next', 'out', 'bin', 'obj', '.env', '.vscode', '.idea')
}

function Test-ShouldExclude {
    param(
        [string]$Path,
        [string]$BasePath
    )

    $excluded = Get-ExcludedDirs
    $relativePath = $Path.Substring($BasePath.Length).TrimStart('\', '/')

    foreach ($pattern in $excluded) {
        if ($relativePath -like "$pattern*" -or $relativePath -like "*\$pattern*" -or $relativePath -like "*/$pattern*") {
            return $true
        }
    }

    return $false
}

function Get-PathDepth {
    param(
        [string]$Path,
        [string]$BasePath
    )

    $relative = $Path.Substring($BasePath.Length).TrimStart('\', '/')
    if ([string]::IsNullOrEmpty($relative)) {
        return 0
    }

    return @($relative -split '[\\/]', [System.StringSplitOptions]::RemoveEmptyEntries).Count
}

# ============================================================================
# Manifest Validation
# ============================================================================

function Test-ManifestParseable {
    param(
        [string]$ManifestPath,
        [string]$FileExtension
    )

    $diagnostics = @()

    try {
        $content = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop

        # Attempt JSON parsing for JSON manifests
        if ($FileExtension -match '\.(json|jsonc)$' -or $ManifestPath -like '*package*.json') {
            try {
                $null = $content | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $relativePath = Split-Path -Leaf $ManifestPath
                $diagnostics += [PSCustomObject]@{
                    type = 'malformed_manifest'
                    severity = 'error'
                    path = $relativePath
                    message = "Failed to parse manifest: $($_.Exception.Message)"
                    details = @{
                        error_type = $_.Exception.GetType().Name
                    }
                }
            }
        }
        # For TOML files, check for basic structural validity
        elseif ($FileExtension -eq '.toml' -or $ManifestPath -like '*.toml') {
            $hasErrors = $false
            $errorMessage = @()

            # Check for unclosed brackets
            $bracketCount = ($content | Select-String '\[' -All).Matches.Count - ($content | Select-String '\]' -All).Matches.Count
            if ($bracketCount -ne 0) {
                $hasErrors = $true
                $errorMessage += "unmatched brackets"
            }

            # Check for unassigned properties (key followed by = with no value)
            $unassignedLines = @($content -split "`n" | Where-Object { $_ -match '^\s*\w+\s*=\s*$' })
            if ($unassignedLines.Count -gt 0) {
                $hasErrors = $true
                $errorMessage += "unassigned property values"
            }

            if ($hasErrors) {
                $relativePath = Split-Path -Leaf $ManifestPath
                $diagnostics += [PSCustomObject]@{
                    type = 'malformed_manifest'
                    severity = 'error'
                    path = $relativePath
                    message = "Invalid TOML syntax: $($errorMessage -join ', ')"
                    details = @{
                        error_type = 'TOMLSyntaxError'
                    }
                }
            }
        }
    }
    catch {
        $relativePath = Split-Path -Leaf $ManifestPath
        $diagnostics += [PSCustomObject]@{
            type = 'malformed_manifest'
            severity = 'error'
            path = $relativePath
            message = "Failed to read manifest: $($_.Exception.Message)"
            details = @{
                error_type = $_.Exception.GetType().Name
            }
        }
    }

    return $diagnostics
}

# ============================================================================
# Manifest Discovery
# ============================================================================

function Find-Manifests {
    param(
        [string]$WorkspacePath,
        [int]$MaxDepth = 2
    )

    $manifests = @()

    $manifestPatterns = @{
        'package.json' = 'node'
        'pyproject.toml' = 'python'
        'setup.py' = 'python'
        'requirements.txt' = 'python'
        'Cargo.toml' = 'rust'
        'go.mod' = 'go'
        'go.sum' = 'go'
        'pom.xml' = 'java'
        'build.gradle' = 'java'
        '*.csproj' = 'dotnet'
        '*.sln' = 'dotnet'
        'Gemfile' = 'ruby'
        'composer.json' = 'php'
    }

    $lockFilePatterns = @{
        'package-lock.json' = 'node'
        'yarn.lock' = 'node'
        'pnpm-lock.yaml' = 'node'
        'Cargo.lock' = 'rust'
        'go.sum' = 'go'
        'Gemfile.lock' = 'ruby'
        'composer.lock' = 'php'
        'Pipfile.lock' = 'python'
        'requirements.lock' = 'python'
        'packages.lock.json' = 'dotnet'
        '.m2' = 'java'
        '.gradle' = 'java'
    }

    # Recursively find all items up to MaxDepth
    Get-ChildItem -LiteralPath $WorkspacePath -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $depth = Get-PathDepth -Path $_.FullName -BasePath $WorkspacePath
            $depth -le $MaxDepth -and -not (Test-ShouldExclude -Path $_.FullName -BasePath $WorkspacePath)
        } |
        ForEach-Object {
            $item = $_
            $relativePath = $item.FullName.Substring($WorkspacePath.Length).TrimStart('\', '/')

            # Check manifest files
            foreach ($pattern in $manifestPatterns.Keys) {
                if ($item.Name -like $pattern) {
                    $ecosystem = $manifestPatterns[$pattern]

                    $manifestObj = [PSCustomObject]@{
                        path = $relativePath
                        type = 'manifest'
                        ecosystem = $ecosystem
                    }

                    $manifests += $manifestObj
                }
            }

            # Check lock files
            foreach ($pattern in $lockFilePatterns.Keys) {
                if ($item.Name -like $pattern) {
                    $ecosystem = $lockFilePatterns[$pattern]
                    $manifests += [PSCustomObject]@{
                        path = $relativePath
                        type = 'lockfile'
                        ecosystem = $ecosystem
                    }
                }
            }
        }

    return $manifests
}

# ============================================================================
# Virtual Environment Detection
# ============================================================================

function Find-VirtualEnvironments {
    param([string]$WorkspacePath)

    $environments = @()

    # Python venv
    $venvPath = Join-Path $WorkspacePath '.venv'
    if (Test-Path -LiteralPath $venvPath -PathType Container) {
        $environments += [PSCustomObject]@{
            path = '.venv'
            type = 'python-venv'
            ecosystem = 'python'
        }
    }

    # node_modules
    $nodeModulesPath = Join-Path $WorkspacePath 'node_modules'
    if (Test-Path -LiteralPath $nodeModulesPath -PathType Container) {
        $environments += [PSCustomObject]@{
            path = 'node_modules'
            type = 'node-modules'
            ecosystem = 'node'
        }
    }

    # vendor (Go)
    $vendorPath = Join-Path $WorkspacePath 'vendor'
    if (Test-Path -LiteralPath $vendorPath -PathType Container) {
        $environments += [PSCustomObject]@{
            path = 'vendor'
            type = 'vendor'
            ecosystem = 'go'
        }
    }

    return $environments
}

# ============================================================================
# Package Manager Inference
# ============================================================================

function Infer-PackageManagers {
    param(
        [object[]]$Manifests,
        [object[]]$VirtualEnvironments
    )

    $managers = @()
    $detectedEcosystems = @($Manifests | Select-Object -ExpandProperty ecosystem -Unique)

    # npm/yarn/pnpm
    if ('node' -in $detectedEcosystems) {
        $managers += 'npm'

        # Check for yarn/pnpm lock files
        if ($Manifests | Where-Object { $_.type -eq 'lockfile' -and $_.path -like 'yarn.lock' }) {
            if ('yarn' -notin $managers) { $managers += 'yarn' }
        }
        if ($Manifests | Where-Object { $_.type -eq 'lockfile' -and $_.path -like 'pnpm-lock.yaml' }) {
            if ('pnpm' -notin $managers) { $managers += 'pnpm' }
        }
    }

    # pip
    if ('python' -in $detectedEcosystems) {
        $managers += 'pip'
    }

    # cargo
    if ('rust' -in $detectedEcosystems) {
        $managers += 'cargo'
    }

    # go
    if ('go' -in $detectedEcosystems) {
        $managers += 'go'
    }

    # java
    if ('java' -in $detectedEcosystems) {
        if ($Manifests | Where-Object { $_.path -like 'pom.xml' }) {
            $managers += 'maven'
        }
        if ($Manifests | Where-Object { $_.path -like 'build.gradle' }) {
            $managers += 'gradle'
        }
    }

    # .NET
    if ('dotnet' -in $detectedEcosystems) {
        $managers += 'dotnet'
    }

    # ruby
    if ('ruby' -in $detectedEcosystems) {
        $managers += 'bundler'
    }

    # php
    if ('php' -in $detectedEcosystems) {
        $managers += 'composer'
    }

    return $managers | Select-Object -Unique
}

# ============================================================================
# Command Inference
# ============================================================================

function Infer-TestCommands {
    param(
        [object[]]$Manifests,
        [object[]]$VirtualEnvironments
    )

    $commands = @()

    # Determine confidence based on environment presence
    $hasNodeEnv = $VirtualEnvironments | Where-Object { $_.ecosystem -eq 'node' }
    $hasPythonEnv = $VirtualEnvironments | Where-Object { $_.ecosystem -eq 'python' }

    # Node.js - npm test
    if ($Manifests | Where-Object { $_.type -eq 'manifest' -and $_.path -eq 'package.json' }) {
        $confidence = if ($hasNodeEnv) { 'high' } else { 'medium' }
        $commands += [PSCustomObject]@{
            command = 'npm test'
            ecosystem = 'node'
            confidence = $confidence
            evidence = @(
                @{ type = 'manifest'; path = 'package.json'; signal = 'found' }
            )
            inferred_from = @('manifest')
        }
    }

    # Python - pytest
    if ($Manifests | Where-Object { $_.type -eq 'manifest' -and $_.path -eq 'pyproject.toml' }) {
        $confidence = if ($hasPythonEnv) { 'high' } else { 'medium' }
        $commands += [PSCustomObject]@{
            command = 'pytest'
            ecosystem = 'python'
            confidence = $confidence
            evidence = @(
                @{ type = 'manifest'; path = 'pyproject.toml'; signal = '[tool.pytest]' }
            )
            inferred_from = @('manifest')
        }
    }

    # Rust - cargo test
    if ($Manifests | Where-Object { $_.type -eq 'manifest' -and $_.path -eq 'Cargo.toml' }) {
        $commands += [PSCustomObject]@{
            command = 'cargo test'
            ecosystem = 'rust'
            confidence = 'high'
            evidence = @(
                @{ type = 'manifest'; path = 'Cargo.toml'; signal = 'found' }
            )
            inferred_from = @('manifest')
        }
    }

    # Go - go test
    if ($Manifests | Where-Object { $_.type -eq 'manifest' -and $_.path -eq 'go.mod' }) {
        $commands += [PSCustomObject]@{
            command = 'go test'
            ecosystem = 'go'
            confidence = 'high'
            evidence = @(
                @{ type = 'manifest'; path = 'go.mod'; signal = 'found' }
            )
            inferred_from = @('manifest')
        }
    }

    return $commands
}

function Infer-BuildCommands {
    param(
        [object[]]$Manifests,
        [object[]]$VirtualEnvironments
    )

    $commands = @()

    # Node.js - npm run build
    if ($Manifests | Where-Object { $_.type -eq 'manifest' -and $_.path -eq 'package.json' }) {
        $commands += [PSCustomObject]@{
            command = 'npm run build'
            ecosystem = 'node'
            confidence = 'medium'
            evidence = @(
                @{ type = 'manifest'; path = 'package.json'; signal = 'build script may exist' }
            )
            inferred_from = @('manifest')
        }
    }

    # Rust - cargo build
    if ($Manifests | Where-Object { $_.type -eq 'manifest' -and $_.path -eq 'Cargo.toml' }) {
        $commands += [PSCustomObject]@{
            command = 'cargo build'
            ecosystem = 'rust'
            confidence = 'high'
            evidence = @(
                @{ type = 'manifest'; path = 'Cargo.toml'; signal = 'found' }
            )
            inferred_from = @('manifest')
        }
    }

    return $commands
}

# ============================================================================
# Tool Availability Checking
# ============================================================================

function Get-ToolAvailability {
    param(
        [object[]]$InferredCommands,
        [string]$MachineInventoryPath
    )

    $toolAvailability = [PSCustomObject]@{}

    if (-not $MachineInventoryPath -or -not (Test-Path -LiteralPath $MachineInventoryPath)) {
        return $toolAvailability
    }

    try {
        $inventory = Get-Content -LiteralPath $MachineInventoryPath -Raw | ConvertFrom-Json
    }
    catch {
        return $toolAvailability
    }

    # Map commands to tools
    $toolMap = @{
        'npm test' = 'npm'
        'npm run build' = 'npm'
        'pytest' = 'pytest'
        'cargo test' = 'cargo'
        'cargo build' = 'cargo'
        'go test' = 'go'
    }

    $requiredTools = @()
    foreach ($cmd in $InferredCommands) {
        $toolName = $toolMap[$cmd.command]
        if ($toolName -and $toolName -notin $requiredTools) {
            $requiredTools += $toolName
        }
    }

    foreach ($tool in $requiredTools) {
        $toolInfo = $inventory.tools | Where-Object { $_.name -eq $tool } | Select-Object -First 1

        if ($toolInfo) {
            $toolAvailability | Add-Member -MemberType NoteProperty -Name $tool -Value @{
                status = 'available'
                version = $toolInfo.version
                path = $toolInfo.path
            }
        } else {
            $toolAvailability | Add-Member -MemberType NoteProperty -Name $tool -Value @{
                status = 'unknown'
                reason = 'not found in machine inventory'
            }
        }
    }

    return $toolAvailability
}

# ============================================================================
# Diagnostics
# ============================================================================

function Detect-Conflicts {
    param([object[]]$Manifests)

    $diagnostics = @()

    # npm + yarn conflict
    $hasNpmLock = $Manifests | Where-Object { $_.type -eq 'lockfile' -and $_.path -eq 'package-lock.json' }
    $hasYarnLock = $Manifests | Where-Object { $_.type -eq 'lockfile' -and $_.path -eq 'yarn.lock' }

    if ($hasNpmLock -and $hasYarnLock) {
        $diagnostics += [PSCustomObject]@{
            type = 'package_manager_conflict'
            severity = 'warning'
            path = 'package.json'
            message = 'Both npm and yarn lockfiles present'
            details = @{
                lockfiles = @('package-lock.json', 'yarn.lock')
            }
        }
    }

    return $diagnostics
}

# ============================================================================
# Main
# ============================================================================

# Validate parameters
$ResolvedWorkspacePath = Resolve-WorkspacePath $WorkspacePath
$script:AnalyzedAt = $AnalyzedAt

if ($MaxDepth -lt 1) {
    Write-Error "MaxDepth must be at least 1" -ErrorAction Stop
}

# Discovery
$manifests = Find-Manifests -WorkspacePath $ResolvedWorkspacePath -MaxDepth $MaxDepth

# Validate manifests and collect parsing diagnostics
$validationDiagnostics = @()
foreach ($manifest in $manifests) {
    if ($manifest.type -eq 'manifest') {
        $manifestFullPath = Join-Path -Path $ResolvedWorkspacePath -ChildPath $manifest.path
        $validationDiagnostics += Test-ManifestParseable -ManifestPath $manifestFullPath -FileExtension ([System.IO.Path]::GetExtension($manifest.path))
    }
}

$environments = Find-VirtualEnvironments -WorkspacePath $ResolvedWorkspacePath
$packageManagers = Infer-PackageManagers -Manifests $manifests -VirtualEnvironments $environments
$testCommands = Infer-TestCommands -Manifests $manifests -VirtualEnvironments $environments
$buildCommands = Infer-BuildCommands -Manifests $manifests -VirtualEnvironments $environments
$toolAvailability = Get-ToolAvailability -InferredCommands @($testCommands) + @($buildCommands) -MachineInventoryPath $MachineInventoryPath
$conflictDiagnostics = Detect-Conflicts -Manifests $manifests

# Combine all diagnostics (validation + conflicts)
$diagnostics = @($validationDiagnostics) + @($conflictDiagnostics)

# Build output - ensure all arrays serialize properly
$ecosystemsArray = @($manifests | Select-Object -ExpandProperty ecosystem -Unique)
$packageManagersArray = @($packageManagers)
$manifestsArray = @($manifests)
$environmentsArray = @($environments)
$testCommandsArray = @($testCommands)
$buildCommandsArray = @($buildCommands)
$diagnosticsArray = @($diagnostics)

# Ensure tool_availability is empty PSCustomObject if no properties
if ($null -eq $toolAvailability -or ($toolAvailability | Get-Member -MemberType Properties).Count -eq 0) {
    $toolAvailability = [PSCustomObject]@{}
}

# Calculate confidence summary
$allCommands = @($testCommandsArray) + @($buildCommandsArray)
$highConfidenceCount = @($allCommands | Where-Object { $_.confidence -eq 'high' }).Count
$mediumConfidenceCount = @($allCommands | Where-Object { $_.confidence -eq 'medium' }).Count
$lowConfidenceCount = @($allCommands | Where-Object { $_.confidence -eq 'low' }).Count

$output = [PSCustomObject]@{
    schema_version = '1.0.0'
    workspace_path = $ResolvedWorkspacePath
    analyzed_at = Get-TimestampISO8601
    ecosystems = $ecosystemsArray
    manifests = $manifestsArray
    virtual_environments = $environmentsArray
    package_managers = $packageManagersArray
    test_commands = $testCommandsArray
    build_commands = $buildCommandsArray
    tool_availability = $toolAvailability
    diagnostics = $diagnosticsArray
    confidence_summary = @{
        high_confidence_count = $highConfidenceCount
        medium_confidence_count = $mediumConfidenceCount
        low_confidence_count = $lowConfidenceCount
    }
}

# Write output
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$output | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding utf8

Write-Verbose "Workspace environment analysis complete: $OutputPath"
