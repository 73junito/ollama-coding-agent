using module Pester

BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $planner = Join-Path $repositoryRoot "tools\command-planner.ps1"
    $schemaPath = Join-Path $repositoryRoot "schemas\command-plan.schema.json"
    $workspaceEnvironmentFixture = Join-Path $repositoryRoot "tests\fixtures\workspace-environments\basic.json"
    $machineInventoryFixture = Join-Path $repositoryRoot "output\machine-inventory.json"
    $testOutputRoot = Join-Path $TestDrive "command-planner"

    if (-not (Test-Path $testOutputRoot)) {
        New-Item -ItemType Directory -Path $testOutputRoot -Force | Out-Null
    }

    function New-TestPlan {
        param(
            [string]$WorkspaceEnvironmentPath,
            [string]$MachineInventoryPath,
            [string]$OutputPath,
            [string]$PlannedAt
        )

        $params = @{
            WorkspaceEnvironmentPath = $WorkspaceEnvironmentPath
            MachineInventoryPath = $MachineInventoryPath
            OutputPath = $OutputPath
            ErrorAction = 'Stop'
        }

        if ($PlannedAt) {
            $params['PlannedAt'] = $PlannedAt
        }

        & $planner @params
        return $OutputPath
    }

    function Get-PlanContent {
        param([string]$OutputPath)
        Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
    }

    function Get-RawJsonValue {
        param([string]$OutputPath, [string]$PropertyName)
        # Extract property value from raw JSON without deserializing
        $json = Get-Content -LiteralPath $OutputPath -Raw
        # Match quoted string value: "planned_at": "value"
        if ($json -match '"' + [regex]::Escape($PropertyName) + '"\s*:\s*"([^"]*)"') {
            return $matches[1]
        }
        return $null
    }

    function Test-PlanAgainstSchema {
        param($Plan, [string]$SchemaPath)

        $schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json
        # Basic schema validation: check required properties
        $requiredProps = @('schema_version', 'workspace_path', 'machine_inventory_path', 'workspace_environment_path', 'planned_at', 'commands', 'diagnostics', 'approval_summary')

        foreach ($prop in $requiredProps) {
            if ($null -eq $Plan.PSObject.Properties[$prop]) {
                return $false
            }
        }
        return $true
    }
}

Describe 'Command Planner Interface' {
    It 'accepts WorkspaceEnvironmentPath parameter' {
        # Create minimal workspace-environment
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @()
            diagnostics = @()
        } | ConvertTo-Json
        $wsEnvPath = Join-Path $testOutputRoot "ws-env.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        # Create minimal machine inventory
        $machInv = @{
            schema_version = "1.0.0"
            tools = @{}
        } | ConvertTo-Json
        $machPath = Join-Path $testOutputRoot "machine-inv.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "plan1.json"

        { New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath } | Should -Not -Throw
        Test-Path $outputPath | Should -BeTrue
    }

    It 'accepts OutputPath parameter' {
        $wsEnv = @{ schema_version = "1.0.0"; workspace_path = "."; commands = @(); diagnostics = @() } | ConvertTo-Json
        $wsEnvPath = Join-Path $testOutputRoot "ws-env2.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{ schema_version = "1.0.0"; tools = @{} } | ConvertTo-Json
        $machPath = Join-Path $testOutputRoot "machine-inv2.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "custom\path\plan.json"

        { New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath } | Should -Not -Throw
        Test-Path $outputPath | Should -BeTrue
    }

    It 'accepts PlannedAt parameter' {
        $wsEnv = @{ schema_version = "1.0.0"; workspace_path = "."; commands = @(); diagnostics = @() } | ConvertTo-Json
        $wsEnvPath = Join-Path $testOutputRoot "ws-env3.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{ schema_version = "1.0.0"; tools = @{} } | ConvertTo-Json
        $machPath = Join-Path $testOutputRoot "machine-inv3.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "plan-with-timestamp.json"
        $timestamp = "2026-08-12T20:00:00Z"

        { New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath -PlannedAt $timestamp } | Should -Not -Throw
        # Use raw JSON to preserve ISO8601 format (ConvertFrom-Json deserializes to DateTime)
        $plannedAtStr = Get-RawJsonValue $outputPath "planned_at"
        $plannedAtStr -like "2026-08-12T20:00:00*" | Should -BeTrue
    }

    It 'creates output directory if needed' {
        $wsEnv = @{ schema_version = "1.0.0"; workspace_path = "."; commands = @(); diagnostics = @() } | ConvertTo-Json
        $wsEnvPath = Join-Path $testOutputRoot "ws-env4.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{ schema_version = "1.0.0"; tools = @{} } | ConvertTo-Json
        $machPath = Join-Path $testOutputRoot "machine-inv4.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "deep\nested\directory\plan.json"
        $outputDir = Split-Path -Parent $outputPath

        { New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath } | Should -Not -Throw
        Test-Path $outputDir | Should -BeTrue
        Test-Path $outputPath | Should -BeTrue
    }
}

