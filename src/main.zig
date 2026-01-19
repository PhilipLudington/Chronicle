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
        .lint => try runLint(),
        .preview => try runPreview(),
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
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("chronicle init: not yet implemented\n");
}

fn runLint() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("chronicle lint: not yet implemented\n");
}

fn runPreview() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("chronicle preview: not yet implemented\n");
}

fn printHelp() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(
        \\Chronicle - Changelog Generator
        \\
        \\USAGE:
        \\    chronicle <COMMAND> [OPTIONS]
        \\
        \\COMMANDS:
        \\    generate    Generate changelog from commits
        \\    init        Create default chronicle.toml
        \\    lint        Validate commit message format
        \\    preview     Show unreleased changes
        \\
        \\OPTIONS:
        \\    -h, --help          Print help information
        \\    -V, --version       Print version information
        \\
        \\GENERATE OPTIONS:
        \\    --version-tag <TAG>  Version for the changelog entry
        \\    --from <TAG>         Start of commit range
        \\    --to <TAG>           End of commit range (default: HEAD)
        \\    -o, --output <PATH>  Output file (default: CHANGELOG.md)
        \\    -c, --config <PATH>  Config file (default: chronicle.toml)
        \\    -f, --format <FMT>   Output format: markdown, json, github
        \\    --dry-run            Print to stdout instead of file
        \\    -q, --quiet          Suppress info messages
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
