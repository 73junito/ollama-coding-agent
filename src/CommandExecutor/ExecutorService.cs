using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CommandExecutor;

/// <summary>
/// Orchestrates the approval-gated command execution workflow.
/// Loads plan, validates each command, executes approved commands, serializes results.
/// </summary>
public class ExecutorService
{
    private readonly PlanValidator _planValidator;
    private readonly WorkspaceGuard _workspaceGuard;
    private readonly ProcessRunner _processRunner;
    private readonly JsonSerializerOptions _jsonOptions;

    public ExecutorService(string workspacePath)
    {
        _workspaceGuard = new WorkspaceGuard(workspacePath);
        _planValidator = new PlanValidator();
        _processRunner = new ProcessRunner();
        _jsonOptions = new JsonSerializerOptions
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
            WriteIndented = true
        };
    }

    /// <summary>
    /// Executes the command plan and returns structured results.
    /// </summary>
    public ExecutionResults Execute(
        ExecutionContext context,
        string requestedBy,
        int defaultTimeoutSeconds = 30)
    {
        var results = new ExecutionResults
        {
            ExecutedAt = DateTime.UtcNow.ToString("O"),
            RequestedBy = requestedBy,
            WorkspacePath = context.WorkspacePath,
            PlanPath = context.PlanPath,
            Commands = new()
        };

        // Load and validate plan
        CommandPlan? plan = null;
        try
        {
            plan = LoadAndValidatePlan(context.PlanPath);
            if (plan == null)
            {
                results.Diagnostics.Add("Failed to load/validate plan");
                return results;
            }

            results.PlanDigest = ComputePlanDigest(context.PlanPath);
            results.WorkspacePath = plan.WorkspacePath;
        }
        catch (Exception ex)
        {
            results.Diagnostics.Add($"Plan loading error: {ex.Message}");
            return results;
        }

        // Process each requested command (or all commands if none specified)
        List<string> commandIdsToProcess = context.CommandIds.Count > 0 ? context.CommandIds : plan.Commands.Select(c => c.Id).ToList();
        int order = 0;

        foreach (var commandId in commandIdsToProcess)
        {
            order++;

            // 1. Find command in plan by ID
            var plannedCommand = _planValidator.FindCommand(plan, commandId);
            if (plannedCommand == null)
            {
                results.Commands.Add(new ExecutionResult
                {
                    Id = commandId,
                    Order = order,
                    Status = "rejected",
                    RejectionReason = "unknown_id"
                });
                continue;
            }

            var result = new ExecutionResult
            {
                Id = plannedCommand.Id,
                Order = order,
                CommandArray = plannedCommand.CommandArray,
                WorkingDirectory = plannedCommand.WorkingDirectory,
                RequestedTool = plannedCommand.RequiredTool
            };

            // 2. Validate policy (status and approval requirement)
            string? policyRejection = _planValidator.ValidateCommandPolicy(plannedCommand);
            if (policyRejection != null)
            {
                result.Status = "rejected";
                result.RejectionReason = policyRejection;
                results.Commands.Add(result);
                continue;
            }

            // 3. Validate workspace containment
            string? containmentRejection = _workspaceGuard.ValidateWorkingDirectory(
                plannedCommand.WorkingDirectory);
            if (containmentRejection != null)
            {
                result.Status = "rejected";
                result.RejectionReason = containmentRejection;
                results.Commands.Add(result);
                continue;
            }

            // 4. Execute the command
            result.Status = "started";
            result.ExecutedAt = DateTime.UtcNow.ToString("O");

            try
            {
                var processResult = _processRunner.Run(
                    plannedCommand.CommandArray,
                    plannedCommand.WorkingDirectory,
                    context.TimeoutSeconds);

                result.FinishedAt = DateTime.UtcNow.ToString("O");
                result.DurationMs = processResult.DurationMs;
                result.ExitCode = processResult.ExitCode;
                result.Stdout = processResult.Stdout;
                result.StdoutTruncated = processResult.StdoutTruncated;
                result.Stderr = processResult.Stderr;
                result.StderrTruncated = processResult.StderrTruncated;

                if (processResult.TimedOut)
                {
                    result.Status = "timed_out";
                }
                else if (processResult.ExitCode == 0)
                {
                    result.Status = "succeeded";
                }
                else
                {
                    result.Status = "failed";
                }
            }
            catch (Exception ex)
            {
                result.Status = "failed";
                result.Stderr = ex.Message;
                result.FinishedAt = DateTime.UtcNow.ToString("O");
                result.DurationMs = (int)(DateTime.UtcNow - DateTime.Parse(result.ExecutedAt ?? DateTime.UtcNow.ToString("O"))).TotalMilliseconds;
            }

            results.Commands.Add(result);
        }

        // Compute summary
        results.ExecutionSummary = ComputeSummary(results.Commands);

        return results;
    }

    /// <summary>
    /// Loads and validates a command plan from JSON.
    /// </summary>
    private CommandPlan? LoadAndValidatePlan(string planPath)
    {
        if (!File.Exists(planPath))
            throw new FileNotFoundException($"Plan file not found: {planPath}");

        string json = File.ReadAllText(planPath);
        var plan = JsonSerializer.Deserialize<CommandPlan>(json, _jsonOptions);

        if (plan == null)
            throw new InvalidOperationException("Failed to deserialize plan");

        if (!_planValidator.ValidatePlan(plan))
            throw new InvalidOperationException($"Plan validation failed: {string.Join("; ", _planValidator.Errors)}");

        return plan;
    }

    /// <summary>
    /// Computes SHA-256 digest of the plan file for audit trail.
    /// </summary>
    private string ComputePlanDigest(string planPath)
    {
        try
        {
            byte[] fileBytes = File.ReadAllBytes(planPath);
            using (var sha256 = SHA256.Create())
            {
                byte[] hash = sha256.ComputeHash(fileBytes);
                return BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant();
            }
        }
        catch
        {
            return "";
        }
    }

    /// <summary>
    /// Computes summary statistics from execution results.
    /// </summary>
    private ExecutionSummary ComputeSummary(List<ExecutionResult> commands)
    {
        var summary = new ExecutionSummary { Total = commands.Count };

        foreach (var cmd in commands)
        {
            switch (cmd.Status)
            {
                case "rejected":
                    summary.Rejected++;
                    break;
                case "succeeded":
                    summary.Succeeded++;
                    break;
                case "failed":
                    summary.Failed++;
                    break;
                case "timed_out":
                    summary.TimedOut++;
                    break;
                case "skipped":
                    summary.Skipped++;
                    break;
                case "started":
                    summary.Started++;
                    break;
            }
        }

        return summary;
    }

    /// <summary>
    /// Serializes results to JSON file matching the execution-results.schema.json.
    /// </summary>
    public string SerializeResults(ExecutionResults results)
    {
        return JsonSerializer.Serialize(results, _jsonOptions);
    }
}
