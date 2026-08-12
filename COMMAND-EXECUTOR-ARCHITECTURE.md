# Command Executor Architecture

## Overview

The command executor is an **approval-gated execution layer** that consumes a command plan and executes only the safest commands: those marked `ready` with `requires_approval: false`. It maintains strict policy enforcement, workspace containment, and produces a versioned audit trail of execution results.

The executor **never executes blocked, ambiguous, or unsafe commands**, regardless of external approval signals. Explicit approval workflows are deferred to a separate layer designed and implemented after v1.

## Implementation

- **Target Framework**: .NET 10.0
- **Language**: C#
- **Testing**: xUnit 2.8.1 + Pester 5.x
- **Entry Point**: CLI (`Program.cs`) with argument parsing

## Design Principles

1. **Policy-Gated**: Executes only `ready` commands with `requires_approval: false`
2. **No Overrides**: Approval cannot override safety classification; unsafe stays unsafe
3. **Deterministic Policy**: Containment, timeout, and truncation rules are fixed and auditable
4. **Direct Execution**: Uses `ProcessStartInfo.ArgumentList`; never constructs shell strings
5. **Workspace-Safe**: Rejects any traversal outside workspace; rejects symlinks and reparse points
6. **Observable**: Captures all output, timing, exit codes; emits complete audit trail
7. **Fail-Safe**: Sequential execution; stops on first failure by default
8. **Timeout-Protected**: 30-second default with bounded configurable maximum
9. **Deterministic Results**: Plan digest binds results to exact input state

## Inputs

### Command Plan (`command-plan.json`)

- **Source**: Command planner (classifies and ranks commands)
- **Purpose**: Defines what was planned and which are approved for automatic execution
- **Key Data**:
  - `commands[]`: Array of planned commands
    - `id` (string): Stable command ID (e.g., `cmd-abc12345`)
    - `status` (enum): `ready` | `blocked` | `ambiguous` | `unsafe`
    - `command_array` (array): Native argument array (not shell string)
    - `working_directory` (string): Execution directory (relative to workspace)
    - `required_tool` (string): Tool name
    - `tool_available` (boolean): Tool present in machine inventory
    - `requires_approval` (boolean): Manual review needed
    - `confidence` (enum): `high` | `medium` | `low`
    - `risk_level` (enum): `low` | `medium` | `high`
  - `schema_version` (string): "1.0.0"
  - `workspace_path` (string): Workspace root (containment anchor)
  - `planned_at` (string, ISO8601): Plan timestamp
  - `approval_summary` (object): Count of each status class

### Execution Request

- **Caller**: User or automated workflow
- **Parameters**:
  - `CommandIds` (array): Explicit command IDs to execute (no wildcards)
  - `RequestedBy` (string): Identity/audit trail
  - `TimeoutSeconds` (int, optional): Per-command timeout (default: 30, max: 300)
  - `ExecutedAt` (string, ISO8601): Execution timestamp

## Processing Pipeline

```
command-plan.json
    ↓
Validate Schema & Version
    ↓ (reject if v ≠ 1.0.0 or malformed)
    |
Compute Plan Digest
    | (SHA-256 of exact plan bytes)
    |
For Each Requested Command ID:
    |
    ├→ Lookup ID in Plan
    |  └→ (reject if not found)
    |
    ├→ Verify Status & Approval
    |  ├→ (reject if status ≠ ready)
    |  ├→ (reject if requires_approval = true)
    |  └→ (reject if tool_available = false)
    |
    ├→ Canonicalize Working Directory
    |  ├→ Resolve absolute path
    |  ├→ Verify inside workspace
    |  ├→ Reject symlinks/reparse-points
    |  └→ (reject if traversal detected)
    |
    ├→ Prepare Process Invocation
    |  ├→ Extract command_array[0] as executable
    |  ├→ Use ArgumentList for args (not shell string)
    |  ├→ Set working directory
    |  └→ Apply environment-variable policy
    |
    ├→ Execute with Timeout Protection
    |  ├→ Start process
    |  ├→ Capture stdout/stderr streams asynchronously
    |  ├→ Monitor for timeout
    |  └→ Terminate process tree if timeout exceeded
    |
    ├→ Capture Results
    |  ├→ Exit code
    |  ├→ Duration (milliseconds)
    |  ├→ Stdout (with truncation flag if exceeds limit)
    |  ├→ Stderr (with truncation flag if exceeds limit)
    |  └→ Start/finish timestamps (ISO8601)
    |
    └→ Record Result
       ├→ Status: succeeded, failed, timed_out, etc.
       ├→ Bind to plan digest
       └→ Add rejection reason if rejected
    
Output: execution-results.json (schema v1.0.0)
```

