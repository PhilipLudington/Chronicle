const std = @import("std");
const build_config = @import("config");

const changelog = @import("changelog.zig");
const git = @import("git.zig");
const parser = @import("parser.zig");
const filter = @import("filter.zig");
const config = @import("config.zig");
const markdown = @import("format/markdown.zig");
const json = @import("format/json.zig");
const github = @import("format/github.zig");

const log = std.log.scoped(.chronicle);

pub const std_options: std.Options = .{
    .log_level = if (build_config.enable_logging) .debug else .info,
};

const Command = enum {
    generate,
    init,
    lint,
    preview,
    help,
    version,
};

const Args = struct {
    command: Command = .help,
    version_tag: ?[]const u8 = null,
    from_tag: ?[]const u8 = null,
    to_tag: ?[]const u8 = null,
    output_path: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    format: Format = .markdown,
    dry_run: bool = false,
    quiet: bool = false,

    const Format = enum {
        markdown,
        json,
        github,
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try parseArgs(allocator);

    switch (args.command) {
        .generate => runGenerate(allocator, args) catch |err| {
            if (err != error.NoVersion and err != error.NotImplemented) {
                return err;
            }
        },
        .init => try runInit(),
        .lint => try runLint(allocator, args),
        .preview => try runPreview(allocator, args),
        .help => printHelp(),
        .version => printVersion(),
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    _ = allocator;
    var args = Args{};

    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // skip program name

    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "generate")) {
            args.command = .generate;
        } else if (std.mem.eql(u8, arg, "init")) {
            args.command = .init;
        } else if (std.mem.eql(u8, arg, "lint")) {
            args.command = .lint;
        } else if (std.mem.eql(u8, arg, "preview")) {
            args.command = .preview;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.command = .help;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            args.command = .version;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            args.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            args.quiet = true;
        } else if (std.mem.eql(u8, arg, "--version-tag")) {
            args.version_tag = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--from")) {
            args.from_tag = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--to")) {
            args.to_tag = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            args.output_path = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            args.config_path = arg_iter.next();
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
            if (arg_iter.next()) |format_str| {
                if (std.mem.eql(u8, format_str, "json")) {
                    args.format = .json;
                } else if (std.mem.eql(u8, format_str, "github")) {
                    args.format = .github;
                } else if (std.mem.eql(u8, format_str, "markdown")) {
                    args.format = .markdown;
                }
            }
        }
    }

    return args;
}

