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
  // root.tasks holds open and completed tasks together. Open ones are
  // grouped by due date; completed ones go in the "Completed" section at the
  // bottom, so a checked task moves there immediately instead of waiting
  // for the next poll.
  readonly property var groupedTasks: root.loggedIn
    ? Api.groupTasksByDue(root.tasks.filter(function(t) { return t.status !== "completed" }))
    : []
  readonly property var completedTasks: root.loggedIn ? Api.completedTasks(root.tasks) : []
  // Collapsed by default, like dr-lyd's regional groups. Kept in memory
  // only, so it starts collapsed again after a shell restart.
  property bool completedExpanded: false
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
      root.loadError = "Add a Google OAuth client ID in the plugin settings"
      return
    }
    if (root.loadBusy) return
    root.loadBusy = true
    auth.withAccessToken(function(token, err) {
      if (!token) {
        root.loadBusy = false
        root.loadError = err || "Not signed in"
        return
      }
      // Open and completed tasks are fetched in parallel and only applied
      // once both have answered, so the list never shows one half.
      var results = {}
      var pending = 2
      var failed = ""
      function fetchList(key, url) {
        var req = new XMLHttpRequest()
        req.onreadystatechange = function() {
          if (req.readyState !== XMLHttpRequest.DONE) return
          if (req.status < 200 || req.status >= 300) {
            failed = failed || Api.responseError(req.status, Api.parseJson(req.responseText, null),
              "Couldn't load tasks")
          } else {
            results[key] = Api.parseTaskList(req.responseText)
          }
          if (--pending > 0) return
          root.loadBusy = false
          if (failed) { root.loadError = failed; return }
          root.tasks = results.open.concat(results.completed.filter(function(t) {
            return t.status === "completed"
          }))
          root.loadError = ""
        }
        req.open("GET", url)
        req.setRequestHeader("Authorization", "Bearer " + token)
        req.send()
      }
      fetchList("open", Api.listTasksUrl())
      fetchList("completed", Api.listCompletedTasksUrl(Date.now()))
    })
  }

  function addTask() {
    var title = String(root.newTaskText || "").trim()
    if (!title || root.addBusy) return
    root.addBusy = true
    auth.withAccessToken(function(token, err) {
      if (!token) {
        root.addBusy = false
        root.loadError = err || "Not signed in"
        return
      }
      var req = new XMLHttpRequest()
      req.onreadystatechange = function() {
        if (req.readyState !== XMLHttpRequest.DONE) return
        root.addBusy = false
        if (req.status < 200 || req.status >= 300) {
          root.loadError = Api.responseError(req.status, Api.parseJson(req.responseText, null),
            "Couldn't create task")
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
        ? { id: item.id, title: item.title, status: nextStatus, due: item.due,
            completed: nextStatus === "completed" ? new Date().toISOString() : "",
            position: item.position }
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
                text: "omagtasks"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.loggedIn
              iconText: "󰑐"
              tooltipText: root.loadBusy ? "Refreshing…" : "Refresh"
              enabled: !root.loadBusy
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.refresh()
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
            text: "Add a Google OAuth client ID in the plugin settings to get started (see README.md in the plugin folder)."
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
              text: auth.loginBusy ? "Signing in…" : "Sign in with Google"
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
            text: "Sign out"
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
                text: "New task…"
                color: Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            PanelActionButton {
              id: addButton
              size: inputBox.height
              bordered: true
              iconText: "󰐕"
              tooltipText: root.addBusy ? "Adding…" : "Add task"
              enabled: !root.addBusy
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.addTask()
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
                TaskRow {}
              }
            }
          }

          Text {
            visible: root.loggedIn && root.openCount === 0 && !root.loadBusy && root.loadError === ""
            x: Style.space(16)
            textFormat: Text.PlainText
            text: "No tasks 🎉"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Completed, newest completion first; collapsed by default ----
          Column {
            visible: root.completedTasks.length > 0
            width: parent.width
            spacing: Style.space(2)

            Rectangle {
              width: parent.width
              height: Style.spacing.hairline
              color: root.bar.foreground
              opacity: 0.12
            }

            Item {
              width: parent.width
              height: Math.max(completedLabel.implicitHeight, completedToggle.implicitHeight) + Style.space(4)

              Text {
                id: completedLabel
                x: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "COMPLETED" + (root.completedExpanded ? "" : " (" + root.completedTasks.length + ")")
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.completedExpanded = !root.completedExpanded
              }

              PanelActionButton {
                id: completedToggle
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.completedExpanded ? "󰍴" : "󰐕"
                tooltipText: root.completedExpanded ? "Collapse" : "Expand"
                foreground: Qt.darker(root.bar.foreground, 1.4)
                hoverColor: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.completedExpanded = !root.completedExpanded
              }
            }

            Repeater {
              model: root.completedExpanded ? root.completedTasks : []
              TaskRow { showCompletedDate: true }
            }
          }
        }
      }
    }
  }

  // One task: checkbox, title and (in "Completed") the completion date.
  // Clicking toggles it between open and completed.
  component TaskRow: Rectangle {
    id: taskRow
    required property var modelData
    property bool showCompletedDate: false
    readonly property bool done: modelData.status === "completed"
    width: parent ? parent.width : 0
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
        text: taskRow.done ? "󰄲" : "󰄱"
        color: taskRow.done ? Color.accent : root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        textFormat: Text.PlainText
        text: taskRow.modelData.title
        wrapMode: Text.WordWrap
        width: taskRowContent.width - Style.space(24)
          - (completedDate.visible ? completedDate.implicitWidth + Style.space(8) : 0)
        color: taskRow.done ? Qt.darker(root.bar.foreground, 1.5) : root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: taskRow.done
      }
    }

    Text {
      id: completedDate
      visible: taskRow.showCompletedDate && text !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.space(16)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: Api.formatCompletedLabel(taskRow.modelData.completed, Date.now())
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
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
