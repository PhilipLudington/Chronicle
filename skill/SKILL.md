---
name: changelog
description: Generate changelog entries from git commits. Use when asked to generate changelog, update changelog, write changelog, create release notes, or document changes for a release.
allowed-tools: Read, Glob, Grep, Bash, Edit, Write
user-invocable: true
---

# Changelog Generation Skill

Generate changelog entries from git commits using conventional commit format.

## Prerequisites

Check if Chronicle CLI is available:

```bash
which chronicle
```

If Chronicle is not found, fall back to raw git commands (see Fallback section).

## Workflow

### Step 1: Style Detection

Before generating, read the existing CHANGELOG.md to detect its style:

```bash
head -100 CHANGELOG.md 2>/dev/null || echo "NO_CHANGELOG"
```

If CHANGELOG.md exists, analyze and note these style patterns:

**Section Names:**
- Keep-a-Changelog: "Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"
- Alternative: "Features", "Bug Fixes", "Breaking Changes", "New", "Improvements"
- Custom: Record exact names used

**Bullet Style:**
- Dash: `- item`
- Asterisk: `* item`
- Plus: `+ item`

**Commit Hash Format:**
- None: No hashes shown
- Short inline: `- Description (abc1234)`
- Link format: `- Description ([abc1234](url))`

**Issue Reference Format:**
- Shorthand: `#123`
- Full URL: `[#123](https://github.com/owner/repo/issues/123)`
- Parenthetical: `(fixes #123)`

**Date Format:**
- ISO: `2026-01-19`
- Long: `January 19, 2026`
- US: `01/19/2026`

**Version Header Format:**
- Bracketed link: `## [v1.0.0] - 2026-01-19`
- Plain: `## v1.0.0 (2026-01-19)`
- No date: `## v1.0.0`

Store these detected patterns for use in Step 6.

### Step 2: Detect Chronicle CLI

Check if the Chronicle CLI is installed:

```bash
which chronicle >/dev/null 2>&1 && echo "found" || echo "not found"
```

### Step 3: Generate Changelog Data

If Chronicle is found, use it to generate structured changelog data:

```bash
chronicle generate --format json --dry-run
```

This outputs JSON with the following structure:
```json
{
  "version": "v1.0.0",
  "date": "2026-01-19",
  "sections": {
    "Added": [
      {
        "description": "new feature description",
        "hash": "abc1234",
        "scope": "parser",
        "breaking": false,
        "issues": ["#123"]
      }
    ],
    "Fixed": [...],
    "Changed": [...]
  },
  "stats": {
    "total": 15,
    "included": 8,
    "excluded": 7
  }
}
```

### Step 4: Enhance Vague Commit Descriptions

After getting the JSON data, scan for vague commit descriptions that need enhancement.

**Vague Description Patterns:**
- Very short: less than 20 characters
- Generic verbs only: "fix bug", "update code", "refactor", "cleanup"
- Placeholder-like: "WIP", "temp fix", "misc changes"
- No specifics: "fix issue", "address feedback", "code review changes"

For each vague commit, read the diff to extract context:

```bash
git show --stat --no-patch <hash>
```

Then get the full diff for context:

```bash
git show <hash> -- '*.zig' '*.ts' '*.py' '*.go' '*.rs' '*.js'
```

**Extract Enhancement Context:**
1. **Files changed**: Which files/modules were modified
2. **Function names**: Look for function definitions added/modified
3. **Error handling**: Look for error types or error handling added
4. **Key identifiers**: Class names, struct names, constant names
5. **Test names**: If tests were added, what do they test

**Enhancement Examples:**

| Original | After Diff Analysis | Enhanced |
|----------|---------------------|----------|
| "fix bug" | Changed `parseDate()` in `parser.zig` to handle empty strings | "fix date parser crash on empty input" |
| "update code" | Added `validateConfig()` function with schema checks | "add configuration validation with schema checks" |
| "refactor" | Extracted `ConnectionPool` from `Database` struct | "extract connection pooling into dedicated module" |

**Enhancement Rules:**
- Keep the original commit type (fix, feat, etc.)
- Add specificity: what component, what behavior
- Mention user-facing impact when clear from diff
- Keep descriptions concise (under 80 characters)
- Preserve original meaning, just add clarity