fn runGenerate(allocator: std.mem.Allocator, args: Args) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Load configuration
    var cfg = blk: {
        if (args.config_path) |path| {
            if (try config.loadFromFile(allocator, path)) |c| {
                break :blk c;
            }
            if (!args.quiet) {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Warning: Config file not found: {s}\n", .{path}) catch "";
                try stderr.writeAll(msg);
            }
        }
        break :blk try config.loadDefault(allocator);
    };
    defer cfg.deinit();

    // Initialize git interface
    var git_repo = git.Git.init(allocator);
    defer git_repo.deinit();

    // Determine version and commit range
    const version = args.version_tag orelse blk: {
        const latest = try git_repo.getLatestTag();
        if (latest) |tag| {
            break :blk tag;
        } else {
            if (!args.quiet) {
                try stderr.writeAll("No tags found. Please specify --version-tag\n");
            }
            return error.NoVersion;
        }
    };
    defer if (args.version_tag == null) allocator.free(version);

    const to_ref = args.to_tag orelse version;
    const from_ref: ?[]const u8 = args.from_tag orelse blk: {
        const prev = try git_repo.getPreviousTag(version);
        break :blk prev;
    };
    defer if (args.from_tag == null) {
        if (from_ref) |f| allocator.free(f);
    };

    if (!args.quiet) {
        var buf: [256]u8 = undefined;
        if (from_ref) |from| {
            const msg = std.fmt.bufPrint(&buf, "Generating changelog for {s} ({s}..{s})\n", .{ version, from, to_ref }) catch "Generating changelog...\n";
            try stderr.writeAll(msg);
        } else {
            const msg = std.fmt.bufPrint(&buf, "Generating changelog for {s} (all commits to {s})\n", .{ version, to_ref }) catch "Generating changelog...\n";
            try stderr.writeAll(msg);
        }
    }

    // Get commits from git
    const raw_commits = try git_repo.getCommits(from_ref, to_ref);
    defer {
        for (raw_commits) |*rc| {
            var commit = rc.*;
            commit.deinit(allocator);
        }
        allocator.free(raw_commits);
    }

    if (!args.quiet) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Found {d} commits\n", .{raw_commits.len}) catch "";
        try stderr.writeAll(msg);
    }

    // Parse commits
    const parsed_commits = try parser.parseRawCommits(allocator, raw_commits);
    defer {
        for (parsed_commits) |*pc| {
            var commit = pc.*;
            commit.deinit(allocator);
        }
        allocator.free(parsed_commits);
    }

    // Filter commits using configuration
    const filter_config = cfg.toFilterConfig();
    const commit_filter = filter.Filter.init(filter_config);
    var stats = filter.FilterStats{};
    defer stats.deinit(allocator);

    const filtered_commits = try commit_filter.filterCommitsWithStats(allocator, parsed_commits, &stats);
    defer allocator.free(filtered_commits);

    if (!args.quiet) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Included {d} commits, excluded {d}\n", .{ stats.included, stats.totalExcluded() }) catch "";
        try stderr.writeAll(msg);
    }

    // Get current date
    const timestamp = std.time.timestamp();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var date_buf: [10]u8 = undefined;
    const date = std.fmt.bufPrint(&date_buf, "{d}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
    }) catch "YYYY-MM-DD";

    // Create changelog entry
    var entry = try changelog.ChangelogEntry.init(allocator, version, date);
    defer entry.deinit();

    for (filtered_commits) |commit| {
        try entry.addCommit(commit);
    }

    // Format output using configuration
    const md_config = cfg.toMarkdownConfig();
    const output = switch (args.format) {
        .markdown => try markdown.formatEntryWithConfig(allocator, &entry, md_config),
        .json => try json.formatEntry(allocator, &entry),
        .github => try github.formatEntryWithConfig(allocator, &entry, .{
            .previous_version = from_ref,
            .repo_url = cfg.repository.url,
        }),
    };
    defer allocator.free(output);

    // Output
    if (args.dry_run) {
        try stdout.writeAll(output);
    } else {
        const output_path = args.output_path orelse "CHANGELOG.md";
        try writeChangelog(allocator, output_path, output);
        if (!args.quiet) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Wrote changelog to {s}\n", .{output_path}) catch "";
            try stderr.writeAll(msg);
        }
    }
}

fn writeChangelog(allocator: std.mem.Allocator, path: []const u8, new_content: []const u8) !void {
    const cwd = std.fs.cwd();

    // Try to read existing file
    const existing = cwd.readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) {
            // Create new file with header
            const file = try cwd.createFile(path, .{});
            defer file.close();
            try file.writeAll("# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n");
            try file.writeAll(new_content);
            return;
        }
        return err;
    };
    defer allocator.free(existing);

    // Find where to insert (after the header, before first version entry)
    const insert_pos = findInsertPosition(existing);

    // Write new file
    const file = try cwd.createFile(path, .{});
    defer file.close();

    try file.writeAll(existing[0..insert_pos]);
    if (insert_pos > 0 and existing[insert_pos - 1] != '\n') {
        try file.writeAll("\n");
    }
    try file.writeAll(new_content);
    try file.writeAll("\n");
    try file.writeAll(existing[insert_pos..]);
}

fn findInsertPosition(content: []const u8) usize {
    // Look for first "## [" which indicates a version entry
    if (std.mem.indexOf(u8, content, "\n## [")) |pos| {
        return pos + 1; // After the newline
    }

    // If no version entries, insert at end
    return content.len;
}

