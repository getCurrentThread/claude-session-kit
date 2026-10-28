# Reboot and continue — steps 2 to 6 (SKILL.md §3)

`${CLAUDE_SKILL_DIR}` below is the skill folder SKILL.md was loaded from.
Step 1 — the user's explicit approval — is in SKILL.md §3 and must already be passed.

2. **Leave a structured handoff note.** Write the prompt that becomes the resumed session's first
   input to `next-prompt-<session id>.txt` in the state folder
   (`<home>\.claude\claude-session-kit\next-prompt-<UUID>.txt`, the UUID from step 3; plain
   `next-prompt.txt` only when the id is unknown) **with the Write tool** (guarantees UTF-8). One file
   per session, so another session's note can never become this one's handoff. Give Write the expanded absolute path, not a variable.
   Fill every heading in this template with concrete details; write "None" when nothing failed:
   ```
   Why the machine restarted
   <the change that required a restart>
   Done so far
   <completed work and its evidence>
   Tried and failed
   <failed attempts and what they showed, or None>
   Next steps
   <the remaining work in order>
   Verify first
   <the command to run first, for example wsl --status, and the expected result>
   ```

3. **Session id** (if you can): in your own scratchpad path `…\Temp\claude\<project>\<UUID>\scratchpad`
   the `<UUID>` is the current session id. If you cannot get it, leave `-SessionId` out — the script
   reads the running session's id from the `CLAUDE_CODE_SESSION_ID` environment variable, and failing
   that takes the newest **interactive** transcript in this folder. Never pass an id you are not sure
   of: `SESSION_REJECTED` means that id has no transcript, is not an interactive session, or belongs
   to another folder (`recordedCwd` says which).

4. **Plan (read-only):**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-plan.ps1" -WorkDir "<absolute project path>" -PromptFile "<absolute path of the note from step 2>" -SessionId <UUID>
   ```
   Read the `REBOOT_PLANNED` result before going on:
   - `sessionMode`: `resume` continues that session; **`fresh` means no session to continue was found
     and a new session carrying only the prompt will start** — tell the user and confirm first.
   - `sessionSource`: `explicit` or `env` is this session. `scan:interactive` / `scan:sidecar` is the
     newest session found in the folder, which is a different conversation when two are open there —
     check `sessionId` against your own, and confirm with the user if you cannot.
   - `promptDelivery`: `file` means `claude` is an npm-style `.cmd` shim here, so after logon the
     prompt is handed over in `resume-prompt.txt` instead of on the command line. Nothing to do.
   - `alsoResume` lists the other open interactive sessions that will return (at most eight).
     Tell the user their titles/ids and folders, and that they reopen **without a prompt**; only
     the primary receives the handoff. `skipped` lists excluded sessions and reasons, including
     any cut by the cap. Other folders must already be trusted. Add `-OnlyThis` when only the
     primary should return. `IDLE` means the session is still running but its transcript has not
     been written for over `-MaxIdleHours` (default 24) — typically a claude left in a terminal
     the user no longer sees. Name those (title, `lastWrite`) and say they will not come back;
     plan again with a larger `-MaxIdleHours` only if the user wants them.
   - `RESUME_PENDING` (`ok=false`) means `state.json` already holds a registered resume; report
     its `sessionId`, `workdir` and `createdAt`. Use `-Replace` only when replacing it is intended.
   - `PROMPT_STALE` (`ok=false`) means the prompt file is over 30 minutes old (or dated in the
     future). Rewrite the handoff; `-AllowStalePrompt` explicitly permits reusing it.

   If the user wants to restart by hand, add `-NoReboot` (registers only). The `alsoResume` list is
   fixed at plan time: those sessions reopen at that logon even if they are closed in between, so
   suggest `-OnlyThis` when the manual restart may be much later.

5. **Commit (destructive — only with the approval from step 1):**
   ```
   pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/reboot-commit.ps1" -Token <token>
   ```
   The token expires after ten minutes and works once.

6. **Branch on `code` and tell the user.**
   - `REBOOT_SCHEDULED` — the computer restarts in `delaySeconds` seconds; `shutdown /a` aborts; after
     logon a terminal opens by itself and this session continues. Say that, then **end the turn at
     once and make no further tool calls.**
   - `RESUME_REGISTERED` (`-NoReboot`) — nothing restarts now; the resume fires at the next logon after
     the user restarts by hand. Say that, then end the turn.
   - `SHUTDOWN_FAILED` — Windows refused the restart, but the resume **is still registered**. Say so,
     offer to cancel it (§4), then end the turn.
   - `NO_PLAN`, `TOKEN_MISMATCH`, `PLAN_EXPIRED`, `PLAN_INVALID` — nothing was registered. Go back to
     step 2: rewrite the note if anything changed, and plan again. The approval from step 1 still stands only while it is the user's latest
     message; otherwise ask again. Never retry with a guessed token, and never edit `plan.json`.

Notes:

- The delay cannot go below 30 seconds (other apps may hold unsaved work).
- Permission prompts behave as usual in the resumed session (nothing is auto-approved).
- **Scheduled and SDK sessions are never resume targets.** They pile up in the same project folder and
  are often the newest, but only interactive transcripts are candidates — plus this session's own
  just-started transcript (a "sidecar"), and only while it is under ten minutes old.
- If the primary saved folder is missing at logon (a drive that is not connected yet), nothing is launched and
  the state is kept; the terminal says how to run the resume again.
  A missing folder for another session skips that session and logs it; the remaining sessions still open.
- If something goes wrong, the log is `<home>\.claude\claude-session-kit\kit.log` (the prompt body is
  never written to it).