Mark enhanced entries for display in the approval workflow.

### Step 5: Present Draft for Approval

Format the changelog matching detected style (or Keep-a-Changelog defaults) and present to user.

**Present Statistics Summary:**
```
Changelog Draft for v1.0.0 (2026-01-19)
----------------------------------------

Statistics:
- Total commits analyzed: 25
- Included in changelog: 12
- Excluded (chore/test/ci): 13

By Section:
- Added: 4 entries
- Fixed: 5 entries
- Changed: 3 entries

Breaking Changes: 1
- (api) Remove deprecated `oldMethod()` function
```

**Show Full Draft:**
Present the formatted changelog entry matching detected style.

**Highlight Enhanced Entries:**
If any entries were enhanced from vague descriptions, show them:
```
Enhanced Descriptions (from diff analysis):
- "fix bug" -> "fix date parser crash on empty input"
- "update code" -> "add configuration validation with schema checks"
```

**Request Explicit Approval:**
```
Do you approve this changelog entry?
- "yes" / "approve" - Write to CHANGELOG.md
- "modify <number>" - Edit a specific entry
- "remove <number>" - Remove an entry
- "reword <number> <new text>" - Replace entry text
- "no" / "cancel" - Discard and exit
```

### Step 6: Handle User Feedback

Process user modification requests in a loop until approved:

**Commands:**
- `approve` / `yes` / `y` - Accept and proceed to writing
- `modify N` - Open entry N for editing (present current text, ask for new text)
- `remove N` - Remove entry N from the draft
- `reword N <text>` - Replace entry N's description with new text
- `add <section> <text>` - Add a new entry to a section
- `cancel` / `no` / `n` - Discard draft and exit

**After Modifications:**
- Re-display the updated draft
- Show what changed
- Request approval again

**Example Interaction:**
```
User: "reword 3 fix memory leak in connection pool cleanup"

Updated entry 3:
  Before: "fix resource cleanup"
  After: "fix memory leak in connection pool cleanup"

[Show updated draft]

Do you approve this changelog entry?
```

### Step 7: Write Output

After user approval, write the changelog entry to file.

**Determine Output Method:**

If CHANGELOG.md exists:
1. Use the Edit tool to prepend new version section
2. Find the insertion point (after header, before first existing version)
3. Match the detected style exactly

If no CHANGELOG.md exists:
1. Create new file with Keep-a-Changelog format
2. Include standard header
3. Add the version section

**New File Template:**
```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v1.0.0] - 2026-01-19

### Added
- New feature description

### Fixed
- Bug fix description
```

**Existing File Update:**
Use Edit tool to insert new version section after `## [Unreleased]` or at the appropriate position:

```
old_string: "## [Unreleased]\n\n## [v0.9.0]"
new_string: "## [Unreleased]\n\n## [v1.0.0] - 2026-01-19\n\n### Added\n- New feature\n\n## [v0.9.0]"
```

**Style Matching Rules:**
- Use detected section names (or defaults)
- Use detected bullet style (or dash default)
- Use detected hash format (or omit)
- Use detected issue link format (or shorthand)
- Use detected date format (or ISO)
- Use detected header format (or bracketed)

## Options

The user may specify:
- `--version-tag <TAG>`: Specific version to generate
- `--from <TAG>`: Start of commit range
- `--full`: Regenerate entire changelog from all tags
- Output format: markdown (default), github (for releases)

## Fallback: Raw Git Mode

If Chronicle CLI is not installed, use raw git commands to gather the same data.

### Step F1: Detect Git Repository

```bash
git rev-parse --git-dir 2>/dev/null && echo "is_git_repo" || echo "not_git_repo"
```

If not a git repo, inform user: "This directory is not a git repository. Please run from a git project root."

### Step F2: Get Version Tags

```bash
# List all version tags sorted by version
git tag --list 'v*' --sort=-version:refname 2>/dev/null | head -20

# Get the latest tag
git describe --tags --abbrev=0 2>/dev/null || echo "NO_TAGS"

# Get the previous tag (for commit range)
git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo ""
```

