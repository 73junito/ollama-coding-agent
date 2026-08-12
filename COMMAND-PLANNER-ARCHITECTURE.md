# Command Planner Architecture

## Overview

The command planner is a **read-only, non-executing** service that consumes machine inventory and workspace environment data to produce a deterministic command plan. It bridges workspace detection (what was found) with eventual command execution (what can be done safely) while maintaining strict separation of concerns.

The planner **never executes commands**. It only evaluates, classifies, and records plans for later approval and execution by a separate layer.

## Design Principles

1. **Read-Only**: Planner observes and plans; execution is handled by a separate layer
2. **Deterministic**: Same inputs always produce identical output (stable command IDs, ordering)
3. **Evidence-Based**: Every command retains source evidence and reasoning
4. **Safety-First**: Detects and blocks unsafe constructs before execution layer encounters them
5. **Transparent**: Command arguments preserved as arrays; no shell string construction
6. **Layered**: Each command includes confidence, risk level, and approval requirements for downstream decision-making

## Inputs

### Machine Inventory (`machine-inventory.json`)

- **Source**: Machine-inventory detector (establishes baseline capabilities)
- **Purpose**: Defines what tools/interpreters/compilers are available on the system
- **Key Data**:
  - PowerShell version
  - Installed language runtimes (Python, Node, Go, Rust, etc.)
  - Build tools (MSBuild, Maven, Cargo, etc.)
  - Package managers (npm, pip, cargo, etc.)
  - Optional: version details, installation paths

### Workspace Environment (`workspace-environment.json`)

- **Source**: Workspace-environment detector (discovers ecosystem signatures)
- **Purpose**: Defines what was detected in the workspace
- **Key Data**:
  - Detected ecosystems (node, python, rust, go, java, dotnet, ruby, php)
  - Manifests found (package.json, pyproject.toml, Cargo.toml, etc.)
  - Inferred test commands (npm test, pytest, cargo test, etc.) with confidence levels
  - Inferred build commands with confidence levels
  - Confidence summary (high/medium/low counts)
  - Diagnostics (malformed manifests, conflicts)

## Processing Pipeline

```
machine-inventory.json
    ↓
    +→ Tool Availability Map
    |   (python → available, go → unavailable, etc.)
    |
workspace-environment.json
    ↓
    +→ Detected Commands
    |   (test: [npm test, pytest], build: [npm run build, cargo build])
    |
    +→ Merge with Availability
    |   Filter commands where required tool is available
    |
    +→ Classify & Evaluate
    |   State: ready, blocked, ambiguous, unsafe
    |   Confidence: high, medium, low
    |   Risk: low, medium, high
    |   Approval: yes/no
    |
    +→ Detect Safety Issues
    |   - Shell metacharacters in arguments
    |   - Unresolved path references
    |   - Suspicious patterns (>>, ||, &&, etc.)
    |
    +→ Assign Stable IDs
    |   Hash: purpose + command + working_directory
    |   Format: cmd-{hash:8}
    |
    +→ Serialize as JSON Schema v1.0.0
    |   command-plan.json
```

## Command State Classification

### Ready

- **Condition**: Required tool is available AND workspace evidence is clear
- **Approval**: Conditional (depends on risk level and confidence)
- **Executable**: Yes (by execution layer after approval)

**Example**:
```json
{
  "id": "cmd-abc12345",
  "status": "ready",
  "command_array": ["npm", "test"],
  "working_directory": ".",
  "required_tool": "npm",
  "tool_available": true,
  "confidence": "high",
  "risk_level": "low",
  "requires_approval": false,
  "purpose": "Run npm test suite"
}
```

### Blocked

- **Condition**: Required tool is unavailable (not in machine inventory)
- **Approval**: Required (decision to skip must be reviewed)
- **Executable**: No

**Example**:
```json
{
  "id": "cmd-def67890",
  "status": "blocked",
  "command_array": ["cargo", "test"],
  "working_directory": ".",
  "required_tool": "cargo",
  "tool_available": false,
  "confidence": "high",
  "risk_level": "none",
  "requires_approval": true,
  "purpose": "Run cargo test suite",
  "diagnostics": [
    {
      "type": "tool_unavailable",
      "message": "Required tool 'cargo' not found in machine inventory"
    }
  ]
}
```

### Ambiguous

- **Condition**: Multiple conflicting commands detected OR insufficient evidence to determine which to execute
- **Approval**: Required
- **Executable**: No (requires human disambiguation)

**Example**:
```json
{
  "id": "cmd-ghi11111",
  "status": "ambiguous",
  "command_array": ["npm", "test"],
  "working_directory": ".",
  "required_tool": "npm",
  "tool_available": true,
  "confidence": "low",
  "risk_level": "medium",
  "requires_approval": true,
  "purpose": "Run tests (command uncertain: multiple candidates found)",
  "notes": "Both 'npm test' and 'npm run test' detected in package.json",
  "diagnostics": [
    {
      "type": "conflicting_commands",
      "message": "Multiple test commands found; requires explicit selection"
    }
  ]
}
```

### Unsafe

- **Condition**: Command contains shell metacharacters, unresolved paths, or matches suspicious patterns
- **Approval**: Required (always; safety review mandatory)
- **Executable**: No (requires explicit security review)

