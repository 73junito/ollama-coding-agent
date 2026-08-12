BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $detectorScript = Join-Path $repositoryRoot "tools\workspace-environment.ps1"
    $schemaPath = Join-Path $repositoryRoot "schemas\workspace-environment.schema.json"
    $machineInventoryPath = Join-Path $repositoryRoot "output\machine-inventory.json"
    $testDataRoot = Join-Path $repositoryRoot "tests\fixtures\workspace-environments"
    $testOutputRoot = Join-Path $TestDrive "workspace-detector"

    # Ensure test output directory exists
    New-Item -ItemType Directory -Path $testOutputRoot -Force | Out-Null

    # Helper to create test workspace
    function Setup-WorkspaceTest {
        param(
            [Parameter(Mandatory)]
            [string]$Name,
            [hashtable]$Manifests = @{},
            [string[]]$Directories = @(),
            [hashtable]$Files = @{}
        )

        $workspacePath = Join-Path $testOutputRoot $Name
        New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null

        # Create manifests
        foreach ($manifestName in $Manifests.Keys) {
            $manifestPath = Join-Path $workspacePath $manifestName
            $manifestContent = $Manifests[$manifestName] | ConvertTo-Json -Depth 10
            Set-Content -LiteralPath $manifestPath -Value $manifestContent -Encoding utf8
        }

        # Create directories
        foreach ($dir in $Directories) {
            New-Item -ItemType Directory -Path (Join-Path $workspacePath $dir) -Force | Out-Null
        }

        # Create arbitrary files
        foreach ($fileName in $Files.Keys) {
            $filePath = Join-Path $workspacePath $fileName
            $dirPath = Split-Path $filePath
            if (-not (Test-Path $dirPath)) {
                New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
            }
            Set-Content -LiteralPath $filePath -Value $Files[$fileName] -Encoding utf8
        }

        return $workspacePath
    }

    # Helper to invoke detector
    function Run-DetectorScript {
        param(
            [Parameter(Mandatory)]
            [string]$WorkspacePath,
            [string]$OutputPath = (Join-Path $testOutputRoot "output-$([guid]::NewGuid()).json"),
            [string]$AnalyzedAt,
            [int]$MaxDepth = 2
        )

        $params = @{
            WorkspacePath = $WorkspacePath
            MachineInventoryPath = $machineInventoryPath
            OutputPath = $OutputPath
            ErrorAction = 'Stop'
            MaxDepth = $MaxDepth
        }

        if ($AnalyzedAt) {
            $params['AnalyzedAt'] = $AnalyzedAt
        }

        & $detectorScript @params

        return $OutputPath
    }

    # Helper to validate output against schema
    function Test-WorkspaceEnvironmentSchema {
        param(
            [Parameter(Mandatory)]
            [string]$JsonPath
        )

        if (-not (Test-Path $schemaPath)) {
            return $false
        }

        $json = Get-Content -LiteralPath $JsonPath -Raw
        return $json | Test-Json -SchemaFile $schemaPath
    }

    $script:DetectorScript = $detectorScript
    $script:SchemaPath = $schemaPath
    $script:TestOutputRoot = $testOutputRoot
}

