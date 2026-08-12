using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using Xunit;

namespace CommandExecutor.Tests;

public class PolicyTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _workspaceRoot;
    private readonly string _planPath;
    private readonly string _resultsPath;

    public PolicyTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"CommandExecutor.Tests-{Guid.NewGuid()}");
        _workspaceRoot = _tempDir;
        _planPath = Path.Combine(_tempDir, "command-plan.json");
        _resultsPath = Path.Combine(_tempDir, "execution-results.json");

        Directory.CreateDirectory(_tempDir);
    }

    private void CreatePlan(List<CommandData> commands)
    {
        var plan = new
        {
            schema_version = "1.0.0",
            workspace_path = _workspaceRoot,
            machine_inventory_path = "",
            workspace_environment_path = "",
            planned_at = DateTime.UtcNow.ToString("o"),
            commands,
            diagnostics = new List<object>(),
            approval_summary = new { }
        };

        var json = JsonSerializer.Serialize(plan, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(_planPath, json);
    }

    [Fact]
    public void RejectUnknownCommandId()
    {
        // Arrange
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-abc12345",
                status = "ready",
                command_array = new[] { "echo", "test" },
                working_directory = ".",
                purpose = "Test",
                purpose_category = "test",
                required_tool = "echo",
                tool_available = true,
                confidence = "high",
                risk_level = "low",
                requires_approval = false,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Request non-existent command ID
        var result = ExecuteCommand(new[] { "cmd-unknown" });

        // Assert: Result should have rejection_reason for unknown_id
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("rejected", result.commands[0].status);
        Assert.Equal("unknown_id", result.commands[0].rejection_reason);
    }

    [Fact]
    public void RejectBlockedCommand()
    {
        // Arrange
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-blk12345",
                status = "blocked",
                command_array = new[] { "cargo", "test" },
                working_directory = ".",
                purpose = "Build test",
                purpose_category = "test",
                required_tool = "cargo",
                tool_available = false,
                confidence = "high",
                risk_level = "low",
                requires_approval = true,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Request blocked command
        var result = ExecuteCommand(new[] { "cmd-blk12345" });

        // Assert: Should be rejected
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("rejected", result.commands[0].status);
    }

    [Fact]
    public void RejectAmbiguousCommand()
    {
        // Arrange
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-amb12345",
                status = "ambiguous",
                command_array = new[] { "npm", "test" },
                working_directory = ".",
                purpose = "Test (ambiguous)",
                purpose_category = "test",
                required_tool = "npm",
                tool_available = true,
                confidence = "low",
                risk_level = "low",
                requires_approval = true,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Request ambiguous command
        var result = ExecuteCommand(new[] { "cmd-amb12345" });

        // Assert: Should be rejected
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("rejected", result.commands[0].status);
    }

    [Fact]
    public void RejectUnsafeCommand()
    {
        // Arrange
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-uns12345",
                status = "unsafe",
                command_array = new[] { "rm", "-rf", "/" },
                working_directory = ".",
                purpose = "Dangerous",
                purpose_category = "other",
                required_tool = "rm",
                tool_available = true,
                confidence = "high",
                risk_level = "high",
                requires_approval = true,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Request unsafe command
        var result = ExecuteCommand(new[] { "cmd-uns12345" });

        // Assert: Should be rejected
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("rejected", result.commands[0].status);
    }

    [Fact]
    public void RejectReadyCommandWithApprovalRequired()
    {
        // Arrange
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-app12345",
                status = "ready",
                command_array = new[] { "echo", "test" },
                working_directory = ".",
                purpose = "Needs approval",
                purpose_category = "test",
                required_tool = "echo",
                tool_available = true,
                confidence = "high",
                risk_level = "low",
                requires_approval = true,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Request ready command with requires_approval=true
        var result = ExecuteCommand(new[] { "cmd-app12345" });

        // Assert: Should be rejected
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("rejected", result.commands[0].status);
        Assert.Equal("requires_approval_true", result.commands[0].rejection_reason);
    }

    [Fact]
    public void PreserveArgumentsWithSpaces()
    {
        // Arrange: Command with argument containing spaces
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-spa12345",
                status = "ready",
                command_array = new[] { "cmd", "/c", "echo", "hello world" },
                working_directory = ".",
                purpose = "Spaces in args",
                purpose_category = "test",
                required_tool = "cmd",
                tool_available = true,
                confidence = "high",
                risk_level = "low",
                requires_approval = false,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Execute command with spaces in arguments
        var result = ExecuteCommand(new[] { "cmd-spa12345" });

        // Assert: Arguments should be preserved as array, "hello world" as one element
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("succeeded", result.commands[0].status);
        Assert.NotNull(result.commands[0].command_array);
        // The original command_array should preserve the 4 elements
        Assert.Equal(4, result.commands[0].command_array.Count);
        Assert.Equal("hello world", result.commands[0].command_array[3]);
    }

    [Fact]
    public void RejectDirectoryOutsideWorkspace()
    {
        // Arrange: Command with working directory outside workspace
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-trav1234",
                status = "ready",
                command_array = new[] { "echo", "test" },
                working_directory = "../../../../etc",  // Traversal attempt
                purpose = "Traversal",
                purpose_category = "test",
                required_tool = "echo",
                tool_available = true,
                confidence = "high",
                risk_level = "low",
                requires_approval = false,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Execute command with traversal directory
        var result = ExecuteCommand(new[] { "cmd-trav1234" });

        // Assert: Should be rejected with containment violation
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("rejected", result.commands[0].status);
        Assert.Equal("workspace_containment_violation", result.commands[0].rejection_reason);
    }

    [Fact]
    public void CaptureStdoutStderrAndExitCode()
    {
        // Arrange: Simple command that produces output
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-cap12345",
                status = "ready",
                command_array = new[] { "cmd", "/c", "echo output & echo error 1>&2 & exit 42" },
                working_directory = ".",
                purpose = "Capture test",
                purpose_category = "test",
                required_tool = "cmd",
                tool_available = true,
                confidence = "high",
                risk_level = "low",
                requires_approval = false,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Execute command
        var result = ExecuteCommand(new[] { "cmd-cap12345" });

        // Assert: Should capture output and exit code
        Assert.NotNull(result);
        Assert.Single(result.commands);
        var cmd = result.commands[0];
        Assert.NotNull(cmd.stdout);
        Assert.True(cmd.stdout.Length > 0, "Should capture stdout");
        Assert.NotNull(cmd.stderr);
        Assert.True(cmd.stderr.Length > 0, "Should capture stderr");
        Assert.Equal(42, cmd.exit_code);
    }

    [Fact]
    public void TimeoutAndTerminateProcessTree()
    {
        // Arrange: Long-running command
        var plan = new List<CommandData>
        {
            new() {
                id = "cmd-tim12345",
                status = "ready",
                command_array = new[] { "cmd", "/c", "timeout /t 100" },
                working_directory = ".",
                purpose = "Timeout test",
                purpose_category = "test",
                required_tool = "cmd",
                tool_available = true,
                confidence = "high",
                risk_level = "low",
                requires_approval = false,
                evidence = new List<object>()
            }
        };
        CreatePlan(plan);

        // Act: Execute with short timeout (2 seconds)
        var result = ExecuteCommand(new[] { "cmd-tim12345", "--timeout-seconds", "2" });

        // Assert: Should timeout and terminate
        Assert.NotNull(result);
        Assert.Single(result.commands);
        Assert.Equal("timed_out", result.commands[0].status);
        Assert.True(result.commands[0].duration_ms > 0, "Should record duration");
    }

    private ExecutionResults? ExecuteCommand(string[] cmdIds)
    {
        // Build command line
        var args = new List<string>
        {
            "dotnet", "run", "--project", "src/CommandExecutor",
            "--",
            "--plan", _planPath,
            "--output", _resultsPath,
            "--requested-by", "xunit-test",
            "--timeout-seconds", "30"
        };
        args.AddRange(cmdIds.SelectMany(id => new[] { "--command-id", id }));

        var psi = new ProcessStartInfo
        {
            FileName = "dotnet",
            Arguments = string.Join(" ", args.Skip(1).Select(arg => 
                arg.Contains(" ") ? $"\"{arg}\"" : arg)),
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        try
        {
            using (var proc = Process.Start(psi))
            {
                proc?.WaitForExit(10000);
                
                if (!File.Exists(_resultsPath))
                    return null;

                var json = File.ReadAllText(_resultsPath);
                return JsonSerializer.Deserialize<ExecutionResults>(json,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            }
        }
        catch
        {
            return null;
        }
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tempDir))
                Directory.Delete(_tempDir, true);
        }
        catch { }
    }
}

