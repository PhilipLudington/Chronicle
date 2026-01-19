const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents a conventional commit type parsed from the commit message prefix.
pub const CommitType = enum {
    feat,
    fix,
    perf,
    refactor,
    docs,
    deprecate,
    remove,
    security,
    chore,
    @"test",
    ci,
    build,
    unknown,

    /// Maps a commit type to its default changelog section name.
    pub fn toSectionName(self: CommitType) []const u8 {
        return switch (self) {
            .feat => "Added",
            .fix => "Fixed",
            .perf => "Performance",
            .refactor => "Changed",
            .docs => "Documentation",
            .deprecate => "Deprecated",
            .remove => "Removed",
            .security => "Security",
            .chore => "Chore",
            .@"test" => "Tests",
            .ci => "CI",
            .build => "Build",
            .unknown => "Other",
        };
    }

    /// Parses a string prefix into a CommitType.
    pub fn fromString(str: []const u8) CommitType {
        const map = std.StaticStringMap(CommitType).initComptime(.{
            .{ "feat", .feat },
            .{ "fix", .fix },
            .{ "perf", .perf },
            .{ "refactor", .refactor },
            .{ "docs", .docs },
            .{ "deprecate", .deprecate },
            .{ "remove", .remove },
            .{ "security", .security },
            .{ "chore", .chore },
            .{ "test", .@"test" },
            .{ "ci", .ci },
            .{ "build", .build },
        });
        return map.get(str) orelse .unknown;
    }

    /// Returns true if this commit type is typically excluded from changelogs.
    pub fn isExcludedByDefault(self: CommitType) bool {
        return switch (self) {
            .chore, .@"test", .ci, .build => true,
            else => false,
        };
    }
};

