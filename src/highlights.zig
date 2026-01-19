const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("changelog.zig");
const Commit = changelog.Commit;
const CommitType = changelog.CommitType;
const Highlight = changelog.Highlight;
const HighlightReason = changelog.HighlightReason;
const ChangelogEntry = changelog.ChangelogEntry;

/// Criteria for detecting highlights.
pub const HighlightCriteria = struct {
    /// Include breaking changes as highlights.
    include_breaking: bool = true,
    /// Include security fixes as highlights.
    include_security: bool = true,
    /// Include deprecations as highlights.
    include_deprecations: bool = true,
    /// Include performance improvements as highlights.
    include_performance: bool = false,
    /// Custom scopes that should be highlighted.
    highlighted_scopes: []const []const u8 = &.{},
    /// Keywords in description that indicate a major feature.
    major_feature_keywords: []const []const u8 = &.{},
};

/// Highlight detection and generation engine.
pub const HighlightGenerator = struct {
    allocator: Allocator,
    criteria: HighlightCriteria,

    const Self = @This();

    pub fn init(allocator: Allocator, criteria: HighlightCriteria) Self {
        return .{
            .allocator = allocator,
            .criteria = criteria,
        };
    }

    /// Generates highlights for a changelog entry based on its commits.
    /// Returns a list of highlights. Caller owns the returned memory.
    pub fn generateHighlights(self: *const Self, entry: *const ChangelogEntry) !std.ArrayListUnmanaged(Highlight) {
        var highlights = std.ArrayListUnmanaged(Highlight){};
        errdefer {
            for (highlights.items) |*h| {
                h.deinit(self.allocator);
            }
            highlights.deinit(self.allocator);
        }

        // Iterate through all sections and commits
        var section_iter = entry.sections.iterator();
        while (section_iter.next()) |kv| {
            const section = kv.value_ptr;
            for (section.commits.items) |commit| {
                if (try self.detectHighlight(commit)) |highlight| {
                    try highlights.append(self.allocator, highlight);
                }
            }
        }

        return highlights;
    }

    /// Detects if a commit should be highlighted and returns the highlight.
    /// Returns null if the commit should not be highlighted.
    fn detectHighlight(self: *const Self, commit: Commit) !?Highlight {
        // Check breaking changes
        if (self.criteria.include_breaking and commit.breaking) {
            const summary = try self.generateSummary(commit, .breaking_change);
            return Highlight{
                .commit = try commit.clone(self.allocator),
                .reason = .breaking_change,
                .summary = summary,
            };
        }

        // Check security fixes
        if (self.criteria.include_security and commit.commit_type == .security) {
            const summary = try self.generateSummary(commit, .security_fix);
            return Highlight{
                .commit = try commit.clone(self.allocator),
                .reason = .security_fix,
                .summary = summary,
            };
        }

        // Check deprecations
        if (self.criteria.include_deprecations and commit.commit_type == .deprecate) {
            const summary = try self.generateSummary(commit, .deprecation);
            return Highlight{
                .commit = try commit.clone(self.allocator),
                .reason = .deprecation,
                .summary = summary,
            };
        }

        // Check performance improvements
        if (self.criteria.include_performance and commit.commit_type == .perf) {
            const summary = try self.generateSummary(commit, .performance_improvement);
            return Highlight{
                .commit = try commit.clone(self.allocator),
                .reason = .performance_improvement,
                .summary = summary,
            };
        }

        // Check highlighted scopes
        if (commit.scope) |scope| {
            for (self.criteria.highlighted_scopes) |hs| {
                if (std.mem.eql(u8, scope, hs)) {
                    const summary = try self.generateSummary(commit, .major_feature);
                    return Highlight{
                        .commit = try commit.clone(self.allocator),
                        .reason = .major_feature,
                        .summary = summary,
                    };
                }
            }
        }

        // Check major feature keywords
        if (self.containsMajorFeatureKeyword(commit.description)) {
            const summary = try self.generateSummary(commit, .major_feature);
            return Highlight{
                .commit = try commit.clone(self.allocator),
                .reason = .major_feature,
                .summary = summary,
            };
        }

        return null;
    }

    /// Checks if description contains any major feature keywords.
    fn containsMajorFeatureKeyword(self: *const Self, description: []const u8) bool {
        // Convert to lowercase for case-insensitive matching
        var lower_buf: [512]u8 = undefined;
        const len = @min(description.len, lower_buf.len);
        for (description[0..len], 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        const lower = lower_buf[0..len];

        for (self.criteria.major_feature_keywords) |keyword| {
            if (std.mem.indexOf(u8, lower, keyword) != null) {
                return true;
            }
        }
        return false;
    }

    /// Generates a summary string for a highlight.
    fn generateSummary(self: *const Self, commit: Commit, reason: HighlightReason) !?[]const u8 {
        var summary = std.ArrayListUnmanaged(u8){};
        errdefer summary.deinit(self.allocator);

        // Add prefix based on reason
        const prefix = switch (reason) {
            .breaking_change => "**BREAKING** ",
            .security_fix => "**SECURITY** ",
            .deprecation => "**DEPRECATED** ",
            .performance_improvement => "**PERFORMANCE** ",
            .major_feature => "",
        };

        try summary.appendSlice(self.allocator, prefix);

        // Add scope if present
        if (commit.scope) |scope| {
            try summary.appendSlice(self.allocator, scope);
            try summary.appendSlice(self.allocator, ": ");
        }

        // Add description
        try summary.appendSlice(self.allocator, commit.description);

        return try summary.toOwnedSlice(self.allocator);
    }
};

/// Returns a human-readable string for a highlight reason.
pub fn reasonToString(reason: HighlightReason) []const u8 {
    return switch (reason) {
        .breaking_change => "Breaking Change",
        .security_fix => "Security Fix",
        .deprecation => "Deprecation",
        .performance_improvement => "Performance Improvement",
        .major_feature => "Major Feature",
    };
}

/// Returns a short label for a highlight reason (for markdown output).
pub fn reasonToLabel(reason: HighlightReason) []const u8 {
    return switch (reason) {
        .breaking_change => "BREAKING",
        .security_fix => "SECURITY",
        .deprecation => "DEPRECATED",
        .performance_improvement => "PERF",
        .major_feature => "NEW",
    };
}

// Tests

test "HighlightGenerator detects breaking changes" {
    const allocator = std.testing.allocator;

    var generator = HighlightGenerator.init(allocator, .{
        .include_breaking = true,
    });

    var entry = try ChangelogEntry.init(allocator, "2.0.0", "2026-01-19");
    defer entry.deinit();

    const breaking_commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = "api",
        .description = "change response format",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = true,
        .issues = &.{},
    };

    try entry.addCommit(breaking_commit);

    var highlights = try generator.generateHighlights(&entry);
    defer {
        for (highlights.items) |*h| {
            h.deinit(allocator);
        }
        highlights.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), highlights.items.len);
    try std.testing.expectEqual(HighlightReason.breaking_change, highlights.items[0].reason);
}

