const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("changelog.zig");
const Commit = changelog.Commit;
const CommitGroup = changelog.CommitGroup;

/// Strategy for grouping commits.
pub const GroupingStrategy = enum {
    /// No grouping - all commits in flat list.
    none,
    /// Group by scope field (e.g., "ui", "api", "core").
    by_scope,
    /// Group by keyword patterns in description.
    by_keyword,
    /// Group by file path prefix (requires path data).
    by_path,
};

/// Pattern for keyword-based grouping.
pub const KeywordPattern = struct {
    /// Keywords to match (case-insensitive).
    keywords: []const []const u8,
    /// Group name to assign.
    group_name: []const u8,
    /// Human-readable label for the group.
    label: ?[]const u8,
};

/// Configuration for commit grouping.
pub const GroupingConfig = struct {
    /// Grouping strategy to use.
    strategy: GroupingStrategy = .none,
    /// Minimum number of commits for a group to be created.
    min_group_size: usize = 2,
    /// Keyword patterns for by_keyword strategy.
    keyword_patterns: []const KeywordPattern = &.{},
    /// Custom scope labels (scope name -> display label).
    scope_labels: []const ScopeLabel = &.{},
};

/// Maps a scope to a human-readable label.
pub const ScopeLabel = struct {
    scope: []const u8,
    label: []const u8,
};

/// Commit grouping engine.
pub const Grouper = struct {
    allocator: Allocator,
    config: GroupingConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: GroupingConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Groups commits according to the configured strategy.
    /// Returns a map from group name to CommitGroup.
    /// Commits not matching any group are placed in the "" (empty string) group.
    /// Caller owns the returned map and must deinit each CommitGroup.
    pub fn groupCommits(self: *const Self, commits: []const Commit) !std.StringHashMapUnmanaged(CommitGroup) {
        return switch (self.config.strategy) {
            .none => self.groupNone(commits),
            .by_scope => self.groupByScope(commits),
            .by_keyword => self.groupByKeyword(commits),
            .by_path => self.groupByScope(commits), // fallback to scope for now
        };
    }

    /// No grouping - returns empty map (commits should be used directly).
    fn groupNone(self: *const Self, commits: []const Commit) !std.StringHashMapUnmanaged(CommitGroup) {
        _ = self;
        _ = commits;
        return std.StringHashMapUnmanaged(CommitGroup){};
    }

    /// Groups commits by their scope field.
    fn groupByScope(self: *const Self, commits: []const Commit) !std.StringHashMapUnmanaged(CommitGroup) {
        var groups = std.StringHashMapUnmanaged(CommitGroup){};
        errdefer {
            var iter = groups.valueIterator();
            while (iter.next()) |group| {
                group.deinit(self.allocator);
            }
            groups.deinit(self.allocator);
        }

        // First pass: count commits per scope
        var scope_counts = std.StringHashMapUnmanaged(usize){};
        defer scope_counts.deinit(self.allocator);

        for (commits) |commit| {
            const scope = commit.scope orelse "";
            const gop = try scope_counts.getOrPut(self.allocator, scope);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
            } else {
                gop.value_ptr.* = 1;
            }
        }

        // Second pass: create groups
        for (commits) |commit| {
            const scope = commit.scope orelse "";
            const count = scope_counts.get(scope) orelse 0;

            // Only create groups that meet minimum size
            if (count >= self.config.min_group_size) {
                const gop = try groups.getOrPut(self.allocator, scope);
                if (!gop.found_existing) {
                    gop.value_ptr.* = CommitGroup{
                        .name = scope,
                        .label = self.getLabelForScope(scope),
                    };
                }
                const cloned = try commit.clone(self.allocator);
                try gop.value_ptr.addCommit(self.allocator, cloned);
            } else if (scope.len > 0) {
                // Put small-count scoped commits in "ungrouped" category
                const ungrouped_key = "";
                const gop = try groups.getOrPut(self.allocator, ungrouped_key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = CommitGroup{
                        .name = "",
                        .label = null,
                    };
                }
                const cloned = try commit.clone(self.allocator);
                try gop.value_ptr.addCommit(self.allocator, cloned);
            } else {
                // Unscoped commits also go to ungrouped
                const ungrouped_key = "";
                const gop = try groups.getOrPut(self.allocator, ungrouped_key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = CommitGroup{
                        .name = "",
                        .label = null,
                    };
                }
                const cloned = try commit.clone(self.allocator);
                try gop.value_ptr.addCommit(self.allocator, cloned);
            }
        }

        return groups;
    }

    /// Groups commits by keyword patterns in their description.
    fn groupByKeyword(self: *const Self, commits: []const Commit) !std.StringHashMapUnmanaged(CommitGroup) {
        var groups = std.StringHashMapUnmanaged(CommitGroup){};
        errdefer {
            var iter = groups.valueIterator();
            while (iter.next()) |group| {
                group.deinit(self.allocator);
            }
            groups.deinit(self.allocator);
        }

        for (commits) |commit| {
            const group_name = self.findKeywordMatch(commit.description) orelse "";
            const gop = try groups.getOrPut(self.allocator, group_name);
            if (!gop.found_existing) {
                gop.value_ptr.* = CommitGroup{
                    .name = group_name,
                    .label = self.getLabelForKeywordGroup(group_name),
                };
            }
            const cloned = try commit.clone(self.allocator);
            try gop.value_ptr.addCommit(self.allocator, cloned);
        }

        return groups;
    }

    /// Finds a keyword pattern match for a description.
    fn findKeywordMatch(self: *const Self, description: []const u8) ?[]const u8 {
        // Convert description to lowercase for matching
        var lower_buf: [512]u8 = undefined;
        const len = @min(description.len, lower_buf.len);
        for (description[0..len], 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        const lower = lower_buf[0..len];

        for (self.config.keyword_patterns) |pattern| {
            for (pattern.keywords) |keyword| {
                if (std.mem.indexOf(u8, lower, keyword) != null) {
                    return pattern.group_name;
                }
            }
        }
        return null;
    }

    /// Gets the display label for a scope.
    fn getLabelForScope(self: *const Self, scope: []const u8) ?[]const u8 {
        for (self.config.scope_labels) |sl| {
            if (std.mem.eql(u8, sl.scope, scope)) {
                return sl.label;
            }
        }
        return null;
    }

    /// Gets the display label for a keyword group.
    fn getLabelForKeywordGroup(self: *const Self, group_name: []const u8) ?[]const u8 {
        for (self.config.keyword_patterns) |pattern| {
            if (std.mem.eql(u8, pattern.group_name, group_name)) {
                return pattern.label;
            }
        }
        return null;
    }
};