If no tags exist:
1. Ask user for version string: "No tags found. What version should this changelog be for? (e.g., v1.0.0)"
2. Use `HEAD~30..HEAD` as default commit range (last 30 commits)
3. Or ask user to specify: "How many commits back should I include?"

### Step F3: Get Commits in Range

```bash
# Get commits between tags (or from start if no previous tag)
git log --format="%H|%h|%s|%b|%an|%aI" <from_ref>..<to_ref>

# Example: commits since last tag to HEAD
git log --format="%H|%h|%s|%b|%an|%aI" v1.0.0..HEAD

# If no previous tag, get all commits:
git log --format="%H|%h|%s|%b|%an|%aI"
```

**Output format:**
- `%H` - Full commit hash
- `%h` - Short hash (7 chars)
- `%s` - Subject line (first line of message)
- `%b` - Body (remaining lines)
- `%an` - Author name
- `%aI` - Author date (ISO 8601)

### Step F4: Parse Conventional Commits

For each commit, apply this regex to the subject line:
```
^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^)]+\))?(!)?:\s*(.+)$
```

**Capture groups:**
1. Type: feat, fix, docs, etc.
2. Scope: optional (scope) portion
3. Breaking indicator: optional !
4. Description: the message after the colon

**Categorize by type:**
| Type | Section |
|------|---------|
| feat | Added |
| fix | Fixed |
| perf | Performance |
| refactor | Changed |
| docs | Documentation |
| deprecate | Deprecated |
| remove | Removed |
| security | Security |

**Filter out (exclude from changelog):**
- `chore:` commits
- `test:` commits
- `ci:` commits
- `build:` commits
- Commits containing: `wip`, `fixup`, `squash`, `typo`, `[skip changelog]`
- Merge commits (subject starting with "Merge ")

### Step F5: Detect Breaking Changes

A commit is breaking if:
1. Has ! before the colon (e.g., feat!: new API)
2. Body contains BREAKING CHANGE: footer

```bash
# Check commit body for BREAKING CHANGE footer
git log -1 --format="%b" <hash> | grep -q "^BREAKING CHANGE:" && echo "breaking"
```

### Step F6: Extract Issue References

Scan commit message for issue patterns:
- `#123` - GitHub issue shorthand
- `fixes #123`, `closes #123`, `resolves #123`
- `GH-123` - Alternative GitHub format
- `JIRA-123` - Jira-style references

### Step F7: Build Changelog Data Structure

Construct the same structure as Chronicle CLI would output:

```json
{
  "version": "v1.1.0",
  "date": "2026-01-19",
  "sections": {
    "Added": [
      {
        "description": "add dark mode support",
        "hash": "abc1234",
        "scope": "ui",
        "breaking": false,
        "issues": ["#45"],
        "author": "developer"
      }
    ],
    "Fixed": [...],
    "Changed": [...]
  },
  "stats": {
    "total": 20,
    "included": 12,
    "excluded": 8,
    "excluded_breakdown": {
      "chore": 4,
      "test": 3,
      "ci": 1
    }
  }
}
```

Then continue with Step 4 (Enhance Vague Descriptions) from the main workflow.

### Fallback Example Session

```
User: Generate changelog
Assistant: I'll check for Chronicle CLI...

Chronicle CLI not found. I'll use raw git commands instead.

[Runs: git describe --tags --abbrev=0]
Latest tag: v1.0.0

[Runs: git log --format="%H|%h|%s|%b|%an|%aI" v1.0.0..HEAD]
Found 15 commits since v1.0.0

Parsed commits:
- 8 follow conventional commit format
- 4 excluded (chore: 2, test: 2)
- 3 non-conventional (will need categorization)

[Continues with enhancement and presentation steps...]
```

## Edge Case: Non-Conventional Commit Projects

When commits don't follow conventional commit format, use AI analysis to categorize them.

### Detection

After parsing commits, check the ratio:
- If < 30% follow conventional format, treat as non-conventional project
- If 30-70%, it's a mixed project (handle both)
- If > 70%, treat as conventional (flag non-conventional as ambiguous)

### Non-Conventional Project Workflow

**Step NC1: Inform User**

