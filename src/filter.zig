const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("changelog.zig");
const CommitType = changelog.CommitType;
const Commit = changelog.Commit;

/// Configuration for filtering commits.
pub const FilterConfig = struct {
    /// Include refactor commits (excluded by default: false).
    include_refactor: bool = false,

    /// Include docs commits (excluded by default: false).
    include_docs: bool = false,

    /// Include chore commits (excluded by default: false).
    include_chore: bool = false,

    /// Include test commits (excluded by default: false).
    include_test: bool = false,

    /// Include CI commits (excluded by default: false).
    include_ci: bool = false,

    /// Include build commits (excluded by default: false).
    include_build: bool = false,

    /// Scopes to exclude (e.g., "deps", "internal").
    exclude_scopes: []const []const u8 = &.{},

    /// Custom patterns to exclude (case-insensitive substring match).
    exclude_patterns: []const []const u8 = &.{},

    /// Include merge commits (excluded by default: false).
    include_merge_commits: bool = false,
};

/// Reason why a commit was excluded.
pub const ExclusionReason = enum {
    /// Commit type excluded by default (chore, test, ci, build).
    excluded_type,
    /// Scope is in the exclusion list.
    excluded_scope,
    /// Message matches an exclusion pattern.
    excluded_pattern,
    /// Commit is a merge commit.
    merge_commit,
    /// Not excluded.
    none,
};

/// Statistics about filtered commits.
pub const FilterStats = struct {
    total: usize = 0,
    included: usize = 0,
    excluded_by_type: usize = 0,
    excluded_by_scope: usize = 0,
    excluded_by_pattern: usize = 0,
    excluded_merge_commits: usize = 0,

    /// Type-specific exclusion counts.
    type_counts: std.StringHashMapUnmanaged(usize) = .{},

    pub fn deinit(self: *FilterStats, allocator: Allocator) void {
        self.type_counts.deinit(allocator);
        self.* = undefined;
    }

    pub fn recordExclusion(self: *FilterStats, allocator: Allocator, reason: ExclusionReason, commit_type: CommitType) !void {
        switch (reason) {
            .excluded_type => {
                self.excluded_by_type += 1;
                const type_name = commit_type.toSectionName();
                const gop = try self.type_counts.getOrPut(allocator, type_name);
                if (gop.found_existing) {
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                }
            },
            .excluded_scope => self.excluded_by_scope += 1,
            .excluded_pattern => self.excluded_by_pattern += 1,
            .merge_commit => self.excluded_merge_commits += 1,
            .none => {},
        }
    }

    pub fn recordInclusion(self: *FilterStats) void {
        self.included += 1;
    }

    pub fn totalExcluded(self: FilterStats) usize {
        return self.excluded_by_type + self.excluded_by_scope + self.excluded_by_pattern + self.excluded_merge_commits;
    }
};

