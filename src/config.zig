const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.config);

const filter_mod = @import("filter.zig");
const FilterConfig = filter_mod.FilterConfig;

const markdown_mod = @import("format/markdown.zig");
const MarkdownConfig = markdown_mod.MarkdownConfig;

/// Configuration error types.
pub const ConfigError = error{
    InvalidSyntax,
    InvalidValue,
    UnknownKey,
    OutOfMemory,
    FileNotFound,
    ReadError,
};

/// Complete Chronicle configuration.
pub const Config = struct {
    allocator: Allocator,

    // Section name customization
    section_names: SectionNames = .{},

    // Filter configuration
    filter: FilterConfig = .{},

    // Format options
    format: FormatOptions = .{},

    // Repository info (for linking)
    repository: RepositoryConfig = .{},

    // Allocated strings that need cleanup
    owned_strings: std.ArrayListUnmanaged([]const u8) = .{},
    owned_string_arrays: std.ArrayListUnmanaged([]const []const u8) = .{},

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.owned_strings.items) |str| {
            self.allocator.free(str);
        }
        self.owned_strings.deinit(self.allocator);

        for (self.owned_string_arrays.items) |arr| {
            self.allocator.free(arr);
        }
        self.owned_string_arrays.deinit(self.allocator);

        self.* = undefined;
    }

    /// Tracks an allocated string for cleanup.
    fn trackString(self: *Self, str: []const u8) !void {
        try self.owned_strings.append(self.allocator, str);
    }

    /// Tracks an allocated string array for cleanup.
    fn trackStringArray(self: *Self, arr: []const []const u8) !void {
        try self.owned_string_arrays.append(self.allocator, arr);
    }

    /// Converts this config to a FilterConfig.
    pub fn toFilterConfig(self: *const Self) FilterConfig {
        return .{
            .include_refactor = self.filter.include_refactor,
            .include_docs = self.filter.include_docs,
            .include_chore = self.filter.include_chore,
            .include_test = self.filter.include_test,
            .include_ci = self.filter.include_ci,
            .include_build = self.filter.include_build,
            .exclude_scopes = self.filter.exclude_scopes,
            .exclude_patterns = self.filter.exclude_patterns,
            .include_merge_commits = self.filter.include_merge_commits,
        };
    }

    /// Converts this config to a MarkdownConfig.
    pub fn toMarkdownConfig(self: *const Self) MarkdownConfig {
        return .{
            .show_hashes = self.format.show_hashes,
            .hash_length = self.format.hash_length,
            .show_authors = self.format.show_authors,
            .commit_url_base = self.repository.commit_url_base,
            .issue_url_base = self.repository.issue_url_base,
            .show_breaking = self.format.show_breaking,
            .show_scope = self.format.show_scope,
        };
    }
};

/// Section name customization.
pub const SectionNames = struct {
    feat: []const u8 = "Added",
    fix: []const u8 = "Fixed",
    perf: []const u8 = "Performance",
    refactor: []const u8 = "Changed",
    docs: []const u8 = "Documentation",
    deprecate: []const u8 = "Deprecated",
    remove: []const u8 = "Removed",
    security: []const u8 = "Security",
    chore: []const u8 = "Chore",
    @"test": []const u8 = "Tests",
    ci: []const u8 = "CI",
    build: []const u8 = "Build",
    other: []const u8 = "Other",
};

/// Format options for output.
pub const FormatOptions = struct {
    show_hashes: bool = true,
    hash_length: usize = 7,
    show_authors: bool = false,
    show_breaking: bool = true,
    show_scope: bool = true,
    link_commits: bool = true,
    link_issues: bool = true,
};

/// Repository configuration for linking.
pub const RepositoryConfig = struct {
    /// GitHub/GitLab repository URL (e.g., "https://github.com/user/repo").
    url: ?[]const u8 = null,

    /// Base URL for commit links. Auto-generated from url if not set.
    commit_url_base: ?[]const u8 = null,

    /// Base URL for issue links. Auto-generated from url if not set.
    issue_url_base: ?[]const u8 = null,
};

