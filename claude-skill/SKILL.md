---
name: omagtasks
description: Create, list, or complete tasks in the user's Google Tasks (via the OmagTasks Omarchy plugin) directly from chat. Use when the user asks to create/add/opret a task or opgave, list open tasks, or mark one done, in Danish or English (e.g. "opret task: hent pakke i dag kl 10", "opret opgave...", "add a task...", "hvad har jeg af opgaver").
---

# OmagTasks

Lets you create, list, and complete tasks in the user's Google Tasks default list without leaving chat. Backs the same account the OmagTasks Omarchy bar plugin (`~/.config/omarchy/plugins/io.github.subjektivdk.omagtasks/`) uses — credentials are read live from `~/.config/omarchy/shell.json` and the GNOME Keyring refresh token, nothing is duplicated here.

## Commands

All via `~/.claude/skills/omagtasks/bin/omagtasks.sh`:

- `omagtasks.sh create "<title>" [YYYY-MM-DD] [notes]` — creates a task and refreshes the bar widget. Date and notes are optional.
- `omagtasks.sh list` — lists open (non-completed) tasks as `due<TAB>title<TAB>id`, sorted by due date.
- `omagtasks.sh complete <task-id>` — marks a task done and refreshes the bar widget.
- `omagtasks.sh delete <task-id>` — permanently deletes a task and refreshes the bar widget. Confirm with the user before deleting anything that isn't an obvious test/throwaway task.
- `omagtasks.sh refresh` — forces the bar widget to refetch without a shell restart (use after any change made outside the widget itself).

## Creating a task from a natural-language request

The user will phrase this conversationally, in Danish or English, e.g.:
- "opret task: hent pakke i dag kl 10"
- "opret opgave: test plugin i dag kl 10"
- "tilføj opgave: ring til tandlægen i morgen"
- "add a task to call the dentist next Tuesday"

Parse it yourself before calling the script:
1. **Title** — the task text with any date/time phrase stripped out. Keep it short and in the user's own words; don't editorialize.
2. **Due date** — resolve relative phrases ("i dag", "i morgen", "på tirsdag", "næste uge") against today's actual date (check with `date +%F` — don't guess or use a training-data date). Pass as `YYYY-MM-DD`. Omit entirely if no date was given — don't invent one.
3. **Time** — Google Tasks' `due` field is date-only; any clock time ("kl. 10", "kl 14:30") goes in the `notes` argument instead, e.g. `"Kl. 10:00"`. Omit `notes` if no time was given.

Example: "opret task: hent pakke i dag kl. 10" with today = 2026-09-22 becomes:
```bash
~/.claude/skills/omagtasks/bin/omagtasks.sh create "Hent pakke" 2026-09-22 "Kl. 10:00"
```

After creating, tell the user what was created in one line (title + date/time if any) — the script already refreshes the bar, so there's no need to mention that mechanic unless something failed.

## Completing a task

If the user names a task to complete/check off, run `omagtasks.sh list` first to find its id (match on title), then `omagtasks.sh complete <id>`.

## Errors

- `no stored refresh token` — the user isn't logged in yet; tell them to open the OmagTasks panel from the bar and click "Log ind med Google".
- Any other curl/HTTP failure — show the raw error; don't guess at a fix silently.
