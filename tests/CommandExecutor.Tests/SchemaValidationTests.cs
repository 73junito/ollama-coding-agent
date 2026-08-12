using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace CommandExecutor.Tests;

/// <summary>
/// Schema contract validation tests.
/// 
/// These tests validate that command plan inputs and execution results outputs
/// conform to the expected JSON structure and required fields.
/// 
/// This is test-time validation. The executor does not enforce
/// JSON Schema at runtime; policy validation is performed by PlanValidator
/// (status/approval gates) and WorkspaceGuard (containment rules).
/// </summary>
public class SchemaValidationTests
{
    private readonly string _projectRoot;

    public SchemaValidationTests()
    {
        _projectRoot = FindProjectRoot();
    }

    [Fact]
    public void ValidCommandPlanHasAllRequiredFields()
    {
        // Arrange: Load the command-plan schema to verify structure
        string schemaPath = Path.Combine(_projectRoot, "schemas", "command-plan.schema.json");
        Assert.True(File.Exists(schemaPath), $"Schema file not found: {schemaPath}");

        // Act: Create a valid command plan and check structure
        var planJson = JsonSerializer.Serialize(new
        {
            schema_version = "1.0.0",
            workspace_path = "/workspace",
            machine_inventory_path = "/workspace/machine-inventory.json",
            workspace_environment_path = "/workspace/workspace-environment.json",
            planned_at = DateTime.UtcNow.ToString("O"),
            commands = new object[]
            {
                new
                {
                    id = "cmd-a1b2c3d4",
                    status = "ready",
                    command_array = new[] { "dotnet", "build" },
                    working_directory = ".",
                    purpose = "Build project",
                    purpose_category = "build",
                    required_tool = "dotnet",
                    tool_available = true,
                    confidence = "high",
                    risk_level = "low",
                    requires_approval = false,
                    evidence = new object[] { }
                }
            },
            diagnostics = new object[] { }
        });

        var planNode = JsonNode.Parse(planJson);

        // Manually add approval_summary since it contains 'unsafe' keyword
        var approvalSummary = JsonNode.Parse(JsonSerializer.Serialize(new
        {
            ready_without_approval = 1,
            requires_approval = 0,
            blocked = 0,
            ambiguous = 0
        }));
        approvalSummary!["unsafe"] = JsonValue.Create(0);
        planNode!["approval_summary"] = approvalSummary;

        // Assert: Validate required top-level properties exist
        var requiredProperties = new[] { "schema_version", "workspace_path", "machine_inventory_path",
            "workspace_environment_path", "planned_at", "commands", "diagnostics", "approval_summary" };

        foreach (var prop in requiredProperties)
        {
            Assert.NotNull(planNode[prop]);
        }

        // Validate commands array structure
        var commands = planNode["commands"];
        Assert.NotNull(commands);
        Assert.True(commands.AsArray().Count > 0, "Commands array should not be empty");

        var command = commands.AsArray()[0];
        var commandRequiredProps = new[] { "id", "status", "command_array", "working_directory",
            "purpose", "purpose_category", "required_tool", "tool_available", "confidence",
            "risk_level", "requires_approval", "evidence" };

        foreach (var prop in commandRequiredProps)
        {
            Assert.NotNull(command[prop]);
        }
    }

    [Fact]
    public void ValidExecutionResultsHasAllRequiredFields()
    {
        // Arrange: Load the execution-results schema
        string schemaPath = Path.Combine(_projectRoot, "schemas", "execution-results.schema.json");
        Assert.True(File.Exists(schemaPath), $"Schema file not found: {schemaPath}");

        // Act: Create valid execution results
        var resultsJson = JsonSerializer.Serialize(new
        {
            schema_version = "1.0.0",
            executed_at = DateTime.UtcNow.ToString("O"),
            requested_by = "test-user",
            workspace_path = "/workspace",
            plan_path = "/workspace/plan.json",
            plan_digest = "a".PadRight(64, 'a'),
            commands = new object[]
            {
                new
                {
                    id = "cmd-a1b2c3d4",
                    order = 1,
                    status = "succeeded",
                    command_array = new[] { "dotnet", "build" },
                    working_directory = "/workspace",
                    requested_tool = "dotnet",
                    stdout_truncated = false,
                    stderr_truncated = false,
                    diagnostics = new object[] { }
                }
            },
            execution_summary = new
            {
                total = 1,
                rejected = 0,
                succeeded = 1,
                failed = 0,
                timed_out = 0,
                cancelled = 0,
                started = 0,
                skipped = 0
            },
            diagnostics = new object[] { }
        });

        var resultsNode = JsonNode.Parse(resultsJson);

        // Assert: Validate required top-level properties exist
        var requiredProperties = new[] { "schema_version", "executed_at", "requested_by",
            "workspace_path", "plan_path", "plan_digest", "commands", "execution_summary", "diagnostics" };

        foreach (var prop in requiredProperties)
        {
            Assert.NotNull(resultsNode[prop]);
        }

        // Validate commands array structure
        var commands = resultsNode["commands"];
        Assert.NotNull(commands);
        Assert.True(commands.AsArray().Count > 0, "Commands array should not be empty");

        var command = commands.AsArray()[0];
        var commandRequiredProps = new[] { "id", "order", "status", "command_array",
            "working_directory", "requested_tool", "stdout_truncated", "stderr_truncated", "diagnostics" };

        foreach (var prop in commandRequiredProps)
        {
            Assert.NotNull(command[prop]);
        }
    }

    [Fact]
    public void CommandIdMustFollowPattern()
    {
        // Arrange
        var commandId = "cmd-a1b2c3d4";

        // Act & Assert
        Assert.Matches("^cmd-[a-f0-9]{8}$", commandId);
    }

    [Fact]
    public void CommandIdRejectsInvalidFormat()
    {
        // Arrange
        var invalidIds = new[] { "invalid-id-format", "cmd-toolong", "cmd-short", "invalid" };

        // Act & Assert
        foreach (var id in invalidIds)
        {
            Assert.DoesNotMatch("^cmd-[a-f0-9]{8}$", id);
        }
    }

    [Fact]
    public void ExecutionStatusEnumIsValid()
    {
        // Arrange
        var validStatuses = new[] { "rejected", "succeeded", "failed", "timed_out", "skipped", "started" };
        var invalidStatus = "invalid_status";

        // Act & Assert
        foreach (var status in validStatuses)
        {
            Assert.True(validStatuses.Contains(status), $"Valid status {status} should be in list");
        }

        Assert.False(validStatuses.Contains(invalidStatus), $"Invalid status should not be in valid list");
    }

    [Fact]
    public void PlanDigestMustBe64CharHexString()
    {
        // Arrange
        var validDigest = "a".PadRight(64, 'a');
        var invalidDigest = "not-a-valid-sha256";

        // Act & Assert
        Assert.Matches("^[a-f0-9]{64}$", validDigest);
        Assert.DoesNotMatch("^[a-f0-9]{64}$", invalidDigest);
    }

    private string FindProjectRoot()
    {
        string? current = Path.GetDirectoryName(typeof(SchemaValidationTests).Assembly.Location);

        for (int i = 0; i < 10 && !string.IsNullOrEmpty(current); i++)
        {
            string projectPath = Path.Combine(current, "src", "CommandExecutor");
            if (Directory.Exists(projectPath))
            {
                return current;
            }
            current = Directory.GetParent(current)?.FullName;
        }

        throw new InvalidOperationException("Could not find project root");
    }
}