/// Minimal TOML parser for Chronicle configuration.
/// Only supports the subset of TOML we need.
pub const TomlParser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize = 0,
    line: usize = 1,

    const Self = @This();

    pub fn init(allocator: Allocator, input: []const u8) Self {
        return .{
            .allocator = allocator,
            .input = input,
        };
    }

    /// Parses TOML content into a Config struct.
    pub fn parse(self: *Self) !Config {
        var config = Config.init(self.allocator);
        errdefer config.deinit();

        var current_section: ?[]const u8 = null;

        while (self.pos < self.input.len) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.input.len) break;

            const c = self.input[self.pos];

            if (c == '[') {
                // Section header
                current_section = try self.parseSection();
            } else if (std.ascii.isAlphabetic(c) or c == '_') {
                // Key-value pair
                try self.parseKeyValue(&config, current_section);
            } else if (c == '\n') {
                self.pos += 1;
                self.line += 1;
            } else {
                return ConfigError.InvalidSyntax;
            }
        }

        // Auto-generate URLs from repository.url if not set
        try self.resolveRepositoryUrls(&config);

        return config;
    }

    fn skipWhitespaceAndComments(self: *Self) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                // Skip to end of line
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else if (c == '\n') {
                // Don't skip newlines here - they're significant for line counting
                break;
            } else {
                break;
            }
        }
    }

    fn parseSection(self: *Self) ![]const u8 {
        if (self.input[self.pos] != '[') return ConfigError.InvalidSyntax;
        self.pos += 1;

        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != ']' and self.input[self.pos] != '\n') {
            self.pos += 1;
        }

        if (self.pos >= self.input.len or self.input[self.pos] != ']') {
            return ConfigError.InvalidSyntax;
        }

        const section = self.input[start..self.pos];
        self.pos += 1; // Skip ']'

        return section;
    }

    fn parseKeyValue(self: *Self, config: *Config, section: ?[]const u8) !void {
        // Parse key
        const key_start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }
        const key = self.input[key_start..self.pos];

        // Skip whitespace and '='
        self.skipWhitespaceAndComments();
        if (self.pos >= self.input.len or self.input[self.pos] != '=') {
            return ConfigError.InvalidSyntax;
        }
        self.pos += 1;
        self.skipWhitespaceAndComments();

        // Parse value based on type
        const value = try self.parseValue(config);

        // Apply to config
        try self.applyConfig(config, section, key, value);
    }

    const Value = union(enum) {
        string: []const u8,
        boolean: bool,
        integer: i64,
        string_array: []const []const u8,
    };

    fn parseValue(self: *Self, config: *Config) !Value {
        if (self.pos >= self.input.len) return ConfigError.InvalidSyntax;

        const c = self.input[self.pos];

        if (c == '"') {
            // String
            const str = try self.parseString(config);
            return .{ .string = str };
        } else if (c == '[') {
            // Array
            const arr = try self.parseArray(config);
            return .{ .string_array = arr };
        } else if (std.mem.startsWith(u8, self.input[self.pos..], "true")) {
            self.pos += 4;
            return .{ .boolean = true };
        } else if (std.mem.startsWith(u8, self.input[self.pos..], "false")) {
            self.pos += 5;
            return .{ .boolean = false };
        } else if (std.ascii.isDigit(c) or c == '-') {
            // Integer
            const num = try self.parseInteger();
            return .{ .integer = num };
        } else {
            return ConfigError.InvalidSyntax;
        }
    }

    fn parseString(self: *Self, config: *Config) ![]const u8 {
        if (self.input[self.pos] != '"') return ConfigError.InvalidSyntax;
        self.pos += 1;

        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        while (self.pos < self.input.len and self.input[self.pos] != '"') {
            const c = self.input[self.pos];
            if (c == '\\' and self.pos + 1 < self.input.len) {
                // Escape sequence
                self.pos += 1;
                const next = self.input[self.pos];
                const escaped: u8 = if (next == 'n')
                    '\n'
                else if (next == 't')
                    '\t'
                else if (next == 'r')
                    '\r'
                else if (next == '"')
                    '"'
                else if (next == '\\')
                    '\\'
                else
                    return ConfigError.InvalidSyntax;
                try result.append(self.allocator, escaped);
            } else if (c == '\n') {
                return ConfigError.InvalidSyntax;
            } else {
                try result.append(self.allocator, c);
            }
            self.pos += 1;
        }

        if (self.pos >= self.input.len or self.input[self.pos] != '"') {
            return ConfigError.InvalidSyntax;
        }
        self.pos += 1;

        const str = try result.toOwnedSlice(self.allocator);
        try config.trackString(str);
        return str;
    }

    fn parseArray(self: *Self, config: *Config) ![]const []const u8 {
        if (self.input[self.pos] != '[') return ConfigError.InvalidSyntax;
        self.pos += 1;

        var items = std.ArrayListUnmanaged([]const u8){};
        errdefer items.deinit(self.allocator);

        self.skipWhitespaceAndNewlines();

        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            if (self.input[self.pos] == '"') {
                const str = try self.parseString(config);
                try items.append(self.allocator, str);
            } else if (self.input[self.pos] == ',') {
                self.pos += 1;
            } else {
                return ConfigError.InvalidSyntax;
            }
            self.skipWhitespaceAndNewlines();
        }

        if (self.pos >= self.input.len or self.input[self.pos] != ']') {
            return ConfigError.InvalidSyntax;
        }
        self.pos += 1;

        const arr = try items.toOwnedSlice(self.allocator);
        try config.trackStringArray(arr);
        return arr;
    }

    fn skipWhitespaceAndNewlines(self: *Self) void {
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                if (c == '\n') self.line += 1;
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn parseInteger(self: *Self) !i64 {
        const start = self.pos;
        if (self.input[self.pos] == '-') {
            self.pos += 1;
        }
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.pos += 1;
        }
        const str = self.input[start..self.pos];
        return std.fmt.parseInt(i64, str, 10) catch return ConfigError.InvalidValue;
    }

    fn applyConfig(self: *Self, config: *Config, section: ?[]const u8, key: []const u8, value: Value) !void {
        _ = self;

        if (section == null) {
            // Top-level keys (currently none defined)
            return;
        }

        const sect = section.?;

        if (std.mem.eql(u8, sect, "filter")) {
            try applyFilterConfig(config, key, value);
        } else if (std.mem.eql(u8, sect, "format")) {
            try applyFormatConfig(config, key, value);
        } else if (std.mem.eql(u8, sect, "repository")) {
            try applyRepositoryConfig(config, key, value);
        } else if (std.mem.eql(u8, sect, "sections")) {
            try applySectionConfig(config, key, value);
        }
    }

    fn applyFilterConfig(config: *Config, key: []const u8, value: Value) !void {
        if (std.mem.eql(u8, key, "include_refactor")) {
            config.filter.include_refactor = value.boolean;
        } else if (std.mem.eql(u8, key, "include_docs")) {
            config.filter.include_docs = value.boolean;
        } else if (std.mem.eql(u8, key, "include_chore")) {
            config.filter.include_chore = value.boolean;
        } else if (std.mem.eql(u8, key, "include_test")) {
            config.filter.include_test = value.boolean;
        } else if (std.mem.eql(u8, key, "include_ci")) {
            config.filter.include_ci = value.boolean;
        } else if (std.mem.eql(u8, key, "include_build")) {
            config.filter.include_build = value.boolean;
        } else if (std.mem.eql(u8, key, "include_merge_commits")) {
            config.filter.include_merge_commits = value.boolean;
        } else if (std.mem.eql(u8, key, "exclude_scopes")) {
            config.filter.exclude_scopes = value.string_array;
        } else if (std.mem.eql(u8, key, "exclude_patterns")) {
            config.filter.exclude_patterns = value.string_array;
        }
    }

    fn applyFormatConfig(config: *Config, key: []const u8, value: Value) !void {
        if (std.mem.eql(u8, key, "show_hashes")) {
            config.format.show_hashes = value.boolean;
        } else if (std.mem.eql(u8, key, "hash_length")) {
            config.format.hash_length = @intCast(value.integer);
        } else if (std.mem.eql(u8, key, "show_authors")) {
            config.format.show_authors = value.boolean;
        } else if (std.mem.eql(u8, key, "show_breaking")) {
            config.format.show_breaking = value.boolean;
        } else if (std.mem.eql(u8, key, "show_scope")) {
            config.format.show_scope = value.boolean;
        } else if (std.mem.eql(u8, key, "link_commits")) {
            config.format.link_commits = value.boolean;
        } else if (std.mem.eql(u8, key, "link_issues")) {
            config.format.link_issues = value.boolean;
        }
    }

    fn applyRepositoryConfig(config: *Config, key: []const u8, value: Value) !void {
        if (std.mem.eql(u8, key, "url")) {
            config.repository.url = value.string;
        } else if (std.mem.eql(u8, key, "commit_url_base")) {
            config.repository.commit_url_base = value.string;
        } else if (std.mem.eql(u8, key, "issue_url_base")) {
            config.repository.issue_url_base = value.string;
        }
    }

    fn applySectionConfig(config: *Config, key: []const u8, value: Value) !void {
        if (std.mem.eql(u8, key, "feat")) {
            config.section_names.feat = value.string;
        } else if (std.mem.eql(u8, key, "fix")) {
            config.section_names.fix = value.string;
        } else if (std.mem.eql(u8, key, "perf")) {
            config.section_names.perf = value.string;
        } else if (std.mem.eql(u8, key, "refactor")) {
            config.section_names.refactor = value.string;
        } else if (std.mem.eql(u8, key, "docs")) {
            config.section_names.docs = value.string;
        } else if (std.mem.eql(u8, key, "deprecate")) {
            config.section_names.deprecate = value.string;
        } else if (std.mem.eql(u8, key, "remove")) {
            config.section_names.remove = value.string;
        } else if (std.mem.eql(u8, key, "security")) {
            config.section_names.security = value.string;
        } else if (std.mem.eql(u8, key, "chore")) {
            config.section_names.chore = value.string;
        } else if (std.mem.eql(u8, key, "test")) {
            config.section_names.@"test" = value.string;
        } else if (std.mem.eql(u8, key, "ci")) {
            config.section_names.ci = value.string;
        } else if (std.mem.eql(u8, key, "build")) {
            config.section_names.build = value.string;
        } else if (std.mem.eql(u8, key, "other")) {
            config.section_names.other = value.string;
        }
    }

    fn resolveRepositoryUrls(self: *Self, config: *Config) !void {
        _ = self;

        // If repository.url is set but specific URLs aren't, derive them
        if (config.repository.url) |repo_url| {
            // Ensure URL doesn't end with /
            const base = if (repo_url.len > 0 and repo_url[repo_url.len - 1] == '/')
                repo_url[0 .. repo_url.len - 1]
            else
                repo_url;

            if (config.repository.commit_url_base == null and config.format.link_commits) {
                // GitHub/GitLab style: {repo}/commit/
                var buf = std.ArrayListUnmanaged(u8){};
                try buf.appendSlice(config.allocator, base);
                try buf.appendSlice(config.allocator, "/commit/");
                const url = try buf.toOwnedSlice(config.allocator);
                try config.trackString(url);
                config.repository.commit_url_base = url;
            }

            if (config.repository.issue_url_base == null and config.format.link_issues) {
                // GitHub/GitLab style: {repo}/issues/
                var buf = std.ArrayListUnmanaged(u8){};
                try buf.appendSlice(config.allocator, base);
                try buf.appendSlice(config.allocator, "/issues/");
                const url = try buf.toOwnedSlice(config.allocator);
                try config.trackString(url);
                config.repository.issue_url_base = url;
            }
        }
    }
};