fn runInit() !void {
    const stderr = std.fs.File.stderr();
    const cwd = std.fs.cwd();

    // Check if chronicle.toml already exists
    if (cwd.statFile("chronicle.toml")) |_| {
        try stderr.writeAll("chronicle.toml already exists. Use --force to overwrite.\n");
        return;
    } else |err| {
        if (err != error.FileNotFound) {
            return err;
        }
    }

    // Write default configuration
    const default_config =
        \\# Chronicle Configuration
        \\# This file configures the changelog generator behavior.
        \\
        \\[repository]
        \\# Repository URL for generating links to commits and issues
        \\# url = "https://github.com/user/repo"
        \\
        \\[filter]
        \\# Include/exclude commit types
        \\# By default, chore, test, ci, and build commits are excluded
        \\include_refactor = false
        \\include_docs = false
        \\include_chore = false
        \\include_test = false
        \\include_ci = false
        \\include_build = false
        \\include_merge_commits = false
        \\
        \\# Scopes to exclude from the changelog
        \\exclude_scopes = []
        \\
        \\# Patterns to exclude (case-insensitive substring match)
        \\exclude_patterns = []
        \\
        \\[format]
        \\# Show commit hashes in output
        \\show_hashes = true
        \\
        \\# Length of hash to display (e.g., 7 for short hash)
        \\hash_length = 7
        \\
        \\# Show author names in changelog
        \\show_authors = false
        \\
        \\# Show breaking change indicators
        \\show_breaking = true
        \\
        \\# Show scope in parentheses before description
        \\show_scope = true
        \\
        \\# Generate links to commits (requires repository.url)
        \\link_commits = true
        \\
        \\# Generate links to issues (requires repository.url)
        \\link_issues = true
        \\
        \\[sections]
        \\# Customize section names (uncomment to override defaults)
        \\# feat = "Added"
        \\# fix = "Fixed"
        \\# perf = "Performance"
        \\# refactor = "Changed"
        \\# docs = "Documentation"
        \\# deprecate = "Deprecated"
        \\# remove = "Removed"
        \\# security = "Security"
        \\
    ;

    const file = try cwd.createFile("chronicle.toml", .{});
    defer file.close();
    try file.writeAll(default_config);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("Created chronicle.toml\n");
}

fn runLint(allocator: std.mem.Allocator, args: Args) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Initialize git interface
    var git_repo = git.Git.init(allocator);
    defer git_repo.deinit();

    // Determine commit range
    const to_ref = args.to_tag orelse "HEAD";
    const from_ref_owned: ?[]const u8 = if (args.from_tag != null)
        null // No need to free user-provided arg
    else blk: {
        const latest = git_repo.getLatestTag() catch null;
        break :blk latest;
    };
    defer if (from_ref_owned) |f| allocator.free(f);

    const from_ref: ?[]const u8 = args.from_tag orelse from_ref_owned;

    // Get commits
    const raw_commits = try git_repo.getCommits(from_ref, to_ref);
    defer {
        for (raw_commits) |*rc| {
            var commit = rc.*;
            commit.deinit(allocator);
        }
        allocator.free(raw_commits);
    }

    if (raw_commits.len == 0) {
        try stdout.writeAll("No commits to lint.\n");
        return;
    }

    var valid_count: usize = 0;
    var invalid_count: usize = 0;
    var buf: [512]u8 = undefined;

    for (raw_commits) |raw| {
        const parsed = parser.parseConventionalCommit(raw.subject);
        if (parsed == null) {
            invalid_count += 1;
            if (!args.quiet) {
                const msg = std.fmt.bufPrint(&buf, "INVALID: {s} ({s})\n", .{ raw.short_hash, raw.subject }) catch "INVALID\n";
                try stderr.writeAll(msg);
            }
        } else {
            valid_count += 1;
            if (!args.quiet) {
                const msg = std.fmt.bufPrint(&buf, "OK:      {s} ({s})\n", .{ raw.short_hash, raw.subject }) catch "OK\n";
                try stdout.writeAll(msg);
            }
        }
    }

    // Summary
    try stdout.writeAll("\n");
    const summary = std.fmt.bufPrint(&buf, "Linted {d} commits: {d} valid, {d} invalid\n", .{
        raw_commits.len,
        valid_count,
        invalid_count,
    }) catch "Lint complete\n";
    try stdout.writeAll(summary);

    if (invalid_count > 0) {
        try stderr.writeAll("\nSome commits do not follow conventional commit format.\n");
        try stderr.writeAll("Expected format: <type>[(scope)][!]: <description>\n");
        try stderr.writeAll("Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert\n");
    }
}