Describe "Workspace environment detector" {
    Context "Interface validation" {
        It "accepts explicit workspace path as mandatory parameter" {
            $workspacePath = Setup-WorkspaceTest -Name "interface-test" -Manifests @{
                "package.json" = @{
                    name = "test-app"
                    version = "1.0.0"
                }
            }

            { Run-DetectorScript -WorkspacePath $workspacePath } | Should -Not -Throw
        }

        It "rejects non-existent workspace path" {
            $invalidPath = Join-Path $TestOutputRoot "non-existent-workspace"

            { Run-DetectorScript -WorkspacePath $invalidPath } | Should -Throw
        }

        It "requires output path parameter" {
            $Command = Get-Command $detectorScript
            $Command.Parameters["OutputPath"].Attributes.Mandatory |
                Should -Contain $true
        }

        It "creates output file at specified path" {
            $workspacePath = Setup-WorkspaceTest -Name "output-file-test" -Manifests @{
                "package.json" = @{ name = "test" }
            }
            $outputPath = Join-Path $TestOutputRoot "custom-output.json"

            Run-DetectorScript -WorkspacePath $workspacePath -OutputPath $outputPath

            Test-Path $outputPath | Should -BeTrue
        }

        It "accepts optional -AnalyzedAt parameter for deterministic testing" {
            $workspacePath = Setup-WorkspaceTest -Name "analyzed-at-test" -Manifests @{
                "package.json" = @{ name = "test" }
            }
            $testTimestamp = "2026-08-11T12:00:00Z"

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath -AnalyzedAt $testTimestamp
            $rawJson = Get-Content -LiteralPath $outputPath -Raw

            # Compare the raw JSON string to preserve the exact timestamp format
            $rawJson | Should -Match ([regex]::Escape($testTimestamp))
        }

        It "accepts optional -MaxDepth parameter for recursion control" {
            $workspacePath = Setup-WorkspaceTest -Name "max-depth-test" -Manifests @{
                "package.json" = @{ name = "root" }
            } -Files @{
                "src/package.json" = '{"name": "src-level"}'
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath -MaxDepth 2
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            # With MaxDepth 2, should find both root and src/package.json
            $manifestCount = @($output.manifests | Where-Object { $_.path -match "^package\.json$|^src" }).Count
            $manifestCount | Should -BeGreaterThan 0
        }
    }

    Context "JSON schema validation" {
        It "produces valid workspace-environment JSON matching schema" {
            if (-not (Test-Path $SchemaPath)) {
                Set-SkipPending -IsSkipped $true -Because "workspace-environment.schema.json does not exist yet"
            }

            $workspacePath = Setup-WorkspaceTest -Name "schema-test" -Manifests @{
                "package.json" = @{ name = "test"; version = "1.0.0" }
            }
            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath

            Test-WorkspaceEnvironmentSchema -JsonPath $outputPath | Should -BeTrue
        }

        It "includes required root properties" {
            $workspacePath = Setup-WorkspaceTest -Name "required-props" -Manifests @{
                "package.json" = @{ name = "test" }
            }
            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath

            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.schema_version | Should -Not -BeNullOrEmpty
            $output.workspace_path | Should -Not -BeNullOrEmpty
            $output.analyzed_at | Should -Not -BeNullOrEmpty
            $output.ecosystems | Should -BeOfType ([object])
            $output.manifests | Should -BeOfType ([object])
            $output.tool_availability | Should -Not -BeNull
            $output | Get-Member -Name diagnostics | Should -Not -BeNullOrEmpty
            $output.diagnostics.GetType() | Should -Be ([System.Object[]])
        }

        It "allows tool_availability to be empty when no machine inventory supplied" {
            $workspacePath = Setup-WorkspaceTest -Name "empty-tool-availability" -Manifests @{
                "package.json" = @{ name = "test" }
            }
            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath

            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.tool_availability | Should -BeOfType ([PSCustomObject])
            # Should allow empty or with entries
            $output.tool_availability -is [object] | Should -BeTrue
        }
    }

    Context "Single-language project detection" {
        It "detects Node.js ecosystem with package.json" {
            $workspacePath = Setup-WorkspaceTest -Name "nodejs-only" -Manifests @{
                "package.json" = @{
                    name = "my-app"
                    version = "1.0.0"
                    scripts = @{ test = "jest" }
                }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.ecosystems | Should -Contain "node"
        }

        It "detects Python ecosystem with pyproject.toml" {
            $workspacePath = Setup-WorkspaceTest -Name "python-only" -Manifests @{
                "pyproject.toml" = @{ }
            } -Directories @(".venv")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.ecosystems | Should -Contain "python"
        }

        It "detects Rust ecosystem with Cargo.toml" {
            $workspacePath = Setup-WorkspaceTest -Name "rust-only" -Manifests @{
                "Cargo.toml" = @{
                    package = @{ name = "my-crate"; version = "0.1.0" }
                }
            } -Directories @("target")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.ecosystems | Should -Contain "rust"
        }

        It "detects Go ecosystem with go.mod" {
            $workspacePath = Setup-WorkspaceTest -Name "go-only" -Manifests @{
                "go.mod" = @{ }
            } -Directories @("vendor")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.ecosystems | Should -Contain "go"
        }
    }

    Context "Manifest detection" {
        It "reports manifest path and type for each discovered manifest" {
            $workspacePath = Setup-WorkspaceTest -Name "manifest-report" -Manifests @{
                "package.json" = @{ name = "test" }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            @($output.manifests).Count | Should -BeGreaterThan 0
            $output.manifests[0].path | Should -Not -BeNullOrEmpty
            $output.manifests[0].type | Should -Not -BeNullOrEmpty
        }

        It "detects lock files alongside manifests" {
            $workspacePath = Setup-WorkspaceTest -Name "lockfile-detect" -Manifests @{
                "package.json" = @{ name = "test" }
                "package-lock.json" = @{ }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $lockFiles = $output.manifests | Where-Object { $_.type -eq "lockfile" }
            $lockFiles | Should -Not -BeNullOrEmpty
        }
    }

    Context "Virtual environment detection" {
        It "detects Python venv with .venv directory" {
            $workspacePath = Setup-WorkspaceTest -Name "venv-detect" -Manifests @{
                "pyproject.toml" = @{ }
            } -Directories @(".venv") -Files @{
                ".venv/pyvenv.cfg" = "[virtualenv]`nversion = 3.11"
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $pythonEnv = $output.virtual_environments | Where-Object { $_.type -eq "python-venv" }
            $pythonEnv | Should -Not -BeNullOrEmpty
        }

        It "detects node_modules directory" {
            $workspacePath = Setup-WorkspaceTest -Name "node-modules-detect" -Manifests @{
                "package.json" = @{ name = "test" }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $nodeEnv = $output.virtual_environments | Where-Object { $_.type -eq "node-modules" }
            $nodeEnv | Should -Not -BeNullOrEmpty
        }
    }

    Context "Package manager inference" {
        It "infers npm from package.json and node_modules" {
            $workspacePath = Setup-WorkspaceTest -Name "npm-infer" -Manifests @{
                "package.json" = @{ name = "test" }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.package_managers | Should -Contain "npm"
        }

        It "infers pip from requirements.txt and venv" {
            $workspacePath = Setup-WorkspaceTest -Name "pip-infer" -Manifests @{
                "requirements.txt" = "requests==2.28.0`ndjangorestframework==3.13.1"
            } -Directories @(".venv")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.package_managers | Should -Contain "pip"
        }

        It "infers cargo from Cargo.toml" {
            $workspacePath = Setup-WorkspaceTest -Name "cargo-infer" -Manifests @{
                "Cargo.toml" = @{ package = @{ name = "test"; version = "0.1.0" } }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.package_managers | Should -Contain "cargo"
        }
    }

    Context "Test command inference" {
        It "infers 'npm test' from package.json with test script" {
            $workspacePath = Setup-WorkspaceTest -Name "npm-test-infer" -Manifests @{
                "package.json" = @{
                    name = "test-app"
                    scripts = @{ test = "jest" }
                }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $testCmd = $output.test_commands | Where-Object { $_.command -eq "npm test" }
            $testCmd | Should -Not -BeNullOrEmpty
        }

        It "infers 'pytest' from pyproject.toml with pytest config" {
            $workspacePath = Setup-WorkspaceTest -Name "pytest-infer" -Manifests @{
                "pyproject.toml" = "[tool.pytest.ini_options]`ntestpaths = ['tests']"
            } -Directories @(".venv")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $testCmd = $output.test_commands | Where-Object { $_.command -eq "pytest" }
            $testCmd | Should -Not -BeNullOrEmpty
        }

        It "infers 'cargo test' from Cargo.toml" {
            $workspacePath = Setup-WorkspaceTest -Name "cargo-test-infer" -Manifests @{
                "Cargo.toml" = @{ package = @{ name = "test"; version = "0.1.0" } }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $testCmd = $output.test_commands | Where-Object { $_.command -eq "cargo test" }
            $testCmd | Should -Not -BeNullOrEmpty
        }

        It "includes evidence for each inferred test command" {
            $workspacePath = Setup-WorkspaceTest -Name "test-evidence" -Manifests @{
                "package.json" = @{ name = "test"; scripts = @{ test = "jest" } }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $testCmd = $output.test_commands | Where-Object { $_.command -eq "npm test" }
            $testCmd.evidence | Should -Not -BeNullOrEmpty
            $testCmd.confidence | Should -Not -BeNullOrEmpty
        }
    }

    Context "Build command inference" {
        It "infers 'npm run build' from package.json with build script" {
            $workspacePath = Setup-WorkspaceTest -Name "npm-build-infer" -Manifests @{
                "package.json" = @{
                    name = "test-app"
                    scripts = @{ build = "webpack" }
                }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $buildCmd = $output.build_commands | Where-Object { $_.command -eq "npm run build" }
            $buildCmd | Should -Not -BeNullOrEmpty
        }

        It "infers 'cargo build' from Cargo.toml" {
            $workspacePath = Setup-WorkspaceTest -Name "cargo-build-infer" -Manifests @{
                "Cargo.toml" = @{ package = @{ name = "test"; version = "0.1.0" } }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $buildCmd = $output.build_commands | Where-Object { $_.command -eq "cargo build" }
            $buildCmd | Should -Not -BeNullOrEmpty
        }
    }

    Context "Polyglot project detection" {
        It "detects multiple ecosystems in same workspace" {
            $workspacePath = Setup-WorkspaceTest -Name "polyglot-multi" -Manifests @{
                "package.json" = @{ name = "frontend" }
                "pyproject.toml" = @{ }
            } -Directories @("node_modules", ".venv")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.ecosystems | Should -Contain "node"
            $output.ecosystems | Should -Contain "python"
        }

        It "infers test commands for all detected ecosystems" {
            $workspacePath = Setup-WorkspaceTest -Name "polyglot-tests" -Manifests @{
                "package.json" = @{ name = "app"; scripts = @{ test = "jest" } }
                "pyproject.toml" = "[tool.pytest.ini_options]`ntestpaths = ['backend/tests']"
            } -Directories @("node_modules", ".venv")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            @($output.test_commands).Count | Should -BeGreaterThan 1
        }
    }

    Context "Edge cases" {
        It "handles empty workspace gracefully" {
            $workspacePath = Setup-WorkspaceTest -Name "empty-workspace"

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.ecosystems.Count | Should -Be 0
            $output.manifests.Count | Should -Be 0
            $output.test_commands.Count | Should -Be 0
            $output.build_commands.Count | Should -Be 0
            $output | Get-Member -Name diagnostics | Should -Not -BeNullOrEmpty
            $output.diagnostics.GetType() | Should -Be ([System.Object[]])
        }

        It "handles missing virtual environment" {
            $workspacePath = Setup-WorkspaceTest -Name "missing-venv" -Manifests @{
                "pyproject.toml" = @{ }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.ecosystems | Should -Contain "python"
            $output.virtual_environments.Count | Should -Be 0
        }

        It "reports malformed manifests and continues detection" {
            $workspacePath = Setup-WorkspaceTest `
                -Name "malformed-manifest" `
                -Manifests @{
                    "package.json" = @{ name = "test" }
                } `
                -Files @{
                    "pyproject.toml" = "invalid [toml content"
                }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 100

            # Confirm detection continued and found the valid manifest
            $output.ecosystems | Should -Contain "node"

            # Verify malformed diagnostic was emitted
            $diagnostic = @(
                $output.diagnostics |
                    Where-Object { $_.type -eq "malformed_manifest" }
            )

            $diagnostic.Count | Should -BeGreaterThan 0
            $diagnostic[0].path | Should -Match "pyproject\.toml"
            $diagnostic[0].message | Should -Not -BeNullOrEmpty
        }

        It "detects balanced-but-invalid TOML syntax errors" {
            # Test case: TOML with balanced brackets but invalid syntax (unassigned property)
            $workspacePath = Setup-WorkspaceTest `
                -Name "balanced-invalid-toml" `
                -Manifests @{
                    "package.json" = @{ name = "test" }
                } `
                -Files @{
                    "pyproject.toml" = @"
[project]
name =
"@
                }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 100

            # Verify malformed diagnostic for unassigned property
            $diagnostic = @(
                $output.diagnostics |
                    Where-Object { $_.type -eq "malformed_manifest" -and $_.path -match "pyproject" }
            )

            $diagnostic.Count | Should -BeGreaterThan 0 -Because "balanced-but-invalid TOML should be detected"
            $diagnostic[0].message | Should -Not -BeNullOrEmpty
        }

        It "ignores deeply nested manifests beyond MaxDepth" {
            $workspacePath = Setup-WorkspaceTest -Name "nested-manifest" -Manifests @{
                "package.json" = @{ name = "root" }
            } -Files @{
                "src/subproject/package.json" = '{"name": "subproject"}'
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $manifestCount = @($output.manifests | Where-Object { $_.path -eq "package.json" }).Count
            $manifestCount | Should -Be 1
        }

        It "detects package manager conflicts (npm + yarn)" {
            $workspacePath = Setup-WorkspaceTest -Name "lockfile-conflict" -Manifests @{
                "package.json" = @{ name = "test" }
            } -Files @{
                "package-lock.json" = '{"version": 1}'
                "yarn.lock" = 'package "package@^1.0.0"'
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.diagnostics | Should -Not -BeNullOrEmpty
            ($output.diagnostics | Where-Object { $_.type -eq "package_manager_conflict" } | Measure-Object).Count | Should -BeGreaterThan 0
        }

        It "reports tool availability separately from inferred commands" {
            $manifests = @{ "package.json" = @{ name = "test"; scripts = @{ test = "jest" } } }
            $workspacePath = Setup-WorkspaceTest -Name "tool-availability" -Manifests $manifests

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output.tool_availability | Should -BeOfType ([PSCustomObject])
            # Test commands are inferred regardless of tool availability
            ($output.test_commands | Measure-Object).Count | Should -BeGreaterThan 0
        }
    }

    Context "Conflict detection" {
        It "produces conflict diagnostic for multiple npm lockfiles" {
            $workspacePath = Setup-WorkspaceTest -Name "npm-conflict" -Manifests @{
                "package.json" = @{ name = "test" }
            } -Files @{
                "package-lock.json" = '{}'
                "yarn.lock" = ''
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $diagnostics = @($output.diagnostics | Where-Object { $_.type -eq "package_manager_conflict" })
            $diagnostics.Count | Should -BeGreaterThan 0
        }
    }

    Context "Diagnostics" {
        It "includes diagnostics array in output" {
            $workspacePath = Setup-WorkspaceTest -Name "with-diagnostics" -Manifests @{}

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $output | Get-Member -Name diagnostics | Should -Not -BeNullOrEmpty
            $output.diagnostics.GetType() | Should -Be ([System.Object[]])
        }

        It "structures diagnostic objects correctly" {
            $workspacePath = Setup-WorkspaceTest -Name "diagnostic-structure" -Manifests @{
                "package.json" = @{ name = "test" }
            } -Files @{
                "pyproject.toml" = "invalid [["
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $diagnostics = @($output.diagnostics | Where-Object { $_.type -ne $null })
            $diagnostics | ForEach-Object {
                $_.type | Should -Not -BeNullOrEmpty
                $_.severity | Should -Not -BeNullOrEmpty
                $_.message | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context "Path resolution" {
        It "resolves relative paths from caller's current directory" {
            $workspacePath = Setup-WorkspaceTest -Name "relative-path-test" -Manifests @{
                "package.json" = @{ name = "test" }
            }

            $originalLocation = Get-Location
            try {
                Set-Location $testOutputRoot
                $relativePath = "relative-path-test"

                $outputPath = Run-DetectorScript -WorkspacePath $relativePath
                $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

                $output.ecosystems | Should -Contain "node"
            }
            finally {
                Set-Location $originalLocation
            }
        }
    }


    Context "Confidence scoring" {
        It "assigns high confidence to manifest + environment detected combinations" {
            $workspacePath = Setup-WorkspaceTest -Name "high-confidence" -Manifests @{
                "package.json" = @{ name = "test"; scripts = @{ test = "jest" } }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $testCmd = $output.test_commands | Where-Object { $_.command -eq "npm test" }
            $testCmd.confidence | Should -Be "high"
        }

        It "assigns medium confidence to manifest-only detection" {
            $workspacePath = Setup-WorkspaceTest -Name "medium-confidence" -Manifests @{
                "package.json" = @{ name = "test"; scripts = @{ test = "jest" } }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $testCmd = $output.test_commands | Where-Object { $_.command -eq "npm test" }
            $testCmd.confidence | Should -Be "medium"
        }
    }

    Context "Evidence documentation" {
        It "documents evidence source for each discovery" {
            $workspacePath = Setup-WorkspaceTest -Name "evidence-doc" -Manifests @{
                "package.json" = @{ name = "test"; scripts = @{ test = "jest" } }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $testCmd = $output.test_commands[0]
            $testCmd.evidence | Should -Not -BeNullOrEmpty
            $testCmd.inferred_from | Should -Not -BeNullOrEmpty
        }

        It "includes file path in evidence objects" {
            $workspacePath = Setup-WorkspaceTest -Name "evidence-paths" -Manifests @{
                "package.json" = @{ name = "test"; scripts = @{ test = "jest" } }
            } -Directories @("node_modules")

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $manifest = $output.manifests | Where-Object { $_.type -eq "manifest" }
            $manifest.path | Should -Not -BeNullOrEmpty
        }
    }

    Context "Confidence scoring" {
        It "summarizes emitted command confidence accurately" {
            $workspacePath = Setup-WorkspaceTest -Name "confidence-summary" -Manifests @{
                "package.json" = @{
                    name = "test"
                    scripts = @{
                        test  = "jest"
                        build = "webpack"
                    }
                }
            }

            $outputPath = Run-DetectorScript -WorkspacePath $workspacePath
            $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 100

            $commands = @($output.test_commands) + @($output.build_commands)

            $output.confidence_summary.high_confidence_count |
                Should -Be @($commands | Where-Object { $_.confidence -eq "high" }).Count

            $output.confidence_summary.medium_confidence_count |
                Should -Be @($commands | Where-Object { $_.confidence -eq "medium" }).Count

            $output.confidence_summary.low_confidence_count |
                Should -Be @($commands | Where-Object { $_.confidence -eq "low" }).Count
        }
    }
}
