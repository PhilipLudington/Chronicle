const std = @import("std");
const config = @import("config");

const log = std.log.scoped(.chronicle);

pub const std_options: std.Options = .{
    .log_level = if (config.enable_logging) .debug else .info,
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
        .generate => try runGenerate(args),
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

fn runGenerate(args: Args) !void {
    _ = args;
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("chronicle generate: not yet implemented\n");
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