fn runPreview(allocator: std.mem.Allocator, args: Args) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Load configuration
    var cfg = blk: {
        if (args.config_path) |path| {
            if (try config.loadFromFile(allocator, path)) |c| {
                break :blk c;
            }
        }
        break :blk try config.loadDefault(allocator);
    };
    defer cfg.deinit();

    // Initialize git interface
    var git_repo = git.Git.init(allocator);
    defer git_repo.deinit();

    // Get the latest tag as the starting point
    const latest_tag = try git_repo.getLatestTag();
    defer if (latest_tag) |t| allocator.free(t);

    if (!args.quiet) {
        var buf: [128]u8 = undefined;
        if (latest_tag) |tag| {
            const msg = std.fmt.bufPrint(&buf, "Showing unreleased changes since {s}\n\n", .{tag}) catch "";
            try stderr.writeAll(msg);
        } else {
            try stderr.writeAll("Showing all commits (no tags found)\n\n");
        }
    }

    // Get commits from latest tag to HEAD
    const raw_commits = try git_repo.getCommits(latest_tag, "HEAD");
    defer {
        for (raw_commits) |*rc| {
            var commit = rc.*;
            commit.deinit(allocator);
        }
        allocator.free(raw_commits);
    }

    if (raw_commits.len == 0) {
        try stdout.writeAll("No unreleased changes.\n");
        return;
    }

    // Parse commits
    const parsed_commits = try parser.parseRawCommits(allocator, raw_commits);
    defer {
        for (parsed_commits) |*pc| {
            var commit = pc.*;
            commit.deinit(allocator);
        }
        allocator.free(parsed_commits);
    }

    // Filter commits
    const filter_config = cfg.toFilterConfig();
    const commit_filter = filter.Filter.init(filter_config);
    var stats = filter.FilterStats{};
    defer stats.deinit(allocator);

    const filtered_commits = try commit_filter.filterCommitsWithStats(allocator, parsed_commits, &stats);
    defer allocator.free(filtered_commits);

    // Group by type
    var feat_commits = std.ArrayListUnmanaged(changelog.Commit){};
    defer feat_commits.deinit(allocator);
    var fix_commits = std.ArrayListUnmanaged(changelog.Commit){};
    defer fix_commits.deinit(allocator);
    var other_commits = std.ArrayListUnmanaged(changelog.Commit){};
    defer other_commits.deinit(allocator);

    for (filtered_commits) |commit| {
        switch (commit.commit_type) {
            .feat => try feat_commits.append(allocator, commit),
            .fix => try fix_commits.append(allocator, commit),
            else => try other_commits.append(allocator, commit),
        }
    }

    var buf: [512]u8 = undefined;

    // Print features
    if (feat_commits.items.len > 0) {
        try stdout.writeAll("### Added\n");
        for (feat_commits.items) |commit| {
            const line = std.fmt.bufPrint(&buf, "- {s}{s}\n", .{
                if (commit.scope) |s| blk: {
                    var scope_buf: [64]u8 = undefined;
                    break :blk std.fmt.bufPrint(&scope_buf, "({s}) ", .{s}) catch "";
                } else "",
                commit.description,
            }) catch "";
            try stdout.writeAll(line);
        }
        try stdout.writeAll("\n");
    }

    // Print fixes
    if (fix_commits.items.len > 0) {
        try stdout.writeAll("### Fixed\n");
        for (fix_commits.items) |commit| {
            const line = std.fmt.bufPrint(&buf, "- {s}{s}\n", .{
                if (commit.scope) |s| blk: {
                    var scope_buf: [64]u8 = undefined;
                    break :blk std.fmt.bufPrint(&scope_buf, "({s}) ", .{s}) catch "";
                } else "",
                commit.description,
            }) catch "";
            try stdout.writeAll(line);
        }
        try stdout.writeAll("\n");
    }

    // Print other
    if (other_commits.items.len > 0) {
        try stdout.writeAll("### Other\n");
        for (other_commits.items) |commit| {
            const line = std.fmt.bufPrint(&buf, "- {s}{s}\n", .{
                if (commit.scope) |s| blk: {
                    var scope_buf: [64]u8 = undefined;
                    break :blk std.fmt.bufPrint(&scope_buf, "({s}) ", .{s}) catch "";
                } else "",
                commit.description,
            }) catch "";
            try stdout.writeAll(line);
        }
        try stdout.writeAll("\n");
    }

    // Summary
    const summary = std.fmt.bufPrint(&buf, "Total: {d} commits ({d} included, {d} excluded)\n", .{
        parsed_commits.len,
        stats.included,
        stats.totalExcluded(),
    }) catch "";
    try stdout.writeAll(summary);
}

