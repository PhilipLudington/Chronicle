const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("changelog.zig");
const PRInfo = changelog.PRInfo;

/// Errors that can occur when interacting with GitHub API.
pub const GitHubError = error{
    GhCommandNotFound,
    GhCommandFailed,
    InvalidJson,
    OutOfMemory,
    NotAuthenticated,
    RepoNotFound,
};

/// GitHub API client that uses the gh CLI.
pub const GitHubAPI = struct {
    allocator: Allocator,
    /// Repository in "owner/repo" format.
    repo: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: Allocator, repo: ?[]const u8) Self {
        return .{
            .allocator = allocator,
            .repo = repo,
        };
    }

    /// Checks if the gh CLI is available and authenticated.
    pub fn isAvailable(self: *const Self) bool {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "gh", "auth", "status" },
        }) catch return false;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        return result.term.Exited == 0;
    }

    /// Gets PR information for a specific commit hash.
    /// Uses `gh pr list --search "<hash>" --state merged`.
    /// Returns null if no PR is found for the commit.
    pub fn getPRForCommit(self: *const Self, hash: []const u8) !?PRInfo {
        const repo_arg = self.repo orelse return null;

        // Build gh command
        var search_buf: [128]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "{s}", .{hash}) catch return null;

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{
                "gh",
                "pr",
                "list",
                "--repo",
                repo_arg,
                "--search",
                search,
                "--state",
                "merged",
                "--json",
                "number,title,body,labels",
                "--limit",
                "1",
            },
        }) catch |err| {
            if (err == error.FileNotFound) {
                return GitHubError.GhCommandNotFound;
            }
            return GitHubError.GhCommandFailed;
        };

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            // Check for auth error
            if (std.mem.indexOf(u8, result.stderr, "auth") != null) {
                return GitHubError.NotAuthenticated;
            }
            return GitHubError.GhCommandFailed;
        }

        // Parse JSON response
        return self.parsePRJson(result.stdout);
    }

    /// Gets PR information for multiple commits.
    /// Returns a map from commit hash to PRInfo.
    /// Commits without PRs are not included in the map.
    pub fn getPRsForCommits(self: *const Self, hashes: []const []const u8) !std.StringHashMapUnmanaged(PRInfo) {
        var result = std.StringHashMapUnmanaged(PRInfo){};
        errdefer {
            var iter = result.iterator();
            while (iter.next()) |entry| {
                var pr_info = entry.value_ptr.*;
                pr_info.deinit(self.allocator);
            }
            result.deinit(self.allocator);
        }

        for (hashes) |hash| {
            if (try self.getPRForCommit(hash)) |pr_info| {
                const owned_hash = try self.allocator.dupe(u8, hash);
                errdefer self.allocator.free(owned_hash);
                try result.put(self.allocator, owned_hash, pr_info);
            }
        }

        return result;
    }

    /// Parses JSON response from gh CLI into PRInfo.
    fn parsePRJson(self: *const Self, json_data: []const u8) !?PRInfo {
        // gh returns an array, even for single results
        // We need to parse [{ "number": N, "title": "...", "body": "...", "labels": [...] }]

        const trimmed = std.mem.trim(u8, json_data, " \t\n\r");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "[]")) {
            return null;
        }

        // Simple JSON parsing for our specific format
        // Find the first object in the array
        const obj_start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;
        const obj_end = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return null;

        if (obj_end <= obj_start) return null;

        const obj = trimmed[obj_start .. obj_end + 1];

        // Extract fields
        const number = self.extractJsonNumber(obj, "number") orelse return null;
        const title = try self.extractJsonString(obj, "title") orelse return null;
        errdefer self.allocator.free(title);

        const body = try self.extractJsonString(obj, "body");
        errdefer if (body) |b| self.allocator.free(b);

        const labels = try self.extractJsonStringArray(obj, "labels");
        errdefer {
            for (labels) |label| self.allocator.free(label);
            self.allocator.free(labels);
        }

        return PRInfo{
            .number = @intCast(number),
            .title = title,
            .body = body,
            .labels = labels,
        };
    }

    /// Extracts a number field from JSON.
    fn extractJsonNumber(self: *const Self, json: []const u8, field: []const u8) ?i64 {
        _ = self;

        // Look for "field":
        var search_buf: [64]u8 = undefined;
        const search_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return null;

        const field_start = std.mem.indexOf(u8, json, search_pattern) orelse return null;
        const value_start = field_start + search_pattern.len;

        // Skip whitespace
        var pos = value_start;
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}

        if (pos >= json.len) return null;

        // Parse number
        var end = pos;
        while (end < json.len and (std.ascii.isDigit(json[end]) or json[end] == '-')) : (end += 1) {}

        if (end == pos) return null;

        return std.fmt.parseInt(i64, json[pos..end], 10) catch null;
    }

    /// Extracts a string field from JSON.
    fn extractJsonString(self: *const Self, json: []const u8, field: []const u8) !?[]const u8 {
        // Look for "field":
        var search_buf: [64]u8 = undefined;
        const search_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return null;

        const field_start = std.mem.indexOf(u8, json, search_pattern) orelse return null;
        const value_start = field_start + search_pattern.len;

        // Skip whitespace
        var pos = value_start;
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}

        if (pos >= json.len) return null;

        // Check for null
        if (pos + 4 <= json.len and std.mem.eql(u8, json[pos .. pos + 4], "null")) {
            return null;
        }

        // Expect opening quote
        if (json[pos] != '"') return null;
        pos += 1;

        // Find closing quote (handle escapes)
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        while (pos < json.len and json[pos] != '"') {
            if (json[pos] == '\\' and pos + 1 < json.len) {
                pos += 1;
                const escaped: u8 = switch (json[pos]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '"' => '"',
                    '\\' => '\\',
                    else => json[pos],
                };
                try result.append(self.allocator, escaped);
            } else {
                try result.append(self.allocator, json[pos]);
            }
            pos += 1;
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Extracts a string array from JSON labels field.
    /// Labels format: [{"name":"label1"},{"name":"label2"}]
    fn extractJsonStringArray(self: *const Self, json: []const u8, field: []const u8) ![]const []const u8 {
        var search_buf: [64]u8 = undefined;
        const search_pattern = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{field}) catch return &.{};

        const field_start = std.mem.indexOf(u8, json, search_pattern) orelse return &.{};
        const value_start = field_start + search_pattern.len;

        // Find the array
        var pos = value_start;
        while (pos < json.len and json[pos] != '[') : (pos += 1) {}

        if (pos >= json.len) return &.{};

        const array_start = pos;
        var depth: usize = 0;
        var array_end = pos;

        while (array_end < json.len) {
            if (json[array_end] == '[') depth += 1;
            if (json[array_end] == ']') {
                depth -= 1;
                if (depth == 0) break;
            }
            array_end += 1;
        }

        const array_content = json[array_start + 1 .. array_end];

        // Extract "name" values from label objects
        var labels = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (labels.items) |label| self.allocator.free(label);
            labels.deinit(self.allocator);
        }

        var search_pos: usize = 0;
        while (std.mem.indexOfPos(u8, array_content, search_pos, "\"name\":")) |name_pos| {
            const name_value_start = name_pos + 7; // len("\"name\":")

            // Skip whitespace and find quote
            var p = name_value_start;
            while (p < array_content.len and (array_content[p] == ' ' or array_content[p] == '\t')) : (p += 1) {}

            if (p < array_content.len and array_content[p] == '"') {
                p += 1;
                const str_start = p;
                while (p < array_content.len and array_content[p] != '"') : (p += 1) {}
                const str_end = p;

                const label = try self.allocator.dupe(u8, array_content[str_start..str_end]);
                try labels.append(self.allocator, label);
            }

            search_pos = name_pos + 1;
        }

        return try labels.toOwnedSlice(self.allocator);
    }
};

