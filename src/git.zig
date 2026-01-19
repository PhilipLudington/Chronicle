const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.git);

/// Errors that can occur during git operations.
pub const GitError = error{
    /// Git command failed to execute.
    CommandFailed,
    /// Not inside a git repository.
    NotARepository,
    /// The specified ref (tag, branch, commit) does not exist.
    RefNotFound,
    /// No tags found in the repository.
    NoTagsFound,
    /// Failed to parse git output.
    ParseError,
    /// Git binary not found.
    GitNotFound,
    /// Out of memory.
    OutOfMemory,
};

/// A parsed commit from git log output.
pub const RawCommit = struct {
    hash: []const u8,
    short_hash: []const u8,
    author: []const u8,
    date: []const u8,
    subject: []const u8,
    body: ?[]const u8,

    /// Frees all memory owned by this commit.
    pub fn deinit(self: *RawCommit, allocator: Allocator) void {
        allocator.free(self.hash);
        allocator.free(self.short_hash);
        allocator.free(self.author);
        allocator.free(self.date);
        allocator.free(self.subject);
        if (self.body) |b| allocator.free(b);
        self.* = undefined;
    }
};

/// Git operations interface.
pub const Git = struct {
    allocator: Allocator,
    repo_path: ?[]const u8,

    const Self = @This();

    /// Creates a Git instance for the current directory.
    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .repo_path = null,
        };
    }

    /// Creates a Git instance for a specific repository path.
    pub fn initWithPath(allocator: Allocator, path: []const u8) !Self {
        const owned_path = try allocator.dupe(u8, path);
        return .{
            .allocator = allocator,
            .repo_path = owned_path,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.repo_path) |path| {
            self.allocator.free(path);
        }
        self.* = undefined;
    }

    /// Runs a git command and returns stdout on success.
    /// Caller owns the returned memory.
    pub fn runCommand(self: *const Self, args: []const []const u8) ![]u8 {
        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "git");

        if (self.repo_path) |path| {
            try argv.append(self.allocator, "-C");
            try argv.append(self.allocator, path);
        }

        for (args) |arg| {
            try argv.append(self.allocator, arg);
        }

        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Use deprecatedReader for Zig 0.15+ compatibility with readAllAlloc
        const stdout = child.stdout.?.deprecatedReader();
        const stderr = child.stderr.?.deprecatedReader();

        const stdout_content = stdout.readAllAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            _ = child.wait() catch {};
            return mapError(err);
        };
        errdefer self.allocator.free(stdout_content);

        const stderr_content = stderr.readAllAlloc(self.allocator, 64 * 1024) catch |err| {
            _ = child.wait() catch {};
            return mapError(err);
        };
        defer self.allocator.free(stderr_content);

        const term = child.wait() catch |err| {
            return mapError(err);
        };

        if (term.Exited != 0) {
            log.debug("git command failed: {s}", .{stderr_content});

            if (std.mem.indexOf(u8, stderr_content, "not a git repository") != null) {
                return GitError.NotARepository;
            }
            if (std.mem.indexOf(u8, stderr_content, "unknown revision") != null or
                std.mem.indexOf(u8, stderr_content, "bad revision") != null)
            {
                return GitError.RefNotFound;
            }
            return GitError.CommandFailed;
        }

        return stdout_content;
    }

    /// Gets all tags in the repository, sorted by version (newest first).
    /// Caller owns the returned slice and its contents.
    pub fn getTags(self: *const Self) ![][]const u8 {
        const output = self.runCommand(&.{
            "tag",
            "--list",
            "--sort=-version:refname",
        }) catch |err| {
            if (err == GitError.CommandFailed) {
                return &[_][]const u8{};
            }
            return err;
        };
        defer self.allocator.free(output);

        return parseLines(self.allocator, output);
    }

    /// Gets the latest tag in the repository.
    /// Returns null if no tags exist.
    pub fn getLatestTag(self: *const Self) !?[]const u8 {
        const output = self.runCommand(&.{
            "describe",
            "--tags",
            "--abbrev=0",
        }) catch |err| {
            if (err == GitError.CommandFailed or err == GitError.RefNotFound) {
                return null;
            }
            return err;
        };
        defer self.allocator.free(output);

        const trimmed = std.mem.trim(u8, output, " \t\n\r");
        if (trimmed.len == 0) return null;

        return try self.allocator.dupe(u8, trimmed);
    }

    /// Gets the tag before the specified tag.
    /// Returns null if no previous tag exists.
    pub fn getPreviousTag(self: *const Self, tag: []const u8) !?[]const u8 {
        // Get the commit before the tag, then find its most recent tag
        var tag_ref_buf: [256]u8 = undefined;
        const tag_ref = std.fmt.bufPrint(&tag_ref_buf, "{s}^", .{tag}) catch {
            return GitError.ParseError;
        };

        const output = self.runCommand(&.{
            "describe",
            "--tags",
            "--abbrev=0",
            tag_ref,
        }) catch |err| {
            if (err == GitError.CommandFailed or err == GitError.RefNotFound) {
                return null;
            }
            return err;
        };
        defer self.allocator.free(output);

        const trimmed = std.mem.trim(u8, output, " \t\n\r");
        if (trimmed.len == 0) return null;

        return try self.allocator.dupe(u8, trimmed);
    }

    /// Gets commits between two refs (exclusive from, inclusive to).
    /// If from is null, gets all commits up to `to`.
    /// Caller owns the returned slice and its contents.
    pub fn getCommits(self: *const Self, from: ?[]const u8, to: []const u8) ![]RawCommit {
        const format = comptime blk: {
            // Format: hash, short_hash, author, date, subject separated by \x00
            // Body follows after \x00\x00
            break :blk "%H%x00%h%x00%an%x00%aI%x00%s%x00%b%x00%x00";
        };

        var range_buf: [512]u8 = undefined;
        const range = if (from) |f|
            std.fmt.bufPrint(&range_buf, "{s}..{s}", .{ f, to }) catch return GitError.ParseError
        else
            to;

        const output = try self.runCommand(&.{
            "log",
            "--format=" ++ format,
            range,
        });
        defer self.allocator.free(output);

        return parseCommits(self.allocator, output);
    }

    /// Gets the full details of a single commit.
    pub fn showCommit(self: *const Self, ref: []const u8) !RawCommit {
        const format = comptime "%H%x00%h%x00%an%x00%aI%x00%s%x00%b";

        const output = try self.runCommand(&.{
            "show",
            "-s",
            "--format=" ++ format,
            ref,
        });
        defer self.allocator.free(output);

        var commits = try parseCommits(self.allocator, output);
        defer {
            for (commits[1..]) |*c| {
                c.deinit(self.allocator);
            }
            self.allocator.free(commits);
        }

        if (commits.len == 0) {
            return GitError.RefNotFound;
        }

        // Move ownership of first commit to caller
        const result = commits[0];
        return result;
    }

    /// Gets the diff for a commit (patch format).
    /// Caller owns the returned memory.
    pub fn getCommitDiff(self: *const Self, ref: []const u8) ![]u8 {
        return self.runCommand(&.{
            "show",
            "--patch",
            "--format=",
            ref,
        });
    }

    /// Checks if a ref exists.
    pub fn refExists(self: *const Self, ref: []const u8) !bool {
        _ = self.runCommand(&.{
            "rev-parse",
            "--verify",
            ref,
        }) catch |err| {
            if (err == GitError.CommandFailed or err == GitError.RefNotFound) {
                return false;
            }
            return err;
        };
        return true;
    }

    /// Gets the current branch name.
    /// Returns null if in detached HEAD state.
    pub fn getCurrentBranch(self: *const Self) !?[]const u8 {
        const output = self.runCommand(&.{
            "symbolic-ref",
            "--short",
            "HEAD",
        }) catch |err| {
            if (err == GitError.CommandFailed) {
                return null;
            }
            return err;
        };
        defer self.allocator.free(output);

        const trimmed = std.mem.trim(u8, output, " \t\n\r");
        if (trimmed.len == 0) return null;

        return try self.allocator.dupe(u8, trimmed);
    }
};

