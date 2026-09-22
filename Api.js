.pragma library

// Google OAuth2 (installed-app / PKCE) + Tasks REST v1 endpoints, plus the
// small pure-function helpers AuthManager.qml and Panel.qml need. Nothing
// here holds state or touches the network directly — callers own the
// XMLHttpRequest/Process objects, since only they can be cancelled or
// re-entered safely from QML's event loop.

var AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
var TOKEN_URL = "https://oauth2.googleapis.com/token"
var TASKS_BASE = "https://tasks.googleapis.com/tasks/v1"
var SCOPES = ["https://www.googleapis.com/auth/tasks"]

function formBody(fields) {
  var parts = []
  for (var key in fields) {
    if (fields[key] === undefined || fields[key] === null) continue
    parts.push(encodeURIComponent(key) + "=" + encodeURIComponent(String(fields[key])))
  }
  return parts.join("&")
}

function appendQuery(url, params) {
  var query = formBody(params)
  return url + (url.indexOf("?") === -1 ? "?" : "&") + query
}

function parseJson(text, fallback) {
  try { return JSON.parse(String(text || "")) }
  catch (e) { return fallback }
}

// Strips anything token/secret-shaped so an error string stays safe to show
// on screen or paste into a bug report.
function redact(value) {
  return String(value || "").replace(/[A-Za-z0-9_-]{20,}/g, "…")
}

function responseError(status, payload, fallback) {
  var message = ""
  if (payload && payload.error) {
    message = typeof payload.error === "string"
      ? payload.error
      : (payload.error.message || payload.error_description || "")
  }
  return redact(message) || (fallback + " (HTTP " + status + ")")
}

function normalizedPort(value) {
  var port = Math.floor(Number(value))
  return port >= 1024 && port <= 65535 ? port : 8990
}

function decode(value) {
  try { return decodeURIComponent(String(value || "").replace(/\+/g, " ")) }
  catch (e) { return "" }
}

function parseQuery(raw) {
  var result = {}
  var query = String(raw || "")
  if (query.charAt(0) === "?") query = query.substring(1)
  var parts = query.split("&")
  for (var i = 0; i < parts.length; i++) {
    if (!parts[i]) continue
    var separator = parts[i].indexOf("=")
    var key = separator < 0 ? parts[i] : parts[i].substring(0, separator)
    var value = separator < 0 ? "" : parts[i].substring(separator + 1)
    result[decode(key)] = decode(value)
  }
  return result
}

function parseCallbackRequestLine(line, expectedPath) {
  var match = String(line || "").match(/^GET\s+([^\s]+)\s+HTTP\/\d(?:\.\d)?$/)
  if (!match) return { ok: false, error: "Ugyldigt svar fra login-vinduet" }
  var target = match[1]
  var separator = target.indexOf("?")
  var path = separator < 0 ? target : target.substring(0, separator)
  var requiredPath = String(expectedPath || "/callback")
  if (path !== requiredPath) return { ok: false, error: "Uventet callback-sti" }
  var values = parseQuery(separator < 0 ? "" : target.substring(separator + 1))
  if (values.error) return { ok: false, error: values.error_description || values.error, state: values.state || "" }
  if (!values.code) return { ok: false, error: "Google returnerede ingen autorisationskode", state: values.state || "" }
  return { ok: true, code: values.code, state: values.state || "" }
}

function parsePkceOutput(line) {
  var parts = String(line || "").trim().split("\t")
  if (parts.length !== 3) return { ok: false, error: "Kunne ikke oprette PKCE-parametre" }
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(parts[0])) return { ok: false, error: "Ugyldig PKCE verifier" }
  if (!/^[A-Za-z0-9_-]{43,128}$/.test(parts[1])) return { ok: false, error: "Ugyldig PKCE challenge" }
  if (!/^[A-Fa-f0-9]{32,128}$/.test(parts[2])) return { ok: false, error: "Ugyldig OAuth state" }
  return { ok: true, verifier: parts[0], challenge: parts[1], state: parts[2] }
}

