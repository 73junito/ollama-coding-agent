[CmdletBinding()]
param(
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-CandidateClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -match '\\AppData\\Local\\Microsoft\\WindowsApps\\') {
        return "windows-app-execution-alias"
    }

    if (
        $ToolName -in @("rustc", "cargo", "rustup") -and
        $Path -match '\\\.cargo\\bin\\'
    ) {
        return "rustup-managed-standard-user-path"
    }

    if (
        $ToolName -in @("gcc", "g++") -and
        $Path -match '\\Ruby[^\\]*\\msys64\\ucrt64\\bin\\'
    ) {
        return "ruby-msys2-ucrt64"
    }

    if (
        $ToolName -in @("node", "npm", "npx") -and
        $Path -match '\\nvm4w\\nodejs\\'
    ) {
        return "nvm-windows-managed"
    }

    if (
        $ToolName -in @("python", "python3") -and
        $Path -match '^C:\\Python\d+\\'
    ) {
        return "native-installation"
    }

    return "path-discovered"
}

function Get-ExternalCommandCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $allowedTypes = @(
        [System.Management.Automation.CommandTypes]::Application
        [System.Management.Automation.CommandTypes]::ExternalScript
    )

    $commands = @(
        Get-Command -Name $Name -All -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandType -in $allowedTypes }
    )

    foreach ($command in $commands) {
        [ordered]@{
            name           = $command.Name
            command_type   = $command.CommandType.ToString()
            source         = $command.Source
            path           = $command.Path
            definition     = $command.Definition
            classification = Get-CandidateClassification `
                -ToolName $Name `
                -Path $command.Path
        }
    }
}

$toolNames = @(
    "python"
    "python3"
    "py"
    "node"
    "npm"
    "npx"
    "nvm"
    "java"
    "javac"
    "dotnet"
    "go"
    "rustc"
    "cargo"
    "rustup"
    "gcc"
    "g++"
    "clang"
    "clang++"
    "ruby"
    "R"
    "Rscript"
    "elixir"
    "erl"
    "swipl"
    "pwsh"
    "powershell"
    "git"
    "cmake"
    "make"
    "ninja"
    "docker"
    "podman"
)

$tools = [ordered]@{}

foreach ($toolName in $toolNames) {
    $candidates = @(
        Get-ExternalCommandCandidate -Name $toolName
    )

    $tools[$toolName] = [ordered]@{
        available  = $candidates.Count -gt 0
        candidates = $candidates
    }
}

$result = [ordered]@{
    schema_version = "0.2.0"
    collected_at   = (Get-Date).ToUniversalTime().ToString("o")
    read_only      = $true

    host = [ordered]@{
        operating_system   = [System.Environment]::OSVersion.VersionString
        architecture       = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell_version = $PSVersionTable.PSVersion.ToString()
        powershell_edition = $PSVersionTable.PSEdition
    }

    tools = $tools
}

$json = $result | ConvertTo-Json -Depth 10

if ($OutputPath) {
    $resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $OutputPath
    )

    $parentDirectory = Split-Path -Parent $resolvedOutputPath

    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        throw "Output directory does not exist: $parentDirectory"
    }

    $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8
}

$json