test "HighlightGenerator detects security fixes" {
    const allocator = std.testing.allocator;

    var generator = HighlightGenerator.init(allocator, .{
        .include_security = true,
    });

    var entry = try ChangelogEntry.init(allocator, "1.0.1", "2026-01-19");
    defer entry.deinit();

    const security_commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .security,
        .scope = null,
        .description = "fix XSS vulnerability",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(security_commit);

    var highlights = try generator.generateHighlights(&entry);
    defer {
        for (highlights.items) |*h| {
            h.deinit(allocator);
        }
        highlights.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), highlights.items.len);
    try std.testing.expectEqual(HighlightReason.security_fix, highlights.items[0].reason);
}

test "HighlightGenerator detects highlighted scopes" {
    const allocator = std.testing.allocator;

    const highlighted_scopes = [_][]const u8{ "api", "auth" };

    var generator = HighlightGenerator.init(allocator, .{
        .include_breaking = false,
        .include_security = false,
        .include_deprecations = false,
        .highlighted_scopes = &highlighted_scopes,
    });

    var entry = try ChangelogEntry.init(allocator, "1.1.0", "2026-01-19");
    defer entry.deinit();

    const api_commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = "api",
        .description = "add new endpoint",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    const ui_commit = Commit{
        .hash = "def456",
        .short_hash = "def",
        .commit_type = .feat,
        .scope = "ui",
        .description = "add button",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(api_commit);
    try entry.addCommit(ui_commit);

    var highlights = try generator.generateHighlights(&entry);
    defer {
        for (highlights.items) |*h| {
            h.deinit(allocator);
        }
        highlights.deinit(allocator);
    }

    // Only api commit should be highlighted
    try std.testing.expectEqual(@as(usize, 1), highlights.items.len);
    try std.testing.expectEqual(HighlightReason.major_feature, highlights.items[0].reason);
}

test "HighlightGenerator respects disabled criteria" {
    const allocator = std.testing.allocator;

    var generator = HighlightGenerator.init(allocator, .{
        .include_breaking = false,
        .include_security = false,
        .include_deprecations = false,
    });

    var entry = try ChangelogEntry.init(allocator, "2.0.0", "2026-01-19");
    defer entry.deinit();

    const breaking_commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "breaking change",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = true,
        .issues = &.{},
    };

    try entry.addCommit(breaking_commit);

    var highlights = try generator.generateHighlights(&entry);
    defer highlights.deinit(allocator);

    // Should not detect breaking change when disabled
    try std.testing.expectEqual(@as(usize, 0), highlights.items.len);
}

test "reasonToString returns correct strings" {
    try std.testing.expectEqualStrings("Breaking Change", reasonToString(.breaking_change));
    try std.testing.expectEqualStrings("Security Fix", reasonToString(.security_fix));
    try std.testing.expectEqualStrings("Deprecation", reasonToString(.deprecation));
}
