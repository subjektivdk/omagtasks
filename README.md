# omagtasks

Google Tasks in the Omarchy bar. See your open tasks, add new ones and check them off — without leaving the keyboard.

## Setup

The plugin needs a Google OAuth client ID **and** a client secret. Sign-in uses PKCE, and Google's own documentation says a secret isn't needed for "Desktop app" clients — but in practice Google's token endpoint requires it anyway (a confirmed platform quirk, see this [Google forum thread](https://discuss.google.dev/t/desktop-oauth-pkce-exchange-returns-invalid-request-after-successful-loopback-callback-with-no-client-secret/390526)). Without it, sign-in fails with `invalid_request`.

### 1. Create an OAuth client ID

1. Go to [Google Cloud Console](https://console.cloud.google.com/) and create a new project (or reuse an existing one).
2. Under **APIs & Services → Library**: find **Google Tasks API** and click **Enable**.
3. Under **APIs & Services → OAuth consent screen**:
   - Choose **External** (unless you have Google Workspace) and fill in the app name, support email and so on.
   - Under **Scopes**, add `https://www.googleapis.com/auth/tasks`.
   - Under **Test users**, add your own Google account (while the app is in "Testing" status, only test users can sign in).
4. Under **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Desktop app** (not "Web application" — that type can't use a loopback redirect on a fixed port).
   - Name it, for example, "omagtasks".
5. Copy the generated **Client ID** (it looks like `123456789-abc...apps.googleusercontent.com`) **and** the **Client Secret** (shown in the same dialog, or in the client's details afterwards).

> Google's "Desktop app" clients automatically allow `http://127.0.0.1:<any port>/...` as a redirect — you don't need to register the port separately. If Google still complains about the redirect URI, you can explicitly add `http://127.0.0.1:8990/callback` (or the port you set in `oauthPort`) in the client's settings.

### 2. Add the client ID in Omarchy

Open the plugin's settings in Omarchy's bar widget setup and paste the client ID and client secret into the **"Google OAuth client ID"** and **"Google OAuth client secret"** fields.

Or edit `~/.config/omarchy/shell.json` directly: the fields go **flat** next to `"id"` in the bar layout entry (the same pattern as `omarchy.clock`'s `format` field), *not* nested under a `"settings"` key:

```json
{
  "id": "io.github.subjektivdk.omagtasks",
  "clientId": "123456789-abc...apps.googleusercontent.com",
  "clientSecret": "GOCSPX-..."
}
```

A manual edit of `shell.json` while the shell is running isn't always hot-reloaded into widget instances that are already loaded — run `omarchy restart shell` afterwards to be sure.

### 3. Sign in

Click the ☐ icon in the bar → **Sign in with Google**. Your browser opens, you approve, and a small local page says "Signed in" — it closes itself.

## What the plugin does

- Shows the number of open tasks in the bar (☑ 3), refreshed every `pollMinutes` minutes (default 5).
- Clicking the bar opens a panel with the tasks from your **default task list** (`@default` in Google Tasks), grouped by due date.
- Click a task to check it off or reopen it.
- Tasks completed in the last 30 days sit at the bottom under **Completed**, collapsed by default. Expand it with + to see them with the most recently completed first and the date on the right. Click one to reopen it.
- Type in the field and press Enter (or click +) to add a new task.

## Claude Code skill

[`omagtasks-skill/`](omagtasks-skill) is a [Claude Code](https://claude.com/claude-code) skill that uses the same Google account as the plugin. It lets Claude create, list, check off and delete tasks from chat, in English or Danish ("add a task: call the dentist tomorrow", "opret opgave: ring til tandlægen i morgen", "hvad har jeg af opgaver"). Link it into your skills so it updates together with the plugin:

```bash
ln -s ~/.config/omarchy/plugins/io.github.subjektivdk.omagtasks/omagtasks-skill ~/.claude/skills/omagtasks
```

**Upgrading from 0.1.0:** the folder used to be called `claude-skill/`, so an existing link stops working after `omarchy plugin update` (plugin folders can't contain symlinks, so there is no compatibility link). Point it at the new folder:

```bash
ln -sfn ~/.config/omarchy/plugins/io.github.subjektivdk.omagtasks/omagtasks-skill ~/.claude/skills/omagtasks
```

## Data and security

- The client ID and client secret are stored in plain text in `~/.config/omarchy/shell.json` (like every other plugin setting). The secret isn't really confidential for an "installed app" client like this one — Google just requires it technically at token exchange — but don't share it unnecessarily.
- Access tokens are only kept in memory.
- The refresh token is stored in **GNOME Keyring** via `secret-tool`, never in plain text on disk.
- OAuth sign-in uses a temporary local HTTP listener (`scripts/oauth-callback.py`) on `127.0.0.1:<oauthPort>` that only lives for the duration of the sign-in window.

## Limitations (v0.2.0)

- Only the default task list (`@default`) — not multiple lists.
- New tasks get a title only: no due date, notes or subtasks from the panel. Due dates set elsewhere are shown as groups.