/// Gets a human-readable label for a scope, with fallback to title case.
pub fn formatScopeLabel(scope: []const u8) []const u8 {
    // For simple implementation, just return the scope as-is
    // A more sophisticated version could title-case it
    return scope;
}

// Tests

test "Grouper groups commits by scope" {
    const allocator = std.testing.allocator;

    var grouper = Grouper.init(allocator, .{
        .strategy = .by_scope,
        .min_group_size = 2,
    });

    const commits = [_]Commit{
        makeTestCommit("ui", "add button"),
        makeTestCommit("ui", "add modal"),
        makeTestCommit("api", "add endpoint"),
        makeTestCommit(null, "general change"),
    };

    var groups = try grouper.groupCommits(&commits);
    defer {
        var iter = groups.valueIterator();
        while (iter.next()) |group| {
            group.deinit(allocator);
        }
        groups.deinit(allocator);
    }

    // "ui" should have its own group
    try std.testing.expect(groups.contains("ui"));
    try std.testing.expectEqual(@as(usize, 2), groups.get("ui").?.commits.items.len);

    // "api" and unscoped should be in the ungrouped category
    try std.testing.expect(groups.contains(""));
    try std.testing.expectEqual(@as(usize, 2), groups.get("").?.commits.items.len);

    // "api" shouldn't have its own group (only 1 commit)
    try std.testing.expect(!groups.contains("api"));
}

test "Grouper respects min_group_size" {
    const allocator = std.testing.allocator;

    var grouper = Grouper.init(allocator, .{
        .strategy = .by_scope,
        .min_group_size = 3,
    });

    const commits = [_]Commit{
        makeTestCommit("ui", "add button"),
        makeTestCommit("ui", "add modal"),
        makeTestCommit("api", "add endpoint"),
    };

    var groups = try grouper.groupCommits(&commits);
    defer {
        var iter = groups.valueIterator();
        while (iter.next()) |group| {
            group.deinit(allocator);
        }
        groups.deinit(allocator);
    }

    // Neither should have its own group with min_size=3
    try std.testing.expect(!groups.contains("ui"));
    try std.testing.expect(!groups.contains("api"));
    // All should be in ungrouped
    try std.testing.expect(groups.contains(""));
}

test "Grouper handles commits without scope" {
    const allocator = std.testing.allocator;

    var grouper = Grouper.init(allocator, .{
        .strategy = .by_scope,
        .min_group_size = 2,
    });

    const commits = [_]Commit{
        makeTestCommit(null, "general change 1"),
        makeTestCommit(null, "general change 2"),
    };

    var groups = try grouper.groupCommits(&commits);
    defer {
        var iter = groups.valueIterator();
        while (iter.next()) |group| {
            group.deinit(allocator);
        }
        groups.deinit(allocator);
    }

    // All should be in ungrouped
    try std.testing.expect(groups.contains(""));
    try std.testing.expectEqual(@as(usize, 2), groups.get("").?.commits.items.len);
}

test "Grouper none strategy returns empty groups" {
    const allocator = std.testing.allocator;

    var grouper = Grouper.init(allocator, .{
        .strategy = .none,
    });

    const commits = [_]Commit{
        makeTestCommit("ui", "add button"),
    };

    var groups = try grouper.groupCommits(&commits);
    defer groups.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), groups.count());
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