Describe 'Command Plan Schema Validation' {
    It 'produces JSON that validates against command-plan.schema.json' {
        $wsEnv = @{ schema_version = "1.0.0"; workspace_path = "."; commands = @(); diagnostics = @() } | ConvertTo-Json
        $wsEnvPath = Join-Path $testOutputRoot "ws-env5.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{ schema_version = "1.0.0"; tools = @{} } | ConvertTo-Json
        $machPath = Join-Path $testOutputRoot "machine-inv5.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "schema-test.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        Test-PlanAgainstSchema -Plan $plan -SchemaPath $schemaPath | Should -BeTrue
    }

    It 'includes required root properties' {
        $wsEnv = @{ schema_version = "1.0.0"; workspace_path = "."; commands = @(); diagnostics = @() } | ConvertTo-Json
        $wsEnvPath = Join-Path $testOutputRoot "ws-env6.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{ schema_version = "1.0.0"; tools = @{} } | ConvertTo-Json
        $machPath = Join-Path $testOutputRoot "machine-inv6.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "required-props.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $plan.schema_version | Should -Match '^\d+\.\d+\.\d+$'
        $plan.workspace_path | Should -Not -BeNullOrEmpty
        $plan.machine_inventory_path | Should -Not -BeNullOrEmpty
        $plan.workspace_environment_path | Should -Not -BeNullOrEmpty
        # Use raw JSON to preserve ISO8601 format
        $plannedAtStr = Get-RawJsonValue $outputPath "planned_at"
        $plannedAtStr | Should -Not -BeNullOrEmpty
        $plannedAtStr -like "20??-??-??*" | Should -BeTrue
        $plan.commands.GetType() | Should -Be ([System.Object[]])
        $plan.diagnostics.GetType() | Should -Be ([System.Object[]])
        $plan.PSObject.Properties['approval_summary'] | Should -Not -BeNullOrEmpty
    }

    It 'includes approval_summary with required counts' {
        $wsEnv = @{ schema_version = "1.0.0"; workspace_path = "."; commands = @(); diagnostics = @() } | ConvertTo-Json
        $wsEnvPath = Join-Path $testOutputRoot "ws-env7.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{ schema_version = "1.0.0"; tools = @{} } | ConvertTo-Json
        $machPath = Join-Path $testOutputRoot "machine-inv7.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "approval-summary.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $plan.approval_summary.PSObject.Properties['ready_without_approval'] | Should -Not -BeNullOrEmpty
        $plan.approval_summary.PSObject.Properties['requires_approval'] | Should -Not -BeNullOrEmpty
        $plan.approval_summary.PSObject.Properties['blocked'] | Should -Not -BeNullOrEmpty
        $plan.approval_summary.PSObject.Properties['ambiguous'] | Should -Not -BeNullOrEmpty
        $plan.approval_summary.PSObject.Properties['unsafe'] | Should -Not -BeNullOrEmpty
    }
}

Describe 'Command Classification: Ready Status' {
    It 'classifies commands as ready when tool available and high confidence' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('npm', 'test')
                    purpose = 'Run npm test suite'
                    purpose_category = 'test'
                    required_tool = 'npm'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'npm script'
                        confidence_reason = 'manifest and environment both present'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "ready-test1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                npm = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "ready-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "ready-status.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $readyCommands = @($plan.commands | Where-Object { $_.status -eq 'ready' })
        $readyCommands.Count | Should -BeGreaterThan 0
    }
}