// JSON DTOs
public class CommandData
{
    public string id { get; set; } = "";
    public string status { get; set; } = "";
    public string[] command_array { get; set; } = Array.Empty<string>();
    public string working_directory { get; set; } = ".";
    public string purpose { get; set; } = "";
    public string purpose_category { get; set; } = "";
    public string required_tool { get; set; } = "";
    public bool tool_available { get; set; }
    public string confidence { get; set; } = "";
    public string risk_level { get; set; } = "";
    public bool requires_approval { get; set; }
    public List<object> evidence { get; set; } = new();
}

public class ExecutionResults
{
    [JsonPropertyName("schema_version")]
    public string SchemaVersion { get; set; } = "";

    [JsonPropertyName("executed_at")]
    public string ExecutedAt { get; set; } = "";

    [JsonPropertyName("requested_by")]
    public string RequestedBy { get; set; } = "";

    [JsonPropertyName("workspace_path")]
    public string WorkspacePath { get; set; } = "";

    [JsonPropertyName("plan_path")]
    public string PlanPath { get; set; } = "";

    [JsonPropertyName("plan_digest")]
    public string PlanDigest { get; set; } = "";

    [JsonPropertyName("commands")]
    public List<CommandResult> commands { get; set; } = new();

    [JsonPropertyName("execution_summary")]
    public ExecutionSummary execution_summary { get; set; } = new();

