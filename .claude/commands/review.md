Trigger an independent code review using the `independent-reviewer` agent.

**Usage:**
- `/review` — review all queued changes (from recent file edits in this session)
- `/review <file>` — review a specific file regardless of whether it was recently edited

**What happens:**
The independent reviewer agent will:
1. Check `.claude/independent-reviewer/pending/` for any queued changes from this session
2. Run `git diff HEAD` to see everything that has changed
3. Read the relevant files in full
4. Produce a structured code review report with severity-tagged findings
5. Clear the pending queue when done

Use this after a session of changes to get a second opinion before committing.
