const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("../changelog.zig");
const ChangelogEntry = changelog.ChangelogEntry;
const Section = changelog.Section;
const Commit = changelog.Commit;
const CommitType = changelog.CommitType;

/// Configuration for GitHub releases format.
pub const GitHubConfig = struct {
    /// Base URL for the repository (e.g., "https://github.com/user/repo").
    /// Used for generating commit and comparison links.
    repo_url: ?[]const u8 = null,

    /// Previous version tag for generating comparison link.
    previous_version: ?[]const u8 = null,

    /// Show commit authors with @ mentions.
    show_authors: bool = true,

    /// Show commit hashes.
    show_hashes: bool = true,
};

/// GitHub releases formatter.
/// Produces markdown in GitHub's "What's Changed" release notes style.
pub const GitHubFormatter = struct {
    allocator: Allocator,
    config: GitHubConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: GitHubConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn initDefault(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .config = .{},
        };
    }

    /// Formats a changelog entry to GitHub releases markdown.
    /// Caller owns the returned string.
    pub fn format(self: *const Self, entry: *const ChangelogEntry) ![]u8 {
        var output = std.ArrayListUnmanaged(u8){};
        errdefer output.deinit(self.allocator);

        // Group commits by type for GitHub-style sections
        try self.appendBreakingChanges(&output, entry);
        try self.appendSection(&output, entry, "Features", &[_]CommitType{.feat});
        try self.appendSection(&output, entry, "Bug Fixes", &[_]CommitType{.fix});
        try self.appendSection(&output, entry, "Performance Improvements", &[_]CommitType{.perf});
        try self.appendSection(&output, entry, "Documentation", &[_]CommitType{.docs});
        try self.appendSection(&output, entry, "Other Changes", &[_]CommitType{ .refactor, .security, .deprecate, .remove, .unknown });

        // Full Changelog comparison link
        if (self.config.repo_url) |repo_url| {
            if (self.config.previous_version) |prev| {
                try output.appendSlice(self.allocator, "\n**Full Changelog**: ");
                try output.appendSlice(self.allocator, repo_url);
                try output.appendSlice(self.allocator, "/compare/");
                try output.appendSlice(self.allocator, prev);
                try output.appendSlice(self.allocator, "...");
                try output.appendSlice(self.allocator, entry.version);
                try output.appendSlice(self.allocator, "\n");
            }
        }

        return output.toOwnedSlice(self.allocator);
    }

    fn appendBreakingChanges(self: *const Self, output: *std.ArrayListUnmanaged(u8), entry: *const ChangelogEntry) !void {
        var has_breaking = false;

        // Check for breaking changes across all sections
        var iter = entry.sections.valueIterator();
        while (iter.next()) |section| {
            for (section.commits.items) |commit| {
                if (commit.breaking) {
                    if (!has_breaking) {
                        try output.appendSlice(self.allocator, "## Breaking Changes\n\n");
                        has_breaking = true;
                    }
                    try self.appendCommit(output, commit);
                }
            }
        }

        if (has_breaking) {
            try output.appendSlice(self.allocator, "\n");
        }
    }

    fn appendSection(self: *const Self, output: *std.ArrayListUnmanaged(u8), entry: *const ChangelogEntry, title: []const u8, types: []const CommitType) !void {
        var has_commits = false;

        // Check if section has any commits (excluding breaking ones already shown)
        var iter = entry.sections.valueIterator();
        while (iter.next()) |section| {
            for (section.commits.items) |commit| {
                if (!commit.breaking and self.matchesTypes(commit.commit_type, types)) {
                    if (!has_commits) {
                        try output.appendSlice(self.allocator, "## ");
                        try output.appendSlice(self.allocator, title);
                        try output.appendSlice(self.allocator, "\n\n");
                        has_commits = true;
                    }
                    try self.appendCommit(output, commit);
                }
            }
        }

        if (has_commits) {
            try output.appendSlice(self.allocator, "\n");
        }
    }

    fn matchesTypes(self: *const Self, commit_type: CommitType, types: []const CommitType) bool {
        _ = self;
        for (types) |t| {
            if (commit_type == t) return true;
        }
        return false;
    }

    fn appendCommit(self: *const Self, output: *std.ArrayListUnmanaged(u8), commit: Commit) !void {
        try output.appendSlice(self.allocator, "* ");

        // Scope prefix
        if (commit.scope) |scope| {
            try output.appendSlice(self.allocator, "**");
            try output.appendSlice(self.allocator, scope);
            try output.appendSlice(self.allocator, ":** ");
        }

        // Description with linked issues
        try self.appendDescriptionWithLinks(output, commit.description);

        // Commit hash link
        if (self.config.show_hashes) {
            if (self.config.repo_url) |repo_url| {
                try output.appendSlice(self.allocator, " ([");
                try output.appendSlice(self.allocator, commit.short_hash);
                try output.appendSlice(self.allocator, "](");
                try output.appendSlice(self.allocator, repo_url);
                try output.appendSlice(self.allocator, "/commit/");
                try output.appendSlice(self.allocator, commit.hash);
                try output.appendSlice(self.allocator, "))");
            } else {
                try output.appendSlice(self.allocator, " (");
                try output.appendSlice(self.allocator, commit.short_hash);
                try output.appendSlice(self.allocator, ")");
            }
        }

        // Author
        if (self.config.show_authors) {
            try output.appendSlice(self.allocator, " by @");
            try output.appendSlice(self.allocator, commit.author);
        }

        try output.appendSlice(self.allocator, "\n");
    }

    fn appendDescriptionWithLinks(self: *const Self, output: *std.ArrayListUnmanaged(u8), description: []const u8) !void {
        if (self.config.repo_url == null) {
            try output.appendSlice(self.allocator, description);
            return;
        }

        const repo_url = self.config.repo_url.?;

        // Parse and link issue references
        var i: usize = 0;
        while (i < description.len) {
            if (description[i] == '#' and i + 1 < description.len and std.ascii.isDigit(description[i + 1])) {
                const start = i;
                i += 1;
                while (i < description.len and std.ascii.isDigit(description[i])) : (i += 1) {}

                const issue_num = description[start + 1 .. i];
                const issue_ref = description[start..i];

                try output.appendSlice(self.allocator, "[");
                try output.appendSlice(self.allocator, issue_ref);
                try output.appendSlice(self.allocator, "](");
                try output.appendSlice(self.allocator, repo_url);
                try output.appendSlice(self.allocator, "/issues/");
                try output.appendSlice(self.allocator, issue_num);
                try output.appendSlice(self.allocator, ")");
            } else {
                try output.append(self.allocator, description[i]);
                i += 1;
            }
        }
    }
};

