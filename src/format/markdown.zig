const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("../changelog.zig");
const ChangelogEntry = changelog.ChangelogEntry;
const Section = changelog.Section;
const Commit = changelog.Commit;

/// Configuration for markdown output.
pub const MarkdownConfig = struct {
    /// Show commit hashes in output.
    show_hashes: bool = true,

    /// Length of hash to display (e.g., 7 for short hash).
    hash_length: usize = 7,

    /// Show author names.
    show_authors: bool = false,

    /// Base URL for commit links (e.g., "https://github.com/user/repo/commit/").
    /// If null, hashes are not linked.
    commit_url_base: ?[]const u8 = null,

    /// Base URL for issue links (e.g., "https://github.com/user/repo/issues/").
    /// If null, issue numbers are not linked.
    issue_url_base: ?[]const u8 = null,

    /// Show breaking change indicators.
    show_breaking: bool = true,

    /// Show scope in parentheses before description.
    show_scope: bool = true,
};

/// Markdown formatter for changelog entries.
pub const MarkdownFormatter = struct {
    allocator: Allocator,
    config: MarkdownConfig,

    const Self = @This();

    pub fn init(allocator: Allocator, config: MarkdownConfig) Self {
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

    /// Formats a changelog entry to Keep-a-Changelog markdown.
    /// Caller owns the returned string.
    pub fn format(self: *const Self, entry: *const ChangelogEntry) ![]u8 {
        var output = std.ArrayListUnmanaged(u8){};
        errdefer output.deinit(self.allocator);

        // Header: ## [version] - date
        try self.appendHeader(&output, entry);

        // Sections in standard order
        const section_order = ChangelogEntry.getSectionOrder();
        var has_content = false;

        for (section_order) |section_name| {
            if (entry.sections.get(section_name)) |section| {
                if (section.commits.items.len > 0) {
                    try self.appendSection(&output, section);
                    has_content = true;
                }
            }
        }

        // Handle sections not in standard order (e.g., custom types)
        var iter = entry.sections.iterator();
        while (iter.next()) |kv| {
            var in_order = false;
            for (section_order) |ordered| {
                if (std.mem.eql(u8, kv.key_ptr.*, ordered)) {
                    in_order = true;
                    break;
                }
            }
            if (!in_order and kv.value_ptr.commits.items.len > 0) {
                try self.appendSection(&output, kv.value_ptr.*);
                has_content = true;
            }
        }

        // If no content, add a note
        if (!has_content) {
            try output.appendSlice(self.allocator, "\n_No significant changes in this release._\n");
        }

        return output.toOwnedSlice(self.allocator);
    }

    fn appendHeader(self: *const Self, output: *std.ArrayListUnmanaged(u8), entry: *const ChangelogEntry) !void {
        try output.appendSlice(self.allocator, "## [");
        try output.appendSlice(self.allocator, entry.version);
        try output.appendSlice(self.allocator, "] - ");
        try output.appendSlice(self.allocator, entry.date);
        try output.appendSlice(self.allocator, "\n");
    }

    fn appendSection(self: *const Self, output: *std.ArrayListUnmanaged(u8), section: Section) !void {
        try output.appendSlice(self.allocator, "\n### ");
        try output.appendSlice(self.allocator, section.name);
        try output.appendSlice(self.allocator, "\n\n");

        for (section.commits.items) |commit| {
            try self.appendCommit(output, commit);
        }
    }

    fn appendCommit(self: *const Self, output: *std.ArrayListUnmanaged(u8), commit: Commit) !void {
        try output.appendSlice(self.allocator, "- ");

        // Breaking change indicator
        if (self.config.show_breaking and commit.breaking) {
            try output.appendSlice(self.allocator, "**BREAKING** ");
        }

        // Scope
        if (self.config.show_scope) {
            if (commit.scope) |scope| {
                try output.appendSlice(self.allocator, "**");
                try output.appendSlice(self.allocator, scope);
                try output.appendSlice(self.allocator, "**: ");
            }
        }

        // Description with linked issues
        try self.appendDescriptionWithLinks(output, commit.description);

        // Hash
        if (self.config.show_hashes) {
            try output.appendSlice(self.allocator, " (");
            try self.appendHashLink(output, commit);
            try output.appendSlice(self.allocator, ")");
        }

        // Author
        if (self.config.show_authors) {
            try output.appendSlice(self.allocator, " by @");
            try output.appendSlice(self.allocator, commit.author);
        }

        try output.appendSlice(self.allocator, "\n");
    }

    fn appendDescriptionWithLinks(self: *const Self, output: *std.ArrayListUnmanaged(u8), description: []const u8) !void {
        if (self.config.issue_url_base == null) {
            try output.appendSlice(self.allocator, description);
            return;
        }

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
                try output.appendSlice(self.allocator, self.config.issue_url_base.?);
                try output.appendSlice(self.allocator, issue_num);
                try output.appendSlice(self.allocator, ")");
            } else {
                try output.append(self.allocator, description[i]);
                i += 1;
            }
        }
    }

    fn appendHashLink(self: *const Self, output: *std.ArrayListUnmanaged(u8), commit: Commit) !void {
        const hash = if (commit.short_hash.len <= self.config.hash_length)
            commit.short_hash
        else
            commit.short_hash[0..self.config.hash_length];

        if (self.config.commit_url_base) |base| {
            try output.appendSlice(self.allocator, "[`");
            try output.appendSlice(self.allocator, hash);
            try output.appendSlice(self.allocator, "`](");
            try output.appendSlice(self.allocator, base);
            try output.appendSlice(self.allocator, commit.hash);
            try output.appendSlice(self.allocator, ")");
        } else {
            try output.appendSlice(self.allocator, "`");
            try output.appendSlice(self.allocator, hash);
            try output.appendSlice(self.allocator, "`");
        }
    }
};

