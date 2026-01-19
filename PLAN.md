# Chronicle Implementation Plan

A changelog generator with a Zig CLI core and Claude Code skill wrapper.

## Phase 1: Project Setup

- [x] Create build.zig with standard Zig 0.13+ configuration
- [x] Create build.zig.zon with project metadata
- [x] Set up source directory structure (src/, src/format/)
- [x] Create main.zig entry point with CLI argument parsing skeleton
- [x] Add .gitignore for Zig build artifacts (zig-out/, zig-cache/)

## Phase 2: Core Types and Data Structures

- [x] Create changelog.zig with core types (Commit, CommitType enum, ChangelogEntry, Stats)
- [x] Implement memory management patterns (allocators, arena allocation)
- [x] Add string utilities for commit parsing

## Phase 3: Git Integration

- [x] Create git.zig module
- [x] Implement runCommand helper to shell out to git
- [x] Implement getTags() to list version tags sorted by version
- [x] Implement getCommits(from, to) to get commit range
- [x] Implement getLatestTag() for default version detection
- [x] Implement getPreviousTag(tag) for determining commit range
- [x] Add git show wrapper for reading individual commits

## Phase 4: Conventional Commit Parser

- [x] Create parser.zig module
- [x] Implement parseConventionalCommit() to extract type, scope, description, breaking flag
- [x] Implement parseCommitType() to map prefixes to CommitType enum
- [x] Handle scope parsing (parentheses)
- [x] Handle breaking change indicator (!)
- [x] Extract issue references from commit messages (#123 patterns)
- [x] Parse commit body for BREAKING CHANGE footer

## Phase 5: Filtering Logic

- [x] Create filter.zig module
- [x] Implement default exclusion rules (chore, test, ci, build, merge commits)
- [x] Implement pattern-based exclusion (wip, fixup, squash, typo, [skip changelog])
- [x] Implement scope-based exclusion
- [x] Implement shouldInclude() predicate combining all rules
- [x] Track exclusion stats by category

## Phase 6: Markdown Output

- [x] Create format/markdown.zig module
- [x] Implement section grouping (Added, Fixed, Changed, etc.)
- [x] Generate standard Keep-a-Changelog format
- [x] Support commit hash linking
- [x] Support issue linking (#123 → GitHub URL)
- [x] Handle empty sections gracefully

## Phase 7: Generate Command

- [x] Wire up `chronicle generate` in main.zig
- [x] Implement --dry-run (stdout output)
- [x] Implement --version flag
- [x] Implement --from and --to flags
- [x] Implement --output flag
- [x] Implement file writing (prepend to existing CHANGELOG.md)
- [x] Add --quiet flag for suppressing info messages

## Phase 8: JSON Output Format

- [x] Create format/json.zig module
- [x] Output structured JSON matching design spec
- [x] Include version, date, sections, stats
- [x] Include commit metadata (hash, scope, author, issues)
- [x] Add --format json flag to generate command

## Phase 9: GitHub Releases Format

- [x] Create format/github.zig module
- [x] Generate GitHub-flavored markdown ("What's Changed" format)
- [x] Include PR/issue links
- [x] Add "Full Changelog" comparison link
- [x] Add --format github flag to generate command

## Phase 10: Configuration System

- [x] Create config.zig module
- [x] Implement TOML parser (minimal, for chronicle.toml subset)
- [x] Load configuration from chronicle.toml if present
- [x] Support section name customization
- [x] Support filter configuration (include_refactor, include_docs, exclude_scopes, exclude_patterns)
- [x] Support format options (show_hashes, hash_length, show_authors, link_commits, link_issues)
- [x] Implement --config flag for custom config path

## Phase 11: Additional CLI Commands

- [x] Implement `chronicle init` - create default chronicle.toml
- [x] Implement `chronicle lint` - validate commit message format
- [x] Implement `chronicle preview` - show unreleased changes
- [x] Add --full flag for full changelog regeneration
- [x] Implement --help with usage documentation

## Phase 12: Claude Code Skill (Basic)

- [x] Create ~/.claude/skills/changelog.md skill file
- [x] Implement CLI detection (which chronicle)
- [x] Call chronicle generate --format json --dry-run
- [x] Parse JSON output for structured data
- [x] Format basic output for user review

## Phase 13: Skill Enhancement Features

- [x] Read existing CHANGELOG.md to detect style
- [x] Read diffs for vague commit messages (git show)
- [x] Enhance descriptions with context from diffs
- [x] Match formatting style to existing changelog
- [x] Present draft with stats for user approval
- [x] Handle user feedback and revisions
- [x] Write final output via Edit tool

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
