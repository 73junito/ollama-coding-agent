Ollama Local Coding Agent

Read-only environment inventory and configuration for a local VS Code codingagent using Continue and Ollama.

Development phases

Machine and workspace inventory

Continue and Ollama model benchmarking

Agent execution hardening

Machine inventory

The inventory collector discovers supported development tools on PATH,classifies each command candidate, and runs a bounded, read-only version probe.It does not install, remove, or configure software.

Generate an inventory from the repository root:

.\tools\machine-inventory.ps1 `
    -OutputPath .\output\machine-inventory.json |
    Out-Null

The default probe timeout is 5,000 milliseconds per candidate. To use adifferent bounded timeout:

.\tools\machine-inventory.ps1 `
-OutputPath .\output\machine-inventory.json `
    -ProbeTimeoutMilliseconds 3000 |
    Out-Null

Windows App Execution Aliases and unsupported external-script candidates arerecorded with a skipped probe status. Other probes report succeeded,failed, or timed-out, together with their arguments, exit code, standardoutput, standard error, and duration.

Validate the collector and its JSON Schema contract with Pester 5:

$Configuration = New-PesterConfiguration
$Configuration.Run.Path = ".\tests\machine-inventory.tests.ps1"
$Configuration.Run.PassThru = $true
$Configuration.Output.Verbosity = "Detailed"

$Result = Invoke-Pester -Configuration $Configuration

if ($Result.FailedCount -gt 0) {
    throw "$($Result.FailedCount) contract test(s) failed."
}

Workspace environment detector

Detects development ecosystems, manifests, package managers, and inferred test/build commands for a workspace.

**Requirements:**
- **PowerShell 7.0 or later is required.** Run tests with `pwsh`, not Windows PowerShell 5.1.
- The detector script includes `#Requires -Version 7.0` and will not run on older versions.

Generate workspace inventory:

pwsh -NoProfile -Command {
    .\tools\workspace-environment.ps1 `
        -WorkspacePath . `
        -OutputPath .\output\workspace-environment.json
}

Validate with Pester 5 under PowerShell 7:

pwsh -NoProfile -Command {
    Invoke-Pester `
        -Path ".\tests\machine-workspace.tests.ps1" `
        -PassThru `
        -Output Detailed
}
