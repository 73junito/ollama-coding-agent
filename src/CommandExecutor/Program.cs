using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace CommandExecutor;

/// <summary>
/// Command Executor: Approval-gated execution layer for command plans.
/// 
/// Safety contract:
/// - Only executes commands with status="ready" and requires_approval=false
/// - Rejects: blocked, ambiguous, unsafe, or approval-required commands
/// - Enforces workspace containment via canonical path resolution
/// - Captures stdout/stderr with size limits
/// - Implements timeout with process tree termination
/// - All arguments passed via ArgumentList (no shell string construction)
/// 
/// CLI: Loads plan, executes approved commands, serializes results to JSON.
/// Exit codes: 0=success, 1=validation error, 2=execution error
/// 
/// Usage:
///   dotnet run -- --plan <path> --workspace <path> --requested-by <user> [--timeout <sec>] [--output <path>] [--command-ids <id1,id2>]
/// </summary>
public static class Program
{
    public static int Main(string[] args)
    {
        try
        {
            // Parse arguments
            var options = ParseArguments(args);
            if (!options.IsValid)
            {
                Console.Error.WriteLine($"Invalid arguments: {options.ErrorMessage}");
                PrintUsage();
                return 1;
            }

            // Validate files exist
            if (!File.Exists(options.PlanPath))
            {
                Console.Error.WriteLine($"Plan file not found: {options.PlanPath}");
                return 1;
            }

            if (!Directory.Exists(options.WorkspacePath))
            {
                Console.Error.WriteLine($"Workspace directory not found: {options.WorkspacePath}");
                return 1;
            }

            // Create output directory if needed
            var outputDir = Path.GetDirectoryName(options.OutputPath);
            if (!string.IsNullOrEmpty(outputDir) && !Directory.Exists(outputDir))
                Directory.CreateDirectory(outputDir);

            // Execute
            var executor = new ExecutorService(options.WorkspacePath);
            var context = new ExecutionContext
            {
                WorkspacePath = options.WorkspacePath,
                PlanPath = options.PlanPath,
                TimeoutSeconds = options.TimeoutSeconds,
                CommandIds = options.CommandIds
            };

            var results = executor.Execute(context, options.RequestedBy, options.TimeoutSeconds);

            // Write results
            string resultsJson = executor.SerializeResults(results);
            File.WriteAllText(options.OutputPath, resultsJson);

            Console.WriteLine($"Execution complete: {options.OutputPath}");
            Console.WriteLine($"Summary: {results.ExecutionSummary.Succeeded} succeeded, {results.ExecutionSummary.Failed} failed, {results.ExecutionSummary.Rejected} rejected");

            return results.ExecutionSummary.Failed > 0 ? 1 : 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Fatal error: {ex.Message}");
            return 2;
        }
    }

    private class CliOptions
    {
        public bool IsValid { get; set; }
        public string ErrorMessage { get; set; } = "";
        public string PlanPath { get; set; } = "";
        public string WorkspacePath { get; set; } = "";
        public string RequestedBy { get; set; } = "";
        public string OutputPath { get; set; } = "";
        public int TimeoutSeconds { get; set; } = 30;
        public List<string> CommandIds { get; set; } = new();
    }

    private static CliOptions ParseArguments(string[] args)
    {
        var options = new CliOptions { IsValid = true };

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (!arg.StartsWith("--"))
                continue;

            string key = arg.Substring(2);
            string value = i + 1 < args.Length ? args[i + 1] : "";

            switch (key)
            {
                case "plan":
                    options.PlanPath = value;
                    i++;
                    break;

                case "workspace":
                    options.WorkspacePath = value;
                    i++;
                    break;

                case "requested-by":
                    options.RequestedBy = value;
                    i++;
                    break;

                case "output":
                    options.OutputPath = value;
                    i++;
                    break;

                case "timeout-seconds":
                    if (int.TryParse(value, out int timeout))
                    {
                        options.TimeoutSeconds = Math.Max(1, Math.Min(300, timeout));
                        i++;
                    }
                    break;

                case "command-id":
                    // Accept both --command-id <id> and --command-ids <id1,id2>
                    if (!string.IsNullOrEmpty(value))
                    {
                        options.CommandIds.Add(value);
                        i++;
                    }
                    break;

                case "command-ids":
                    options.CommandIds = value.Split(',', StringSplitOptions.RemoveEmptyEntries)
                        .Select(s => s.Trim())
                        .ToList();
                    i++;
                    break;
            }
        }

        // Validate required arguments
        if (string.IsNullOrWhiteSpace(options.PlanPath))
        {
            options.IsValid = false;
            options.ErrorMessage = "Missing required --plan argument";
        }
        else if (string.IsNullOrWhiteSpace(options.WorkspacePath))
        {
            options.IsValid = false;
            options.ErrorMessage = "Missing required --workspace argument";
        }
        else if (string.IsNullOrWhiteSpace(options.RequestedBy))
        {
            options.IsValid = false;
            options.ErrorMessage = "Missing required --requested-by argument";
        }

        // Set default output path if not provided
        if (string.IsNullOrWhiteSpace(options.OutputPath))
        {
            var resultDir = Path.Combine(options.WorkspacePath, ".executor");
            options.OutputPath = Path.Combine(resultDir, "execution-results.json");
        }

        return options;
    }

    private static void PrintUsage()
    {
        Console.WriteLine(@"
Usage: dotnet CommandExecutor.dll [options]

Options:
  --plan <path>           Path to command-plan.json (required)
  --workspace <path>      Workspace root directory (required)
  --requested-by <user>   User/agent requesting execution (required)
  --timeout <seconds>     Timeout per command (default: 30, range: 1-300)
  --output <path>         Output file path (default: .executor/execution-results.json)
  --command-ids <id,id>   Comma-separated command IDs to execute (optional)

Example:
  dotnet CommandExecutor.dll \
    --plan /workspace/command-plan.json \
    --workspace /workspace \
    --requested-by agent-1 \
    --timeout 60 \
    --output /workspace/.executor/results.json
");
    }
}