/// Parses newline-separated output into a slice of strings.
fn parseLines(allocator: Allocator, output: []const u8) ![][]const u8 {
    var lines = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (lines.items) |line| {
            allocator.free(line);
        }
        lines.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, output, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            const owned = try allocator.dupe(u8, trimmed);
            try lines.append(allocator, owned);
        }
    }

    return lines.toOwnedSlice(allocator);
}

/// Parses git log output with custom format into commits.
fn parseCommits(allocator: Allocator, output: []const u8) ![]RawCommit {
    var commits = std.ArrayListUnmanaged(RawCommit){};
    errdefer {
        for (commits.items) |*c| {
            c.deinit(allocator);
        }
        commits.deinit(allocator);
    }

    // Split by double null (record separator)
    var records = std.mem.splitSequence(u8, output, "\x00\x00");
    while (records.next()) |record| {
        // Trim whitespace and null bytes (trailing nulls can occur after last record)
        const trimmed = std.mem.trim(u8, record, " \t\n\r\x00");
        if (trimmed.len == 0) continue;

        const commit = try parseCommitRecord(allocator, trimmed);
        try commits.append(allocator, commit);
    }

    return commits.toOwnedSlice(allocator);
}

/// Parses a single commit record.
fn parseCommitRecord(allocator: Allocator, record: []const u8) !RawCommit {
    var parts = std.mem.splitScalar(u8, record, '\x00');

    const hash = parts.next() orelse return GitError.ParseError;
    const short_hash = parts.next() orelse return GitError.ParseError;
    const author = parts.next() orelse return GitError.ParseError;
    const date = parts.next() orelse return GitError.ParseError;
    const subject = parts.next() orelse return GitError.ParseError;
    const body_raw = parts.next();

    const owned_hash = try allocator.dupe(u8, hash);
    errdefer allocator.free(owned_hash);

    const owned_short_hash = try allocator.dupe(u8, short_hash);
    errdefer allocator.free(owned_short_hash);

    const owned_author = try allocator.dupe(u8, author);
    errdefer allocator.free(owned_author);

    const owned_date = try allocator.dupe(u8, date);
    errdefer allocator.free(owned_date);

    const owned_subject = try allocator.dupe(u8, subject);
    errdefer allocator.free(owned_subject);

    const owned_body: ?[]const u8 = if (body_raw) |b| blk: {
        const trimmed = std.mem.trim(u8, b, " \t\n\r");
        if (trimmed.len == 0) break :blk null;
        break :blk try allocator.dupe(u8, trimmed);
    } else null;

    return RawCommit{
        .hash = owned_hash,
        .short_hash = owned_short_hash,
        .author = owned_author,
        .date = owned_date,
        .subject = owned_subject,
        .body = owned_body,
    };
}

