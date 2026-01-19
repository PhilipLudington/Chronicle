const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("changelog.zig");
const git = @import("git.zig");
const CommitType = changelog.CommitType;
const Commit = changelog.Commit;
const RawCommit = git.RawCommit;

/// Errors that can occur during commit parsing.
pub const ParseError = error{
    /// The commit message does not follow conventional commit format.
    InvalidFormat,
    /// Out of memory.
    OutOfMemory,
};

/// Result of parsing a conventional commit message.
pub const ParsedMessage = struct {
    commit_type: CommitType,
    scope: ?[]const u8,
    description: []const u8,
    breaking: bool,
};

/// Parses a conventional commit subject line.
/// Format: <type>[optional scope][!]: <description>
/// Examples:
///   - feat: add new feature
///   - fix(ui): resolve button alignment
///   - feat!: breaking change
///   - refactor(core)!: major refactor
///
/// Returns null if the message doesn't follow conventional commit format.
pub fn parseConventionalCommit(subject: []const u8) ?ParsedMessage {
    const trimmed = std.mem.trim(u8, subject, " \t");
    if (trimmed.len == 0) return null;

    // Find the colon that separates type[scope][!] from description
    const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    if (colon_pos == 0) return null;

    const prefix = trimmed[0..colon_pos];
    const description_raw = if (colon_pos + 1 < trimmed.len)
        std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t")
    else
        return null;

    if (description_raw.len == 0) return null;

    // Parse the prefix: type[(scope)][!]
    var type_end = prefix.len;
    var scope: ?[]const u8 = null;
    var breaking = false;

    // Check for breaking indicator at end
    if (prefix.len > 0 and prefix[prefix.len - 1] == '!') {
        breaking = true;
        type_end = prefix.len - 1;
    }

    // Check for scope in parentheses
    if (type_end > 0) {
        const check_end = type_end;
        if (prefix[check_end - 1] == ')') {
            // Find matching opening paren
            if (std.mem.lastIndexOfScalar(u8, prefix[0..check_end], '(')) |paren_pos| {
                scope = prefix[paren_pos + 1 .. check_end - 1];
                if (scope.?.len == 0) scope = null;
                type_end = paren_pos;

                // Check for ! before the scope
                if (type_end > 0 and prefix[type_end - 1] == '!') {
                    breaking = true;
                    type_end -= 1;
                }
            }
        }
    }

    if (type_end == 0) return null;

    const type_str = prefix[0..type_end];
    const commit_type = CommitType.fromString(type_str);

    return ParsedMessage{
        .commit_type = commit_type,
        .scope = scope,
        .description = description_raw,
        .breaking = breaking,
    };
}