// Tests

test "GitHubAPI parses PR JSON response" {
    const allocator = std.testing.allocator;

    var api = GitHubAPI.init(allocator, "owner/repo");

    const json =
        \\[{"number":123,"title":"Add feature","body":"Description here","labels":[{"name":"enhancement"},{"name":"good first issue"}]}]
    ;

    const pr_info = try api.parsePRJson(json);
    try std.testing.expect(pr_info != null);

    var pr = pr_info.?;
    defer pr.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 123), pr.number);
    try std.testing.expectEqualStrings("Add feature", pr.title);
    try std.testing.expectEqualStrings("Description here", pr.body.?);
    try std.testing.expectEqual(@as(usize, 2), pr.labels.len);
    try std.testing.expectEqualStrings("enhancement", pr.labels[0]);
    try std.testing.expectEqualStrings("good first issue", pr.labels[1]);
}

test "GitHubAPI handles empty JSON response" {
    const allocator = std.testing.allocator;

    var api = GitHubAPI.init(allocator, "owner/repo");

    const json = "[]";

    const pr_info = try api.parsePRJson(json);
    try std.testing.expect(pr_info == null);
}

test "GitHubAPI handles null body" {
    const allocator = std.testing.allocator;

    var api = GitHubAPI.init(allocator, "owner/repo");

    const json =
        \\[{"number":456,"title":"Quick fix","body":null,"labels":[]}]
    ;

    const pr_info = try api.parsePRJson(json);
    try std.testing.expect(pr_info != null);

    var pr = pr_info.?;
    defer pr.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 456), pr.number);
    try std.testing.expectEqualStrings("Quick fix", pr.title);
    try std.testing.expect(pr.body == null);
    try std.testing.expectEqual(@as(usize, 0), pr.labels.len);
}

test "GitHubAPI handles escaped characters in JSON" {
    const allocator = std.testing.allocator;

    var api = GitHubAPI.init(allocator, "owner/repo");

    const json =
        \\[{"number":789,"title":"Fix \"bug\" with\\backslash","body":"Line1\nLine2","labels":[]}]
    ;

    const pr_info = try api.parsePRJson(json);
    try std.testing.expect(pr_info != null);

    var pr = pr_info.?;
    defer pr.deinit(allocator);

    try std.testing.expectEqualStrings("Fix \"bug\" with\\backslash", pr.title);
    try std.testing.expectEqualStrings("Line1\nLine2", pr.body.?);
}
