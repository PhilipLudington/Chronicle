# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Chronicle is a changelog generator with a Zig CLI core and Claude Code skill wrapper. The CLI parses conventional commits, filters noise, and outputs structured changelog entries. The skill wraps the CLI with AI intelligence for polished release notes.

**Status**: Planning phase - core implementation not yet started.

## Build Commands

```bash
zig build              # Build library and executable
zig build run          # Build and run executable
zig build test         # Run all tests
zig fmt src/           # Format code
zig fmt --check src/   # Check formatting (CI)
```

Build options:
- `-Doptimize=ReleaseFast` - Production build
- `-Dlog=true/false` - Enable/disable debug logging

## Architecture

**Planned structure** (from DESIGN.md):
```
src/
├── main.zig           # Entry point, CLI argument parsing
├── git.zig            # Git operations (shells out to git binary)
├── parser.zig         # Conventional commit parser
├── filter.zig         # Commit filtering logic
├── changelog.zig      # Core data structures (Commit, CommitType, ChangelogEntry)
├── config.zig         # TOML config loading
└── format/
    ├── markdown.zig   # Keep-a-Changelog markdown output
    ├── json.zig       # JSON output for skill consumption
    └── github.zig     # GitHub releases format
```

**Key design decisions**:
- Shell out to `git` binary rather than linking libgit2
- Arena allocator for per-request memory management
- Minimal TOML parser (only parse what we need)
- JSON output designed for Claude Code skill consumption

## CarbideZig Standards

This project uses CarbideZig for Zig development standards. Key rules in `.claude/rules/`:

- **Memory**: Accept allocator parameter, use `defer`/`errdefer` immediately after acquisition
- **Errors**: Define specific error sets, use `try` for propagation
- **API**: Accept slices, use optional types, config structs with defaults
- **Naming**: PascalCase types, camelCase functions/variables, snake_case constants/files

Zig 0.15+ specifics:
- Use `std.ArrayListUnmanaged{}` (not `.init(allocator)`)
- Pass allocator to each ArrayList method
- Use `root_module` pattern in build.zig
- File.Writer has no `.print()` - use `std.fmt.bufPrint()` + `writeAll()`

## Slash Commands

| Command | Description |
|---------|-------------|
| `/carbide-review` | Code review against CarbideZig standards |
| `/carbide-check` | Run validation (build, test, format) |
| `/carbide-safety` | Security and memory safety review |