/// Parses a raw git commit into a structured Commit.
/// Extracts conventional commit information and issue references.
/// Caller owns the returned Commit and must call deinit.
pub fn parseRawCommit(allocator: Allocator, raw: RawCommit) !Commit {
    // Parse the subject line for conventional commit format
    const parsed = parseConventionalCommit(raw.subject);

    const commit_type = if (parsed) |p| p.commit_type else .unknown;
    const scope_raw = if (parsed) |p| p.scope else null;
    const description_raw = if (parsed) |p| p.description else raw.subject;
    var breaking = if (parsed) |p| p.breaking else false;

    // Check body for BREAKING CHANGE footer
    if (!breaking) {
        if (raw.body) |body| {
            breaking = hasBreakingChangeFooter(body);
        }
    }

    // Extract issues from subject and body
    var all_issues = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (all_issues.items) |issue| {
            allocator.free(issue);
        }
        all_issues.deinit(allocator);
    }

    // Extract from subject
    const subject_issues = try changelog.extractIssues(allocator, raw.subject);
    defer {
        for (subject_issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(subject_issues);
    }

    for (subject_issues) |issue| {
        const owned = try allocator.dupe(u8, issue);
        try all_issues.append(allocator, owned);
    }

    // Extract from body
    if (raw.body) |body| {
        const body_issues = try changelog.extractIssues(allocator, body);
        defer {
            for (body_issues) |issue| {
                allocator.free(issue);
            }
            allocator.free(body_issues);
        }

        for (body_issues) |issue| {
            // Avoid duplicates
            var found = false;
            for (all_issues.items) |existing| {
                if (std.mem.eql(u8, existing, issue)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const owned = try allocator.dupe(u8, issue);
                try all_issues.append(allocator, owned);
            }
        }
    }

    // Allocate all strings
    const hash = try allocator.dupe(u8, raw.hash);
    errdefer allocator.free(hash);

    const short_hash = try allocator.dupe(u8, raw.short_hash);
    errdefer allocator.free(short_hash);

    const description = try allocator.dupe(u8, description_raw);
    errdefer allocator.free(description);

    const scope: ?[]const u8 = if (scope_raw) |s| try allocator.dupe(u8, s) else null;
    errdefer if (scope) |s| allocator.free(s);

    const body: ?[]const u8 = if (raw.body) |b| try allocator.dupe(u8, b) else null;
    errdefer if (body) |b| allocator.free(b);

    const author = try allocator.dupe(u8, raw.author);
    errdefer allocator.free(author);

    const date = try allocator.dupe(u8, raw.date);
    errdefer allocator.free(date);

    const issues = try all_issues.toOwnedSlice(allocator);

    return Commit{
        .hash = hash,
        .short_hash = short_hash,
        .commit_type = commit_type,
        .scope = scope,
        .description = description,
        .body = body,
        .author = author,
        .date = date,
        .breaking = breaking,
        .issues = issues,
    };
}

/// Checks if the commit body contains a BREAKING CHANGE footer.
/// Conventional commit spec: "BREAKING CHANGE:" or "BREAKING-CHANGE:" in footer.
pub fn hasBreakingChangeFooter(body: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "BREAKING CHANGE:") or
            std.mem.startsWith(u8, trimmed, "BREAKING-CHANGE:") or
            std.mem.startsWith(u8, trimmed, "BREAKING CHANGE ") or
            std.mem.startsWith(u8, trimmed, "BREAKING-CHANGE "))
        {
            return true;
        }
    }
    return false;
}

/// Parses multiple raw commits into structured Commits.
/// Caller owns the returned slice and its contents.
pub fn parseRawCommits(allocator: Allocator, raw_commits: []const RawCommit) ![]Commit {
    var commits = std.ArrayListUnmanaged(Commit){};
    errdefer {
        for (commits.items) |*c| {
            c.deinit(allocator);
        }
        commits.deinit(allocator);
    }

    for (raw_commits) |raw| {
        const commit = try parseRawCommit(allocator, raw);
        try commits.append(allocator, commit);
    }

    return commits.toOwnedSlice(allocator);
}

// Tests

test "parseConventionalCommit parses basic types" {
    const result = parseConventionalCommit("feat: add new feature");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(CommitType.feat, result.?.commit_type);
    try std.testing.expect(result.?.scope == null);
    try std.testing.expectEqualStrings("add new feature", result.?.description);
    try std.testing.expect(!result.?.breaking);
}

test "parseConventionalCommit parses with scope" {
    const result = parseConventionalCommit("fix(ui): resolve button alignment");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(CommitType.fix, result.?.commit_type);
    try std.testing.expectEqualStrings("ui", result.?.scope.?);
    try std.testing.expectEqualStrings("resolve button alignment", result.?.description);
    try std.testing.expect(!result.?.breaking);
}

test "parseConventionalCommit parses breaking with !" {
    const result = parseConventionalCommit("feat!: breaking change");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(CommitType.feat, result.?.commit_type);
    try std.testing.expect(result.?.scope == null);
    try std.testing.expectEqualStrings("breaking change", result.?.description);
    try std.testing.expect(result.?.breaking);
}

test "parseConventionalCommit parses breaking with scope and !" {
    const result = parseConventionalCommit("refactor(core)!: major refactor");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(CommitType.refactor, result.?.commit_type);
    try std.testing.expectEqualStrings("core", result.?.scope.?);
    try std.testing.expectEqualStrings("major refactor", result.?.description);
    try std.testing.expect(result.?.breaking);
}

test "parseConventionalCommit handles unknown type" {
    const result = parseConventionalCommit("custom: some message");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(CommitType.unknown, result.?.commit_type);
}

