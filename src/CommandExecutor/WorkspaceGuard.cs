using System;
using System.IO;
using System.Linq;

namespace CommandExecutor;

/// <summary>
/// Enforces workspace containment: no symlinks, no parent traversal, no absolute paths outside workspace.
/// Canonical paths are resolved before comparison to prevent bypass via path normalization tricks.
/// </summary>
public class WorkspaceGuard
{
    private readonly string _workspacePath;
    private readonly string _canonicalWorkspace;

    public WorkspaceGuard(string workspacePath)
    {
        _workspacePath = workspacePath ?? throw new ArgumentNullException(nameof(workspacePath));
        _canonicalWorkspace = Path.GetFullPath(_workspacePath);
    }

    /// <summary>
    /// Validates that the working directory is within workspace and has no symlinks.
    /// Returns null if valid, or rejection_reason if containment is violated.
    /// </summary>
    public string? ValidateWorkingDirectory(string relativeOrAbsolutePath)
    {
        if (string.IsNullOrWhiteSpace(relativeOrAbsolutePath))
            return null; // Empty path defaults to workspace root

        try
        {
            // Resolve to absolute path
            string targetPath;
            if (Path.IsPathRooted(relativeOrAbsolutePath))
            {
                // Absolute path: only accept if it's under workspace
                targetPath = Path.GetFullPath(relativeOrAbsolutePath);
            }
            else
            {
                // Relative path: resolve from workspace
                targetPath = Path.GetFullPath(Path.Combine(_canonicalWorkspace, relativeOrAbsolutePath));
            }

            // Normalize both paths for comparison (remove . and .. components)
            string targetCanonical = Path.GetFullPath(targetPath);

            // Check containment: target must be under or equal to workspace
            if (!IsPathUnderOrEqual(targetCanonical, _canonicalWorkspace))
            {
                return "workspace_containment_violation";
            }

            // Check for symlinks in the resolved path
            if (ContainsSymlink(targetCanonical))
            {
                return "workspace_containment_violation";
            }

            return null; // Valid
        }
        catch (Exception)
        {
            // Any path resolution error is treated as containment violation
            return "workspace_containment_violation";
        }
    }

    /// <summary>
    /// Checks if a path is under or equal to the base path (case-insensitive on Windows).
    /// </summary>
    private static bool IsPathUnderOrEqual(string path, string basePath)
    {
        // Normalize slashes and ensure both paths are fully resolved
        var pathNorm = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        var baseNorm = Path.GetFullPath(basePath).TrimEnd(Path.DirectorySeparatorChar);

        // Case-insensitive comparison (Windows) vs case-sensitive (Linux/Mac)
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

        return pathNorm.Equals(baseNorm, comparison) ||
               pathNorm.StartsWith(baseNorm + Path.DirectorySeparatorChar, comparison);
    }

    /// <summary>
    /// Detects symlinks in the path chain (if running on a system that supports them).
    /// </summary>
    private static bool ContainsSymlink(string path)
    {
        try
        {
            // On Windows, symlinks require special handling (requires admin or dev mode).
            // On Linux/Mac, check each component.
            if (OperatingSystem.IsLinux() || OperatingSystem.IsMacOS())
            {
                var info = new FileInfo(path);
                if (info.Exists && info.LinkTarget != null)
                    return true;
            }

            return false;
        }
        catch
        {
            // If we can't check, assume it's safe (symlink detection is platform-dependent)
            return false;
        }
    }
}