## Execution Policies

### Command Selection

- **Acceptance Criteria**: `status == ready` AND `requires_approval == false`
- **Rejection Reasons**:
  - `unknown_id`: Command ID not in plan
  - `duplicate_id`: ID appears multiple times in request
  - `status_not_ready`: Command status is not `ready`
  - `requires_approval_true`: `requires_approval` is true (approval workflow not implemented)
  - `tool_unavailable`: `tool_available` is false
  - `plan_schema_unsupported`: Plan schema version not 1.0.0
  - `plan_malformed`: JSON parsing or schema validation failed
  - `workspace_containment_violation`: Working directory outside workspace or symlink/reparse-point
  - `missing_executable`: First element of `command_array` not found on PATH

### Workspace Containment

- **Anchor**: `command-plan.json` → `workspace_path` (absolute)
- **Validation**:
  1. Resolve `working_directory` to absolute path
  2. Normalize both paths (remove `.`, `..`, resolve symlinks)
  3. Verify resolved path starts with workspace path
  4. Reject if symlink or reparse point detected at any level
  5. Reject if parent-path traversal (`..`) attempts escape
- **Error**: `workspace_containment_violation`

### Process Execution

- **Invocation**: `ProcessStartInfo.ArgumentList` with direct executable
- **Never**: Shell strings, command substitution, environment variable interpolation
- **Working Directory**: Canonical absolute path (as validated above)
- **Environment**: Inherit from executor process; no untrusted variable injection
- **Argument Array**: Passed directly to OS without tokenization

### Timeout Policy

- **Default**: 30 seconds per command
- **Configurable**: 1–300 seconds (reject if outside range)
- **Behavior on Timeout**:
  - Send termination signal to process
  - Kill entire process tree (via `Process.Kill(entireProcessTree: true)`)
  - Wait up to 5 seconds for graceful termination
  - Force-kill any remaining child processes
  - Record as `timed_out` status
  - Include partial stdout/stderr with truncation flag

### Output Capture

- **Stdout/Stderr**: Captured asynchronously to avoid deadlock
- **Max Size**: 100 KB per stream (configurable, default)
- **Truncation**: If output exceeds limit, set `truncated` flag and record tail
- **Encoding**: UTF-8 (invalid sequences replaced with U+FFFD)
- **Newlines**: Preserved as-is; no platform conversion
- **Timestamps**: ISO8601 start/finish (UTC)
- **Duration**: Milliseconds (wall-clock, including I/O wait)

### Sequential Execution

- **Ordering**: Commands execute in request order
- **Stop-on-Failure**: By default, if any command exits with code ≠ 0, stop processing
- **No Dependencies**: Commands are independent; no piping or sequencing
- **No Retries**: Each command runs exactly once
- **Atomicity**: Results are recorded incrementally; partial results are valid

### Result States

```
rejected      ← Command failed validation (policy/schema/containment)
              → Status assigned before execution
              → Includes rejection_reason

started       ← Process started but not yet completed
              → Intermediate state (if results captured mid-stream)
              → Rarely appears in final output

succeeded     ← Process terminated with exit code 0
              → stdout/stderr captured
              → Duration recorded

failed        ← Process terminated with exit code ≠ 0
              → stdout/stderr captured
              → Non-zero exit code included

timed_out     ← Execution exceeded TimeoutSeconds
              → Process tree terminated
              → Partial output (if any) included
              → Truncation flag set if output was capped

cancelled     ← Execution stopped after prior command failed
              → Sequential stop-on-failure behavior
              → No execution attempt made

skipped       ← Command explicitly excluded or duplicated
              → Not in execution request
              → Included in results for audit completeness
```

## Result Schema

### Root Properties

- `schema_version` (string): "1.0.0"
- `executed_at` (string, ISO8601): Execution start timestamp
- `requested_by` (string): Identity of requestor
- `workspace_path` (string): Workspace root (from plan)
- `plan_path` (string): Source plan file path
- `plan_digest` (string): SHA-256 of plan bytes (hex)
- `commands` (array): Results for each command
- `diagnostics` (array): Execution-layer errors
- `execution_summary` (object): Status counts

### Command Result Properties

