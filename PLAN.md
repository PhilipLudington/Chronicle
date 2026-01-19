# Chronicle Implementation Plan

A changelog generator with a Zig CLI core and Claude Code skill wrapper.

## Phase 1: Project Setup

- [x] Create build.zig with standard Zig 0.13+ configuration
- [x] Create build.zig.zon with project metadata
- [x] Set up source directory structure (src/, src/format/)
- [x] Create main.zig entry point with CLI argument parsing skeleton
- [x] Add .gitignore for Zig build artifacts (zig-out/, zig-cache/)

## Phase 2: Core Types and Data Structures

- [ ] Create changelog.zig with core types (Commit, CommitType enum, ChangelogEntry, Stats)
- [ ] Implement memory management patterns (allocators, arena allocation)
- [ ] Add string utilities for commit parsing

## Phase 3: Git Integration

- [ ] Create git.zig module
- [ ] Implement runCommand helper to shell out to git
- [ ] Implement getTags() to list version tags sorted by version
- [ ] Implement getCommits(from, to) to get commit range
- [ ] Implement getLatestTag() for default version detection
- [ ] Implement getPreviousTag(tag) for determining commit range
- [ ] Add git show wrapper for reading individual commits

## Phase 4: Conventional Commit Parser

- [ ] Create parser.zig module
- [ ] Implement parseConventionalCommit() to extract type, scope, description, breaking flag
- [ ] Implement parseCommitType() to map prefixes to CommitType enum
- [ ] Handle scope parsing (parentheses)
- [ ] Handle breaking change indicator (!)
- [ ] Extract issue references from commit messages (#123 patterns)
- [ ] Parse commit body for BREAKING CHANGE footer

## Phase 5: Filtering Logic

- [ ] Create filter.zig module
- [ ] Implement default exclusion rules (chore, test, ci, build, merge commits)
- [ ] Implement pattern-based exclusion (wip, fixup, squash, typo, [skip changelog])
- [ ] Implement scope-based exclusion
- [ ] Implement shouldInclude() predicate combining all rules
- [ ] Track exclusion stats by category

## Phase 6: Markdown Output

- [ ] Create format/markdown.zig module
- [ ] Implement section grouping (Added, Fixed, Changed, etc.)
- [ ] Generate standard Keep-a-Changelog format
- [ ] Support commit hash linking
- [ ] Support issue linking (#123 → GitHub URL)
- [ ] Handle empty sections gracefully

## Phase 7: Generate Command

- [ ] Wire up `chronicle generate` in main.zig
- [ ] Implement --dry-run (stdout output)
- [ ] Implement --version flag
- [ ] Implement --from and --to flags
- [ ] Implement --output flag
- [ ] Implement file writing (prepend to existing CHANGELOG.md)
- [ ] Add --quiet flag for suppressing info messages

## Phase 8: JSON Output Format

- [ ] Create format/json.zig module
- [ ] Output structured JSON matching design spec
- [ ] Include version, date, sections, stats
- [ ] Include commit metadata (hash, scope, author, issues)
- [ ] Add --format json flag to generate command

## Phase 9: GitHub Releases Format

- [ ] Create format/github.zig module
- [ ] Generate GitHub-flavored markdown ("What's Changed" format)
- [ ] Include PR/issue links
- [ ] Add "Full Changelog" comparison link
- [ ] Add --format github flag to generate command

## Phase 10: Configuration System

- [ ] Create config.zig module
- [ ] Implement TOML parser (minimal, for chronicle.toml subset)
- [ ] Load configuration from chronicle.toml if present
- [ ] Support section name customization
- [ ] Support filter configuration (include_refactor, include_docs, exclude_scopes, exclude_patterns)
- [ ] Support format options (show_hashes, hash_length, show_authors, link_commits, link_issues)
- [ ] Implement --config flag for custom config path

## Phase 11: Additional CLI Commands

- [ ] Implement `chronicle init` - create default chronicle.toml
- [ ] Implement `chronicle lint` - validate commit message format
- [ ] Implement `chronicle preview` - show unreleased changes
- [ ] Add --full flag for full changelog regeneration
- [ ] Implement --help with usage documentation

## Phase 12: Claude Code Skill (Basic)

- [ ] Create ~/.claude/skills/changelog.md skill file
- [ ] Implement CLI detection (which chronicle)
- [ ] Call chronicle generate --format json --dry-run
- [ ] Parse JSON output for structured data
- [ ] Format basic output for user review

## Phase 13: Skill Enhancement Features

- [ ] Read existing CHANGELOG.md to detect style
- [ ] Read diffs for vague commit messages (git show)
- [ ] Enhance descriptions with context from diffs
- [ ] Match formatting style to existing changelog
- [ ] Present draft with stats for user approval
- [ ] Handle user feedback and revisions
- [ ] Write final output via Edit tool

## Phase 14: Skill Edge Cases

- [ ] Implement fallback to raw git when CLI unavailable
- [ ] Handle non-conventional commit projects
- [ ] Handle ambiguous commits with user prompts
- [ ] Handle large releases (50+ commits) with grouping suggestions

## Phase 15: Advanced Features

- [ ] Implement related commit grouping
- [ ] Generate highlights section for major releases
- [ ] Add monorepo support (per-package changelogs)
- [ ] Fetch GitHub PR descriptions for enhanced context

## Phase 16: Testing and Polish

- [ ] Test CLI with various conventional commit formats
- [ ] Test edge cases (no tags, no commits, malformed commits)
- [ ] Test all output formats
- [ ] Test configuration loading
- [ ] Add error messages for common failure cases
- [ ] Document usage in README.md

---

## Implementation Notes

**Dependencies:**
- Zig 0.13+ standard library only (no external dependencies)
- Shells out to `git` binary (no libgit2)
- Skill requires Chronicle CLI in PATH or falls back to raw git

**Key Design Decisions:**
- Arena allocator for per-request memory management
- Shell out to git rather than linking libgit2 for simplicity
- Minimal TOML parser (only parse what we need)
- JSON output designed for skill consumption

**File Structure:**
```
chronicle/
├── src/
│   ├── main.zig           # Entry point, CLI parsing
│   ├── git.zig            # Git operations
│   ├── parser.zig         # Conventional commit parser
│   ├── filter.zig         # Commit filtering logic
│   ├── changelog.zig      # Core data structures
│   ├── config.zig         # TOML config loading
│   └── format/
│       ├── markdown.zig   # Markdown output
│       ├── json.zig       # JSON output
│       └── github.zig     # GitHub releases format
├── build.zig
├── build.zig.zon
├── chronicle.toml         # Example config
└── README.md
```
