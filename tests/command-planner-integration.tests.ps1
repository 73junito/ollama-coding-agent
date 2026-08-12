BeforeAll {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $detectorScript = Join-Path $repositoryRoot "tools\workspace-environment.ps1"
    $plannerScript = Join-Path $repositoryRoot "tools\command-planner.ps1"
    $machineInventoryTemplate = Join-Path $repositoryRoot "output\machine-inventory.json"
    $testOutputRoot = Join-Path $TestDrive "command-planner-integration"

    New-Item -ItemType Directory -Path $testOutputRoot -Force | Out-Null

    # Helper to create a temporary workspace with test/build scripts
    function New-TestWorkspaceWithScripts {
        param(
            [string]$Name = "workspace",
            [hashtable]$Scripts = @{},
            [hashtable]$Tools = @{}
        )

        $workspacePath = Join-Path $testOutputRoot $Name
        New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null

        # Create package.json with optional scripts
        $packageJson = @{
            name = "test-app"
            version = "1.0.0"
        }

        if ($Scripts.Count -gt 0) {
            $packageJson.scripts = $Scripts
        }

        $packageJsonPath = Join-Path $workspacePath "package.json"
        $packageJson | ConvertTo-Json | Set-Content -LiteralPath $packageJsonPath -Encoding utf8

        # Create machine inventory with specified tool availability
        $machineInventory = @{
            schema_version = "1.0.0"
            machine_id = "test-machine-$([guid]::NewGuid())"
            timestamp = [DateTime]::UtcNow.ToString('o')
            tools = @{}
        }

        foreach ($toolName in $Tools.Keys) {
            $machineInventory.tools[$toolName] = @{
                available = $Tools[$toolName]
                version = "1.0.0"
            }
        }

        $machineInvPath = Join-Path $workspacePath "machine-inventory.json"
        $machineInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $machineInvPath -Encoding utf8

        return @{
            workspace = $workspacePath
            machineInventory = $machineInvPath
        }
    }

    # Helper to run detector and planner together
    function Invoke-DetectorAndPlanner {
        param(
            [Parameter(Mandatory)]
            [string]$WorkspacePath,
            [Parameter(Mandatory)]
            [string]$MachineInventoryPath,
            [string]$TestName = "integration-test"
        )

        $detectorOutput = Join-Path $testOutputRoot "detector-$TestName.json"
        $plannerOutput = Join-Path $testOutputRoot "plan-$TestName.json"

        # Run detector
        & $detectorScript `
            -WorkspacePath $WorkspacePath `
            -MachineInventoryPath $MachineInventoryPath `
            -OutputPath $detectorOutput -ErrorAction Stop | Out-Null

        # Run planner
        & $plannerScript `
            -WorkspaceEnvironmentPath $detectorOutput `
            -MachineInventoryPath $MachineInventoryPath `
            -OutputPath $plannerOutput -ErrorAction Stop | Out-Null

        return @{
            detector = $detectorOutput
            planner = $plannerOutput
        }
    }

    # Helper to run planner with mocked detector output
    function Invoke-PlannerWithMockedDetector {
        param(
            [Parameter(Mandatory)]
            [object[]]$Commands,  # Array of commands to include
            [Parameter(Mandatory)]
            [hashtable]$Tools,
            [string]$TestName = "mocked-test"
        )

        $detectorOutput = Join-Path $testOutputRoot "detector-$TestName.json"
        $plannerOutput = Join-Path $testOutputRoot "plan-$TestName.json"

        # Create mocked detector output
        $mockDetector = [PSCustomObject]@{
            schema_version = "1.0.0"
            workspace_path = "C:\test\workspace"
            analyzed_at = [DateTime]::UtcNow.ToString('o')
            ecosystems = @("test")
            manifests = @()
            virtual_environments = @()
            package_managers = @()
            test_commands = @($Commands)
            build_commands = @()
            tool_availability = [PSCustomObject]@{}
            diagnostics = @()
        }

        $mockDetector | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $detectorOutput -Encoding utf8

        # Create machine inventory
        $machineInventory = @{
            schema_version = "1.0.0"
            machine_id = "test-machine-$([guid]::NewGuid())"
            timestamp = [DateTime]::UtcNow.ToString('o')
            tools = @{}
        }

        foreach ($toolName in $Tools.Keys) {
            $machineInventory.tools[$toolName] = @{
                available = $Tools[$toolName]
                version = "1.0.0"
            }
        }

        $machineInvPath = Join-Path $testOutputRoot "mocked-machine-inventory-$TestName.json"
        $machineInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $machineInvPath -Encoding utf8

        # Run planner
        & $plannerScript `
            -WorkspaceEnvironmentPath $detectorOutput `
            -MachineInventoryPath $machineInvPath `
            -OutputPath $plannerOutput -ErrorAction Stop | Out-Null

        return @{
            detector = $detectorOutput
            planner = $plannerOutput
        }
    }

    $script:RepositoryRoot = $repositoryRoot
    $script:DetectorScript = $detectorScript
    $script:PlannerScript = $plannerScript
    $script:TestOutputRoot = $testOutputRoot
}

Describe "Command Planner Integration: Real Detector Output" {

    Context "Nonempty command sets" {
        It "processes nonempty test_commands from detector" {
            $workspace = New-TestWorkspaceWithScripts -Name "nonempty-test" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $result = Invoke-DetectorAndPlanner `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -TestName "nonempty-test"

            $detector = Get-Content -LiteralPath $result.detector -Raw | ConvertFrom-Json
            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            # Verify detector output contains test_commands
            $detector.test_commands.Count | Should -BeGreaterThan 0

            # Verify planner received and processed commands
            $plan.commands.Count | Should -BeGreaterThan 0
        }

        It "processes nonempty build_commands from detector" {
            $workspace = New-TestWorkspaceWithScripts -Name "nonempty-build" -Scripts @{
                build = "tsc"
            } -Tools @{
                npm = $true
                tsc = $true
            }

            $result = Invoke-DetectorAndPlanner `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -TestName "nonempty-build"

            $detector = Get-Content -LiteralPath $result.detector -Raw | ConvertFrom-Json
            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            $detector.build_commands.Count | Should -BeGreaterThan 0
            $plan.commands.Count | Should -BeGreaterThan 0
        }

        It "emits both test_commands and build_commands when both exist" {
            $workspace = New-TestWorkspaceWithScripts -Name "both-commands" -Scripts @{
                test = "jest"
                build = "tsc"
            } -Tools @{
                npm = $true
                jest = $true
                tsc = $true
            }

            $result = Invoke-DetectorAndPlanner `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -TestName "both-commands"

            $detector = Get-Content -LiteralPath $result.detector -Raw | ConvertFrom-Json
            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            $detector.test_commands.Count | Should -BeGreaterThan 0
            $detector.build_commands.Count | Should -BeGreaterThan 0
            $plan.commands.Count | Should -Be ($detector.test_commands.Count + $detector.build_commands.Count)
        }
    }

    Context "Tool availability safety" {
        It "tool with available:false produces blocked status" {
            $mockCmd = [PSCustomObject]@{
                command = "jest"
                ecosystem = "node"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($mockCmd) `
                -Tools @{ jest = $false } `
                -TestName "tool-unavailable"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            # Should have blocked command
            $blockedCommands = @($plan.commands | Where-Object { $_.status -eq 'blocked' })
            $blockedCommands.Count | Should -BeGreaterThan 0
        }

        It "unsafe status does not change available tool to unavailable" {
            $mockCmd = [PSCustomObject]@{
                command = "npm && npm"
                ecosystem = "node"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($mockCmd) `
                -Tools @{ npm = $true } `
                -TestName "unsafe-available-tool"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            # Should have unsafe command
            $unsafeCommands = @($plan.commands | Where-Object { $_.status -eq 'unsafe' })
            $unsafeCommands.Count | Should -BeGreaterThan 0

            # But tool should still show as available
            $unsafeCommands[0].tool_available | Should -BeTrue
        }

        It "blocked command requires approval even though tool is unavailable" {
            $mockCmd = [PSCustomObject]@{
                command = "pytest"
                ecosystem = "python"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($mockCmd) `
                -Tools @{ pytest = $false } `
                -TestName "blocked-approval"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            $blockedCommands = @($plan.commands | Where-Object { $_.status -eq 'blocked' })
            $blockedCommands.Count | Should -BeGreaterThan 0

            # All blocked commands should require approval
            foreach ($blocked in $blockedCommands) {
                $blocked.requires_approval | Should -BeTrue
            }

            # Approval summary should count blocked correctly
            $plan.approval_summary.blocked | Should -Be $blockedCommands.Count
        }
    }

    Context "Unsafe pattern detection" {
        It "detects embedded shell operators (&&) as unsafe" {
            $mockCmd = [PSCustomObject]@{
                command = "npm && npm"
                ecosystem = "node"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($mockCmd) `
                -Tools @{ npm = $true } `
                -TestName "unsafe-and"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            $unsafeCommands = @($plan.commands | Where-Object { $_.status -eq 'unsafe' })
            $unsafeCommands.Count | Should -BeGreaterThan 0

            # Verify diagnostic contains the unsafe pattern
            $unsafeCmd = $unsafeCommands[0]
            $unsafeCmd.diagnostics | Where-Object { $_.type -eq 'unsafe_shell_construct' } | Should -Not -BeNullOrEmpty
        }

        It "detects piping operator (|) as unsafe" {
            $mockCmd = [PSCustomObject]@{
                command = "grep something | sed transform"
                ecosystem = "shell"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($mockCmd) `
                -Tools @{ grep = $true; sed = $true } `
                -TestName "unsafe-pipe"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            $unsafeCommands = @($plan.commands | Where-Object { $_.status -eq 'unsafe' })
            $unsafeCommands.Count | Should -BeGreaterThan 0
        }

        It "detects parent directory traversal (../outside) as unsafe" {
            $mockCmd = [PSCustomObject]@{
                command = "cp ../outside/secret.txt ."
                ecosystem = "shell"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($mockCmd) `
                -Tools @{ cp = $true } `
                -TestName "unsafe-traversal"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            $unsafeCommands = @($plan.commands | Where-Object { $_.status -eq 'unsafe' })
            $unsafeCommands.Count | Should -BeGreaterThan 0

            $unsafeCmd = $unsafeCommands[0]
            $unsafeCmd.diagnostics | Where-Object { $_.type -eq 'unresolved_path' -and $_.pattern -match '\.\.' } | Should -Not -BeNullOrEmpty
        }

        It "commands with quoted arguments must be marked ambiguous or unsafe (legacy tokenization)" {
            # String tokenization with -split '\s+' does not preserve quoted arguments
            # npm run test -- --name "engine control" becomes ["npm", "run", "test", "--", "--name", "\"engine", "control\""]
            # Such commands should not be marked ready to warn about potential argument loss
            $mockCmd = [PSCustomObject]@{
                command = 'npm run test -- --name "engine control"'
                ecosystem = "node"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($mockCmd) `
                -Tools @{ npm = $true } `
                -TestName "quoted-arguments"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            # Command must not be marked ready; should be ambiguous or unsafe
            $readyCommands = @($plan.commands | Where-Object { $_.status -eq 'ready' })
            $readyCommands.Count | Should -Be 0

            # Should be marked as ambiguous or unsafe
            $nonReadyCommands = @($plan.commands | Where-Object { $_.status -in @('ambiguous', 'unsafe') })
            $nonReadyCommands.Count | Should -BeGreaterThan 0
        }
    }

    Context "Argument array collision detection" {
        It "different argument arrays do not collide (test 1)" {
            # Two commands with different argument parsing should have different IDs
            $cmd1 = [PSCustomObject]@{
                command = "tool a b c"
                ecosystem = "test"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $cmd2 = [PSCustomObject]@{
                command = "tool a b"
                ecosystem = "test"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($cmd1, $cmd2) `
                -Tools @{ tool = $true } `
                -TestName "no-collision-1"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            # Should have both commands
            $plan.commands.Count | Should -Be 2

            # IDs should be unique
            $id1 = $plan.commands[0].id
            $id2 = $plan.commands[1].id
            $id1 | Should -Not -Be $id2
        }

        It "different argument arrays do not collide (test 2)" {
            # Different tool names with same args should have different IDs
            $cmd1 = [PSCustomObject]@{
                command = "tool1 arg1 arg2"
                ecosystem = "test"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $cmd2 = [PSCustomObject]@{
                command = "tool2 arg1 arg2"
                ecosystem = "test"
                confidence = "high"
                evidence = @()
                inferred_from = @()
            }

            $result = Invoke-PlannerWithMockedDetector `
                -Commands @($cmd1, $cmd2) `
                -Tools @{ tool1 = $true; tool2 = $true } `
                -TestName "no-collision-2"

            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            $id1 = $plan.commands[0].id
            $id2 = $plan.commands[1].id
            $id1 | Should -Not -Be $id2
        }
    }

    Context "Timestamp validation" {
        It "invalid PlannedAt terminates before generating output" {
            $workspace = New-TestWorkspaceWithScripts -Name "invalid-timestamp" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $detectorOutput = Join-Path $testOutputRoot "detector-invalid-ts.json"

            & $detectorScript `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $detectorOutput -ErrorAction Stop | Out-Null

            $plannerOutput = Join-Path $testOutputRoot "plan-invalid-ts.json"

            # Invalid timestamp should cause error
            { & $plannerScript `
                -WorkspaceEnvironmentPath $detectorOutput `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $plannerOutput `
                -PlannedAt "not-a-timestamp" `
                -ErrorAction Stop
            } | Should -Throw

            # Output file should NOT exist
            Test-Path $plannerOutput | Should -BeFalse
        }

        It "valid ISO8601 PlannedAt is accepted" {
            $workspace = New-TestWorkspaceWithScripts -Name "valid-timestamp" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $detectorOutput = Join-Path $testOutputRoot "detector-valid-ts.json"

            & $detectorScript `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $detectorOutput -ErrorAction Stop | Out-Null

            $plannerOutput = Join-Path $testOutputRoot "plan-valid-ts.json"
            $validTimestamp = "2026-08-12T10:30:00Z"

            { & $plannerScript `
                -WorkspaceEnvironmentPath $detectorOutput `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $plannerOutput `
                -PlannedAt $validTimestamp `
                -ErrorAction Stop
            } | Should -Not -Throw

            Test-Path $plannerOutput | Should -BeTrue
        }
    }

    Context "Output path handling" {
        It "bare output filename (no directory) is rejected" {
            $workspace = New-TestWorkspaceWithScripts -Name "bare-filename" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $detectorOutput = Join-Path $testOutputRoot "detector-bare.json"

            & $detectorScript `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $detectorOutput -ErrorAction Stop | Out-Null

            # Bare filename without directory should fail
            { & $plannerScript `
                -WorkspaceEnvironmentPath $detectorOutput `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath "plan.json" `
                -ErrorAction Stop
            } | Should -Throw
        }

        It "output path with directory is accepted" {
            $workspace = New-TestWorkspaceWithScripts -Name "with-directory" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $detectorOutput = Join-Path $testOutputRoot "detector-with-dir.json"

            & $detectorScript `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $detectorOutput -ErrorAction Stop | Out-Null

            $subdir = Join-Path $testOutputRoot "subdir"
            $plannerOutput = Join-Path $subdir "plan.json"

            { & $plannerScript `
                -WorkspaceEnvironmentPath $detectorOutput `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $plannerOutput `
                -ErrorAction Stop
            } | Should -Not -Throw

            Test-Path $plannerOutput | Should -BeTrue
        }
    }

    Context "Medium-confidence approval behavior" {
        It "medium-confidence commands require approval" {
            # Create workspace without node_modules to reduce confidence
            $workspace = New-TestWorkspaceWithScripts -Name "medium-confidence" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $result = Invoke-DetectorAndPlanner `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -TestName "medium-confidence"

            $detector = Get-Content -LiteralPath $result.detector -Raw | ConvertFrom-Json
            $plan = Get-Content -LiteralPath $result.planner -Raw | ConvertFrom-Json

            # Find medium confidence commands
            $mediumConf = @($detector.test_commands | Where-Object { $_.confidence -eq 'medium' })

            if ($mediumConf.Count -gt 0) {
                # These should be marked ambiguous/requiring approval in the plan
                $ambiguous = @($plan.commands | Where-Object { $_.status -eq 'ambiguous' })
                $ambiguous.Count | Should -BeGreaterThan 0

                foreach ($amb in $ambiguous) {
                    $amb.requires_approval | Should -BeTrue
                }
            }
        }
    }

    Context "Malformed input handling" {
        It "missing workspace_environment.json terminates with error" {
            $workspace = New-TestWorkspaceWithScripts -Name "missing-input" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $nonexistentDetectorOutput = Join-Path $testOutputRoot "does-not-exist.json"
            $plannerOutput = Join-Path $testOutputRoot "plan-missing-input.json"

            { & $plannerScript `
                -WorkspaceEnvironmentPath $nonexistentDetectorOutput `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $plannerOutput `
                -ErrorAction Stop
            } | Should -Throw

            # Output should not exist
            Test-Path $plannerOutput | Should -BeFalse
        }

        It "missing machine-inventory.json terminates with error" {
            $workspace = New-TestWorkspaceWithScripts -Name "missing-inventory" -Scripts @{
                test = "jest"
            } -Tools @{
                npm = $true
                jest = $true
            }

            $detectorOutput = Join-Path $testOutputRoot "detector-missing-inventory.json"

            & $detectorScript `
                -WorkspacePath $workspace.workspace `
                -MachineInventoryPath $workspace.machineInventory `
                -OutputPath $detectorOutput -ErrorAction Stop | Out-Null

            $nonexistentMachineInventory = Join-Path $testOutputRoot "does-not-exist-inventory.json"
            $plannerOutput = Join-Path $testOutputRoot "plan-missing-inventory.json"

            { & $plannerScript `
                -WorkspaceEnvironmentPath $detectorOutput `
                -MachineInventoryPath $nonexistentMachineInventory `
                -OutputPath $plannerOutput `
                -ErrorAction Stop
            } | Should -Throw

            Test-Path $plannerOutput | Should -BeFalse
        }

        It "malformed JSON in workspace_environment terminates with error" {
            $malformedDetectorOutput = Join-Path $testOutputRoot "malformed-detector.json"
            Set-Content -LiteralPath $malformedDetectorOutput -Value "{ invalid json }" -Encoding utf8

            $machineInv = Join-Path $testOutputRoot "mocked-machine-inventory.json"
            @{
                schema_version = "1.0.0"
                machine_id = "test"
                timestamp = [DateTime]::UtcNow.ToString('o')
                tools = @{}
            } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $machineInv -Encoding utf8

            $plannerOutput = Join-Path $testOutputRoot "plan-malformed-detector.json"

            { & $plannerScript `
                -WorkspaceEnvironmentPath $malformedDetectorOutput `
                -MachineInventoryPath $machineInv `
                -OutputPath $plannerOutput `
                -ErrorAction Stop
            } | Should -Throw

            Test-Path $plannerOutput | Should -BeFalse
        }
    }
}
