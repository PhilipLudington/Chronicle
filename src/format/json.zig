const std = @import("std");
const Allocator = std.mem.Allocator;

const changelog = @import("../changelog.zig");
const ChangelogEntry = changelog.ChangelogEntry;
const Section = changelog.Section;
const Commit = changelog.Commit;
const Stats = changelog.Stats;

/// JSON formatter for changelog entries.
/// Produces structured JSON suitable for machine consumption and skill integration.
pub const JsonFormatter = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Formats a changelog entry to JSON.
    /// Caller owns the returned string.
    pub fn format(self: *const Self, entry: *const ChangelogEntry) ![]u8 {
        var output = std.ArrayListUnmanaged(u8){};
        errdefer output.deinit(self.allocator);

        try output.appendSlice(self.allocator, "{\n");

        // Version and date
        try self.appendString(&output, "  \"version\": ", entry.version);
        try output.appendSlice(self.allocator, ",\n");
        try self.appendString(&output, "  \"date\": ", entry.date);
        try output.appendSlice(self.allocator, ",\n");

        // Sections array
        try output.appendSlice(self.allocator, "  \"sections\": [\n");

        const section_order = ChangelogEntry.getSectionOrder();
        var first_section = true;

        for (section_order) |section_name| {
            if (entry.sections.get(section_name)) |section| {
                if (section.commits.items.len > 0) {
                    if (!first_section) {
                        try output.appendSlice(self.allocator, ",\n");
                    }
                    try self.appendSection(&output, section);
                    first_section = false;
                }
            }
        }

        // Handle sections not in standard order
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
                if (!first_section) {
                    try output.appendSlice(self.allocator, ",\n");
                }
                try self.appendSection(&output, kv.value_ptr.*);
                first_section = false;
            }
        }

        try output.appendSlice(self.allocator, "\n  ],\n");

        // Stats
        try output.appendSlice(self.allocator, "  \"stats\": {\n");
        try self.appendNumber(&output, "    \"included\": ", entry.stats.included);
        try output.appendSlice(self.allocator, ",\n");
        try self.appendNumber(&output, "    \"excluded\": ", entry.stats.excluded);
        try output.appendSlice(self.allocator, "\n  }\n");

        try output.appendSlice(self.allocator, "}\n");

        return output.toOwnedSlice(self.allocator);
    }

    fn appendSection(self: *const Self, output: *std.ArrayListUnmanaged(u8), section: Section) !void {
        try output.appendSlice(self.allocator, "    {\n");
        try self.appendString(output, "      \"name\": ", section.name);
        try output.appendSlice(self.allocator, ",\n");
        try output.appendSlice(self.allocator, "      \"commits\": [\n");

        for (section.commits.items, 0..) |commit, i| {
            if (i > 0) {
                try output.appendSlice(self.allocator, ",\n");
            }
            try self.appendCommit(output, commit);
        }

        try output.appendSlice(self.allocator, "\n      ]\n");
        try output.appendSlice(self.allocator, "    }");
    }

    fn appendCommit(self: *const Self, output: *std.ArrayListUnmanaged(u8), commit: Commit) !void {
        try output.appendSlice(self.allocator, "        {\n");

        try self.appendString(output, "          \"hash\": ", commit.hash);
        try output.appendSlice(self.allocator, ",\n");
        try self.appendString(output, "          \"short_hash\": ", commit.short_hash);
        try output.appendSlice(self.allocator, ",\n");
        try self.appendString(output, "          \"type\": ", @tagName(commit.commit_type));
        try output.appendSlice(self.allocator, ",\n");

        if (commit.scope) |scope| {
            try self.appendString(output, "          \"scope\": ", scope);
        } else {
            try output.appendSlice(self.allocator, "          \"scope\": null");
        }
        try output.appendSlice(self.allocator, ",\n");

        try self.appendString(output, "          \"description\": ", commit.description);
        try output.appendSlice(self.allocator, ",\n");
        try self.appendString(output, "          \"author\": ", commit.author);
        try output.appendSlice(self.allocator, ",\n");
        try self.appendString(output, "          \"date\": ", commit.date);
        try output.appendSlice(self.allocator, ",\n");

        try output.appendSlice(self.allocator, "          \"breaking\": ");
        if (commit.breaking) {
            try output.appendSlice(self.allocator, "true");
        } else {
            try output.appendSlice(self.allocator, "false");
        }
        try output.appendSlice(self.allocator, ",\n");

        // Issues array
        try output.appendSlice(self.allocator, "          \"issues\": [");
        for (commit.issues, 0..) |issue, i| {
            if (i > 0) {
                try output.appendSlice(self.allocator, ", ");
            }
            try output.append(self.allocator, '"');
            try self.appendEscaped(output, issue);
            try output.append(self.allocator, '"');
        }
        try output.appendSlice(self.allocator, "]\n");

        try output.appendSlice(self.allocator, "        }");
    }

    fn appendString(self: *const Self, output: *std.ArrayListUnmanaged(u8), prefix: []const u8, value: []const u8) !void {
        try output.appendSlice(self.allocator, prefix);
        try output.append(self.allocator, '"');
        try self.appendEscaped(output, value);
        try output.append(self.allocator, '"');
    }

    fn appendNumber(self: *const Self, output: *std.ArrayListUnmanaged(u8), prefix: []const u8, value: usize) !void {
        try output.appendSlice(self.allocator, prefix);
        var buf: [20]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
        try output.appendSlice(self.allocator, num_str);
    }

    fn appendEscaped(self: *const Self, output: *std.ArrayListUnmanaged(u8), str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try output.appendSlice(self.allocator, "\\\""),
                '\\' => try output.appendSlice(self.allocator, "\\\\"),
                '\n' => try output.appendSlice(self.allocator, "\\n"),
                '\r' => try output.appendSlice(self.allocator, "\\r"),
                '\t' => try output.appendSlice(self.allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        // Control character - output as \u00XX
                        var buf: [6]u8 = undefined;
                        const escaped = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                        try output.appendSlice(self.allocator, escaped);
                    } else {
                        try output.append(self.allocator, c);
                    }
                },
            }
        }
    }
};