fn printHelp() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(
        \\Chronicle - Changelog Generator
        \\
        \\A tool for generating changelogs from conventional commit messages.
        \\
        \\USAGE:
        \\    chronicle <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    generate    Generate changelog from commits (default)
        \\    init        Create default chronicle.toml configuration file
        \\    lint        Validate commit messages against conventional format
        \\    preview     Show unreleased changes since last tag
        \\
        \\GLOBAL OPTIONS:
        \\    -h, --help          Print help information
        \\    -V, --version       Print version information
        \\    -q, --quiet         Suppress informational messages
        \\    -c, --config <PATH> Use custom config file (default: chronicle.toml)
        \\
        \\GENERATE OPTIONS:
        \\    --version-tag <TAG>  Version for the changelog entry
        \\    --from <TAG>         Start of commit range (exclusive)
        \\    --to <TAG>           End of commit range (default: latest tag)
        \\    -o, --output <PATH>  Output file (default: CHANGELOG.md)
        \\    -f, --format <FMT>   Output format: markdown, json, github
        \\    --dry-run            Print to stdout instead of writing to file
        \\
        \\LINT OPTIONS:
        \\    --from <TAG>         Start of commit range (exclusive)
        \\    --to <TAG>           End of commit range (default: HEAD)
        \\
        \\EXAMPLES:
        \\    chronicle init                      Create chronicle.toml
        \\    chronicle generate                  Generate changelog for latest tag
        \\    chronicle generate --dry-run       Preview changelog without writing
        \\    chronicle lint                      Check commit messages since last tag
        \\    chronicle preview                   Show unreleased changes
        \\    chronicle generate -f github       Generate GitHub-style release notes
        \\
        \\CONVENTIONAL COMMIT FORMAT:
        \\    <type>[(scope)][!]: <description>
        \\
        \\    Types: feat, fix, docs, style, refactor, perf, test, build, ci, chore
        \\    The ! indicates a breaking change.
        \\
        \\    Examples:
        \\      feat: add user authentication
        \\      fix(parser): handle empty input
        \\      feat!: change API response format
        \\
    ) catch {};
}

fn printVersion() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll("chronicle 0.1.0\n") catch {};
}

test "parseArgs returns default help command" {
    // Basic smoke test
    const args = Args{};
    try std.testing.expectEqual(Command.help, args.command);
}
