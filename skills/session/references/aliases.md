# Adding or changing an alias

`${CLAUDE_SKILL_DIR}` below is the skill folder SKILL.md was loaded from.

When the user says something like "add an alias for this folder too: `<name>` = `<path>`":

1. Check that the path really exists (if not, do not create it — ask).
2. Ask which phrases should select it (`triggers`), and whether the bare name can mean something else
   (`note`).
3. Edit the `aliases.json` at the `file` path reported by `list-aliases.ps1` (confirm before
   applying); when the code was `NO_ALIASES` the file does not exist yet, so create it. The format is
   the one in `${CLAUDE_SKILL_DIR}/../../examples/aliases.example.json`. A `path` is an absolute
   path; `%VAR%` references in it are expanded.
4. Run `list-aliases.ps1` again. `ALIASES_UNREADABLE` means the JSON is broken — fix it before
   anything else, because every script that takes `-Alias` fails until it parses.

To look for new candidates (read-only):

```
pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/list-candidates.ps1"
```

It lists the most-used folders. A row whose `alias` is not null is already registered — do not offer
it as a new candidate.
