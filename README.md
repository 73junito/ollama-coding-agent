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