/// Represents a parsed commit from the git history.
pub const Commit = struct {
    hash: []const u8,
    short_hash: []const u8,
    commit_type: CommitType,
    scope: ?[]const u8,
    description: []const u8,
    body: ?[]const u8,
    author: []const u8,
    date: []const u8,
    breaking: bool,
    issues: []const []const u8,

    /// Creates a commit struct, duplicating all strings using the provided allocator.
    /// Caller owns the returned struct and must call deinit to free memory.
    pub fn clone(self: Commit, allocator: Allocator) !Commit {
        const hash = try allocator.dupe(u8, self.hash);
        errdefer allocator.free(hash);

        const short_hash = try allocator.dupe(u8, self.short_hash);
        errdefer allocator.free(short_hash);

        const description = try allocator.dupe(u8, self.description);
        errdefer allocator.free(description);

        const scope = if (self.scope) |s| try allocator.dupe(u8, s) else null;
        errdefer if (scope) |s| allocator.free(s);

        const body = if (self.body) |b| try allocator.dupe(u8, b) else null;
        errdefer if (body) |b| allocator.free(b);

        const author = try allocator.dupe(u8, self.author);
        errdefer allocator.free(author);

        const date = try allocator.dupe(u8, self.date);
        errdefer allocator.free(date);

        const issues = try allocator.alloc([]const u8, self.issues.len);
        errdefer allocator.free(issues);

        for (self.issues, 0..) |issue, i| {
            issues[i] = try allocator.dupe(u8, issue);
        }

        return Commit{
            .hash = hash,
            .short_hash = short_hash,
            .commit_type = self.commit_type,
            .scope = scope,
            .description = description,
            .body = body,
            .author = author,
            .date = date,
            .breaking = self.breaking,
            .issues = issues,
        };
    }

    /// Frees all memory owned by this commit.
    pub fn deinit(self: *Commit, allocator: Allocator) void {
        for (self.issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(self.issues);

        allocator.free(self.hash);
        allocator.free(self.short_hash);
        allocator.free(self.description);
        allocator.free(self.author);
        allocator.free(self.date);

        if (self.scope) |s| allocator.free(s);
        if (self.body) |b| allocator.free(b);

        self.* = undefined;
    }
};

/// Statistics about commit processing.
pub const Stats = struct {
    included: usize = 0,
    excluded: usize = 0,
    excluded_by_type: std.StringHashMapUnmanaged(usize) = .{},

    pub fn deinit(self: *Stats, allocator: Allocator) void {
        self.excluded_by_type.deinit(allocator);
        self.* = undefined;
    }

    /// Records an excluded commit by its type.
    pub fn recordExclusion(self: *Stats, allocator: Allocator, commit_type: CommitType) !void {
        self.excluded += 1;
        const type_name = commit_type.toSectionName();
        const gop = try self.excluded_by_type.getOrPut(allocator, type_name);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }

    /// Records an included commit.
    pub fn recordInclusion(self: *Stats) void {
        self.included += 1;
    }
};

/// A section in the changelog (e.g., "Added", "Fixed").
pub const Section = struct {
    name: []const u8,
    commits: std.ArrayListUnmanaged(Commit) = .{},

    pub fn deinit(self: *Section, allocator: Allocator) void {
        for (self.commits.items) |*commit| {
            commit.deinit(allocator);
        }
        self.commits.deinit(allocator);
        self.* = undefined;
    }

    pub fn addCommit(self: *Section, allocator: Allocator, commit: Commit) !void {
        try self.commits.append(allocator, commit);
    }
};

/// Represents a complete changelog entry for a single version.
pub const ChangelogEntry = struct {
    allocator: Allocator,
    version: []const u8,
    date: []const u8,
    sections: std.StringHashMapUnmanaged(Section) = .{},
    stats: Stats = .{},

    pub fn init(allocator: Allocator, version: []const u8, date: []const u8) !ChangelogEntry {
        const owned_version = try allocator.dupe(u8, version);
        errdefer allocator.free(owned_version);

        const owned_date = try allocator.dupe(u8, date);

        return ChangelogEntry{
            .allocator = allocator,
            .version = owned_version,
            .date = owned_date,
        };
    }

    pub fn deinit(self: *ChangelogEntry) void {
        var section_iter = self.sections.valueIterator();
        while (section_iter.next()) |section| {
            section.deinit(self.allocator);
        }
        self.sections.deinit(self.allocator);
        self.stats.deinit(self.allocator);

        self.allocator.free(self.version);
        self.allocator.free(self.date);

        self.* = undefined;
    }

    /// Adds a commit to the appropriate section based on its type.
    /// Clones the commit, so the caller retains ownership of the original.
    pub fn addCommit(self: *ChangelogEntry, commit: Commit) !void {
        const section_name = commit.commit_type.toSectionName();
        const gop = try self.sections.getOrPut(self.allocator, section_name);

        if (!gop.found_existing) {
            gop.value_ptr.* = Section{ .name = section_name };
        }

        const cloned = try commit.clone(self.allocator);
        try gop.value_ptr.addCommit(self.allocator, cloned);
        self.stats.recordInclusion();
    }

    /// Records an excluded commit in the stats.
    pub fn recordExclusion(self: *ChangelogEntry, commit_type: CommitType) !void {
        try self.stats.recordExclusion(self.allocator, commit_type);
    }

    /// Returns section names in the standard Keep-a-Changelog order.
    pub fn getSectionOrder() []const []const u8 {
        return &[_][]const u8{
            "Added",
            "Changed",
            "Deprecated",
            "Removed",
            "Fixed",
            "Security",
            "Performance",
            "Documentation",
            "Other",
        };
    }
};

// String utilities for commit parsing

/// Extracts issue references (e.g., #123, #456) from text.
/// Returns a slice of issue strings. Caller owns the returned memory.
pub fn extractIssues(allocator: Allocator, text: []const u8) ![]const []const u8 {
    var issues = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (issues.items) |issue| {
            allocator.free(issue);
        }
        issues.deinit(allocator);
    }

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '#') {
            const start = i;
            i += 1;
            // Consume digits
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
            // Must have at least one digit
            if (i > start + 1) {
                const issue = try allocator.dupe(u8, text[start..i]);
                try issues.append(allocator, issue);
            }
        }
    }

    return try issues.toOwnedSlice(allocator);
}

/// Trims whitespace from both ends of a string.
pub fn trimWhitespace(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, " \t\n\r");
}

/// Splits a string by a delimiter, returning an array of slices.
/// Caller owns the returned slice array (but not the string data).
pub fn splitLines(allocator: Allocator, text: []const u8) ![]const []const u8 {
    var lines = std.ArrayListUnmanaged([]const u8){};
    errdefer lines.deinit(allocator);

    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        const trimmed = trimWhitespace(line);
        if (trimmed.len > 0) {
            try lines.append(allocator, trimmed);
        }
    }

    return try lines.toOwnedSlice(allocator);
}

/// Checks if a string contains any of the given patterns (case-insensitive).
pub fn containsAnyPattern(text: []const u8, patterns: []const []const u8) bool {
    const lower = blk: {
        var buf: [256]u8 = undefined;
        const len = @min(text.len, buf.len);
        for (text[0..len], 0..) |c, i| {
            buf[i] = std.ascii.toLower(c);
        }
        break :blk buf[0..len];
    };

    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, lower, pattern) != null) {
            return true;
        }
    }
    return false;
}