/// Commit filter that applies filtering rules.
pub const Filter = struct {
    config: FilterConfig,

    const Self = @This();

    /// Creates a filter with the given configuration.
    pub fn init(config: FilterConfig) Self {
        return .{ .config = config };
    }

    /// Creates a filter with default configuration.
    pub fn initDefault() Self {
        return .{ .config = .{} };
    }

    /// Determines if a commit should be included in the changelog.
    /// Returns the exclusion reason (or .none if included).
    pub fn shouldInclude(self: *const Self, commit: Commit) ExclusionReason {
        // Check for merge commit
        if (!self.config.include_merge_commits and changelog.isMergeCommit(commit.description)) {
            return .merge_commit;
        }

        // Check for exclusion patterns in message
        if (self.matchesExclusionPattern(commit)) {
            return .excluded_pattern;
        }

        // Check for excluded scope
        if (self.isExcludedScope(commit.scope)) {
            return .excluded_scope;
        }

        // Check for excluded type
        if (self.isExcludedType(commit.commit_type)) {
            return .excluded_type;
        }

        return .none;
    }

    /// Checks if the commit message matches any exclusion pattern.
    fn matchesExclusionPattern(self: *const Self, commit: Commit) bool {
        // Check default patterns first
        if (changelog.shouldExcludeByMessage(commit.description)) {
            return true;
        }

        // Check body if present
        if (commit.body) |body| {
            if (changelog.shouldExcludeByMessage(body)) {
                return true;
            }
        }

        // Check custom patterns
        if (self.config.exclude_patterns.len > 0) {
            if (changelog.containsAnyPattern(commit.description, self.config.exclude_patterns)) {
                return true;
            }
            if (commit.body) |body| {
                if (changelog.containsAnyPattern(body, self.config.exclude_patterns)) {
                    return true;
                }
            }
        }

        return false;
    }

    /// Checks if the scope is in the exclusion list.
    fn isExcludedScope(self: *const Self, scope: ?[]const u8) bool {
        const s = scope orelse return false;

        for (self.config.exclude_scopes) |excluded| {
            if (std.ascii.eqlIgnoreCase(s, excluded)) {
                return true;
            }
        }
        return false;
    }

    /// Checks if the commit type should be excluded based on config.
    fn isExcludedType(self: *const Self, commit_type: CommitType) bool {
        return switch (commit_type) {
            .chore => !self.config.include_chore,
            .@"test" => !self.config.include_test,
            .ci => !self.config.include_ci,
            .build => !self.config.include_build,
            .refactor => !self.config.include_refactor,
            .docs => !self.config.include_docs,
            else => false,
        };
    }

    /// Filters a list of commits, returning only those that should be included.
    /// Caller owns the returned slice (but not the commit contents - they reference the input).
    pub fn filterCommits(self: *const Self, allocator: Allocator, commits: []const Commit) ![]const Commit {
        var result = std.ArrayListUnmanaged(Commit){};
        errdefer result.deinit(allocator);

        for (commits) |commit| {
            if (self.shouldInclude(commit) == .none) {
                try result.append(allocator, commit);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Filters commits and tracks statistics.
    /// Caller owns the returned slice.
    pub fn filterCommitsWithStats(
        self: *const Self,
        allocator: Allocator,
        commits: []const Commit,
        stats: *FilterStats,
    ) ![]const Commit {
        var result = std.ArrayListUnmanaged(Commit){};
        errdefer result.deinit(allocator);

        for (commits) |commit| {
            stats.total += 1;
            const reason = self.shouldInclude(commit);
            if (reason == .none) {
                try result.append(allocator, commit);
                stats.recordInclusion();
            } else {
                try stats.recordExclusion(allocator, reason, commit.commit_type);
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

// Tests

test "Filter excludes chore by default" {
    const filter = Filter.initDefault();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .chore,
        .scope = null,
        .description = "update dependencies",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.excluded_type, filter.shouldInclude(commit));
}

test "Filter includes feat by default" {
    const filter = Filter.initDefault();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "add new feature",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.none, filter.shouldInclude(commit));
}

test "Filter can include chore with config" {
    const filter = Filter.init(.{ .include_chore = true });

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .chore,
        .scope = null,
        .description = "update dependencies",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.none, filter.shouldInclude(commit));
}

test "Filter excludes by scope" {
    const filter = Filter.init(.{
        .exclude_scopes = &[_][]const u8{ "deps", "internal" },
    });

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = "deps",
        .description = "update dependencies",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.excluded_scope, filter.shouldInclude(commit));
}

test "Filter excludes by pattern" {
    const filter = Filter.initDefault();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "WIP: work in progress",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.excluded_pattern, filter.shouldInclude(commit));
}

test "Filter excludes merge commits" {
    const filter = Filter.initDefault();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .unknown,
        .scope = null,
        .description = "Merge branch 'feature' into main",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.merge_commit, filter.shouldInclude(commit));
}

test "Filter can include merge commits with config" {
    const filter = Filter.init(.{ .include_merge_commits = true });

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .unknown,
        .scope = null,
        .description = "Merge branch 'feature' into main",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.none, filter.shouldInclude(commit));
}

