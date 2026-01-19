# Chronicle

A changelog generator for projects using [Conventional Commits](https://www.conventionalcommits.org/). Written in Zig with zero external dependencies.

## Features

- Parses conventional commit messages (`feat:`, `fix:`, `docs:`, etc.)
- Outputs [Keep a Changelog](https://keepachangelog.com/) format
- Multiple output formats: Markdown, JSON, GitHub Releases
- Configurable via `chronicle.toml`
- Filters noise commits (chore, test, ci, build, merge commits)
- Supports breaking change detection (`!` suffix)
- Commit grouping by scope
- Highlights generation for notable changes
- Monorepo support with package filtering

## Installation

### Build from source

Requires [Zig 0.13+](https://ziglang.org/download/):

```bash
git clone https://github.com/your-username/chronicle.git
cd chronicle
zig build -Doptimize=ReleaseFast
# Binary is at ./zig-out/bin/chronicle
```

### Add to PATH

```bash
sudo cp ./zig-out/bin/chronicle /usr/local/bin/
```

## Quick Start

```bash
# Initialize configuration file
chronicle init

# Preview unreleased changes
chronicle preview

# Generate changelog for the latest tag
chronicle generate

# Preview without writing to file
chronicle generate --dry-run

# Generate for a specific version
chronicle generate --version-tag v1.0.0

# Regenerate full changelog from all tags
chronicle generate --full
```

## Usage

```
chronicle <COMMAND> [OPTIONS]

COMMANDS:
    generate    Generate changelog from commits (default)
    init        Create default chronicle.toml configuration file
    lint        Validate commit messages against conventional format
    preview     Show unreleased changes since last tag

GLOBAL OPTIONS:
    -h, --help          Print help information
    -V, --version       Print version information
    -q, --quiet         Suppress informational messages
    -c, --config <PATH> Use custom config file (default: chronicle.toml)

GENERATE OPTIONS:
    --version-tag <TAG>  Version for the changelog entry
    --from <TAG>         Start of commit range (exclusive)
    --to <TAG>           End of commit range (default: latest tag)
    -o, --output <PATH>  Output file (default: CHANGELOG.md)
    -f, --format <FMT>   Output format: markdown, json, github
    --dry-run            Print to stdout instead of writing to file
    --full               Regenerate full changelog from all tags

ADVANCED OPTIONS:
    --group              Group commits by scope within sections
    --highlights         Generate highlights section for notable changes
    --package <NAME>     Filter to specific package (monorepo mode)
    --all-packages       Generate changelogs for all packages
    --fetch-prs          Fetch PR descriptions from GitHub (requires gh CLI)
```

## Output Formats

### Markdown (default)

Standard [Keep a Changelog](https://keepachangelog.com/) format:

```bash
chronicle generate --dry-run
```

```markdown
## [v1.0.0] - 2024-01-15

### Added

- Add user authentication ([`abc1234`](https://github.com/user/repo/commit/abc1234))
- Add password reset flow ([`def5678`](https://github.com/user/repo/commit/def5678))

### Fixed

- Fix login timeout issue ([`ghi9012`](https://github.com/user/repo/commit/ghi9012))
```

### JSON

Structured output for programmatic consumption:

```bash
chronicle generate --dry-run --format json
```

```json
{
  "version": "v1.0.0",
  "date": "2024-01-15",
  "sections": [
    {
      "name": "Added",
      "commits": [
        {
          "hash": "abc1234...",
          "type": "feat",
          "scope": null,
          "description": "Add user authentication",
          "breaking": false
        }
      ]
    }
  ],
  "stats": {
    "included": 5,
    "excluded": 3
  }
}
```

### GitHub Releases

Format suitable for GitHub release notes:

```bash
chronicle generate --dry-run --format github
```

```markdown
## Features

* Add user authentication ([abc1234](https://github.com/user/repo/commit/abc1234)) by @username

**Full Changelog**: https://github.com/user/repo/compare/v0.9.0...v1.0.0
```

## Configuration

Create a `chronicle.toml` file in your project root:

```bash
chronicle init
```

### Example Configuration

```toml
[repository]
url = "https://github.com/your-username/your-repo"

[filter]
# Include commit types that are excluded by default
include_refactor = false
include_docs = false
include_chore = false
include_test = false
include_ci = false
include_build = false
include_merge_commits = false

# Exclude specific scopes
exclude_scopes = ["internal", "deps"]

# Exclude by pattern (case-insensitive substring match)
exclude_patterns = ["wip", "fixup", "squash"]

[format]
show_hashes = true
hash_length = 7
show_authors = false
show_breaking = true
show_scope = true
link_commits = true
link_issues = true

[sections]
# Customize section names
feat = "Added"
fix = "Fixed"
perf = "Performance"
```

## Conventional Commits

Chronicle expects commits to follow the [Conventional Commits](https://www.conventionalcommits.org/) specification:

```
<type>[(scope)][!]: <description>

[body]

[footer]
```

### Supported Types

| Type | Section | Included by default |
|------|---------|---------------------|
| `feat` | Added | Yes |
| `fix` | Fixed | Yes |
| `perf` | Performance | Yes |
| `refactor` | Changed | No |
| `docs` | Documentation | No |
| `deprecate` | Deprecated | Yes |
| `remove` | Removed | Yes |
| `security` | Security | Yes |
| `chore` | - | No |
| `test` | - | No |
| `ci` | - | No |
| `build` | - | No |

### Examples

```bash
feat: add user authentication
feat(auth): add OAuth2 support
fix(parser): handle empty input gracefully
feat!: change API response format  # Breaking change
```

### Lint Commit Messages

Validate that commits follow the conventional format:

```bash
chronicle lint
# Or specify a range
chronicle lint --from v1.0.0 --to HEAD
```

## Advanced Features

### Commit Grouping

Group commits by scope within sections:

```bash
chronicle generate --group
```

### Highlights

Generate a highlights section for notable changes:

```bash
chronicle generate --highlights
```

### Monorepo Support

Filter commits to a specific package:

```bash
chronicle generate --package core
# Or generate for all packages
chronicle generate --all-packages
```

## Claude Code Integration

Chronicle includes a Claude Code skill for AI-assisted changelog generation. The skill can:

- Enhance vague commit descriptions using git diffs
- Match the style of existing changelogs
- Suggest groupings for large releases
- Fall back to raw git when CLI is unavailable

See `~/.claude/skills/changelog.md` for the skill definition.

## Development

```bash
# Build
zig build

# Run tests
zig build test

# Format code
zig fmt src/

# Build with debug logging
zig build -Dlog=true

# Release build
zig build -Doptimize=ReleaseFast
```

## License

MIT
