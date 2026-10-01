# OmagTasks

Google Tasks i Omarchy-baren. Se dine åbne opgaver, tilføj nye, og afkryds dem — uden at forlade tastaturet.

## Opsætning

Pluginet har brug for et Google OAuth-klient-id **og** et client secret. Login foregår med PKCE, og Googles egen dokumentation siger et secret er unødvendigt for "Desktop app"-klienter — men i praksis kræver Googles token-endpoint det alligevel (bekræftet platformskvirk, se [Google-forum-tråd](https://discuss.google.dev/t/desktop-oauth-pkce-exchange-returns-invalid-request-after-successful-loopback-callback-with-no-client-secret/390526)). Uden det fejler login med `invalid_request`.

### 1. Opret et OAuth-klient-id

1. Gå til [Google Cloud Console](https://console.cloud.google.com/) og opret et nyt projekt (eller genbrug et eksisterende).
2. Under **APIs & Services → Library**: find **Google Tasks API** og klik **Enable**.
3. Under **APIs & Services → OAuth consent screen**:
   - Vælg **External** (medmindre du har Google Workspace), udfyld app-navn, support-email osv.
   - Under **Scopes**, tilføj `https://www.googleapis.com/auth/tasks`.
   - Under **Test users**, tilføj din egen Google-konto (så længe appen er i "Testing"-status, er det kun test-brugere der kan logge ind).
4. Under **APIs & Services → Credentials → Create Credentials → OAuth client ID**:
   - Application type: **Desktop app** (ikke "Web application" — den type kan ikke bruge en loopback-redirect på en fast port).
   - Navngiv den fx "OmagTasks".
5. Kopiér det genererede **Client ID** (ser ud som `123456789-abc...apps.googleusercontent.com`) **og** **Client Secret** (vises i samme dialog, eller under klientens detaljer bagefter).

> Google's "Desktop app"-klienter tillader automatisk `http://127.0.0.1:<enhver port>/...` som redirect — du behøver ikke registrere porten separat. Hvis Google alligevel klager over redirect-URI'en, kan du under klientens indstillinger eksplicit tilføje `http://127.0.0.1:8990/callback` (eller den port du har sat i `oauthPort`).

### 2. Indsæt client-id i Omarchy

Åbn pluginets indstillinger i Omarchys bar-widget-opsætning og indsæt client-id og client secret i felterne **"Google OAuth client-id"** og **"Google OAuth client secret"**.

Eller redigér direkte i `~/.config/omarchy/shell.json`: felterne skal ligge **fladt** ved siden af `"id"` i bar-layout-entryen (samme mønster som `omarchy.clock`s `format`-felt), *ikke* nested under en `"settings"`-nøgle:

```json
{
  "id": "io.github.subjektivdk.omagtasks",
  "clientId": "123456789-abc...apps.googleusercontent.com",
  "clientSecret": "GOCSPX-..."
}
```

En manuel redigering af `shell.json` mens shell'en kører bliver ikke altid hot-reloadet ned i allerede-loadede widget-instanser — kør `omarchy restart shell` bagefter for at være sikker.

### 3. Log ind

Klik på ☐-ikonet i baren → **Log ind med Google**. Din browser åbner, du godkender, og en lille lokal side siger "Login gennemført" — den lukker sig selv.

## Hvad pluginet gør

- Viser antal åbne opgaver i baren (☑ 3), opdateret hvert `pollMinutes` minut (standard 5).
- Klik på baren åbner et panel med listen fra din **standard-opgaveliste** (`@default` i Google Tasks).
- Klik på en opgave for at afkrydse/genåbne den.
- Skriv i feltet og tryk Enter (eller klik +) for at tilføje en ny opgave.

## Claude Code skill

[`omagtasks-skill/`](omagtasks-skill) er en [Claude Code](https://claude.com/claude-code)-skill, der bruger samme Google-konto som pluginet. Den lader Claude oprette, vise, afkrydse og slette opgaver fra chatten ("opret opgave: ring til tandlægen i morgen", "hvad har jeg af opgaver"). Link den ind i dine skills, så den opdateres sammen med pluginet:

```bash
ln -s ~/.config/omarchy/plugins/io.github.subjektivdk.omagtasks/omagtasks-skill ~/.claude/skills/omagtasks
```

**Opgradering fra 0.1.0:** mappen hed tidligere `claude-skill/`, så et eksisterende link holder op med at virke efter `omarchy plugin update` (plugin-mapper må ikke indeholde symlinks, så der er intet kompatibilitetslink). Peg det på den nye mappe:

```bash
ln -sfn ~/.config/omarchy/plugins/io.github.subjektivdk.omagtasks/omagtasks-skill ~/.claude/skills/omagtasks
```

## Data og sikkerhed

- Client-id og client secret gemmes i klartekst i `~/.config/omarchy/shell.json` (samme som alle andre plugin-indstillinger). Secretet er reelt ikke fortroligt for en "installed app"-klient som denne — Google kræver det bare teknisk ved token-exchange — men del det ikke unødigt.
- Access-tokens holdes kun i hukommelse.
- Refresh-tokenet gemmes i **GNOME Keyring** via `secret-tool`, aldrig i klartekst på disk.
- OAuth-loginet bruger en midlertidig lokal HTTP-lytter (`scripts/oauth-callback.py`) på `127.0.0.1:<oauthPort>`, som kun lever under selve login-vinduet.

## Begrænsninger (v0.1.0)

- Kun standard-opgavelisten (`@default`) — ikke flere lister.
- Ingen forfaldsdatoer, noter eller underopgaver — kun titel og status.