    [JsonPropertyName("diagnostics")]
    public List<object> diagnostics { get; set; } = new();
}

public class CommandResult
{
    [JsonPropertyName("id")]
    public string id { get; set; } = "";

    [JsonPropertyName("order")]
    public int order { get; set; }

    [JsonPropertyName("status")]
    public string status { get; set; } = "";

    [JsonPropertyName("command_array")]
    public List<string> command_array { get; set; } = new();

    [JsonPropertyName("working_directory")]
    public string working_directory { get; set; } = "";

    [JsonPropertyName("requested_tool")]
    public string requested_tool { get; set; } = "";

    [JsonPropertyName("rejection_reason")]
    public string? rejection_reason { get; set; }

    [JsonPropertyName("executed_at")]
    public string? executed_at { get; set; }

    [JsonPropertyName("finished_at")]
    public string? finished_at { get; set; }

    [JsonPropertyName("duration_ms")]
    public int? duration_ms { get; set; }

    [JsonPropertyName("exit_code")]
    public int? exit_code { get; set; }

    [JsonPropertyName("stdout")]
    public string? stdout { get; set; }

    [JsonPropertyName("stdout_truncated")]
    public bool stdout_truncated { get; set; }

    [JsonPropertyName("stderr")]
    public string? stderr { get; set; }

    [JsonPropertyName("stderr_truncated")]
    public bool stderr_truncated { get; set; }

    [JsonPropertyName("diagnostics")]
    public List<object> diagnostics { get; set; } = new();
}

public class ExecutionSummary
{
    [JsonPropertyName("total")]
    public int total { get; set; }

    [JsonPropertyName("rejected")]
    public int rejected { get; set; }

    [JsonPropertyName("succeeded")]
    public int succeeded { get; set; }

    [JsonPropertyName("failed")]
    public int failed { get; set; }

    [JsonPropertyName("timed_out")]
    public int timed_out { get; set; }

    [JsonPropertyName("cancelled")]
    public int cancelled { get; set; }

    [JsonPropertyName("started")]
    public int started { get; set; }

    [JsonPropertyName("skipped")]
    public int skipped { get; set; }
}
