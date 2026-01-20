# Chronicle - Design Document

A changelog generator with a Zig CLI core and Claude Code skill wrapper.

---

## Overview

**Architecture:** Zig CLI + Claude Code Skill
**CLI Language:** Zig
**Skill Location:** `~/.claude/skills/changelog/SKILL.md`

### The Problem

Maintaining changelogs is tedious but important:
- Manual updates are forgotten or inconsistent
- Git logs are too granular ("fix typo" doesn't belong in release notes)
- Conventional commits help but still require aggregation and prose
- Release notes are often an afterthought, written hastily at ship time

### The Solution

A two-layer approach:

1. **Zig CLI (`chronicle`)** — Fast, deterministic changelog generation. Parses conventional commits, filters noise, outputs structured changelog entries. Works standalone in CI, scripts, or any workflow.

2. **Claude Code Skill (`/changelog`)** — Wraps the CLI with AI intelligence. Reads diffs to understand context, improves prose quality, handles edge cases, matches existing style.

Use the CLI when you need deterministic output. Use the skill when you want polished release notes.

---

## Part 1: Zig CLI

### Installation

```bash
# Build from source
zig build -Doptimize=ReleaseFast
cp zig-out/bin/chronicle ~/.local/bin/

# Or download release binary
curl -L https://github.com/user/chronicle/releases/latest/download/chronicle-macos-arm64 -o chronicle
chmod +x chronicle && mv chronicle ~/.local/bin/
```

### Basic Usage

```bash
# Generate changelog for latest tag
chronicle generate

# Generate for specific version
chronicle generate --version 1.2.0

# Preview without writing (stdout)
chronicle generate --dry-run

# Output as JSON (for tooling/skill consumption)
chronicle generate --format json

# Regenerate entire changelog from all tags
chronicle generate --full

# Validate commit messages
chronicle lint
```

### CLI Commands

```
chronicle <command> [options]

Commands:
  generate     Generate changelog entries
  lint         Validate commit message format
  init         Create chronicle.toml with defaults
  preview      Show what would be included in next release

Options:
  -o, --output <file>       Output file (default: CHANGELOG.md)
  -f, --format <format>     Output format: markdown, json, github
  -v, --version <version>   Version string (default: latest tag)
      --from <tag>          Start tag (default: previous tag)
      --to <ref>            End ref (default: HEAD)
      --dry-run             Print to stdout, don't write file
      --full                Regenerate entire changelog
  -c, --config <file>       Config file (default: chronicle.toml)
  -q, --quiet               Suppress info messages
  -h, --help                Show help
```

### Conventional Commit Parsing

The CLI recognizes standard prefixes:

| Prefix | Section | Example |
|--------|---------|---------|
| `feat:` | Added | `feat: add dark mode` |
| `fix:` | Fixed | `fix: resolve crash on startup` |
| `perf:` | Performance | `perf: optimize query speed` |
| `refactor:` | Changed | `refactor: simplify auth flow` |
| `docs:` | Documentation | `docs: update API reference` |
| `deprecate:` | Deprecated | `deprecate: old config format` |
| `remove:` | Removed | `remove: legacy endpoint` |
| `security:` | Security | `security: fix XSS vulnerability` |
| `feat!:` | Breaking Changes | `feat!: new config format` |

Scopes are supported: `feat(ui): add toggle` → categorized under "Added" with scope preserved.

### Filtering

**Excluded by default:**
- `chore:` — dependency updates, formatting
- `test:` — test additions/changes
- `ci:` — CI/CD configuration
- `build:` — build system changes
- Merge commits
- Messages containing: `wip`, `fixup`, `squash`, `typo`, `[skip changelog]`

### Output Formats

**Markdown (default):**
```markdown
## [1.2.0] - 2026-01-19

### Added
- Add dark mode toggle
- Add keyboard shortcuts for common actions

### Fixed
- Resolve crash when opening large files
- Fix memory leak in image processing

### Breaking Changes
- Configuration format changed from JSON to TOML
```

**JSON (for tooling):**
```json
{
  "version": "1.2.0",
  "date": "2026-01-19",
  "sections": {
    "added": [
      {
        "message": "Add dark mode toggle",
        "hash": "a1b2c3d",
        "scope": "ui",
        "author": "username",
        "issues": ["#123"]
      }
    ],
    "fixed": [...],
    "breaking": [...]
  },
  "stats": {
    "included": 15,
    "excluded": 8,
    "excluded_breakdown": {
      "chore": 4,
      "test": 3,
      "ci": 1
    }
  }
}
```

**GitHub Releases:**
```markdown
## What's Changed

### New Features
* Add dark mode toggle in #123
* Add keyboard shortcuts in #125

### Bug Fixes
* Fix crash on large files in #124

**Full Changelog**: https://github.com/user/repo/compare/v1.1.0...v1.2.0
```

### Configuration

Optional `chronicle.toml` in project root:

```toml
[chronicle]
output = "CHANGELOG.md"
repository = "https://github.com/username/repo"
date_format = "%Y-%m-%d"

[sections]
# Map commit types to section names
feat = "Added"
fix = "Fixed"
perf = "Performance"
refactor = "Changed"
docs = "Documentation"
deprecate = "Deprecated"
remove = "Removed"
security = "Security"

[filter]
# Include refactor in changelog (default: true)
include_refactor = true

# Include docs in changelog (default: false)
include_docs = false

# Exclude specific scopes
exclude_scopes = ["internal", "dev"]

# Additional exclude patterns
exclude_patterns = ["experiment", "temp"]

[format]
# Include commit hashes
show_hashes = true
hash_length = 7

# Include author names
show_authors = false

# Link commits and issues
link_commits = true
link_issues = true
```

### Implementation

#### Project Structure

```
chronicle/
├── src/
│   ├── main.zig           # Entry point, CLI parsing
│   ├── git.zig            # Git operations (shell out to git)
│   ├── parser.zig         # Conventional commit parser
│   ├── filter.zig         # Commit filtering logic
│   ├── changelog.zig      # Changelog data structures
│   ├── format/
│   │   ├── markdown.zig   # Markdown output
│   │   ├── json.zig       # JSON output
│   │   └── github.zig     # GitHub releases format
│   └── config.zig         # TOML config loading
├── build.zig
├── build.zig.zon
├── README.md
└── chronicle.toml         # Example config
```

#### Core Types

```zig
const Commit = struct {
    hash: []const u8,
    short_hash: []const u8,
    type: CommitType,
    scope: ?[]const u8,
    description: []const u8,
    body: ?[]const u8,
    author: []const u8,
    date: []const u8,
    breaking: bool,
    issues: [][]const u8,
};

const CommitType = enum {
    feat,
    fix,
    perf,
    refactor,
    docs,
    deprecate,
    remove,
    security,
    chore,
    test,
    ci,
    build,
    unknown,
};

const ChangelogEntry = struct {
    version: []const u8,
    date: []const u8,
    sections: std.StringHashMap([]Commit),
    stats: Stats,
};

const Stats = struct {
    included: usize,
    excluded: usize,
    excluded_breakdown: std.StringHashMap(usize),
};
```

#### Git Integration

Shell out to git for simplicity and correctness:

```zig
fn getCommits(allocator: Allocator, from: []const u8, to: []const u8) ![]Commit {
    const result = try runCommand(allocator, &.{
        "git", "log",
        std.fmt.allocPrint(allocator, "{s}..{s}", .{ from, to }),
        "--pretty=format:%H|%h|%s|%b|%an|%ad",
        "--date=short",
    });

    // Parse output into Commit structs
    return parseCommits(allocator, result.stdout);
}

fn getTags(allocator: Allocator) ![][]const u8 {
    const result = try runCommand(allocator, &.{
        "git", "tag", "--sort=-version:refname",
    });
    return splitLines(allocator, result.stdout);
}
```

#### Commit Parsing

```zig
fn parseConventionalCommit(message: []const u8) ?ParsedCommit {
    // Pattern: type(scope)!: description
    // Examples:
    //   feat: add feature
    //   fix(ui): resolve bug
    //   feat!: breaking change
    //   feat(api)!: breaking with scope

    const type_end = std.mem.indexOfAny(u8, message, "(!:") orelse return null;
    const commit_type = parseCommitType(message[0..type_end]) orelse return null;

    var pos = type_end;
    var scope: ?[]const u8 = null;
    var breaking = false;

    // Parse optional scope
    if (message[pos] == '(') {
        const scope_end = std.mem.indexOf(u8, message[pos..], ')') orelse return null;
        scope = message[pos + 1 .. pos + scope_end];
        pos += scope_end + 1;
    }

    // Check for breaking indicator
    if (pos < message.len and message[pos] == '!') {
        breaking = true;
        pos += 1;
    }

    // Expect colon and space
    if (pos + 2 > message.len or message[pos] != ':' or message[pos + 1] != ' ') {
        return null;
    }

    const description = std.mem.trim(u8, message[pos + 2 ..], " \n");

    return .{
        .type = commit_type,
        .scope = scope,
        .description = description,
        .breaking = breaking,
    };
}
```

---

## Part 2: Claude Code Skill

The skill wraps the CLI and adds intelligence.

### Invocation

```bash
/changelog                    # Preview unreleased changes
/changelog 1.2.0              # Generate for specific version
/changelog --full             # Regenerate entire history
/changelog --enhance          # CLI output + AI enhancement (default)
/changelog --raw              # CLI output only, no AI enhancement
```

### What the Skill Adds

| Capability | CLI | Skill |
|------------|-----|-------|
| Parse conventional commits | ✓ | ✓ (via CLI) |
| Filter noise | ✓ | ✓ (via CLI) |
| Categorize changes | ✓ | ✓ (via CLI) |
| Understand context | ✗ | ✓ (reads diffs) |
| Improve prose | ✗ | ✓ |
| Match existing style | ✗ | ✓ |
| Handle ambiguity | ✗ | ✓ (asks) |
| Group related changes | ✗ | ✓ |

### Skill Workflow

```
1. Run `chronicle generate --format json --dry-run`
2. Parse JSON output to get structured changelog data
3. Read existing CHANGELOG.md to understand style
4. For vague commit messages, read diffs: `git show <hash>`
5. Enhance descriptions with context
6. Group related commits if appropriate
7. Generate prose summaries for highlights
8. Present draft for approval
9. Write to CHANGELOG.md via Edit tool
```

### Example Session

```
User: /changelog 1.2.0

Claude: I'll generate the changelog for v1.2.0.

[Runs: chronicle generate --version 1.2.0 --format json --dry-run]

The CLI found 23 commits (15 included, 8 excluded).
Let me enhance the descriptions by checking the actual changes...

[Reads diffs for commits with vague messages]

---

## [1.2.0] - 2026-01-19

### Highlights

This release adds dark mode and improves startup performance by 40%.

### Added

- **Dark mode** — New appearance toggle in Settings > Appearance.
  Follows system preference by default. ([#123])
- **Keyboard shortcuts** — Cmd+K for search, Cmd+Shift+P for command
  palette. Full list in Help > Shortcuts. ([#125])
- **PDF export** — Export documents from File > Export with custom
  headers and page sizes.

### Fixed

- Fixed crash when opening files larger than 100MB ([#118])
- Fixed memory leak when switching projects rapidly — was leaking
  ~50MB per switch ([#121])
- Fixed tooltip positioning on ultrawide monitors ([#119])
- Fixed undo history loss after auto-save

### Performance

- Startup time reduced 40% via lazy plugin initialization
- Search indexing moved to background thread

### Breaking Changes

- **Config format changed** — Now uses TOML instead of JSON.
  Existing files migrate automatically on launch. For manual
  management: rename to `config.toml` and update syntax.

---

15 commits included, 8 excluded (chore: 4, test: 3, ci: 1)

Write this to CHANGELOG.md?
```

```
User: Remove the highlights section and make the breaking change more prominent

Claude: I'll adjust that.

[Updates draft, writes via Edit tool]

Done. CHANGELOG.md updated with v1.2.0 release notes.
```

### Skill File

`~/.claude/skills/changelog/SKILL.md`:

```markdown
---
name: changelog
description: Generate changelog entries from git commits. Use when asked to generate changelog, update changelog, write changelog, create release notes, or document changes for a release.
allowed-tools: Read, Glob, Grep, Bash, Edit, Write
user-invocable: true
---

# Changelog Generation Skill

Generate changelog entries from git commits using conventional commit format.

## Arguments

- `version` — Target version (e.g., "1.2.0"). Omit for unreleased changes.
- `--full` — Regenerate entire changelog from all tags
- `--raw` — Output CLI results without AI enhancement
- `--enhance` — Enhance with AI (default)

## Workflow

### 1. Check for Chronicle CLI

Run `which chronicle`. If not found, inform user:
"Chronicle CLI not found. Install from: [repo link] or run with --raw to use git directly."

### 2. Run Chronicle CLI

```bash
chronicle generate --format json --dry-run [--version X.Y.Z] [--full]
```

Parse the JSON output to get:
- Version and date
- Categorized commits with hashes, scopes, descriptions
- Stats (included/excluded counts)

### 3. If --raw flag, output CLI results directly

Format the JSON as markdown and present. Skip enhancement steps.

### 4. Read existing CHANGELOG.md

Note the style:
- Header format (## [1.0.0] vs ## 1.0.0)
- Date format
- Whether hashes/links are included
- Section ordering
- Entry style (bullets, prose)

### 5. Enhance descriptions

For commits with vague messages (e.g., "fix bug", "update handling"):
```bash
git show <hash> --stat
git show <hash> -p  # if stat isn't enough
```

Rewrite to be user-facing:
- BAD: "fix: resolve issue"
- GOOD: "Fixed crash when opening files with unicode paths"

### 6. Group related commits (optional)

If 3+ commits touch the same feature, consider grouping:
- 5 commits about search → "Overhauled search with fuzzy matching and filters"

Ask user if unsure whether to group.

### 7. Add highlights section (for major releases)

If release includes significant features or breaking changes, draft a
1-2 sentence highlights summary. Offer to remove if unwanted.

### 8. Present draft

Show:
- The formatted changelog section
- Stats: "X commits included, Y excluded (breakdown)"
- Ask: "Write this to CHANGELOG.md?"

### 9. Handle feedback

User may request:
- Remove sections (highlights, specific entries)
- Reword entries
- Change formatting
- Add/remove details

Adjust and re-present, or write if approved.

### 10. Write changes

Use Edit tool to prepend new version section after the header/unreleased
section in CHANGELOG.md.

## Edge Cases

### No Chronicle CLI installed

Fall back to direct git commands:
```bash
git log v1.1.0..HEAD --pretty=format:"%H|%s|%b|%an|%ad" --date=short
```

Parse conventional commits manually and proceed with enhancement.

### No conventional commits

Inform user:
"This project doesn't use conventional commits. I'll categorize based on
reading the diffs. This may be less accurate."

Offer options:
1. Proceed with best-effort categorization
2. Show commits for manual categorization
3. Generate a flat list without categories

### Ambiguous commits

Ask user:
"I'm unsure about this commit: 'Update user handling' (abc1234)

The diff shows auth changes. Should this be:
1. Added - 'Session timeout handling'
2. Fixed - 'Session persistence bug'
3. Changed - 'Authentication flow'
4. Exclude"

### Very large releases (50+ commits)

"This release has 67 commits. I recommend grouping related changes
rather than listing each. Proceed with grouping?"
```

---

## CI Integration

The CLI works standalone for CI/CD:

```yaml
# GitHub Actions example
- name: Generate Changelog
  run: |
    chronicle generate --version ${{ github.ref_name }}
    git add CHANGELOG.md
    git commit -m "chore: update changelog for ${{ github.ref_name }}"
```

For AI-enhanced changelogs in CI, run Claude Code:

```yaml
- name: Generate Enhanced Changelog
  run: |
    claude -p "Run /changelog ${{ github.ref_name }} and write the result"
```

---

## Implementation Plan

### Phase 1: CLI Core
- [ ] Project setup (build.zig, structure)
- [ ] Git operations (tags, log, show)
- [ ] Conventional commit parser
- [ ] Basic filtering (chore, test, ci, wip)
- [ ] Markdown output
- [ ] `chronicle generate` command

### Phase 2: CLI Polish
- [ ] JSON output format
- [ ] GitHub releases format
- [ ] Configuration file (chronicle.toml)
- [ ] `chronicle lint` command
- [ ] `chronicle init` command
- [ ] Commit/issue linking

### Phase 3: Skill
- [ ] Basic skill that calls CLI
- [ ] JSON parsing and enhancement
- [ ] Diff reading for context
- [ ] Style matching from existing changelog
- [ ] Interactive feedback handling

### Phase 4: Enhancements
- [ ] Grouping related commits
- [ ] Highlights generation
- [ ] Monorepo support (CLI)
- [ ] `--full` regeneration
- [ ] GitHub PR description fetching

---

## Dependencies

**CLI (Zig):**
- Zig 0.13+ standard library only
- Shells out to `git` (no libgit2)

**Skill:**
- Chronicle CLI in PATH
- Falls back to raw git if CLI unavailable

---

## Summary

| Component | Purpose | When to Use |
|-----------|---------|-------------|
| `chronicle` CLI | Fast, deterministic generation | CI/CD, scripts, quick generation |
| `/changelog` skill | AI-enhanced generation | Polished release notes, complex releases |

The CLI does the mechanical work. The skill adds judgment.

---

*Design Document v3.0 — January 2026*
