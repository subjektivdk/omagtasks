import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "Api.js" as Api

Panel {
  id: root
  moduleName: "io.github.subjektivdk.omagtasks"
  ipcTarget: "io.github.subjektivdk.omagtasks"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property string pluginDir: ""

  function open() {
    root.controller.show()
    // Always refetch on open, not just when stale: opening the panel is a
    // deliberate look-at-it action, and out-of-band changes (chat-created
    // tasks, edits in the Google Tasks app) should never look stale here.
    root.refresh()
  }

  function openFromHotkey() {
    root.open()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- Settings (manifest-backed: clientId, oauthPort, pollMinutes) ----
  readonly property string clientId: String(root.setting("clientId", "")).trim()
  readonly property string clientSecret: String(root.setting("clientSecret", "")).trim()
  readonly property int oauthPort: Api.normalizedPort(root.setting("oauthPort", 8990))
  readonly property int pollMinutes: Math.max(1, Math.min(60,
    Math.floor(Number(root.setting("pollMinutes", 5)) || 5)))

  // ---- Task state ----
  property var tasks: []
  readonly property int openCount: {
    var n = 0
    for (var i = 0; i < root.tasks.length; i++)
      if (root.tasks[i].status !== "completed") n++
    return n
  }
  readonly property bool loggedIn: auth.loggedIn
  // Completed tasks are hidden rather than shown struck-through: the API
  // fetch already excludes them (showCompleted=false), and this filter
  // makes a just-checked task disappear immediately rather than waiting
  // for the next poll to drop it.
  readonly property var groupedTasks: root.loggedIn
    ? Api.groupTasksByDue(root.tasks.filter(function(t) { return t.status !== "completed" }))
    : []
  property bool loadBusy: false
  property string loadError: ""
  property string newTaskText: ""
  property bool addBusy: false

  AuthManager {
    id: auth
    pluginDir: root.pluginDir
    clientId: root.clientId
    clientSecret: root.clientSecret
    oauthPort: root.oauthPort
    onLoginSucceeded: root.refresh()
    onSessionUnavailable: function(reason) { root.loadError = reason }
  }

  function refresh() {
    if (!root.clientId) {
      root.loadError = "Indsæt et Google OAuth-klient-id i pluginets indstillinger"
      return
    }
    if (root.loadBusy) return
    root.loadBusy = true
    auth.withAccessToken(function(token, err) {
      if (!token) {
        root.loadBusy = false
        root.loadError = err || "Ikke logget ind"
        return
      }
      var req = new XMLHttpRequest()
      req.onreadystatechange = function() {
        if (req.readyState !== XMLHttpRequest.DONE) return
        root.loadBusy = false
        if (req.status < 200 || req.status >= 300) {
          root.loadError = Api.responseError(req.status, Api.parseJson(req.responseText, null),
            "Kunne ikke hente opgaver")
          return
        }
        root.tasks = Api.parseTaskList(req.responseText)
        root.loadError = ""
      }
      req.open("GET", Api.listTasksUrl())
      req.setRequestHeader("Authorization", "Bearer " + token)
      req.send()
    })
  }

  function addTask() {
    var title = String(root.newTaskText || "").trim()
    if (!title || root.addBusy) return
    root.addBusy = true
    auth.withAccessToken(function(token, err) {
      if (!token) {
        root.addBusy = false
        root.loadError = err || "Ikke logget ind"
        return
      }
      var req = new XMLHttpRequest()
      req.onreadystatechange = function() {
        if (req.readyState !== XMLHttpRequest.DONE) return
        root.addBusy = false
        if (req.status < 200 || req.status >= 300) {
          root.loadError = Api.responseError(req.status, Api.parseJson(req.responseText, null),
            "Kunne ikke oprette opgave")
          return
        }
        root.newTaskText = ""
        root.refresh()
      }
      req.open("POST", Api.insertTaskUrl())
      req.setRequestHeader("Authorization", "Bearer " + token)
      req.setRequestHeader("Content-Type", "application/json")
      req.send(JSON.stringify({ title: title }))
    })
  }

  function toggleTaskDone(task) {
    var nextStatus = task.status === "completed" ? "needsAction" : "completed"
    // Optimistic local flip so the checkbox responds immediately; a failed
    // PATCH below falls back to a full refresh rather than trying to undo it.
    var next = []
    for (var i = 0; i < root.tasks.length; i++) {
      var item = root.tasks[i]
      next.push(item.id === task.id
        ? { id: item.id, title: item.title, status: nextStatus, due: item.due, position: item.position }
        : item)
    }
    root.tasks = next

    auth.withAccessToken(function(token, err) {
      if (!token) { root.refresh(); return }
      var req = new XMLHttpRequest()
      req.onreadystatechange = function() {
        if (req.readyState !== XMLHttpRequest.DONE) return
        if (req.status < 200 || req.status >= 300) root.refresh()
      }
      req.open("PATCH", Api.taskPatchUrl(task.id))
      req.setRequestHeader("Authorization", "Bearer " + token)
      req.setRequestHeader("Content-Type", "application/json")
      req.send(JSON.stringify({ status: nextStatus }))
    })
  }

  onLoggedInChanged: if (root.loggedIn) root.refresh()
  Component.onCompleted: auth.restoreSession()

  // A task created out-of-band (e.g. via the Google Tasks API directly,
  // bypassing this plugin's own UI) doesn't touch root.tasks, so the bar
  // count and panel stay stale until the next poll. This lets that be
  // forced on demand: `omarchy-shell shell io.github.subjektivdk.omagtasks
  // refresh` — without restarting the whole shell.
  IpcHandler {
    target: "io.github.subjektivdk.omagtasks"
    function refresh(): void { root.refresh() }
  }

  Timer {
    interval: root.pollMinutes * 60000
    running: root.loggedIn
    repeat: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: taskScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: taskScroll.width
          spacing: Style.space(10)

          // ---- Header ----
          Item {
            width: parent.width
            height: headerRow.implicitHeight + Style.space(12)

            Row {
              id: headerRow
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "OmagTasks"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            Rectangle {
              id: refreshButton
              width: Style.space(26)
              height: Style.space(26)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              radius: Style.cornerRadius
              visible: root.loggedIn
              color: refreshArea.containsMouse && !root.loadBusy
                ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.loadBusy ? "…" : "↻"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body

                RotationAnimator on rotation {
                  running: root.loadBusy
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                id: refreshArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.loadBusy
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refresh()
              }
            }
          }

          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          // ---- Not configured ----
          Text {
            visible: root.clientId === ""
            x: Style.space(16)
            width: parent.width - Style.space(32)
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Indsæt et Google OAuth-klient-id i pluginets indstillinger for at komme i gang (se README.md i plugin-mappen)."
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- Login ----
          Rectangle {
            visible: root.clientId !== "" && !root.loggedIn
            x: Style.space(16)
            width: loginLabel.implicitWidth + Style.space(20)
            height: loginLabel.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            border.width: 1
            border.color: Qt.darker(root.bar.foreground, 1.3)
            color: loginArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

            Text {
              id: loginLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: auth.loginBusy ? "Logger ind…" : "Log ind med Google"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            MouseArea {
              id: loginArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              enabled: !auth.loginBusy
              onClicked: auth.beginLogin()
            }
          }

          // ---- Log out (small link under the list, once logged in) ----
          Text {
            visible: root.loggedIn
            x: Style.space(16)
            textFormat: Text.PlainText
            text: "Log ud"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: logoutArea.containsMouse

            MouseArea {
              id: logoutArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { auth.logout(); root.tasks = [] }
            }
          }

          // ---- Error ----
          Text {
            visible: root.loadError !== ""
            x: Style.space(16)
            width: parent.width - Style.space(32)
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.loadError
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Add task ----
          Row {
            visible: root.loggedIn
            x: Style.space(16)
            width: parent.width - Style.space(32)
            spacing: Style.space(8)

            Rectangle {
              id: inputBox
              width: parent.width - addButton.width - parent.spacing
              height: Style.space(28)
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: Qt.darker(root.bar.foreground, 1.3)

              TextInput {
                id: newTaskField
                anchors.fill: parent
                anchors.margins: Style.space(6)
                clip: true
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                text: root.newTaskText
                onTextChanged: root.newTaskText = text
                onAccepted: root.addTask()
              }

              Text {
                visible: newTaskField.text === ""
                anchors.left: newTaskField.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Ny opgave…"
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Rectangle {
              id: addButton
              width: Style.space(28)
              height: Style.space(28)
              radius: Style.cornerRadius
              color: addArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"
              border.width: 1
              border.color: Qt.darker(root.bar.foreground, 1.3)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.addBusy ? "…" : "+"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: addArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !root.addBusy
                cursorShape: Qt.PointingHandCursor
                onClicked: root.addTask()
              }
            }
          }

          // ---- Task list, grouped by due date (newest date first) ----
          Repeater {
            model: root.groupedTasks

            Column {
              id: groupColumn
              required property var modelData
              width: parent.width
              spacing: Style.space(2)

              Text {
                x: Style.space(16)
                textFormat: Text.PlainText
                text: groupColumn.modelData.label.toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              Repeater {
                model: groupColumn.modelData.items

                Rectangle {
                  id: taskRow
                  required property var modelData
                  width: parent.width
                  height: taskRowContent.implicitHeight + Style.space(10)
                  radius: Style.cornerRadius
                  color: taskArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                  Row {
                    id: taskRowContent
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(16)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(16)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      textFormat: Text.PlainText
                      text: taskRow.modelData.status === "completed" ? "■" : "□"
                      color: taskRow.modelData.status === "completed"
                        ? Color.accent : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: taskRow.modelData.title
                      wrapMode: Text.WordWrap
                      width: taskRowContent.width - Style.space(24)
                      color: taskRow.modelData.status === "completed"
                        ? Qt.darker(root.bar.foreground, 1.5) : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      font.strikeout: taskRow.modelData.status === "completed"
                    }
                  }

                  MouseArea {
                    id: taskArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleTaskDone(taskRow.modelData)
                  }
                }
              }
            }
          }

          Text {
            visible: root.loggedIn && root.tasks.length === 0 && !root.loadBusy && root.loadError === ""
            x: Style.space(16)
            textFormat: Text.PlainText
            text: "Ingen opgaver 🎉"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }
        }
      }
    }
  }
}