**Example**:
```json
{
  "id": "cmd-jkl22222",
  "status": "unsafe",
  "command_array": ["sh", "-c", "npm test && npm run build"],
  "working_directory": ".",
  "required_tool": "npm",
  "tool_available": true,
  "confidence": "high",
  "risk_level": "high",
  "requires_approval": true,
  "purpose": "Run tests and build",
  "diagnostics": [
    {
      "type": "unsafe_shell_construct",
      "severity": "high",
      "message": "Shell operator '&&' detected in command construction",
      "pattern": "&&",
      "argument_index": 2
    },
    {
      "type": "unsafe_shell_construct",
      "severity": "medium",
      "message": "Command uses shell invocation; arguments not directly passed to binary"
    }
  ]
}
```

## Safety Detection Rules

### Shell Metacharacters

Reject commands containing:
- Command chaining: `&&`, `||`, `;`
- Redirection: `>`, `>>`, `<`, `<<<`
- Piping: `|`
- Process substitution: `<()`, `>()`
- Background execution: `&`

**Reasoning**: These require shell interpretation, introducing injection risks and execution ambiguity.

### Unresolved Paths

Reject commands where:
- Path arguments start with `$` (unexpanded variables)
- Path arguments reference parent dirs (`../`) without clear anchor
- Path contains globbing patterns (`*`, `?`, `[...]`)

**Reasoning**: Planner cannot resolve paths; execution layer must verify.

### Suspicious Patterns

Flag commands where:
- Arguments contain whitespace without explicit array boundaries (construction risk)
- Command invokes `shell`, `cmd`, `powershell` with user-provided scripts
- Working directory is relative without clear workspace anchor

**Reasoning**: These indicate fragile construction that may break under different conditions.

## Stable Command ID Assignment

Command IDs are **deterministic and stable** across runs:

```powershell
$seed = "{0}#{1}#{2}" -f $purpose, ($commandArray -join " "), $workingDirectory
$hash = Get-SHA256Hash($seed) | Select-Object -First 8
$commandId = "cmd-{0}" -f $hash
```

**Properties**:
- Same command + purpose + directory = identical ID
- IDs remain stable across planner invocations
- Enables tracking and deduplication
- Survives incremental updates to workspace

## Approval Requirements

Commands automatically marked `requires_approval: true` if:

1. **Status is blocked**: Cannot execute; requires decision to skip
2. **Status is ambiguous**: Multiple options; requires selection
3. **Status is unsafe**: Security risk; requires explicit approval
4. **Confidence is low**: Insufficient evidence; human judgment needed
5. **Risk level is high**: Destructive operation; approval mandatory

Commands may execute without approval if:
- Status is `ready` AND
- Confidence is `high` AND
- Risk level is `low` or `medium`

## Output: Command Plan Schema

- **File**: `command-plan.json`
- **Schema**: `command-plan.schema.json` (JSON Schema v1.0.0)
- **Root Properties**:
  - `schema_version` (string): "1.0.0"
  - `workspace_path` (string): Analyzed workspace root
  - `machine_inventory_path` (string): Source of tool availability
  - `workspace_environment_path` (string): Source of detected commands
  - `planned_at` (string, ISO8601): Timestamp
  - `commands` (array): Planned commands
  - `diagnostics` (array): Plan-level issues
  - `approval_summary` (object): Approval requirement statistics

- **Command Properties**:
  - `id` (string): Stable command ID
  - `status` (enum): `ready` | `blocked` | `ambiguous` | `unsafe`
  - `command_array` (array): Arguments preserved as array (not shell string)
  - `working_directory` (string): Execution directory
  - `purpose` (string): Intent (test, build, lint, validate)
  - `purpose_category` (enum): `test` | `build` | `lint` | `validate` | `other`
  - `required_tool` (string): Tool needed for execution
  - `tool_available` (boolean): Present in machine inventory
  - `confidence` (enum): `high` | `medium` | `low`
  - `risk_level` (enum): `none` | `low` | `medium` | `high`
  - `requires_approval` (boolean): Must be approved before execution
  - `evidence` (object): Source documentation
  - `diagnostics` (array): Issues specific to this command
  - `notes` (string, optional): Additional context

- **Evidence Object**:
  - `manifest_type` (string): Type of source (package.json, Cargo.toml, etc.)
  - `manifest_path` (string): File path relative to workspace root
  - `detected_as` (string): How command was inferred (npm script, test runner, etc.)
  - `confidence_reason` (string): Why confidence level was assigned

## Implementation Notes

- **No Shell String Construction**: Arguments are preserved as arrays; the execution layer constructs shell commands after approval
- **Legacy String Tokenization**: Detector output using command strings (not arrays) is split on whitespace via `-split '\s+'`. This does not preserve quoted arguments (e.g., `npm run test -- --name "value"` is incorrectly tokenized). Detectors emitting `command_array` (not `command` string) avoid this limitation. Commands with quotes are automatically classified as ambiguous or unsafe during evaluation.
- **No Command Execution**: The planner is purely declarative
- **Incremental Updates**: If workspace-environment.json is updated, command-planner re-runs and detects changes (stable IDs enable diff)
- **Deterministic Ordering**: Commands sorted by ID within each status group for consistent output
- **Diagnostics Chain**: Planner diagnostics feed into execution-layer decision tree (approve/skip/modify/request-info)

## Files

- **COMMAND-PLANNER-ARCHITECTURE.md** (this document)
- **schemas/command-plan.schema.json** (JSON Schema contract)
- **tools/command-planner.ps1** (implementation)
- **tests/command-planner.tests.ps1** (Pester v5.7.1 contracts)