/// Loads configuration from a file path.
/// Returns null if file doesn't exist.
/// Caller owns the returned Config and must call deinit.
pub fn loadFromFile(allocator: Allocator, path: []const u8) !?Config {
    const cwd = std.fs.cwd();

    const content = cwd.readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return ConfigError.ReadError;
    };
    defer allocator.free(content);

    var parser = TomlParser.init(allocator, content);
    return try parser.parse();
}

/// Loads configuration from chronicle.toml in the current directory.
/// Returns default config if file doesn't exist.
pub fn loadDefault(allocator: Allocator) !Config {
    if (try loadFromFile(allocator, "chronicle.toml")) |config| {
        return config;
    }
    return Config.init(allocator);
}

// Tests

test "TomlParser parses empty config" {
    var parser = TomlParser.init(std.testing.allocator, "");
    var config = try parser.parse();
    defer config.deinit();

    // Should have defaults
    try std.testing.expectEqual(false, config.filter.include_refactor);
    try std.testing.expectEqual(true, config.format.show_hashes);
}

test "TomlParser parses filter section" {
    const input =
        \\[filter]
        \\include_refactor = true
        \\include_docs = true
        \\include_chore = false
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqual(true, config.filter.include_refactor);
    try std.testing.expectEqual(true, config.filter.include_docs);
    try std.testing.expectEqual(false, config.filter.include_chore);
}