function parseTokenResponse(status, text, previousRefreshToken) {
  var payload = parseJson(text, null)
  if (status < 200 || status >= 300 || !payload || !payload.access_token) {
    return {
      ok: false,
      invalidGrant: !!payload && payload.error === "invalid_grant",
      error: responseError(status, payload, "Kunne ikke fuldføre login hos Google. Prøv igen")
    }
  }
  return {
    ok: true,
    accessToken: String(payload.access_token),
    refreshToken: String(payload.refresh_token || previousRefreshToken || ""),
    expiresIn: Math.max(60, Number(payload.expires_in) || 3600),
    scope: String(payload.scope || "")
  }
}

function successResponse() {
  var body = "<!doctype html><meta charset=\"utf-8\"><title>OmagTasks</title>"
    + "<style>:root{color-scheme:light dark}body{font-family:system-ui;background:Canvas;color:CanvasText;display:grid;place-items:center;height:100vh;margin:0}"
    + "main{max-width:32rem;padding:2rem;border:1px solid GrayText;border-radius:.5rem}</style>"
    + "<main><h1>Login gennemført</h1><p>Vender tilbage til OmagTasks…</p>"
    + "<p><small>Du kan lukke denne fane.</small></p></main>"
    + "<script>setTimeout(function(){window.close()},150)</script>"
  return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: "
    + body.length + "\r\nConnection: close\r\n\r\n" + body
}

function failureResponse() {
  var body = "<!doctype html><meta charset=\"utf-8\"><title>Login mislykkedes</title>"
    + "<p>Login mislykkedes. Vend tilbage til Omarchy for detaljer.</p>"
  return "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: "
    + body.length + "\r\nConnection: close\r\n\r\n" + body
}

// ---- Google Tasks REST v1 (single, default task list) ----

function listTasksUrl() {
  return appendQuery(TASKS_BASE + "/lists/@default/tasks", {
    showCompleted: "false",
    showHidden: "false",
    maxResults: "100"
  })
}

function insertTaskUrl() {
  return TASKS_BASE + "/lists/@default/tasks"
}

function taskPatchUrl(taskId) {
  return TASKS_BASE + "/lists/@default/tasks/" + encodeURIComponent(taskId)
}

function parseTaskList(text) {
  var payload = parseJson(text, null)
  var items = payload && Array.isArray(payload.items) ? payload.items : []
  var out = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (!item || !item.id) continue
    out.push({
      id: String(item.id),
      title: String(item.title || "(uden titel)"),
      status: String(item.status || "needsAction"),
      due: String(item.due || ""),
      position: String(item.position || "")
    })
  }
  out.sort(function(a, b) {
    return a.position < b.position ? -1 : (a.position > b.position ? 1 : 0)
  })
  return out
}

// ---- Due-date grouping (headings, newest date first; undated tasks last) ----

var WEEKDAYS_DA = ["søndag", "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag"]
var MONTHS_DA = ["januar", "februar", "marts", "april", "maj", "juni", "juli",
  "august", "september", "oktober", "november", "december"]

// Google's "due" field is a date-only timestamp (always midnight UTC), so the
// ISO date portion alone identifies the day — no timezone conversion needed.
function dueDateKey(due) {
  var match = /^(\d{4}-\d{2}-\d{2})/.exec(String(due || ""))
  return match ? match[1] : ""
}

function formatDueLabel(key) {
  if (!key) return "Ingen dato"
  var parts = key.split("-")
  var year = parseInt(parts[0], 10)
  var month = parseInt(parts[1], 10)
  var day = parseInt(parts[2], 10)
  var date = new Date(year, month - 1, day)
  return WEEKDAYS_DA[date.getDay()] + " " + day + ". " + MONTHS_DA[month - 1] + " " + year
}

function groupTasksByDue(tasks) {
  var byKey = {}
  var order = []
  for (var i = 0; i < tasks.length; i++) {
    var key = dueDateKey(tasks[i].due)
    if (!(key in byKey)) { byKey[key] = []; order.push(key) }
    byKey[key].push(tasks[i])
  }
  // Soonest due date first (nearest upcoming at top); undated tasks ("")
  // always sort last.
  order.sort(function(a, b) {
    if (a === "") return 1
    if (b === "") return -1
    return a < b ? -1 : (a > b ? 1 : 0)
  })
  return order.map(function(key) {
    return { key: key || "none", label: formatDueLabel(key), items: byKey[key] }
  })
}
