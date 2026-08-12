# Workspace Environment Detector Architecture

## Overview

The workspace environment detector is a read-only analysis tool that identifies project ecosystems, package managers, virtual environments, and command entry points within an explicit workspace path. It produces deterministic JSON output with evidence and confidence levels for every inference.

## Design Principles

- **Explicit Scoping**: Accept workspace path explicitly; never scan the whole machine
- **Bounded Recursion**: Search workspace recursively up to `-MaxDepth` levels (default: 2). Never traverse excluded directories: `.git`, `node_modules`, `.venv`, `vendor`, `target`, `dist`, `build`, `.next`, `out`, `bin`, `obj`
- **Read-Only**: Analyze only; never execute commands or modify files
- **Deterministic Output (injectable timestamp)**: Same input → same output (analysis always identical). Only `analyzed_at` is intentionally nondeterministic; override via `-AnalyzedAt` parameter for deterministic testing
- **Evidence-Based**: Record discovery source and confidence for every finding
- **Command Inference Independence**: Report inferred commands separately from tool-availability status
- **Graceful Degradation**: Malformed manifests produce diagnostics, not failures; analysis continues with remaining valid manifests
- **Explicit Tool Status**: Report tool availability as available/unavailable/unknown, separate from whether a command is inferred
- **Polyglot Compatible**: Support multiple ecosystems and package managers in single workspace; detect conflicts (e.g., yarn + npm lockfiles)
- **Compatible**: Integrate seamlessly with v0.3.0 machine inventory

## Phase 1 Scope: Manifest & Command Detection

### Inputs

1. **WorkspacePath** (required)
   - Explicit filesystem path to project root
   - Resolves relative to caller's current directory (not script directory)
   - Validation: must be directory and accessible; empty workspaces are valid
   - Missing workspace: terminating parameter error (Write-Error -ErrorAction Stop)

2. **MachineInventoryPath** (optional)
   - Path to `machine-inventory.json` output from machine-inventory.ps1
   - Used to cross-reference inferred commands against available tools
   - Tool availability is reported separately from inferred command
   - If omitted, commands are inferred without tool-availability verification

3. **OutputPath** (required)
   - Destination for `workspace-environment.json` output
   - Parent directory must exist or be creatable

4. **MaxDepth** (optional, default: 2)
   - Maximum recursion depth for manifest discovery
   - Depth 1 = workspace root only
   - Depth 2 = workspace root + immediate subdirectories
   - Default 2 balances discovery with performance and excludes deep project nesting

5. **AnalyzedAt** (optional, default: current timestamp)
   - Injectable timestamp for deterministic testing (ISO 8601 format)
   - Allows reproducible test runs with fixed timestamp
   - If omitted, uses current time

### Discovery Targets

#### 1. Project Manifests

Detected by presence and analyzed for ecosystem signals:

| Ecosystem | Primary Manifest | Lock Files | Test Commands | Build Commands |
|-----------|------------------|-----------|---|---|
| **Node.js** | package.json | package-lock.json, yarn.lock, pnpm-lock.yaml | npm test, yarn test, jest | npm run build, webpack |
| **Python** | setup.py, pyproject.toml, requirements.txt | requirements.lock, Pipfile.lock | pytest, unittest, tox | setuptools, poetry |
| **Rust** | Cargo.toml | Cargo.lock | cargo test | cargo build |
| **Go** | go.mod | go.sum | go test | go build |
| **Java** | pom.xml, build.gradle | pom.xml (built-in), gradle.lock | mvn test, gradle test | mvn compile, gradle build |
| **.NET** | .csproj, .sln | packages.lock.json | dotnet test | dotnet build |
| **Ruby** | Gemfile | Gemfile.lock | rake test, rspec | rake build |
| **PHP** | composer.json | composer.lock | phpunit | composer install |

#### 2. Virtual Environments

Detected by directory presence and metadata:

| Type | Indicators | Confidence |
|------|-----------|------------|
| Python venv | `.venv/`, `venv/` with `pyvenv.cfg` | High |
| Python virtualenv | `env/` with `bin/activate` or `Scripts/activate` | Medium |
| Node.js | `node_modules/` with `package.json` in parent | High |
| Go vendor | `vendor/` with `go.mod` in parent | High |
| Ruby bundler | `Gemfile.lock` + `vendor/bundle/` | High |
| Java Maven | `.m2/` in workspace | Medium |
| Java Gradle | `.gradle/` in workspace | Medium |

#### 3. Package Managers

Inferred from:
- Manifests present
- Virtual environments detected
- Ecosystem signals in lock files

| Manager | Detection Signal |
|---------|-----------------|
| npm | package.json, node_modules/ |
| yarn | yarn.lock |
| pnpm | pnpm-lock.yaml |
| pip | requirements.txt, setup.py |
| pipenv | Pipfile, Pipfile.lock |
| poetry | pyproject.toml with [tool.poetry] |
| cargo | Cargo.toml, Cargo.lock |
| go mod | go.mod, go.sum |
| maven | pom.xml, .m2/ |
| gradle | build.gradle, .gradle/ |
| dotnet | .csproj, packages.lock.json |
| bundler | Gemfile, Gemfile.lock |
| composer | composer.json, composer.lock |

#### 4. Test Command Inference

