BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repositoryRoot "tools/machine-inventory.ps1"
    $schemaPath = Join-Path $repositoryRoot "schemas/machine-inventory.schema.json"
    $testOutputPath = Join-Path $TestDrive "machine-inventory.json"

    & $scriptPath `
        -OutputPath $testOutputPath `
        -ProbeTimeoutMilliseconds 3000 |
        Out-Null

    $script:InventoryJson = Get-Content -LiteralPath $testOutputPath -Raw
    $script:Inventory = $script:InventoryJson | ConvertFrom-Json
    $script:SchemaPath = $schemaPath
}

Describe "Machine inventory contract" {
    It "produces JSON that satisfies the schema" {
        $InventoryJson | Test-Json -SchemaFile $SchemaPath | Should -BeTrue
    }

    It "reports schema version 0.3.0 and read-only operation" {
        $Inventory.schema_version | Should -Be "0.3.0"
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

    It "records a bounded version probe for every discovered candidate" {
        $validStatuses = @("succeeded", "failed", "timed-out", "skipped")

        foreach ($tool in $Inventory.tools.PSObject.Properties) {
            foreach ($candidate in $tool.Value.candidates) {
                $probe = $candidate.version_probe

                $probe.status | Should -BeIn $validStatuses -Because $tool.Name
                $probe.timeout_milliseconds | Should -Be 3000 -Because $tool.Name
                @($probe.arguments).Count | Should -BeGreaterThan 0 -Because $tool.Name
                $probe.duration_milliseconds | Should -BeGreaterOrEqual 0 -Because $tool.Name
                $probe.standard_output | Should -BeOfType ([string]) -Because $tool.Name
                $probe.standard_error | Should -BeOfType ([string]) -Because $tool.Name
            }
        }
    }

    It "keeps probe status consistent with exit and skip metadata" {
        foreach ($tool in $Inventory.tools.PSObject.Properties) {
            foreach ($candidate in $tool.Value.candidates) {
                $probe = $candidate.version_probe

                switch ($probe.status) {
                    "succeeded" {
                        $probe.exit_code | Should -Be 0 -Because $tool.Name
                        $probe.skip_reason | Should -BeNullOrEmpty -Because $tool.Name
                    }
                    "skipped" {
                        $probe.exit_code | Should -BeNullOrEmpty -Because $tool.Name
                        $probe.skip_reason | Should -Not -BeNullOrEmpty -Because $tool.Name
                    }
                    "timed-out" {
                        $probe.exit_code | Should -BeNullOrEmpty -Because $tool.Name
                        $probe.skip_reason | Should -BeNullOrEmpty -Because $tool.Name
                    }
                    "failed" {
                        $probe.skip_reason | Should -BeNullOrEmpty -Because $tool.Name
                    }
                }
            }
        }
    }

    It "skips Windows App Execution Aliases" {
        $aliases = @(
            $Inventory.tools.PSObject.Properties |
                ForEach-Object { $_.Value.candidates } |
                Where-Object { $_.classification -eq "windows-app-execution-alias" }
        )

        foreach ($alias in $aliases) {
            $alias.version_probe.status | Should -Be "skipped"
            $alias.version_probe.skip_reason | Should -Be "windows-app-execution-alias"
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
