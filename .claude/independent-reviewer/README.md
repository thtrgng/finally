# independent-reviewer

A Claude Code plugin that adds an **independent code review agent** to your project.

After every file edit Claude makes, a review is queued. Run `/review` at any point to get a second-opinion report with severity-tagged findings — before you commit anything.

---

## What it does

| Feature | Description |
|---|---|
| **Post-edit hook** | Fires after every `Write`, `Edit`, or `MultiEdit` tool call. Queues the change for review. |
| **`/review` command** | Triggers the independent reviewer agent. Checks the queue + `git diff HEAD`. |
| **Reviewer agent** | A skeptical, separate sub-agent that checks for bugs, security issues, logic errors, and style problems. |

## Install

```bash
# Install into the current project
bash .claude/independent-reviewer/install.sh

# Install into a specific project
bash .claude/independent-reviewer/install.sh /path/to/your/project
```

## Uninstall

```bash
bash .claude/independent-reviewer/uninstall.sh
```

## Usage

After installing, just work normally with Claude Code. After any file edits, you'll see:

```
📋 [independent-reviewer] Queued review for: src/api/trade.py → run /review for feedback
```

When you're ready for a review, type:

```
/review
```

The reviewer agent will output something like:

```
## 🔍 Independent Review

**File(s) reviewed:** `src/api/trade.py`
**Lines changed:** +38 / -12
**Verdict:** 🚨 Issues found — action required

### Findings

**🔴 Critical** — `trade.py:87` — Cash balance check is not atomic
> The balance check at line 87 and the debit at line 94 are two separate DB calls
> without a transaction. Two concurrent requests can both pass the check and both
> execute, overdrawing the account.
> **Suggestion:** Wrap lines 87–94 in `BEGIN EXCLUSIVE TRANSACTION ... COMMIT`.

### Summary
The trade execution logic is mostly correct but has a TOCTOU race condition on
the cash balance that could allow account overdraw under concurrent load.
Address the atomicity issue before merging.
```

## Sharing with your team

This plugin lives in `.claude/independent-reviewer/` inside the project. To distribute it:

**Option 1 — Via this repo** (if your team already uses this repo):
- The plugin is already committed. Colleagues just run `bash .claude/independent-reviewer/install.sh` after cloning.

**Option 2 — Standalone plugin repo**:
- Copy the `.claude/independent-reviewer/` folder to its own git repo.
- Colleagues clone it anywhere, then run `install.sh /path/to/their/project`.

**Option 3 — Company marketplace** (recommended for teams with multiple plugins):
- The install script automatically updates `~/.claude/marketplace/marketplace.json`.
- Share the `~/.claude/marketplace/` directory (or the JSON) as a git repo.
- Use `claude-plugin.sh` (at the project root) to browse and install from the catalog.

## File layout

```
.claude/independent-reviewer/
├── plugin.json           ← Plugin metadata
├── README.md             ← This file
├── install.sh            ← Install into any project
├── uninstall.sh          ← Remove from any project
├── agents/
│   └── independent-reviewer.md  ← The reviewer sub-agent
├── hooks/
│   └── post-edit-review.sh      ← PostToolUse hook script
└── commands/
    └── review.md                 ← /review slash command
```

After `install.sh` runs, the following are added to your project:

```
.claude/
├── agents/independent-reviewer.md   ← installed
├── commands/review.md               ← installed  (/review)
├── .independent-reviewer/
│   ├── hooks/post-edit-review.sh    ← installed
│   └── pending/                     ← review queue (auto-created)
└── settings.json                    ← updated with PostToolUse hook
```