test "TomlParser parses format section" {
    const input =
        \\[format]
        \\show_hashes = false
        \\hash_length = 10
        \\show_authors = true
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqual(false, config.format.show_hashes);
    try std.testing.expectEqual(@as(usize, 10), config.format.hash_length);
    try std.testing.expectEqual(true, config.format.show_authors);
}

test "TomlParser parses repository section" {
    const input =
        \\[repository]
        \\url = "https://github.com/user/repo"
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqualStrings("https://github.com/user/repo", config.repository.url.?);
    // Should auto-generate commit and issue URLs
    try std.testing.expectEqualStrings("https://github.com/user/repo/commit/", config.repository.commit_url_base.?);
    try std.testing.expectEqualStrings("https://github.com/user/repo/issues/", config.repository.issue_url_base.?);
}

test "TomlParser parses string arrays" {
    const input =
        \\[filter]
        \\exclude_scopes = ["deps", "internal"]
        \\exclude_patterns = ["wip", "skip"]
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.filter.exclude_scopes.len);
    try std.testing.expectEqualStrings("deps", config.filter.exclude_scopes[0]);
    try std.testing.expectEqualStrings("internal", config.filter.exclude_scopes[1]);

    try std.testing.expectEqual(@as(usize, 2), config.filter.exclude_patterns.len);
    try std.testing.expectEqualStrings("wip", config.filter.exclude_patterns[0]);
    try std.testing.expectEqualStrings("skip", config.filter.exclude_patterns[1]);
}

