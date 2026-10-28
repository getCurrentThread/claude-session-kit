# Restore — the steps (SKILL.md §5)

`${CLAUDE_SKILL_DIR}` below is the skill folder SKILL.md was loaded from.

1. **List first (opens nothing; drops records that can never be reopened):**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore-open.ps1"
   ```
   `OPEN_SESSIONS` gives numbered rows (`n`, `title`, `cwd`, `cwdExists`, `lastWrite`,
   `permissionMode`), newest first. Sessions that are open right now never appear. Claude Code cannot
   tell a closed window from a crash, so the rows include every session whose tab or window was
   closed, and they stay until forgotten: when rows are days old, show their `lastWrite` and offer
   `-Forget` for the ones the user does not want. On `NOTHING_TO_RESTORE`, tell the user there is
   nothing to bring back, and do not switch to §2 on your own.
2. **Confirm before opening more than one tab.** Show the list and ask: all of them, or which numbers?
   One row that the user has already named can be opened without asking again.
3. **Reopen:**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore-open.ps1" -All
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore-open.ps1" -Ids <sessionId>,<sessionId>
   ```
   Pass the `sessionId` values of the rows the user chose. Row numbers (`-Ids 1,3`) work too, but
   they shift whenever a session closes or reopens. `NOT_IN_LIST` means list again. Each
   tab resumes its own session in the folder recorded for it, with the permission mode that session
   was started with (`permissionMode`). `bypassPermissions` is never replayed. When a result carries
   `droppedPermissionMode`, tell the user that session now runs with normal permission prompts.
4. **Relay `results`, one line per session.** `RESUMED` means it is open again.
   `UNTRUSTED_WORKSPACE` and `PATH_NOT_FOUND` mean the same as in §1, and nothing was opened for
   that session. `ALREADY_RUNNING` means it is already open in another tab. The top-level
   `RESTORED` means at least one session opened; `NOT_RESTORED` means none did. For an untrusted
   one, offer `-Ids <sessionId> -TrustFolder` (§1 — the same offer, rules and codes).
5. **Forget** — when the user does not want some of them back, this opens nothing (`FORGOTTEN`):
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore-open.ps1" -Forget <sessionId>,<sessionId>
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/restore-open.ps1" -ForgetAll
   ```
