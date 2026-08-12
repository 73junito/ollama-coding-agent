using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace CommandExecutor;

// Input Models (from command-plan.json)

public class CommandPlan
{
    [JsonPropertyName("schema_version")]
    public string SchemaVersion { get; set; } = "";

    [JsonPropertyName("workspace_path")]
    public string WorkspacePath { get; set; } = "";

    [JsonPropertyName("machine_inventory_path")]
    public string MachineInventoryPath { get; set; } = "";

    [JsonPropertyName("workspace_environment_path")]
    public string WorkspaceEnvironmentPath { get; set; } = "";

    [JsonPropertyName("planned_at")]
    public string PlannedAt { get; set; } = "";

    [JsonPropertyName("commands")]
    public List<PlannedCommand> Commands { get; set; } = new();

    [JsonPropertyName("approval_summary")]
    public Dictionary<string, object> ApprovalSummary { get; set; } = new();

    [JsonPropertyName("diagnostics")]
    public List<object> Diagnostics { get; set; } = new();
}

public class PlannedCommand
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("status")]
    public string Status { get; set; } = "";

    [JsonPropertyName("command_array")]
    public List<string> CommandArray { get; set; } = new();

    [JsonPropertyName("working_directory")]
    public string WorkingDirectory { get; set; } = ".";

    [JsonPropertyName("purpose")]
    public string Purpose { get; set; } = "";

    [JsonPropertyName("purpose_category")]
    public string PurposeCategory { get; set; } = "";

    [JsonPropertyName("required_tool")]
    public string RequiredTool { get; set; } = "";

    [JsonPropertyName("tool_available")]
    public bool ToolAvailable { get; set; }

    [JsonPropertyName("confidence")]
    public string Confidence { get; set; } = "";

    [JsonPropertyName("risk_level")]
    public string RiskLevel { get; set; } = "";

    [JsonPropertyName("requires_approval")]
    public bool RequiresApproval { get; set; }

    [JsonPropertyName("evidence")]
    public List<object> Evidence { get; set; } = new();
}

// Output Models (for execution-results.json)

public class ExecutionResults
{
    [JsonPropertyName("schema_version")]
    public string SchemaVersion { get; set; } = "1.0.0";

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
    public List<ExecutionResult> Commands { get; set; } = new();

    [JsonPropertyName("execution_summary")]
    public ExecutionSummary ExecutionSummary { get; set; } = new();

    [JsonPropertyName("diagnostics")]
    public List<object> Diagnostics { get; set; } = new();
}

public class ExecutionResult
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("order")]
    public int Order { get; set; }

    [JsonPropertyName("status")]
    public string Status { get; set; } = "rejected";

    [JsonPropertyName("command_array")]
    public List<string> CommandArray { get; set; } = new();

    [JsonPropertyName("working_directory")]
    public string WorkingDirectory { get; set; } = "";

    [JsonPropertyName("requested_tool")]
    public string RequestedTool { get; set; } = "";

    [JsonPropertyName("rejection_reason")]
    public string? RejectionReason { get; set; }

    [JsonPropertyName("executed_at")]
    public string? ExecutedAt { get; set; }

    [JsonPropertyName("finished_at")]
    public string? FinishedAt { get; set; }

    [JsonPropertyName("duration_ms")]
    public int? DurationMs { get; set; }

    [JsonPropertyName("exit_code")]
    public int? ExitCode { get; set; }

    [JsonPropertyName("stdout")]
    public string? Stdout { get; set; }

    [JsonPropertyName("stdout_truncated")]
    public bool StdoutTruncated { get; set; }

    [JsonPropertyName("stderr")]
    public string? Stderr { get; set; }

    [JsonPropertyName("stderr_truncated")]
    public bool StderrTruncated { get; set; }

    [JsonPropertyName("diagnostics")]
    public List<object> Diagnostics { get; set; } = new();
}

public class ExecutionSummary
{
    [JsonPropertyName("total")]
    public int Total { get; set; }

    [JsonPropertyName("rejected")]
    public int Rejected { get; set; }

    [JsonPropertyName("succeeded")]
    public int Succeeded { get; set; }

    [JsonPropertyName("failed")]
    public int Failed { get; set; }

    [JsonPropertyName("timed_out")]
    public int TimedOut { get; set; }

    [JsonPropertyName("cancelled")]
    public int Cancelled { get; set; }

    [JsonPropertyName("started")]
    public int Started { get; set; }

    [JsonPropertyName("skipped")]
    public int Skipped { get; set; }
}

// Execution state for orchestration

public class ExecutionContext
{
    public string WorkspacePath { get; set; } = "";
    public string PlanPath { get; set; } = "";
    public string RequestedBy { get; set; } = "";
    public CommandPlan Plan { get; set; } = new();
    public int TimeoutSeconds { get; set; } = 30;
    public List<string> CommandIds { get; set; } = new();
}
