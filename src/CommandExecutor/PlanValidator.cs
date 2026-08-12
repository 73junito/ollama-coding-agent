using System;
using System.Collections.Generic;
using System.Linq;

namespace CommandExecutor;

/// <summary>
/// Validates command-plan.json integrity and command policy compliance.
/// Enforces the approval-gated execution safety contract.
/// </summary>
public class PlanValidator
{
    public List<string> Errors { get; private set; } = new();

    /// <summary>
    /// Validates the entire plan structure and consistency.
    /// </summary>
    public bool ValidatePlan(CommandPlan plan)
    {
        Errors.Clear();

        if (string.IsNullOrWhiteSpace(plan.SchemaVersion))
            Errors.Add("Plan missing schema_version");

        if (string.IsNullOrWhiteSpace(plan.WorkspacePath))
            Errors.Add("Plan missing workspace_path");

        if (plan.Commands == null || plan.Commands.Count == 0)
        {
            Errors.Add("Plan contains no commands");
            return false;
        }

        var ids = new HashSet<string>();
        for (int i = 0; i < plan.Commands.Count; i++)
        {
            var cmd = plan.Commands[i];
            if (string.IsNullOrWhiteSpace(cmd.Id))
            {
                Errors.Add($"Command at index {i} missing id");
                continue;
            }

            if (ids.Contains(cmd.Id))
            {
                Errors.Add($"Duplicate command id: {cmd.Id}");
            }
            ids.Add(cmd.Id);

            if (cmd.CommandArray == null || cmd.CommandArray.Count == 0)
                Errors.Add($"Command {cmd.Id} has empty command_array");
        }

        return Errors.Count == 0;
    }

    /// <summary>
    /// Finds a command by ID in the plan.
    /// </summary>
    public PlannedCommand? FindCommand(CommandPlan plan, string commandId)
    {
        return plan.Commands?.FirstOrDefault(c => c.Id == commandId);
    }

    /// <summary>
    /// Validates command status and approval requirements.
    /// Returns rejection reason if command should be rejected, null if approved for execution.
    /// </summary>
    public string? ValidateCommandPolicy(PlannedCommand command)
    {
        // Policy: Only "ready" status with requires_approval=false can be executed.
        // All other statuses are rejected (blocked, ambiguous, unsafe).
        // "ready" status with requires_approval=true is also rejected.

        if (command.Status != "ready")
        {
            // Status is blocked, ambiguous, unsafe, or other non-ready state
            return $"status_{command.Status}";
        }

        if (command.RequiresApproval)
        {
            // Ready but waiting for approval
            return "requires_approval_true";
        }

        // Command is ready and does not require approval—proceed to execution validation
        return null;
    }
}