/// Formats a changelog entry to JSON.
/// Caller owns the returned string.
pub fn formatEntry(allocator: Allocator, entry: *const ChangelogEntry) ![]u8 {
    const formatter = JsonFormatter.init(allocator);
    return formatter.format(entry);
}

// Tests

test "JsonFormatter formats basic entry" {
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

    // Verify key fields are present
    try std.testing.expect(std.mem.indexOf(u8, output, "\"version\": \"1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"date\": \"2026-01-19\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"name\": \"Added\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"description\": \"add new feature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"hash\": \"abc123def456789\"") != null);
}

test "JsonFormatter escapes special characters" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .fix,
        .scope = null,
        .description = "fix \"bug\" with\\backslash",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\\\"bug\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\\\backslash") != null);
}

test "JsonFormatter includes scope" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = "ui",
        .description = "add button",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"scope\": \"ui\"") != null);
}

test "JsonFormatter includes breaking flag" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "2.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
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

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"breaking\": true") != null);
}

test "JsonFormatter includes issues" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const issues = [_][]const u8{ "#123", "#456" };
    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .fix,
        .scope = null,
        .description = "fix issue",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &issues,
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"issues\": [\"#123\", \"#456\"]") != null);
}

test "JsonFormatter includes stats" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const commit = Commit{
        .hash = "abc123",
        .short_hash = "abc",
        .commit_type = .feat,
        .scope = null,
        .description = "feature",
        .body = null,
        .author = "developer",
        .date = "2026-01-19",
        .breaking = false,
        .issues = &.{},
    };

    try entry.addCommit(commit);

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"stats\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"included\": 1") != null);
}

test "JsonFormatter handles empty entry" {
    var entry = try ChangelogEntry.init(std.testing.allocator, "1.0.0", "2026-01-19");
    defer entry.deinit();

    const output = try formatEntry(std.testing.allocator, &entry);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"sections\": [") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"included\": 0") != null);
}