/// Formats a changelog entry with default configuration.
/// Caller owns the returned string.
pub fn formatEntry(allocator: Allocator, entry: *const ChangelogEntry) ![]u8 {
    const formatter = GitHubFormatter.initDefault(allocator);
    return formatter.format(entry);
}

/// Formats a changelog entry with custom configuration.
/// Caller owns the returned string.
pub fn formatEntryWithConfig(allocator: Allocator, entry: *const ChangelogEntry, config: GitHubConfig) ![]u8 {
    const formatter = GitHubFormatter.init(allocator, config);
    return formatter.format(entry);
}

// Tests

test "GitHubFormatter formats basic entry" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "v1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123def456789",
        .short_hash = "abc123d",
        .commit_type = .feat,
        .scope = null,
        .description = "add new feature",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "## Features") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "add new feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "@developer") != null);
}

test "GitHubFormatter shows breaking changes first" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "v2.0.0", "2026-01-19");
    defer entry.deinit();

    const breaking_commit = Commit{
        .hash = "break123",
        .short_hash = "break",
        .commit_type = .feat,
        .scope = "api",
        .description = "remove deprecated endpoint",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = true,
        .issues = &.{},
    };

    try entry.addCommit(breaking_commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    const breaking_pos = std.mem.indexOf(u8, output, "## Breaking Changes");
    try std.testing.expect(breaking_pos != null);

    // Breaking changes should be first
    try std.testing.expectEqual(@as(usize, 0), breaking_pos.?);
}

test "GitHubFormatter links issues" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "v1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .fix,
        .scope = null,
        .description = "fix bug #123",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntryWithConfig(std.testing.allocator, &entry, .{
        .repo_url = "https://github.com/user/repo",
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[#123](https://github.com/user/repo/issues/123)") != null);
}

test "GitHubFormatter includes comparison link" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "v1.1.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "add feature",
        .body = null,
        .author = "dev",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntryWithConfig(std.testing.allocator, &entry, .{
        .repo_url = "https://github.com/user/repo",
        .previous_version = "v1.0.0",
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "**Full Changelog**:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/compare/v1.0.0...v1.1.0") != null);
}

test "GitHubFormatter links commits" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "v1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123def456789",
        .short_hash = "abc123d",
        .commit_type = .feat,
        .scope = null,
        .description = "add feature",
        .body = null,
        .author = "dev",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntryWithConfig(std.testing.allocator, &entry, .{
        .repo_url = "https://github.com/user/repo",
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[abc123d](https://github.com/user/repo/commit/abc123def456789)") != null);
}

test "GitHubFormatter shows scope" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "v1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .fix,
        .scope = "ui",
        .description = "fix button",
        .body = null,
        .author = "dev",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "**ui:**") != null);
}

test "GitHubFormatter can hide authors" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "v1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "add feature",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntryWithConfig(std.testing.allocator, &entry, .{
        .show_authors = false,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "@developer") == null);
}