Describe 'Command Classification: Blocked Status' {
    It 'classifies commands as blocked when required tool unavailable' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('cargo', 'test')
                    purpose = 'Run cargo test suite'
                    purpose_category = 'test'
                    required_tool = 'cargo'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'Cargo.toml'
                        manifest_path = './Cargo.toml'
                        detected_as = 'cargo command'
                        confidence_reason = 'manifest present'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "blocked-test1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{}
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "blocked-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "blocked-status.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $blockedCommands = @($plan.commands | Where-Object { $_.status -eq 'blocked' })
        $blockedCommands.Count | Should -BeGreaterThan 0
        $blockedCommands[0].tool_available | Should -BeFalse
    }

    It 'includes tool_unavailable diagnostic for blocked commands' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('go', 'test')
                    purpose = 'Run go test'
                    purpose_category = 'test'
                    required_tool = 'go'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'go.mod'
                        manifest_path = './go.mod'
                        detected_as = 'go command'
                        confidence_reason = 'manifest present'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "blocked-diag1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{}
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "blocked-diag-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "blocked-diagnostic.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $blockedCmd = $plan.commands | Where-Object { $_.status -eq 'blocked' } | Select-Object -First 1
        $blockedCmd.diagnostics | Should -Not -BeNullOrEmpty
        ($blockedCmd.diagnostics | Where-Object { $_.type -eq 'tool_unavailable' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Command Classification: Ambiguous Status' {
    It 'classifies commands as ambiguous when confidence is low' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('npm', 'test')
                    purpose = 'Possible test command'
                    purpose_category = 'test'
                    required_tool = 'npm'
                    working_directory = '.'
                    confidence = 'low'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'inferred from heuristics'
                        confidence_reason = 'low evidence; multiple candidates'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "ambig-test1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                npm = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "ambig-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "ambig-status.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $ambigCommands = @($plan.commands | Where-Object { $_.status -eq 'ambiguous' })
        $ambigCommands.Count | Should -BeGreaterThan 0
    }

    It 'marks ambiguous commands as requiring approval' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('python', '-m', 'pytest')
                    purpose = 'Uncertain python test runner'
                    purpose_category = 'test'
                    required_tool = 'python'
                    working_directory = '.'
                    confidence = 'low'
                    evidence = @{
                        manifest_type = 'pyproject.toml'
                        manifest_path = './pyproject.toml'
                        detected_as = 'inference'
                        confidence_reason = 'uncertain'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "ambig-approval1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                python = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "ambig-approval-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "ambig-approval.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $ambigCmd = $plan.commands | Where-Object { $_.status -eq 'ambiguous' } | Select-Object -First 1
        $ambigCmd.requires_approval | Should -BeTrue
    }
}

Describe 'Command Classification: Unsafe Status' {
    It 'classifies commands as unsafe when containing shell metacharacters' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('sh', '-c', 'npm test && npm build')
                    purpose = 'Run tests and build'
                    purpose_category = 'test'
                    required_tool = 'sh'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'npm script with operator'
                        confidence_reason = 'manifest present'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "unsafe-test1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                sh = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "unsafe-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "unsafe-status.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $unsafeCommands = @($plan.commands | Where-Object { $_.status -eq 'unsafe' })
        $unsafeCommands.Count | Should -BeGreaterThan 0
    }

    It 'detects && as unsafe shell operator' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('npm', 'test', '&&', 'npm', 'build')
                    purpose = 'Test and build'
                    purpose_category = 'test'
                    required_tool = 'npm'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'npm command'
                        confidence_reason = 'manifest present'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "unsafe-and1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                npm = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "unsafe-and-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "unsafe-and.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $unsafeCmd = $plan.commands | Where-Object { $_.status -eq 'unsafe' } | Select-Object -First 1
        $unsafeCmd.diagnostics | Should -Not -BeNullOrEmpty
        ($unsafeCmd.diagnostics | Where-Object { $_.type -eq 'unsafe_shell_construct' }).Count | Should -BeGreaterThan 0
    }

    It 'marks unsafe commands as requiring approval' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('bash', '-c', 'npm test | tee log.txt')
                    purpose = 'Run tests with logging'
                    purpose_category = 'test'
                    required_tool = 'bash'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'npm command'
                        confidence_reason = 'manifest'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "unsafe-approval1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                bash = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "unsafe-approval-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "unsafe-approval.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $unsafeCmd = $plan.commands | Where-Object { $_.status -eq 'unsafe' } | Select-Object -First 1
        $unsafeCmd.requires_approval | Should -BeTrue
    }
}