```
This project doesn't use conventional commit format.
I found 0 of 25 commits following the type: description pattern.

I can:
1. Analyze each commit's diff to categorize changes (recommended)
2. Show all commits for you to categorize manually
3. Generate a flat list without categories

Which approach would you prefer?
```

**Step NC2: AI-Based Categorization**

For each commit, read the diff and classify:

```bash
git show --stat <hash>
git show <hash> -- '*.zig' '*.ts' '*.py' '*.go' '*.rs' '*.js' '*.md'
```

**Classification heuristics:**

| Diff Pattern | Likely Category |
|--------------|-----------------|
| New file added | Added |
| File deleted | Removed |
| Test file changes only | Test (exclude) |
| CI/workflow file changes | CI (exclude) |
| README/docs changes only | Documentation |
| Error handling added | Fixed (likely) |
| New function/class/struct | Added |
| Function signature changed | Changed |
| Performance keywords (cache, optimize, fast) | Performance |
| Security keywords (auth, token, encrypt, sanitize) | Security |

**Step NC3: Confidence Scoring**

For each classification, assign confidence:
- **High (80%+)**: Clear pattern match (new file = Added, deleted = Removed)
- **Medium (50-79%)**: Keyword/pattern match
- **Low (<50%)**: Best guess, needs user confirmation

Present low-confidence items for user review:

```
I categorized 20 commits. 5 need your input:

1. "Update user handling" (abc1234) - Best guess: Changed
   Diff shows: Modified auth.ts, changed session logic
   -> Added / Fixed / Changed / Exclude?

2. "Cleanup" (def5678) - Best guess: Exclude (chore)
   Diff shows: Whitespace changes, import reordering
   -> Keep as Changed / Exclude?
```

**Step NC4: Description Enhancement**

Non-conventional commits often have poor descriptions. Always enhance:

| Original | Files Changed | Enhanced |
|----------|---------------|----------|
| "Update" | user.ts, auth.ts | "update user authentication flow" |
| "Fix" | parser.zig | "fix parser crash on malformed input" |
| "Changes" | api.go, types.go | "refactor API response types" |

**Step NC5: Generate Draft**

Present categorized commits with confidence indicators:

```
Changelog Draft for v1.0.0 (2026-01-19)
----------------------------------------

### Added
- Add user profile page (abc1234) ✓ high confidence
- Add dark mode toggle (def5678) ✓ high confidence

### Fixed
- Fix login timeout issue (ghi9012) ~ medium confidence
- Fix memory leak in parser (jkl3456) ✓ high confidence

### Changed
- Update authentication flow (mno7890) ? needs review

---
Commits excluded: 8 (chore-like: 5, test-like: 3)

Items marked with ? need your confirmation.
Reply with numbers to recategorize, or "approve" to continue.
```

### Mixed Project Handling

For projects with some conventional commits:

```
Mixed commit format detected:
- 15 conventional commits (parsed automatically)
- 10 non-conventional commits (need analysis)

I'll parse the conventional ones and analyze the rest.
```

Process conventional commits normally, then apply NC workflow to the rest.

### Manual Categorization Option

If user chooses manual categorization:

```
Here are 25 commits to categorize:

1. abc1234 - "Update user handling"
2. def5678 - "Fix bug"
3. ghi9012 - "Improvements"
...

Reply with categorizations like:
  1 Added, 2 Fixed, 3 exclude, 4-6 Changed

Or type "all Added" / "all Fixed" / "all exclude" for bulk actions.
```

### Flat List Option

If user chooses flat list:

```
## [v1.0.0] - 2026-01-19

### Changes

- Update user handling (abc1234)
- Fix bug (def5678)
- Improvements (ghi9012)
- Add new feature (jkl3456)
...

Note: Commits listed chronologically without categorization.
```

## Edge Case: Ambiguous Commits

Handle commits that match conventional format but have unclear intent.

### Ambiguity Triggers

A commit is ambiguous when:
1. **Vague description**: "fix issue", "update code", "changes", "misc"
2. **Mismatched type**: `fix:` but diff shows new feature
3. **Multiple concerns**: Diff touches unrelated areas
4. **Scope mismatch**: `fix(ui):` but changes backend files

### Ambiguity Detection

After parsing, scan for ambiguous commits:

