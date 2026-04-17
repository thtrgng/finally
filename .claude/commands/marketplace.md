Browse and manage plugins in the local company marketplace.

**Usage:**
- `/marketplace` — list all available plugins and their install status
- `/marketplace install <name>` — install a plugin into this project
- `/marketplace info <name>` — show details about a specific plugin

**Instructions for Claude:**

Run the following bash command and display the output clearly to the user:

```
bash claude-plugin.sh list
```

If the user said `/marketplace install <name>`, run:
```
bash claude-plugin.sh install <name>
```

If the user said `/marketplace info <name>`, run:
```
bash claude-plugin.sh info <name>
```

If the command fails because `~/.claude/marketplace/marketplace.json` does not exist yet, explain that no plugins have been installed yet and suggest running the install script for a plugin (e.g. `bash .claude/independent-reviewer/install.sh`).

Always display the output in a clean, readable format. If the list is empty, tell the user how to add plugins.