/// Formats a changelog entry with default configuration.
/// Caller owns the returned string.
pub fn formatEntry(allocator: Allocator, entry: *const ChangelogEntry) ![]u8 {
    const formatter = MarkdownFormatter.initDefault(allocator);
    return formatter.format(entry);
}

/// Formats a changelog entry with custom configuration.
/// Caller owns the returned string.
pub fn formatEntryWithConfig(allocator: Allocator, entry: *const ChangelogEntry, config: MarkdownConfig) ![]u8 {
    const formatter = MarkdownFormatter.init(allocator, config);
    return formatter.format(entry);
}

// Tests

test "MarkdownFormatter formats basic entry" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
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

    try std.testing.expect(std.mem.indexOf(u8, output, "## [1.0.0] - 2026-01-19") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "### Added") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "add new feature") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "`abc123d`") != null);
}

test "MarkdownFormatter shows scope" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .fix,
        .scope = "ui",
        .description = "fix button alignment",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "**ui**:") != null);
}

test "MarkdownFormatter shows breaking change" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "2.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "change API",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = true,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "**BREAKING**") != null);
}

test "MarkdownFormatter links commits" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123def456789",
        .short_hash = "abc123d",
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
        .commit_url_base = "https://github.com/user/repo/commit/",
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[`abc123d`](https://github.com/user/repo/commit/abc123def456789)") != null);
}

test "MarkdownFormatter links issues" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
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
        .issue_url_base = "https://github.com/user/repo/issues/",
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[#123](https://github.com/user/repo/issues/123)") != null);
}

test "MarkdownFormatter handles empty entry" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "No significant changes") != null);
}

test "MarkdownFormatter orders sections correctly" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    // Add commits in reverse order
    const fix_commit = Commit{
        .hash = "fix1",
        .short_hash = "fix",
        .commit_type = .fix,
        .scope = null,
        .description = "fix something",
        .body = null,
        .author = "dev",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    const feat_commit = Commit{
        .hash = "feat1",
        .short_hash = "feat",
        .commit_type = .feat,
        .scope = null,
        .description = "add something",
        .body = null,
        .author = "dev",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(fix_commit);
    try entry.addCommit(feat_commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    // "Added" should come before "Fixed" in output
    const added_pos = std.mem.indexOf(u8, output, "### Added").?;
    const fixed_pos = std.mem.indexOf(u8, output, "### Fixed").?;
    try std.testing.expect(added_pos < fixed_pos);
}

test "MarkdownFormatter can hide hashes" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
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
        .show_hashes = false,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "abc") == null);
}

test "MarkdownFormatter shows authors" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "add feature",
        .body = null,
        .author = "johndoe",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntryWithConfig(std.testing.allocator, &entry, .{
        .show_authors = true,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "by @johndoe") != null);
}