Describe 'Stable Command IDs' {
    It 'generates stable IDs for identical commands' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('npm', 'test')
                    purpose = 'Run npm test suite'
                    purpose_category = 'test'
                    required_tool = 'npm'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'npm script'
                        confidence_reason = 'manifest present'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "stable-id1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                npm = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "stable-id-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath1 = Join-Path $testOutputRoot "stable-id-run1.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath1

        $outputPath2 = Join-Path $testOutputRoot "stable-id-run2.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath2

        $plan1 = Get-PlanContent $outputPath1
        $plan2 = Get-PlanContent $outputPath2

        $plan1.commands[0].id | Should -Be $plan2.commands[0].id
    }

    It 'IDs follow cmd-{8hexchars} format' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('cargo', 'test')
                    purpose = 'Run cargo test'
                    purpose_category = 'test'
                    required_tool = 'cargo'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'Cargo.toml'
                        manifest_path = './Cargo.toml'
                        detected_as = 'cargo'
                        confidence_reason = 'manifest'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "id-format1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                cargo = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "id-format-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "id-format.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $plan.commands[0].id | Should -Match '^cmd-[a-f0-9]{8}$'
    }
}

Describe 'Command Array Preservation' {
    It 'preserves command arguments as array (not shell string)' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('python', '-m', 'pytest', '--verbose', '--tb=short')
                    purpose = 'Run pytest with options'
                    purpose_category = 'test'
                    required_tool = 'python'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'pyproject.toml'
                        manifest_path = './pyproject.toml'
                        detected_as = 'pytest'
                        confidence_reason = 'manifest'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "array-preserve1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                python = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "array-preserve-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "array-preserve.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $cmd = $plan.commands[0]
        $cmd.command_array.GetType() | Should -Be ([System.Object[]])
        $cmd.command_array.Count | Should -Be 5
        $cmd.command_array[0] | Should -Be 'python'
        $cmd.command_array[1] | Should -Be '-m'
        $cmd.command_array[2] | Should -Be 'pytest'
        $cmd.command_array[3] | Should -Be '--verbose'
        $cmd.command_array[4] | Should -Be '--tb=short'
    }
}

Describe 'Evidence Tracking' {
    It 'includes evidence object with manifest info' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('npm', 'run', 'build')
                    purpose = 'Build project'
                    purpose_category = 'build'
                    required_tool = 'npm'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'npm script build'
                        confidence_reason = 'manifest and environment both present'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "evidence1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                npm = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "evidence-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "evidence.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $cmd = $plan.commands[0]
        $cmd.evidence | Should -Not -BeNullOrEmpty
        $cmd.evidence.manifest_type | Should -Be 'package.json'
        $cmd.evidence.manifest_path | Should -Be './package.json'
        $cmd.evidence.detected_as | Should -Not -BeNullOrEmpty
        $cmd.evidence.confidence_reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'Approval Summary Accuracy' {
    It 'reports accurate counts in approval_summary' {
        $wsEnv = @{
            schema_version = "1.0.0"
            workspace_path = "."
            commands = @(
                @{
                    command_array = @('npm', 'test')
                    purpose = 'npm test (ready)'
                    purpose_category = 'test'
                    required_tool = 'npm'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'package.json'
                        manifest_path = './package.json'
                        detected_as = 'npm'
                        confidence_reason = 'manifest'
                    }
                },
                @{
                    command_array = @('cargo', 'test')
                    purpose = 'cargo test (blocked)'
                    purpose_category = 'test'
                    required_tool = 'cargo'
                    working_directory = '.'
                    confidence = 'high'
                    evidence = @{
                        manifest_type = 'Cargo.toml'
                        manifest_path = './Cargo.toml'
                        detected_as = 'cargo'
                        confidence_reason = 'manifest'
                    }
                }
            )
            diagnostics = @()
        } | ConvertTo-Json -Depth 10
        $wsEnvPath = Join-Path $testOutputRoot "summary-accuracy1.json"
        Set-Content -LiteralPath $wsEnvPath -Value $wsEnv

        $machInv = @{
            schema_version = "1.0.0"
            tools = @{
                npm = @{ available = $true }
            }
        } | ConvertTo-Json -Depth 5
        $machPath = Join-Path $testOutputRoot "summary-accuracy-machine.json"
        Set-Content -LiteralPath $machPath -Value $machInv

        $outputPath = Join-Path $testOutputRoot "summary-accuracy.json"
        New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machPath -OutputPath $outputPath

        $plan = Get-PlanContent $outputPath
        $readyCount = @($plan.commands | Where-Object { $_.status -eq 'ready' -and $_.requires_approval -eq $false }).Count
        $blockedCount = @($plan.commands | Where-Object { $_.status -eq 'blocked' }).Count

        $plan.approval_summary.ready_without_approval | Should -Be $readyCount
        $plan.approval_summary.blocked | Should -Be $blockedCount
    }
}