test "parseConventionalCommit returns null for invalid format" {
    try std.testing.expect(parseConventionalCommit("no colon here") == null);
    try std.testing.expect(parseConventionalCommit(": no type") == null);
    try std.testing.expect(parseConventionalCommit("type:") == null);
    try std.testing.expect(parseConventionalCommit("") == null);
    try std.testing.expect(parseConventionalCommit("   ") == null);
}

test "parseConventionalCommit handles empty scope" {
    const result = parseConventionalCommit("feat(): description");
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.scope == null);
}

test "hasBreakingChangeFooter detects footer" {
    try std.testing.expect(hasBreakingChangeFooter("BREAKING CHANGE: something changed"));
    try std.testing.expect(hasBreakingChangeFooter("Some text\n\nBREAKING CHANGE: api removed"));
    try std.testing.expect(hasBreakingChangeFooter("BREAKING-CHANGE: alternative format"));
    try std.testing.expect(!hasBreakingChangeFooter("This is not a breaking change"));
    try std.testing.expect(!hasBreakingChangeFooter("breaking change without caps"));
}

test "parseRawCommit extracts all fields" {
    const raw = RawCommit{
        .hash = "abc123def456789",
        .short_hash = "abc123d",
        .author = "John Doe",
        .date = "2026-01-19T10:00:00Z",
        .subject = "feat(parser): add conventional commit parsing #123",
        .body = "This implements the parser.\n\nCloses #456",
    };

    var commit = try parseRawCommit(std.testing.allocator, raw);
    defer commit.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123def456789", commit.hash);
    try std.testing.expectEqualStrings("abc123d", commit.short_hash);
    try std.testing.expectEqual(CommitType.feat, commit.commit_type);
    try std.testing.expectEqualStrings("parser", commit.scope.?);
    try std.testing.expectEqualStrings("add conventional commit parsing #123", commit.description);
    try std.testing.expectEqualStrings("John Doe", commit.author);
    try std.testing.expect(!commit.breaking);

    // Should have extracted both issues without duplicates
    try std.testing.expectEqual(@as(usize, 2), commit.issues.len);
}

test "parseRawCommit handles breaking change footer" {
    const raw = RawCommit{
        .hash = "abc123",
        .short_hash = "abc",
        .author = "Author",
        .date = "2026-01-19",
        .subject = "feat: add feature",
        .body = "Description\n\nBREAKING CHANGE: API removed",
    };

    var commit = try parseRawCommit(std.testing.allocator, raw);
    defer commit.deinit(std.testing.allocator);

    try std.testing.expect(commit.breaking);
}

test "parseRawCommit handles non-conventional commit" {
    const raw = RawCommit{
        .hash = "abc123",
        .short_hash = "abc",
        .author = "Author",
        .date = "2026-01-19",
        .subject = "Just a regular commit message",
        .body = null,
    };

    var commit = try parseRawCommit(std.testing.allocator, raw);
    defer commit.deinit(std.testing.allocator);

    try std.testing.expectEqual(CommitType.unknown, commit.commit_type);
    try std.testing.expect(commit.scope == null);
    try std.testing.expectEqualStrings("Just a regular commit message", commit.description);
}

test "parseRawCommits parses multiple commits" {
    const raw_commits = [_]RawCommit{
        .{
            .hash = "hash1",
            .short_hash = "h1",
            .author = "Author",
            .date = "2026-01-19",
            .subject = "feat: first",
            .body = null,
        },
        .{
            .hash = "hash2",
            .short_hash = "h2",
            .author = "Author",
            .date = "2026-01-19",
            .subject = "fix: second",
            .body = null,
        },
    };

    const commits = try parseRawCommits(std.testing.allocator, &raw_commits);
    defer {
        for (commits) |*c| {
            var mc = c.*;
            mc.deinit(std.testing.allocator);
        }
        std.testing.allocator.free(commits);
    }

    try std.testing.expectEqual(@as(usize, 2), commits.len);
    try std.testing.expectEqual(CommitType.feat, commits[0].commit_type);
    try std.testing.expectEqual(CommitType.fix, commits[1].commit_type);
}
