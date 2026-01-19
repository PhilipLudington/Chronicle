const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("changelog.zig");
const Commit = changelog.Commit;

/// Configuration for monorepo support.
pub const MonorepoConfig = struct {
    /// Whether monorepo mode is enabled.
    enabled: bool = false,
    /// Prefixes that indicate a package scope (e.g., "packages/", "@org/").
    package_prefixes: []const []const u8 = &.{},
    /// Generate per-package changelogs.
    per_package_changelogs: bool = false,
    /// Strip prefix from package name in output.
    strip_prefix: bool = true,
};

/// Monorepo management engine for package detection and filtering.
pub const MonorepoManager = struct {
    allocator: Allocator,
    config: MonorepoConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: MonorepoConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Extracts the package name from a commit's scope.
    /// Returns null if the scope doesn't match any package prefix.
    pub fn extractPackage(self: *const Self, scope: ?[]const u8) ?[]const u8 {
        const s = scope orelse return null;

        for (self.config.package_prefixes) |prefix| {
            if (std.mem.startsWith(u8, s, prefix)) {
                if (self.config.strip_prefix) {
                    const stripped = s[prefix.len..];
                    // Find end of package name (first / or end of string)
                    const end = std.mem.indexOfScalar(u8, stripped, '/') orelse stripped.len;
                    return stripped[0..end];
                } else {
                    const end = std.mem.indexOfScalarPos(u8, s, prefix.len, '/') orelse s.len;
                    return s[0..end];
                }
            }
        }

        // Check if scope itself looks like a package name without prefix
        // (e.g., just "cli" or "core" in a monorepo)
        if (self.config.package_prefixes.len == 0) {
            // If no prefixes defined, treat any scope as a potential package
            return s;
        }

        return null;
    }

    /// Gets all unique packages from a list of commits.
    /// Returns a slice of package names. Caller owns the returned memory.
    pub fn getPackages(self: *const Self, commits: []const Commit) ![]const []const u8 {
        var packages = std.StringHashMapUnmanaged(void){};
        defer packages.deinit(self.allocator);

        for (commits) |commit| {
            if (self.extractPackage(commit.scope)) |pkg| {
                _ = try packages.getOrPut(self.allocator, pkg);
            }
        }

        var result = std.ArrayListUnmanaged([]const u8){};
        errdefer result.deinit(self.allocator);

        var iter = packages.keyIterator();
        while (iter.next()) |key| {
            const owned = try self.allocator.dupe(u8, key.*);
            try result.append(self.allocator, owned);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Filters commits to only include those belonging to a specific package.
    /// Returns a slice of commits (references to original commits, not cloned).
    /// Caller owns the returned slice array but not the commit data.
    pub fn filterByPackage(self: *const Self, commits: []const Commit, package: []const u8) ![]const Commit {
        var filtered = std.ArrayListUnmanaged(Commit){};
        errdefer filtered.deinit(self.allocator);

        for (commits) |commit| {
            if (self.extractPackage(commit.scope)) |pkg| {
                if (std.mem.eql(u8, pkg, package)) {
                    try filtered.append(self.allocator, commit);
                }
            }
        }

        return try filtered.toOwnedSlice(self.allocator);
    }

    /// Filters commits to exclude those belonging to any known package.
    /// This returns commits that are "shared" across all packages.
    /// Returns a slice of commits (references to original commits, not cloned).
    pub fn filterSharedCommits(self: *const Self, commits: []const Commit) ![]const Commit {
        var shared = std.ArrayListUnmanaged(Commit){};
        errdefer shared.deinit(self.allocator);

        for (commits) |commit| {
            if (self.extractPackage(commit.scope) == null) {
                try shared.append(self.allocator, commit);
            }
        }

        return try shared.toOwnedSlice(self.allocator);
    }

    /// Checks if a scope belongs to a specific package.
    pub fn scopeBelongsToPackage(self: *const Self, scope: ?[]const u8, package: []const u8) bool {
        if (self.extractPackage(scope)) |pkg| {
            return std.mem.eql(u8, pkg, package);
        }
        return false;
    }
};

/// Formats a package name for display (e.g., as a section header).
pub fn formatPackageName(package: []const u8) []const u8 {
    // For now, just return as-is
    // Could be enhanced to title-case or add formatting
    return package;
}

// Tests

test "MonorepoManager extracts package from scope with prefix" {
    const allocator = std.testing.allocator;

    const prefixes = [_][]const u8{"packages/"};

    var manager = MonorepoManager.init(allocator, .{
        .enabled = true,
        .package_prefixes = &prefixes,
        .strip_prefix = true,
    });

    // Should extract "cli" from "packages/cli"
    try std.testing.expectEqualStrings("cli", manager.extractPackage("packages/cli").?);

    // Should extract "core" from "packages/core/utils"
    try std.testing.expectEqualStrings("core", manager.extractPackage("packages/core/utils").?);

    // Should return null for non-matching scope
    try std.testing.expect(manager.extractPackage("ui") == null);

    // Should return null for null scope
    try std.testing.expect(manager.extractPackage(null) == null);
}

test "MonorepoManager extracts package without stripping prefix" {
    const allocator = std.testing.allocator;

    const prefixes = [_][]const u8{"@org/"};

    var manager = MonorepoManager.init(allocator, .{
        .enabled = true,
        .package_prefixes = &prefixes,
        .strip_prefix = false,
    });

    // Should keep prefix when strip_prefix is false
    try std.testing.expectEqualStrings("@org/cli", manager.extractPackage("@org/cli").?);
}

test "MonorepoManager filters commits by package" {
    const allocator = std.testing.allocator;

    const prefixes = [_][]const u8{"packages/"};

    var manager = MonorepoManager.init(allocator, .{
        .enabled = true,
        .package_prefixes = &prefixes,
    });

    const commits = [_]Commit{
        makeTestCommit("packages/cli", "add command"),
        makeTestCommit("packages/core", "add util"),
        makeTestCommit("packages/cli", "fix bug"),
        makeTestCommit("ui", "update style"),
    };

    const filtered = try manager.filterByPackage(&commits, "cli");
    defer allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
}

test "MonorepoManager gets all packages" {
    const allocator = std.testing.allocator;

    const prefixes = [_][]const u8{"packages/"};

    var manager = MonorepoManager.init(allocator, .{
        .enabled = true,
        .package_prefixes = &prefixes,
    });

    const commits = [_]Commit{
        makeTestCommit("packages/cli", "add command"),
        makeTestCommit("packages/core", "add util"),
        makeTestCommit("packages/cli", "fix bug"),
        makeTestCommit("ui", "update style"),
    };

    const packages = try manager.getPackages(&commits);
    defer {
        for (packages) |pkg| {
            allocator.free(pkg);
        }
        allocator.free(packages);
    }

    try std.testing.expectEqual(@as(usize, 2), packages.len);

    // Check that both packages are present
    var has_cli = false;
    var has_core = false;
    for (packages) |pkg| {
        if (std.mem.eql(u8, pkg, "cli")) has_cli = true;
        if (std.mem.eql(u8, pkg, "core")) has_core = true;
    }
    try std.testing.expect(has_cli);
    try std.testing.expect(has_core);
}

test "MonorepoManager filters shared commits" {
    const allocator = std.testing.allocator;

    const prefixes = [_][]const u8{"packages/"};

    var manager = MonorepoManager.init(allocator, .{
        .enabled = true,
        .package_prefixes = &prefixes,
    });

    const commits = [_]Commit{
        makeTestCommit("packages/cli", "add command"),
        makeTestCommit("packages/core", "add util"),
        makeTestCommit("ui", "update style"),
        makeTestCommit(null, "general change"),
    };

    const shared = try manager.filterSharedCommits(&commits);
    defer allocator.free(shared);

    // Should get "ui" and null-scoped commits
    try std.testing.expectEqual(@as(usize, 2), shared.len);
}

fn makeTestCommit(scope: ?[]const u8, description: []const u8) Commit {
    return Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = scope,
        .description = description,
        .body = null,
        .author = "test",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };
}