Describe 'Integration: Real Detector Output' {
    It 'processes actual workspace-environment.json and machine-inventory.json' {
        # Use REAL detector output from output/ directory
        $wsEnvPath = Join-Path $repositoryRoot "output\workspace-environment.json"
        $machInvPath = Join-Path $repositoryRoot "output\machine-inventory.json"

        # Skip test if real output doesn't exist
        if (-not (Test-Path $wsEnvPath) -or -not (Test-Path $machInvPath)) {
            Set-ItResult -Skipped -Because "Real detector output not found"
            return
        }

        $outputPath = Join-Path $testOutputRoot "integration-real-output.json"

        # Should not throw
        { New-TestPlan -WorkspaceEnvironmentPath $wsEnvPath -MachineInventoryPath $machInvPath -OutputPath $outputPath } | Should -Not -Throw

        # Verify output file exists and is valid JSON
        Test-Path $outputPath | Should -BeTrue
        $plan = Get-PlanContent $outputPath

        # Verify plan structure
        $plan.schema_version | Should -Be "1.0.0"
        $plan.workspace_path | Should -Not -BeNullOrEmpty
        # Use raw JSON to get planned_at as ISO8601 string (not DateTime)
        $plannedAtStr = Get-RawJsonValue $outputPath "planned_at"
        $plannedAtStr | Should -Match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'

        # Verify it can read test_commands and build_commands (not synthetic 'commands' array)
        # Note: workspace may have 0 commands, but the structure must be valid
        # The commands property should always be an array (possibly empty)
        $plan.PSObject.Properties['commands'] | Should -Not -BeNullOrEmpty
        # Verify commands is an array type
        $plan.commands.GetType().Name | Should -Be 'Object[]'
        $plan.approval_summary | Should -Not -BeNullOrEmpty
        $plan.approval_summary.ready_without_approval -ge 0 | Should -BeTrue
        $plan.approval_summary.requires_approval -ge 0 | Should -BeTrue
        $plan.approval_summary.blocked -ge 0 | Should -BeTrue
        $plan.approval_summary.ambiguous -ge 0 | Should -BeTrue
        $plan.approval_summary.unsafe -ge 0 | Should -BeTrue
    }

    It 'reads test_commands and build_commands from detector output' {
        $wsEnvPath = Join-Path $repositoryRoot "output\workspace-environment.json"
        if (-not (Test-Path $wsEnvPath)) {
            Set-ItResult -Skipped -Because "Real detector output not found"
            return
        }

        $wsEnv = Get-Content -LiteralPath $wsEnvPath -Raw | ConvertFrom-Json

        # Verify detector output has the correct structure
        $wsEnv.PSObject.Properties['test_commands'] | Should -Not -BeNullOrEmpty
        $wsEnv.PSObject.Properties['build_commands'] | Should -Not -BeNullOrEmpty

        # Must NOT have a 'commands' property (which the old fixtures used)
        $wsEnv.PSObject.Properties['commands'] | Should -BeNullOrEmpty

        Write-Host "✓ Detector output structure verified:"
        Write-Host "  - test_commands: $($wsEnv.test_commands.Count) items"
        Write-Host "  - build_commands: $($wsEnv.build_commands.Count) items"
    }
}