Inferred *without execution* from:
1. Manifest presence (npm test, pytest, cargo test)
2. Lock file presence (indicates active ecosystem)
3. Virtual environment detection (indicates prepared state)
4. Package manager presence

Examples:
- If `package.json` + `node_modules/` exist → `npm test` is available
- If `pyproject.toml` with `[tool.pytest.ini_options]` → `pytest` is available
- If `Cargo.toml` + `Cargo.lock` → `cargo test` is available

#### 5. Build Command Inference

Inferred from:
1. Manifest presence and type
2. Presence of build-related files (Makefile, gulpfile, webpack.config.js)
3. Package manager capabilities

Examples:
- If `package.json` with "build" script → `npm run build`
- If `Makefile` present → `make`
- If `Cargo.toml` → `cargo build`

### Output Schema

**Root Properties:**
- `schema_version`: "1.0.0"
- `workspace_path`: (absolute path analyzed)
- `analyzed_at`: ISO 8601 timestamp (intentionally nondeterministic; can be overridden for testing)
- `ecosystems`: array of detected ecosystems
- `manifests`: array of found manifests with paths and metadata
- `virtual_environments`: array of detected environments
- `package_managers`: array of inferred package managers
- `test_commands`: array of inferred test commands with evidence
- `build_commands`: array of inferred build commands with evidence
- `tool_availability`: object mapping inferred tool names to availability status
- `diagnostics`: array of non-fatal warnings and errors (malformed manifests, conflicts)
- `confidence_summary`: aggregate confidence metrics

**Command Object Structure:**
```json
{
  "command": "pytest",
  "ecosystem": "python",
  "confidence": "high",
  "evidence": [
    { "type": "manifest", "path": "pyproject.toml", "signal": "[tool.pytest]" },
    { "type": "environment", "found": true, "path": ".venv" }
  ],
  "inferred_from": ["manifest", "environment"],
  "required_tool": "python",
  "tool_status": "available"
}
```

**Tool Availability Object:**
```json
{
  "tool_availability": {
    "python": { "status": "available", "version": "3.11.7", "path": "C:\\Python311\\python.exe" },
    "npm": { "status": "available", "version": "9.6.4", "path": "C:\\Users\\user\\AppData\\Roaming\\npm\\npm.cmd" },
    "pytest": { "status": "unknown", "reason": "inferred from manifest; not in machine inventory" },
    "cargo": { "status": "unavailable", "reason": "not found on machine" }
  }
}
```

**Diagnostic Object Examples:**
```json
{
  "diagnostics": [
    { "type": "malformed_manifest", "path": "pyproject.toml", "error": "invalid TOML syntax on line 5" },
    { "type": "package_manager_conflict", "path": "package-lock.json, yarn.lock", "message": "both npm and yarn lockfiles present" },
    { "type": "deep_nested_manifest", "path": "src/subproject/package.json", "message": "ignored (beyond MaxDepth)" }
  ]
}
```

**Evidence Object:**
- `type`: "manifest" | "environment" | "lockfile" | "script" | "config"
- `path`: relative path within workspace
- `signal`: specific content/name that triggered detection
- `found`: boolean (presence confirmation)

### Test Matrix

Phase 1 Pester tests will validate:

#### Single-Language Projects
- ✓ Node.js-only (package.json + node_modules)
- ✓ Python-only (pyproject.toml + .venv)
- ✓ Rust-only (Cargo.toml + Cargo.lock)
- ✓ Go-only (go.mod + go.sum)

#### Polyglot Projects
- ✓ Node.js + Python (package.json + pyproject.toml)
- ✓ Node.js + Go (package.json + go.mod)
- ✓ Python + Rust (setup.py + Cargo.toml)

#### Edge Cases
- ✓ Empty workspace (no manifests)
- ✓ Missing virtual environment (manifest present, venv not created)
- ✓ Malformed JSON manifest (graceful error handling)
- ✓ Deep nesting (manifests in subdirectories)
- ✓ Multiple package managers in same ecosystem (npm + yarn)

### Non-Scope (Phase 2+)

- Command execution or validation
- CI/CD pipeline detection (GitHub Actions, GitLab CI, etc.)
- Dependency vulnerability scanning
- Performance profiling
- IDE/editor configuration analysis
- Docker/container detection
- Cloud platform specifics

### Integration with Machine Inventory

Cross-reference available tools from `machine-inventory.json`:
- Verify `npm` is in `available: true` tools before reporting npm commands
- Verify `python` is available before reporting pytest
- Verify `cargo` is available before reporting cargo test
- Record tool availability in confidence metadata

---

## Implementation Checklist

- [ ] Define JSON schema (workspace-environment.schema.json)
- [ ] Create Pester test suite (machine-workspace.tests.ps1)
- [ ] Implement manifest detection engine
- [ ] Implement virtual environment detection
- [ ] Implement package manager inference
- [ ] Implement command inference logic
- [ ] Add JSON Schema validation
- [ ] Integrate machine inventory cross-reference
- [ ] Document confidence levels
- [ ] Create example outputs for test data

---

## Success Criteria

1. All Pester tests pass (100%)
2. JSON Schema validation passes
3. Handles polyglot workspaces correctly
4. Provides evidence for every inference
5. Runs deterministically (same input → same output)
6. No command execution or file modification
7. Integrates cleanly with v0.3.0 inventory