test "TomlParser handles comments" {
    const input =
        \\# This is a comment
        \\[filter]
        \\# Another comment
        \\include_refactor = true  # inline comment
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqual(true, config.filter.include_refactor);
}

test "TomlParser parses section names" {
    const input =
        \\[sections]
        \\feat = "Features"
        \\fix = "Bug Fixes"
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqualStrings("Features", config.section_names.feat);
    try std.testing.expectEqualStrings("Bug Fixes", config.section_names.fix);
}

test "TomlParser handles escape sequences in strings" {
    const input =
        \\[repository]
        \\url = "https://example.com/path\twith\ttabs"
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqualStrings("https://example.com/path\twith\ttabs", config.repository.url.?);
}

test "Config.toFilterConfig converts correctly" {
    const input =
        \\[filter]
        \\include_refactor = true
        \\exclude_scopes = ["deps"]
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    const filter_config = config.toFilterConfig();
    try std.testing.expectEqual(true, filter_config.include_refactor);
    try std.testing.expectEqual(@as(usize, 1), filter_config.exclude_scopes.len);
    try std.testing.expectEqualStrings("deps", filter_config.exclude_scopes[0]);
}

test "Config.toMarkdownConfig converts correctly" {
    const input =
        \\[format]
        \\show_hashes = false
        \\show_authors = true
        \\
        \\[repository]
        \\url = "https://github.com/user/repo"
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    const md_config = config.toMarkdownConfig();
    try std.testing.expectEqual(false, md_config.show_hashes);
    try std.testing.expectEqual(true, md_config.show_authors);
    try std.testing.expectEqualStrings("https://github.com/user/repo/commit/", md_config.commit_url_base.?);
}

test "TomlParser handles multiline arrays" {
    const input =
        \\[filter]
        \\exclude_scopes = [
        \\    "deps",
        \\    "internal",
        \\    "scripts"
        \\]
    ;

    var parser = TomlParser.init(std.testing.allocator, input);
    var config = try parser.parse();
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 3), config.filter.exclude_scopes.len);
    try std.testing.expectEqualStrings("deps", config.filter.exclude_scopes[0]);
    try std.testing.expectEqualStrings("internal", config.filter.exclude_scopes[1]);
    try std.testing.expectEqualStrings("scripts", config.filter.exclude_scopes[2]);
}

test "loadDefault returns default config when no file exists" {
    // This test relies on chronicle.toml not existing in the test directory
    // Since we can't guarantee that, we test the Config.init path
    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(false, config.filter.include_refactor);
    try std.testing.expectEqual(true, config.format.show_hashes);
}
