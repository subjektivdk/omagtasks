import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api

// OAuth and token storage live here so the rest of the plugin never needs to
// know what a refresh token looks like. Access tokens exist only in memory;
// refresh tokens cross the process boundary over stdin and are persisted by
// GNOME Keyring.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir
  property string clientId: ""
  // Google now auto-generates a secret even for "Desktop app" clients and
  // requires it at the token endpoint despite PKCE, contrary to their own
  // docs (confirmed on Google's developer forums, 2025+). Sent only to
  // Google's token endpoint, never to the authorization URL.
  property string clientSecret: ""
  property int oauthPort: 8990
  property string callbackPath: "/callback"
  property var scopes: Api.SCOPES
  readonly property string redirectUri: "http://127.0.0.1:"
    + Api.normalizedPort(oauthPort) + callbackPath

  property string accessToken: ""
  property double accessTokenExpiresAt: 0
  property bool loggedIn: false
  property bool sessionChecked: false
  property bool loginBusy: false
  property bool refreshBusy: false
  readonly property bool sessionBusy: refreshBusy || secretLookup.running
  property string lastError: ""

  property var tokenWaiters: []
  property string lookupPurpose: ""
  property bool lookupHandled: false
  property string keyringWriteToken: ""
  property string pendingKeyringWrite: ""

  property string pkceVerifier: ""
  property string pkceChallenge: ""
  property string oauthState: ""
  property bool callbackHandled: false
  property bool exchangingCode: false
  property var tokenRequest: null
  property int tokenRequestSerial: 0
  property bool logoutPendingClear: false

  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)

  function safeError(value) {
    return Api.redact(String(value || ""))
  }

  function tokenIsFresh() {
    return accessToken !== "" && Date.now() + 60000 < accessTokenExpiresAt
  }

  function resetMemorySession() {
    accessToken = ""
    accessTokenExpiresAt = 0
    loggedIn = false
  }

  function invalidateAccessToken() {
    accessToken = ""
    accessTokenExpiresAt = 0
  }

  function finishWaiters(token, error) {
    var pending = tokenWaiters.slice()
    tokenWaiters = []
    for (var i = 0; i < pending.length; i++) {
      try { pending[i](token || "", safeError(error)) }
      catch (e) { /* consumers own their callback errors */ }
    }
  }

  function withAccessToken(callback) {
    if (typeof callback !== "function") return
    if (!clientId) { callback("", "Add a Google OAuth client ID in the plugin settings"); return }
    if (tokenIsFresh()) {
      callback(accessToken, "")
      return
    }

    var next = tokenWaiters.slice()
    next.push(callback)
    tokenWaiters = next
    if (refreshBusy || secretLookup.running) return

    lookupPurpose = "request"
    startSecretLookup()
  }

  function restoreSession() {
    if (!clientId) { sessionChecked = true; return }
    sessionChecked = false
    if (secretLookup.running || refreshBusy) return
    lookupPurpose = "restore"
    startSecretLookup()
  }

  function startSecretLookup() {
    lookupHandled = false
    secretLookup.command = [
      "secret-tool", "lookup",
      "service", "omagtasks",
      "kind", "refresh-token",
      "client-id", String(clientId)
    ]
    secretLookup.running = true
  }

  function handleSecretLookup(raw) {
    if (lookupHandled) return
    lookupHandled = true
    var token = String(raw || "").trim()
    var purpose = lookupPurpose
    lookupPurpose = ""
    if (!token) {
      resetMemorySession()
      sessionChecked = true
      // Always resolve any queued withAccessToken() callbacks, even if this
      // particular lookup started as a plain restoreSession(): a caller can
      // queue behind an in-flight restore lookup (withAccessToken sees
      // secretLookup.running and just appends), and gating this on
      // purpose === "request" left those callbacks — and loadBusy/addBusy —
      // stuck forever when restore found nothing.
      finishWaiters("", "Sign in with Google first")
      return
    }
    refreshWithToken(token, purpose)
  }

  function postTokenRequest(body, previousRefreshToken, callback) {
    var serial = ++tokenRequestSerial
    var request = new XMLHttpRequest()
    tokenRequest = request
    request.onreadystatechange = function() {
      if (request.readyState !== XMLHttpRequest.DONE) return
      if (serial !== root.tokenRequestSerial) return
      if (root.tokenRequest === request) root.tokenRequest = null
      var result = Api.parseTokenResponse(request.status, request.responseText,
        previousRefreshToken)
      if (typeof callback === "function") callback(result)
    }
    request.open("POST", Api.TOKEN_URL)
    request.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
    request.send(body)
  }

  function refreshWithToken(refreshToken, purpose) {
    refreshBusy = true
    postTokenRequest(Api.formBody({
      client_id: clientId,
      client_secret: clientSecret || undefined,
      grant_type: "refresh_token",
      refresh_token: refreshToken
    }), refreshToken, function(result) {
      refreshToken = ""
      root.refreshBusy = false
      root.sessionChecked = true
      if (!result.ok) {
        root.resetMemorySession()
        root.lastError = root.safeError(result.error)
        if (result.invalidGrant) root.clearStoredToken()
        // Same reasoning as handleSecretLookup: a waiter can be queued
        // behind an in-flight restore/refresh regardless of what purpose
        // started it, so it must always be resolved here.
        root.finishWaiters("", root.lastError)
        if (purpose !== "request") root.sessionUnavailable(root.lastError)
        return
      }
      root.acceptToken(result)
      root.finishWaiters(root.accessToken, "")
    })
  }

  function acceptToken(result) {
    accessToken = result.accessToken
    accessTokenExpiresAt = Date.now() + result.expiresIn * 1000
    loggedIn = true
    lastError = ""
    if (result.refreshToken) storeRefreshToken(result.refreshToken)
  }

  function storeRefreshToken(refreshToken) {
    if (!refreshToken) return
    // A rotated token arriving while the previous write is still in flight
    // must not be dropped — Google may have already invalidated the old
    // one, so losing this write would silently break the next restore.
    // Stash it; keyringStore.onExited flushes it once the write completes.
    if (keyringStore.running) { pendingKeyringWrite = String(refreshToken); return }
    keyringWriteToken = String(refreshToken)
    keyringStore.command = [pluginDir + "/scripts/keyring-store.sh", String(clientId)]
    keyringStore.running = true
  }

  function clearStoredToken() {
    if (keyringClear.running) return
    keyringClear.command = [
      "secret-tool", "clear",
      "service", "omagtasks",
      "kind", "refresh-token",
      "client-id", String(clientId)
    ]
    keyringClear.running = true
  }

  function logout() {
    cancelLogin()
    resetMemorySession()
    sessionChecked = true
    lastError = ""
    finishWaiters("", "Signed out")
    if (keyringStore.running) logoutPendingClear = true
    else clearStoredToken()
    loggedOut()
  }

  function beginLogin() {
    if (loginBusy || refreshBusy || !clientId) return
    lastError = ""
    loginBusy = true
    callbackHandled = false
    exchangingCode = false
    pkceGenerator.command = [pluginDir + "/scripts/pkce.sh"]
    pkceGenerator.running = true
  }

  function handlePkce(raw) {
    if (!loginBusy || pkceVerifier !== "") return
    var result = Api.parsePkceOutput(raw)
    if (!result.ok) {
      failLogin("Couldn't start a secure Google sign-in. Try again")
      return
    }
    pkceVerifier = result.verifier
    pkceChallenge = result.challenge
    oauthState = result.state
    callbackListener.command = [
      pluginDir + "/scripts/oauth-callback.py",
      "--port", String(Api.normalizedPort(oauthPort)),
      "--path", String(callbackPath),
      "--timeout", "180"
    ]
    callbackListener.running = true
    authTimeout.restart()
  }

  function openAuthorizationPage() {
    if (!loginBusy || callbackHandled || pkceChallenge === "") return
    var url = Api.appendQuery(Api.AUTH_URL, {
      client_id: clientId,
      code_challenge: pkceChallenge,
      code_challenge_method: "S256",
      redirect_uri: redirectUri,
      response_type: "code",
      scope: (Array.isArray(scopes) ? scopes : Api.SCOPES).join(" "),
      state: oauthState,
      access_type: "offline",
      prompt: "consent"
    })
    Quickshell.execDetached(["xdg-open", url])
  }

  function handleCallbackLine(rawLine) {
    if (!loginBusy || callbackHandled) return
    var line = String(rawLine || "").replace(/\r$/, "")
    if (line.indexOf("GET ") !== 0) return
    callbackHandled = true
    authTimeout.stop()
    var callback = Api.parseCallbackRequestLine(line, callbackPath)
    if (!callback.ok || callback.state !== oauthState) {
      callbackListener.write(Qt.btoa(Api.failureResponse()) + "\n")
      callbackStopTimer.restart()
      failLogin(callback.ok
        ? "Couldn't verify the Google sign-in. Try again"
        : callback.error, true)
      return
    }
    callbackListener.write(Qt.btoa(Api.successResponse()) + "\n")
    callbackStopTimer.restart()
    exchangeAuthorizationCode(callback.code)
  }

  function exchangeAuthorizationCode(code) {
    exchangingCode = true
    var verifier = pkceVerifier
    var requestBody = Api.formBody({
      client_id: clientId,
      client_secret: clientSecret || undefined,
      code: code,
      code_verifier: verifier,
      grant_type: "authorization_code",
      redirect_uri: redirectUri
    })
    code = ""
    verifier = ""
    clearPkce()

    postTokenRequest(requestBody, "", function(result) {
      root.exchangingCode = false
      root.loginBusy = false
      if (!result.ok) {
        root.lastError = root.safeError(result.error)
        root.sessionUnavailable(root.lastError)
        return
      }
      root.acceptToken(result)
      root.sessionChecked = true
      root.finishWaiters(root.accessToken, "")
      root.loginSucceeded()
    })
    requestBody = ""
  }

  function clearPkce() {
    pkceVerifier = ""
    pkceChallenge = ""
    oauthState = ""
  }

  function failLogin(reason, listenerAlreadyAnswered) {
    lastError = safeError(reason || "Google sign-in failed. Try again")
    loginBusy = false
    exchangingCode = false
    authTimeout.stop()
    authOpenDelay.stop()
    if (!listenerAlreadyAnswered && callbackListener.running) callbackListener.running = false
    clearPkce()
    sessionUnavailable(lastError)
  }

  function cancelLogin() {
    authTimeout.stop()
    authOpenDelay.stop()
    callbackStopTimer.stop()
    if (callbackListener.running) callbackListener.running = false
    if (pkceGenerator.running) pkceGenerator.running = false
    tokenRequestSerial++
    if (tokenRequest && tokenRequest.abort) tokenRequest.abort()
    tokenRequest = null
    refreshBusy = false
    loginBusy = false
    exchangingCode = false
    callbackHandled = false
    clearPkce()
  }

  onClientIdChanged: {
    cancelLogin()
    resetMemorySession()
    sessionChecked = false
    restoreSession()
  }

  Timer {
    id: authOpenDelay
    interval: 120
    onTriggered: root.openAuthorizationPage()
  }

  Timer {
    id: callbackStopTimer
    interval: 250
    onTriggered: if (callbackListener.running) callbackListener.running = false
  }

  Timer {
    id: authTimeout
    interval: 180000
    onTriggered: root.failLogin("Google sign-in took too long. Try again")
  }

  Process {
    id: pkceGenerator
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handlePkce(line) }
    }
    onExited: function(exitCode) {
      if (root.loginBusy && root.pkceVerifier === "" && exitCode !== 0)
        root.failLogin("Couldn't start a secure Google sign-in. Try again")
    }
  }

  Process {
    id: callbackListener
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleCallbackLine(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: authOpenDelay.restart()
    onExited: function(exitCode) {
      if (root.loginBusy && !root.callbackHandled && !root.exchangingCode)
        root.failLogin(exitCode === 0
          ? "The sign-in window closed before it finished"
          : "Couldn't complete Google sign-in. Close other sign-in windows and try again")
    }
  }

  Process {
    id: secretLookup
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleSecretLookup(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (!root.lookupHandled) root.handleSecretLookup("")
    }
  }

  Process {
    id: keyringStore
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.keyringWriteToken + "\n")
      root.keyringWriteToken = ""
    }
    onExited: function(exitCode) {
      root.keyringWriteToken = ""
      if (exitCode !== 0)
        root.lastError = "Connected to Google, but the session couldn't be stored securely. You may need to sign in again after a restart"
      if (root.logoutPendingClear) {
        root.logoutPendingClear = false
        root.pendingKeyringWrite = ""
        root.clearStoredToken()
      } else if (root.pendingKeyringWrite !== "") {
        var next = root.pendingKeyringWrite
        root.pendingKeyringWrite = ""
        root.storeRefreshToken(next)
      }
    }
  }

  Process {
    id: keyringClear
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  // A listener left running holds the port and keeps waiting on loopback.
  Component.onDestruction: {
    authTimeout.stop()
    callbackStopTimer.stop()
    if (callbackListener.running) callbackListener.running = false
  }
}
