BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repositoryRoot "tools/machine-inventory.ps1"
    $schemaPath = Join-Path $repositoryRoot "schemas/machine-inventory.schema.json"
    $testOutputPath = Join-Path $TestDrive "machine-inventory.json"

    & $scriptPath -OutputPath $testOutputPath | Out-Null

    $script:InventoryJson = Get-Content -LiteralPath $testOutputPath -Raw
    $script:Inventory = $script:InventoryJson | ConvertFrom-Json
    $script:SchemaPath = $schemaPath
}

Describe "Machine inventory contract" {
    It "produces JSON that satisfies the schema" {
        $InventoryJson | Test-Json -SchemaFile $SchemaPath | Should -BeTrue
    }

    It "reports schema version 0.2.0 and read-only operation" {
        $Inventory.schema_version | Should -Be "0.2.0"
        $Inventory.read_only | Should -BeTrue
    }

    It "preserves the complete 32-tool inventory" {
        @($Inventory.tools.PSObject.Properties).Count | Should -Be 32
    }

    It "keeps availability consistent with candidate count" {
        foreach ($tool in $Inventory.tools.PSObject.Properties) {
            $candidateCount = @($tool.Value.candidates).Count

            if ($tool.Value.available) {
                $candidateCount | Should -BeGreaterThan 0 -Because $tool.Name
            } else {
                $candidateCount | Should -Be 0 -Because $tool.Name
            }
        }
    }

    It "classifies every discovered candidate" {
        $availableTools = @(
            $Inventory.tools.PSObject.Properties |
                Where-Object { $_.Value.available }
        )

        $availableTools.Count | Should -BeGreaterThan 0

        foreach ($tool in $availableTools) {
            foreach ($candidate in $tool.Value.candidates) {
                $candidate.classification | Should -Not -BeNullOrEmpty -Because $tool.Name
            }
        }
    }

    It "classifies known Windows installation patterns when present" {
        $cases = @(
            @{ Tool = "rustc"; Pattern = '\\.cargo\\bin\\'; Expected = "rustup-managed-standard-user-path" }
            @{ Tool = "python"; Pattern = '\\AppData\\Local\\Microsoft\\WindowsApps\\'; Expected = "windows-app-execution-alias" }
            @{ Tool = "node"; Pattern = '\\nvm4w\\nodejs\\'; Expected = "nvm-windows-managed" }
            @{ Tool = "gcc"; Pattern = '\\Ruby[^\\]*\\msys64\\ucrt64\\bin\\'; Expected = "ruby-msys2-ucrt64" }
        )

        foreach ($case in $cases) {
            $candidate = @($Inventory.tools.($case.Tool).candidates) |
                Where-Object { $_.path -match $case.Pattern } |
                Select-Object -First 1

            if ($candidate) {
                $candidate.classification | Should -Be $case.Expected
            }
        }
    }
}