/// Default patterns that indicate a commit should be excluded.
pub const default_exclude_patterns = [_][]const u8{
    "wip",
    "fixup",
    "squash",
    "typo",
    "[skip changelog]",
    "[skip ci]",
};

/// Checks if a commit message indicates it should be excluded.
pub fn shouldExcludeByMessage(message: []const u8) bool {
    return containsAnyPattern(message, &default_exclude_patterns);
}

/// Checks if a commit is a merge commit based on message prefix.
pub fn isMergeCommit(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "Merge ") or
        std.mem.startsWith(u8, message, "Merge:");
}

// Tests
test "CommitType.fromString parses valid types" {
    try std.testing.expectEqual(CommitType.feat, CommitType.fromString("feat"));
    try std.testing.expectEqual(CommitType.fix, CommitType.fromString("fix"));
    try std.testing.expectEqual(CommitType.@"test", CommitType.fromString("test"));
    try std.testing.expectEqual(CommitType.unknown, CommitType.fromString("invalid"));
}

test "CommitType.isExcludedByDefault returns correct values" {
    try std.testing.expect(CommitType.chore.isExcludedByDefault());
    try std.testing.expect(CommitType.@"test".isExcludedByDefault());
    try std.testing.expect(CommitType.ci.isExcludedByDefault());
    try std.testing.expect(CommitType.build.isExcludedByDefault());
    try std.testing.expect(!CommitType.feat.isExcludedByDefault());
    try std.testing.expect(!CommitType.fix.isExcludedByDefault());
}

test "Stats tracks inclusions and exclusions" {
    var stats = Stats{};
    defer stats.deinit(std.testing.allocator);

    stats.recordInclusion();
    stats.recordInclusion();
    try stats.recordExclusion(std.testing.allocator, .chore);
    try stats.recordExclusion(std.testing.allocator, .chore);
    try stats.recordExclusion(std.testing.allocator, .@"test");

    try std.testing.expectEqual(@as(usize, 2), stats.included);
    try std.testing.expectEqual(@as(usize, 3), stats.excluded);
    try std.testing.expectEqual(@as(usize, 2), stats.excluded_by_type.get("Chore").?);
    try std.testing.expectEqual(@as(usize, 1), stats.excluded_by_type.get("Tests").?);
}

test "ChangelogEntry lifecycle" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123def456",
        .short_hash = "abc123d",
        .commit_type = .feat,
        .scope = "ui",
        .description = "Add dark mode toggle",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &[_][]const u8{"#123"},
    };

    try entry.addCommit(commit);

    try std.testing.expectEqual(@as(usize, 1), entry.stats.included);
    try std.testing.expect(entry.sections.contains("Added"));

    const section = entry.sections.get("Added").?;
    try std.testing.expectEqual(@as(usize, 1), section.commits.items.len);
    try std.testing.expectEqualStrings("Add dark mode toggle", section.commits.items[0].description);
}

test "extractIssues finds issue references" {
    const issues = try extractIssues(std.testing.allocator, "Fix bug #123 and #456");
    defer {
        for (issues) |issue| {
            std.testing.allocator.free(issue);
        }
        std.testing.allocator.free(issues);
    }

    try std.testing.expectEqual(@as(usize, 2), issues.len);
    try std.testing.expectEqualStrings("#123", issues[0]);
    try std.testing.expectEqualStrings("#456", issues[1]);
}

test "extractIssues handles no issues" {
    const issues = try extractIssues(std.testing.allocator, "No issues here");
    defer std.testing.allocator.free(issues);

    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "extractIssues ignores invalid patterns" {
    const issues = try extractIssues(std.testing.allocator, "# not an issue #abc #");
    defer std.testing.allocator.free(issues);

    try std.testing.expectEqual(@as(usize, 0), issues.len);
}

test "splitLines splits and trims" {
    const text = "line1\n  line2  \n\nline3\n";
    const lines = try splitLines(std.testing.allocator, text);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
}

test "shouldExcludeByMessage detects exclude patterns" {
    try std.testing.expect(shouldExcludeByMessage("WIP: working on feature"));
    try std.testing.expect(shouldExcludeByMessage("fixup! previous commit"));
    try std.testing.expect(shouldExcludeByMessage("fix typo in readme"));
    try std.testing.expect(shouldExcludeByMessage("chore: update [skip changelog]"));
    try std.testing.expect(!shouldExcludeByMessage("feat: add new feature"));
}

test "isMergeCommit detects merge commits" {
    try std.testing.expect(isMergeCommit("Merge branch 'feature' into main"));
    try std.testing.expect(isMergeCommit("Merge pull request #123"));
    try std.testing.expect(!isMergeCommit("feat: merge two lists"));
}