test "Filter excludes by custom pattern" {
    const filter = Filter.init(.{
        .exclude_patterns = &[_][]const u8{"experimental"},
    });

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "add experimental feature",
        .body = null,
        .author = "Author",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try std.testing.expectEqual(ExclusionReason.excluded_pattern, filter.shouldInclude(commit));
}

test "FilterStats tracks exclusions" {
    var stats = FilterStats{};
    defer stats.deinit(std.testing.allocator);

    try stats.recordExclusion(std.testing.allocator, .excluded_type, .chore);
    try stats.recordExclusion(std.testing.allocator, .excluded_type, .chore);
    try stats.recordExclusion(std.testing.allocator, .excluded_scope, .feat);
    stats.recordInclusion();

    try std.testing.expectEqual(@as(usize, 2), stats.excluded_by_type);
    try std.testing.expectEqual(@as(usize, 1), stats.excluded_by_scope);
    try std.testing.expectEqual(@as(usize, 1), stats.included);
    try std.testing.expectEqual(@as(usize, 3), stats.totalExcluded());
    try std.testing.expectEqual(@as(usize, 2), stats.type_counts.get("Chore").?);
}

test "filterCommits returns only included commits" {
    const filter = Filter.initDefault();

    const commits = [_]Commit{
        .{
            .hash = "1",
            .short_hash = "1",
            .commit_type = .feat,
            .scope = null,
            .description = "feature",
            .body = null,
            .author = "A",
            .date = "D",
            .breaking = false,
            .issues = &.{},
        },
        .{
            .hash = "2",
            .short_hash = "2",
            .commit_type = .chore,
            .scope = null,
            .description = "chore",
            .body = null,
            .author = "A",
            .date = "D",
            .breaking = false,
            .issues = &.{},
        },
        .{
            .hash = "3",
            .short_hash = "3",
            .commit_type = .fix,
            .scope = null,
            .description = "fix",
            .body = null,
            .author = "A",
            .date = "D",
            .breaking = false,
            .issues = &.{},
        },
    };

    const filtered = try filter.filterCommits(std.testing.allocator, &commits);
    defer std.testing.allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqual(CommitType.feat, filtered[0].commit_type);
    try std.testing.expectEqual(CommitType.fix, filtered[1].commit_type);
}

test "filterCommitsWithStats tracks all statistics" {
    const filter = Filter.initDefault();

    const commits = [_]Commit{
        .{
            .hash = "1",
            .short_hash = "1",
            .commit_type = .feat,
            .scope = null,
            .description = "feature",
            .body = null,
            .author = "A",
            .date = "D",
            .breaking = false,
            .issues = &.{},
        },
        .{
            .hash = "2",
            .short_hash = "2",
            .commit_type = .chore,
            .scope = null,
            .description = "chore",
            .body = null,
            .author = "A",
            .date = "D",
            .breaking = false,
            .issues = &.{},
        },
        .{
            .hash = "3",
            .short_hash = "3",
            .commit_type = .feat,
            .scope = null,
            .description = "WIP: incomplete",
            .body = null,
            .author = "A",
            .date = "D",
            .breaking = false,
            .issues = &.{},
        },
    };

    var stats = FilterStats{};
    defer stats.deinit(std.testing.allocator);

    const filtered = try filter.filterCommitsWithStats(std.testing.allocator, &commits, &stats);
    defer std.testing.allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqual(@as(usize, 3), stats.total);
    try std.testing.expectEqual(@as(usize, 1), stats.included);
    try std.testing.expectEqual(@as(usize, 1), stats.excluded_by_type);
    try std.testing.expectEqual(@as(usize, 1), stats.excluded_by_pattern);
}