```javascript
function isAmbiguous(commit, diff) {
  // Vague description check
  const vaguePatterns = [
    /^(fix|update|change|improve|refactor)\s*(bug|issue|code|it|stuff)?$/i,
    /^(misc|various|multiple|several)\s*(changes|updates|fixes)?$/i,
    /^(wip|temp|tmp|todo)/i
  ];
  if (vaguePatterns.some(p => p.test(commit.description))) return true;

  // Type mismatch check
  if (commit.type === 'fix' && diff.hasNewFiles) return true;
  if (commit.type === 'feat' && !diff.hasNewCode) return true;

  // Multi-concern check
  if (diff.touchedModules.length > 3) return true;

  return false;
}
```

### Resolution Workflow

**Step A1: Present Ambiguous Commits**

```
I found 3 ambiguous commits that need clarification:

---
Commit 1: fix(api): update handling (abc1234)

The diff shows:
- Modified: src/api/auth.ts (+45 -12)
- Modified: src/api/types.ts (+8 -0)
- New file: src/api/session.ts (+67)

This looks like it might be:
1. Fixed - Fix session handling bug
2. Added - Add session management feature
3. Changed - Refactor authentication system
4. Exclude - Don't include in changelog

Which category? (1/2/3/4)
---

Commit 2: feat: improvements (def5678)
...
```

**Step A2: Offer Rewording**

After category selection, offer to improve description:

```
You chose: Added

Current description: "update handling"
Suggested reword: "add session management for persistent logins"

Use suggested description? (yes/no/custom)
```

**Step A3: Batch Processing**

For many ambiguous commits, offer batch mode:

```
Found 12 ambiguous commits. Options:

1. Review each one (recommended for accuracy)
2. Auto-categorize using diff analysis (faster, less accurate)
3. Exclude all ambiguous commits
4. Include all as "Changed" section

Choice?
```

### Type Mismatch Handling

When commit type doesn't match the actual changes:

```
Potential mismatch detected:

Commit: fix(parser): add validation
Type says: Fixed
But diff shows: New validateInput() function added

This appears to be a new feature, not a bug fix.
Should I:
1. Keep as Fixed (trust the commit message)
2. Move to Added (based on diff analysis)
3. Let me explain the context -> [user explains]
```

### Multi-Concern Commits

When one commit does multiple things:

```
Commit abc1234 touches multiple areas:
- src/auth/* (authentication changes)
- src/ui/* (UI updates)
- src/api/* (API modifications)
- tests/* (test additions)

Options:
1. Include once in most relevant section
2. Split into multiple changelog entries
3. Exclude (too broad for changelog)

Choice?
```

If user chooses split:

```
I'll create separate entries:

### Added
- Add OAuth2 authentication support (abc1234)

### Changed
- Update login UI for OAuth flow (abc1234)

### Fixed
- Fix API token refresh timing (abc1234)

Look correct?
```

## Edge Case: Large Releases (50+ Commits)

Handle releases with many commits to avoid overwhelming changelogs.

### Detection

If commit count exceeds threshold (default: 50):

```
This release has 67 commits to include in the changelog.
A detailed list may be overwhelming for readers.

Recommended approaches:
1. Group related commits (recommended)
2. Show top 20 most significant + summary
3. Generate full detailed list anyway
4. Let me select which commits to include

Choice?
```

### Grouping Strategy

**Step L1: Identify Clusters**

Group commits by:
1. **Scope**: All commits with same scope (e.g., `(parser)`, `(ui)`, `(api)`)
2. **Feature area**: Commits touching same files/directories
3. **Time proximity**: Commits within 24h on same topic
4. **Related keywords**: Similar terms in descriptions

```bash
# Find commits by scope
git log --oneline v1.0.0..HEAD | grep -E '\([a-z]+\):' | \
  sed 's/.*(\([^)]*\)).*/\1/' | sort | uniq -c | sort -rn

# Find commits by directory
git log --name-only --oneline v1.0.0..HEAD | \
  grep -E '^src/' | cut -d/ -f2 | sort | uniq -c | sort -rn
```

**Step L2: Create Summary Entries**

For each cluster with 3+ commits:

