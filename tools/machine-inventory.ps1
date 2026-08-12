[CmdletBinding()]
param(
    [string]$OutputPath,

    [ValidateRange(100, 60000)]
    [int]$ProbeTimeoutMilliseconds = 5000
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

function Get-VersionProbeArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName
    )

    switch ($ToolName) {
        "nvm" { return @("version") }
        "R" { return @("--version") }
        default { return @("--version") }
    }
}

function New-VersionProbeResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [int]$TimeoutMilliseconds,

        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [AllowEmptyString()]
        [string]$StandardOutput = "",

        [AllowEmptyString()]
        [string]$StandardError = "",

        [Parameter(Mandatory)]
        [long]$DurationMilliseconds,

        [AllowNull()]
        [string]$SkipReason
    )

    [ordered]@{
        status               = $Status
        arguments            = @($Arguments)
        timeout_milliseconds = $TimeoutMilliseconds
        exit_code            = $ExitCode
        standard_output = if ($null -eq $StandardOutput) { "" } else { [string]$StandardOutput }
        standard_error = if ($null -eq $StandardError) { "" } else { [string]$StandardError }
        duration_milliseconds = $DurationMilliseconds
        skip_reason          = $SkipReason
    }
}

function Invoke-VersionProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$CommandType,

        [Parameter(Mandatory)]
        [string]$Classification,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [int]$TimeoutMilliseconds
    )

    if ($Classification -eq "windows-app-execution-alias") {
        return New-VersionProbeResult `
            -Status "skipped" `
            -Arguments $Arguments `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -ExitCode $null `
            -DurationMilliseconds 0 `
            -SkipReason "windows-app-execution-alias"
    }

    if ($CommandType -ne "Application") {
        return New-VersionProbeResult `
            -Status "skipped" `
            -Arguments $Arguments `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -ExitCode $null `
            -DurationMilliseconds 0 `
            -SkipReason "unsupported-command-type"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Path
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if (-not $process.Start()) {
            throw "The process did not start."
        }

        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill($true)
            } catch {
                # The process may have exited between the timeout and kill request.
            }

            $process.WaitForExit()
            $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
            $standardError = $standardErrorTask.GetAwaiter().GetResult()
            $stopwatch.Stop()

            return New-VersionProbeResult `
                -Status "timed-out" `
                -Arguments $Arguments `
                -TimeoutMilliseconds $TimeoutMilliseconds `
                -ExitCode $null `
                -StandardOutput $standardOutput `
                -StandardError $standardError `
                -DurationMilliseconds $stopwatch.ElapsedMilliseconds `
                -SkipReason $null
        }

        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $stopwatch.Stop()
        $status = if ($process.ExitCode -eq 0) { "succeeded" } else { "failed" }

        return New-VersionProbeResult `
            -Status $status `
            -Arguments $Arguments `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -ExitCode $process.ExitCode `
            -StandardOutput $standardOutput `
            -StandardError $standardError `
            -DurationMilliseconds $stopwatch.ElapsedMilliseconds `
            -SkipReason $null
    } catch {
        $stopwatch.Stop()

        return New-VersionProbeResult `
            -Status "failed" `
            -Arguments $Arguments `
            -TimeoutMilliseconds $TimeoutMilliseconds `
            -ExitCode $null `
            -StandardError $_.Exception.Message `
            -DurationMilliseconds $stopwatch.ElapsedMilliseconds `
            -SkipReason $null
    } finally {
        $process.Dispose()
    }
}

function Get-ExternalCommandCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$TimeoutMilliseconds
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
        $classification = Get-CandidateClassification -ToolName $Name -Path $command.Path
        $probeArguments = @(Get-VersionProbeArguments -ToolName $Name)

        [ordered]@{
            name           = $command.Name
            command_type   = $command.CommandType.ToString()
            source         = $command.Source
            path           = $command.Path
            definition     = $command.Definition
            classification = $classification
            version_probe  = Invoke-VersionProbe `
                -Path $command.Path `
                -CommandType $command.CommandType.ToString() `
                -Classification $classification `
                -Arguments $probeArguments `
                -TimeoutMilliseconds $TimeoutMilliseconds
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
        Get-ExternalCommandCandidate `
            -Name $toolName `
            -TimeoutMilliseconds $ProbeTimeoutMilliseconds
    )

    $tools[$toolName] = [ordered]@{
        available  = $candidates.Count -gt 0
        candidates = $candidates
    }
}

$result = [ordered]@{
    schema_version = "0.3.0"
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

$json = $result | ConvertTo-Json -Depth 12

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