/// Maps std errors to GitError.
fn mapError(err: anytype) GitError {
    return switch (@TypeOf(err)) {
        error{OutOfMemory} => GitError.OutOfMemory,
        else => GitError.CommandFailed,
    };
}

// Tests
test "Git.init creates instance" {
    var git = Git.init(std.testing.allocator);
    defer git.deinit();

    try std.testing.expect(git.repo_path == null);
}

test "Git.initWithPath stores path" {
    var git = try Git.initWithPath(std.testing.allocator, "/tmp/test");
    defer git.deinit();

    try std.testing.expectEqualStrings("/tmp/test", git.repo_path.?);
}

test "parseLines splits output correctly" {
    const output = "v1.0.0\nv0.9.0\nv0.8.0\n";
    const lines = try parseLines(std.testing.allocator, output);
    defer {
        for (lines) |line| {
            std.testing.allocator.free(line);
        }
        std.testing.allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("v1.0.0", lines[0]);
    try std.testing.expectEqualStrings("v0.9.0", lines[1]);
    try std.testing.expectEqualStrings("v0.8.0", lines[2]);
}

test "parseLines handles empty lines" {
    const output = "v1.0.0\n\n\nv0.9.0\n";
    const lines = try parseLines(std.testing.allocator, output);
    defer {
        for (lines) |line| {
            std.testing.allocator.free(line);
        }
        std.testing.allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.len);
}

test "parseCommitRecord parses valid record" {
    const record = "abc123def456\x00abc123d\x00John Doe\x002026-01-19T10:00:00Z\x00feat: add feature\x00This is the body";
    var commit = try parseCommitRecord(std.testing.allocator, record);
    defer commit.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc123def456", commit.hash);
    try std.testing.expectEqualStrings("abc123d", commit.short_hash);
    try std.testing.expectEqualStrings("John Doe", commit.author);
    try std.testing.expectEqualStrings("2026-01-19T10:00:00Z", commit.date);
    try std.testing.expectEqualStrings("feat: add feature", commit.subject);
    try std.testing.expectEqualStrings("This is the body", commit.body.?);
}

test "parseCommitRecord handles empty body" {
    const record = "abc123\x00abc\x00Author\x002026-01-19\x00subject\x00";
    var commit = try parseCommitRecord(std.testing.allocator, record);
    defer commit.deinit(std.testing.allocator);

    try std.testing.expect(commit.body == null);
}