```
Found clusters:
- 8 commits related to "authentication"
- 6 commits related to "parser improvements"
- 5 commits related to "UI polish"
- 4 commits related to "error handling"

I'll create summary entries for these, e.g.:
- "Overhauled authentication system with OAuth2 support and session management"
  (replaces 8 individual commits)
```

**Step L3: Determine Significance**

Rank commits by significance:

| Signal | Weight |
|--------|--------|
| Breaking change (!) | +5 |
| New feature (feat:) | +3 |
| Bug fix (fix:) | +2 |
| Mentioned in issues | +2 |
| Large diff (100+ lines) | +1 |
| Multiple reviewers (from metadata) | +1 |

Present top significant commits individually, group the rest.

### Grouped Output Format

```
## [v2.0.0] - 2026-01-19

### Highlights

This major release brings OAuth2 authentication, a redesigned settings page,
and significant performance improvements.

### Added

- **OAuth2 Authentication** — Complete OAuth2 implementation with support
  for Google, GitHub, and custom providers. Includes session management
  and token refresh. (8 commits)

- **Settings Redesign** — New tabbed settings interface with search and
  keyboard navigation. (5 commits)

- Add export to PDF format ([#234])
- Add keyboard shortcut customization ([#241])

### Fixed

- **Parser Reliability** — Fixed multiple edge cases in the parser including
  unicode handling, nested structures, and large file support. (6 commits)

- Fix memory leak when switching projects ([#198])
- Fix tooltip positioning on HiDPI displays ([#203])

### Performance

- Reduce startup time by 40% through lazy initialization
- Improve search indexing performance (4 commits)

---
67 commits total: 45 grouped into summaries, 22 listed individually
```

### Individual Significant Commits

Always list individually (never group):
- Breaking changes
- Security fixes
- Commits with linked issues/PRs
- Commits explicitly tagged as important

### User Refinement

After presenting grouped draft:

```
Grouped changelog generated:
- 6 summary groups (45 commits)
- 22 individual entries
- 0 excluded

Options:
1. Approve as-is
2. Expand a group to show individual commits
3. Merge additional commits into existing groups
4. Ungroup all (show full list)

To expand a group: "expand authentication"
To merge: "merge commits 5,7,9 into 'error handling'"
```

### Threshold Configuration

User can adjust grouping threshold:

```
Current settings:
- Minimum commits for release to trigger grouping: 50
- Minimum commits in cluster to create group: 3

Adjust? (e.g., "threshold 30" or "cluster 5")
```

## Examples

### Generate changelog for latest tag
```
User: Generate the changelog for the latest release
Assistant: I'll check if Chronicle is available, detect the existing changelog style, and generate the changelog...
[Reads CHANGELOG.md for style detection]
[Runs: chronicle generate --format json --dry-run]
[Enhances any vague descriptions using git show]
[Presents draft with statistics]
[Awaits user approval]
```

### Generate with specific version
```
User: Generate changelog for v2.0.0
Assistant: I'll generate the changelog for v2.0.0...
[Uses: chronicle generate --version-tag v2.0.0 --format json --dry-run]
```

### Full changelog regeneration
```
User: Regenerate the entire changelog
Assistant: I'll regenerate the complete changelog from all tags...
[Uses: chronicle generate --full --dry-run]
```

### Preview unreleased changes
```
User: What changes are unreleased?
Assistant: I'll check for unreleased changes since the last tag...
[Uses: chronicle preview]
```

### Handle user feedback
```
User: Generate changelog
Assistant: [Shows draft]
User: Remove entry 3 and reword entry 5 to "improve error messages for API validation"
Assistant:
Updated draft:
- Removed entry 3: "fix typo in docs"
- Rewrote entry 5: "improve error messages for API validation"

[Shows updated draft]
Do you approve this changelog entry?
```

## Error Handling

- **No tags found**: Ask user to specify --version-tag or create a tag first
- **No commits found**: Inform user there are no changes to document
- **Invalid commit format**: Show which commits don't follow conventional format
- **Git not available**: Report that this must be run in a git repository
- **CHANGELOG.md read error**: Proceed with default Keep-a-Changelog style
- **Edit tool failure**: Report error and show the formatted output for manual copy