- `id` (string): Command ID from plan
- `order` (int): Execution order (1-indexed)
- `status` (enum): `rejected` | `started` | `succeeded` | `failed` | `timed_out` | `cancelled` | `skipped`
- `command_array` (array): Original command (for audit)
- `working_directory` (string): Canonical execution directory
- `requested_tool` (string): Expected executable
- `rejection_reason` (string, optional): If `status == rejected`
- `executed_at` (string, ISO8601): Start timestamp (null if not executed)
- `finished_at` (string, ISO8601): End timestamp (null if not executed)
- `duration_ms` (int): Wall-clock milliseconds (null if not executed)
- `exit_code` (int, optional): Process exit code (null if not executed)
- `stdout` (string): Captured standard output
- `stdout_truncated` (boolean): True if output exceeded limit
- `stderr` (string): Captured standard error
- `stderr_truncated` (boolean): True if error output exceeded limit
- `diagnostics` (array): Per-command errors/warnings

## Plan Digest Binding

The executor computes a SHA-256 hash of the exact command-plan.json bytes to bind results to input state:

```powershell
$planBytes = [System.IO.File]::ReadAllBytes($CommandPlanPath)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$hashBytes = $sha256.ComputeHash($planBytes)
$planDigest = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
```

This allows downstream consumers to:
- Verify results correspond to specific plan version
- Detect if plan was modified between execution and audit
- Correlate multiple execution runs against same plan

## Language Choice: C# / .NET 8

**Rationale**:
- Native argument arrays (`ProcessStartInfo.ArgumentList`) prevent shell-injection risks
- Reliable async output capture (no deadlock risks) via `StreamReader` with async APIs
- Process-tree termination via `Process.Kill(entireProcessTree: true)`
- Built-in SHA-256 support (`System.Security.Cryptography`)
- Straightforward JSON handling (`System.Text.Json`)
- Windows process management is native; cross-platform via `.NET 8`
- Single executable deployment (no runtime installer needed)

## Implementation Scope (v1)

### Included

- Command-ID validation and plan lookup
- Policy enforcement (status, approval, containment)
- Direct process execution (no shell)
- Timeout and process-tree termination
- Output capture and truncation
- Audit-trail JSON serialization
- Schema versioning

### Deferred to v2+

- Explicit approval workflow (approve unsafe/ambiguous commands)
- Dependency chains or ordering
- Parallel execution
- Retry logic
- Interactive prompts
- Fallback/alternative commands

## Files

- **COMMAND-EXECUTOR-ARCHITECTURE.md** (this document)
- **schemas/execution-results.schema.json** (JSON Schema v1.0.0 contract)
- **src/CommandExecutor/CommandExecutor.csproj** (C# project)
- **src/CommandExecutor/Program.cs** (entry point)
- **tests/CommandExecutor.Tests/CommandExecutor.Tests.csproj** (xUnit tests)
- **tests/command-executor.tests.ps1** (Pester integration tests, optional thin wrapper)

## Audit Trail Example

```json
{
  "schema_version": "1.0.0",
  "executed_at": "2026-08-12T21:00:00Z",
  "requested_by": "Rafael",
  "workspace_path": "C:\\Users\\rafael\\workspace",
  "plan_path": "C:\\Users\\rafael\\workspace\\output\\command-plan.json",
  "plan_digest": "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6",
  "commands": [
    {
      "id": "cmd-abc12345",
      "order": 1,
      "status": "succeeded",
      "command_array": ["npm", "test"],
      "working_directory": "C:\\Users\\rafael\\workspace",
      "requested_tool": "npm",
      "executed_at": "2026-08-12T21:00:00Z",
      "finished_at": "2026-08-12T21:00:15Z",
      "duration_ms": 15234,
      "exit_code": 0,
      "stdout": "✓ All tests passed (42 passed)",
      "stdout_truncated": false,
      "stderr": "",
      "stderr_truncated": false,
      "diagnostics": []
    },
    {
      "id": "cmd-def67890",
      "order": 2,
      "status": "rejected",
      "command_array": ["cargo", "test"],
      "working_directory": "C:\\Users\\rafael\\workspace",
      "requested_tool": "cargo",
      "rejection_reason": "tool_unavailable",
      "executed_at": null,
      "finished_at": null,
      "duration_ms": null,
      "exit_code": null,
      "stdout": null,
      "stdout_truncated": false,
      "stderr": null,
      "stderr_truncated": false,
      "diagnostics": []
    }
  ],
  "execution_summary": {
    "total": 2,
    "rejected": 1,
    "succeeded": 1,
    "failed": 0,
    "timed_out": 0,
    "cancelled": 0,
    "started": 0,
    "skipped": 0
  },
  "diagnostics": []
}
```

## See Also

- `COMMAND-PLANNER-ARCHITECTURE.md` - Upstream planning layer
- `schemas/command-plan.schema.json` - Input contract (plan schema)
- `schemas/execution-results.schema.json` - Output contract (results schema)
