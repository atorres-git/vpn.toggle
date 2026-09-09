import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "vpn.toggle"
  ipcTarget: "vpn.toggle"

  property var activeNames: ({})
  property var connectionsModel: []
  readonly property bool hasAnyConnection: connectionsModel.length > 0
  property string statusText: ""
  property string configureStatus: ""
  property string ipsecWarning: ""
  property int editingIndex: -1
  property bool editing: false
  property int deleteArmedIndex: -1
  property int pendingDeleteIndex: -1
  property string deleteError: ""
  property var pendingConnection: null

  onSettingsChanged: connectionsModel = root.readConnections()
  Component.onCompleted: connectionsModel = root.readConnections()
  readonly property bool configureError: String(configureStatus).indexOf("Error:") === 0
    || String(configureStatus).indexOf("Failed") === 0
    || String(configureStatus).indexOf("Delete error") === 0
    || String(configureStatus).indexOf("Delete failed") === 0

  readonly property int activeCount: {
    var n = 0
    for (var i = 0; i < connectionsModel.length; i++) {
      if (root.isActive(String(connectionsModel[i].name))) n++
    }
    return n
  }

  readonly property bool anyConnected: activeCount > 0
  readonly property string icon: anyConnected ? "󰦝" : "󰦞"

  onOpenedChanged: if (opened) {
    editing = false
    deleteArmedIndex = -1
    configureStatus = ""
  }

  // Poll VPN status
  Timer {
    id: statusPoll
    interval: 3000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: if (root.hasAnyConnection && !statusProc.running) statusProc.running = true
  }

  Process {
    id: statusProc
    command: ["nmcli", "-t", "-f", "NAME,ACTIVE", "connection", "show"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateStatus(text)
    }
  }

  Process {
    id: ipsecProbe
    command: ["ipsec", "version"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.checkIpsec(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.checkIpsec(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.ipsecWarning === "") {
        root.ipsecWarning = "strongSwan/ipsec not found — L2TP/IPsec requires it. See README."
      }
    }
    Component.onCompleted: running = true
  }

  // Secrets are never part of the persisted connection list. They live only in
  // NetworkManager's secret storage and are provisioned over stdin on save.
  function sanitizeConnection(entry) {
    if (!entry) return null
    return {
      "name": String(entry.name || ""),
      "serverIp": String(entry.serverIp || ""),
      "username": String(entry.username || "")
    }
  }

  function readConnections() {
    var out = []
    var raw = settings ? settings.connections : null
    var list = null
    if (raw && typeof raw === "object") {
      if (typeof raw.length === "number" && raw.length >= 0) {
        list = raw
      } else if (raw.items && typeof raw.items === "object"
          && typeof raw.items.length === "number" && raw.items.length >= 0) {
        list = raw.items
      }
    }
    if (list) {
      for (var i = 0; i < list.length; i++) {
        var clean = root.sanitizeConnection(list[i])
        if (clean && String(clean.name || "") !== "") out.push(clean)
      }
      return out
    }
    // Tolerate a lone object (e.g. hand-written config) the same as a
    // single-entry list.
    if (raw && typeof raw === "object") {
      var single = root.sanitizeConnection(raw)
      if (single && String(single.name || "") !== "") out.push(single)
      return out
    }
    if (settings && settings.vpnName) {
      var legacy = root.sanitizeConnection(settings)
      if (legacy) out.push(legacy)
    }
    return out
  }

  function isActive(name) {
    return root.activeNames[String(name || "")] === true
  }

  function updateStatus(raw) {
    var active = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var idx = line.lastIndexOf(":")
      if (idx < 0) continue
      var name = line.slice(0, idx)
      var state = line.slice(idx + 1)
      if (state === "yes") active[name] = true
    }
    root.activeNames = active
    root.statusText = root.anyConnected ? "Connected" : "Disconnected"
  }

  // strongSwan 6.1+ disabled IKEv1 at build time; NetworkManager-L2TP needs
  // it, so detect a known-broken build and warn instead of failing silently.
  function checkIpsec(text) {
    if (root.ipsecWarning !== "") return
    var raw = String(text || "")
    var m = raw.match(/U(\d+)\.(\d+)\.(\d+)/)
    if (m) {
      var major = parseInt(m[1], 10)
      var minor = parseInt(m[2], 10)
      if (major === 6 && minor >= 1) {
        root.ipsecWarning = "strongSwan " + major + "." + minor + "+ dropped IKEv1, which L2TP/IPsec needs. "
          + "Use strongSwan 6.0.x or a build with --enable-ikev1 (Arch: pin it via IgnorePkg). See README."
      }
    }
  }

  function toggleConnection(index) {
    var conn = root.connectionsModel[index]
    if (!conn) return
    var name = String(conn.name || "").trim()
    if (!name) return
    if (root.isActive(name)) {
      disconnectProc.command = ["nmcli", "connection", "down", name]
      disconnectProc.running = true
    } else {
      connectProc.command = ["nmcli", "connection", "up", name]
      connectProc.running = true
    }
  }

  function toggleAll() {
    if (!hasAnyConnection) return
    var connect = !root.anyConnected
    var parts = []
    for (var i = 0; i < connectionsModel.length; i++) {
      var name = String(connectionsModel[i].name || "").trim()
      if (!name) continue
      parts.push("nmcli connection " + (connect ? "up" : "down") + " " + root.shq(name))
    }
    if (parts.length === 0) return
    var script = parts.join(connect ? " & " : " ; ")
    if (connect) script += " ; wait"
    toggleProc.command = ["bash", "-c", script]
    toggleProc.running = true
  }

  function shq(value) {
    return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
  }

  function buildDataString() {
    return "gateway = " + serverField.text.trim()
      + ", ipsec-enabled = yes"
      + ", ipsec-psk-flags = 0"
      + ", machine-auth-type = psk"
      + ", machine-certpass-flags = 0"
      + ", user = " + userField.text.trim()
      + ", user-auth-type = password"
      + ", password-flags = 0"
      + ", mtu = 1400"
      + ", mru = 1400"
      + ", ephemeral-port = yes"
  }

  function clearFields() {
    nameField.text = ""
    serverField.text = ""
    userField.text = ""
    passField.text = ""
    pskField.text = ""
  }

  function fillFormFrom(index) {
    var conn = root.connectionsModel[index]
    if (!conn) { root.clearFields(); return }
    nameField.text = String(conn.name || "")
    serverField.text = String(conn.serverIp || "")
    userField.text = String(conn.username || "")
    passField.text = String(conn.password || "")
    pskField.text = String(conn.psk || "")
  }

  function openAdd() {
    root.editingIndex = -1
    root.deleteArmedIndex = -1
    root.configureStatus = ""
    root.clearFields()
    root.editing = true
  }

  function openEdit(index) {
    root.editingIndex = index
    root.deleteArmedIndex = -1
    root.configureStatus = ""
    root.fillFormFrom(index)
    root.editing = true
  }

  function cancelEdit() {
    if (root.editingIndex >= 0) root.fillFormFrom(root.editingIndex)
    else root.clearFields()
    root.editing = false
    root.configureStatus = ""
  }

  // Persist-then-apply state for the async settings write below.
  property var pendingPersistList: []
  property string pendingPersistAction: ""
  property string persistError: ""

  function widgetId() {
    return root.moduleName !== "" ? root.moduleName : "vpn.toggle"
  }

  // Widget settings are read-only from QML: there is no shell.mutateShellConfig
  // API. The supported write path is the shell CLI, which updates the live
  // shell and persists to shell.json, so onSettingsChanged fires and the list
  // refreshes on its own.
  // The list travels wrapped as {"items": [...]}: the qs IPC layer splats a
  // top-level JSON array into separate arguments ([] vanishes, [a,b] becomes
  // two args), so a bare array can never survive the trip. The wrapper object
  // passes through untouched for 0, 1, or N entries.
  function persistConnections(list, action) {
    var clean = []
    for (var j = 0; j < list.length; j++) {
      var c = root.sanitizeConnection(list[j])
      if (c) clean.push(c)
    }
    root.pendingPersistList = clean
    root.pendingPersistAction = String(action || "")
    root.persistError = ""
    root.configureStatus = "Saving settings…"
    persistProc.command = ["omarchy", "bar", "set", root.widgetId(), "connections", JSON.stringify({ "items": clean }), "--json"]
    persistProc.running = true
  }

  function collectConnection() {
    return root.sanitizeConnection({
      "name": nameField.text.trim(),
      "serverIp": serverField.text.trim(),
      "username": userField.text.trim(),
      "password": passField.text,
      "psk": pskField.text
    })
  }

  // Builds the nmcli interactive editor script that provisions secrets. The
  // connection must already exist. Secrets travel over stdin, never argv.
  function buildSecretsScript() {
    var parts = []
    if (passField.text !== "") parts.push("set vpn.secrets password=" + passField.text)
    if (pskField.text !== "") parts.push("set vpn.secrets ipsec-psk=" + pskField.text)
    return parts.length === 0 ? "" : parts.join("\n") + "\nsave\nquit\n"
  }

  function buildConfigureScript(oldName) {
    var name = nameField.text.trim()
    var old = String(oldName || "")

    var script = ""
    if (old && old !== name) {
      script += "if nmcli -t connection show " + shq(old) + " >/dev/null 2>&1; then "
        + "nmcli connection modify " + shq(old) + " connection.id " + shq(name) + "; fi\n"
    }
    script += "if nmcli -t connection show " + shq(name) + " >/dev/null 2>&1; then\n"
    script += "  nmcli connection modify " + shq(name)
    script += " vpn.data " + shq(buildDataString()) + "\n"
    script += "else\n"
    script += "  nmcli connection add type vpn vpn-type l2tp con-name " + shq(name)
    script += " vpn.data " + shq(buildDataString()) + "\n"
    script += "fi\n"
    return script
  }

  // Secrets to provision via stdin after the configure step completes. Captured
  // at saveAll() time so that field edits during the async configure don't leak.
  property string pendingSecrets: ""

  function finalizeSave() {
    var collected = root.pendingConnection
    var list = JSON.parse(JSON.stringify(root.connectionsModel || []))
    if (root.editingIndex >= 0 && root.editingIndex < list.length) {
      list[root.editingIndex] = collected
    } else {
      list.push(collected)
    }
    root.pendingConnection = null
    root.pendingSecrets = ""
    root.persistConnections(list, "save")
  }

  function saveAll() {
    var name = nameField.text.trim()
    var server = serverField.text.trim()
    if (!name) { configureStatus = "Connection name is required"; return }
    if (!server) { configureStatus = "Server IP is required"; return }

    var oldName = root.editingIndex >= 0 ? String(root.connectionsModel[root.editingIndex].name || "") : ""
    root.pendingConnection = root.collectConnection()
    root.pendingSecrets = root.buildSecretsScript()
    root.pendingDeleteIndex = -1

    configureStatus = "Writing connection…"
    configureProc.prepare(buildConfigureScript(oldName))
  }

  Process {
    id: connectProc
    command: ["nmcli", "connection", "up", ""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: statusPoll.restart()
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
  }

  Process {
    id: disconnectProc
    command: ["nmcli", "connection", "down", ""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: statusPoll.restart()
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
  }

  Process {
    id: toggleProc
    command: ["bash", "-c", "true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: statusPoll.restart()
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
  }

  // Persists the connection list through the shell CLI instead of editing
  // shell.json directly, so the running shell picks the change up live.
  Process {
    id: persistProc
    command: ["omarchy", "bar", "set", "vpn.toggle", "connections", "{\"items\":[]}", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.persistError = String(text).trim()
    }
    onExited: function(exitCode) {
      var action = root.pendingPersistAction
      var list = JSON.parse(JSON.stringify(root.pendingPersistList || []))
      root.pendingPersistAction = ""
      if (exitCode === 0) {
        root.connectionsModel = list
        if (action === "save") {
          statusPoll.restart()
          root.editing = false
          root.editingIndex = -1
          root.deleteArmedIndex = -1
          root.configureStatus = "Saved"
          root.open()
        } else if (action === "delete") {
          root.pendingDeleteIndex = -1
          root.configureStatus = ""
          statusPoll.restart()
          if (root.connectionsModel.length === 0) {
            root.editing = false
            root.editingIndex = -1
            root.clearFields()
          }
        }
      } else {
        var detail = root.persistError !== "" ? root.persistError : "exit " + exitCode
        root.configureStatus = "Error: settings not saved (" + detail + ")"
        root.persistError = ""
      }
    }
  }

  Process {
    id: configureProc
    command: ["bash", "-c", "true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text).trim()
        if (message) root.configureStatus = message
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text).trim()
        if (message) root.configureStatus = "Error: " + message
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        if (root.pendingSecrets !== "") {
          root.configureStatus = "Saving secrets…"
          secretProc.command = ["nmcli", "connection", "edit", root.pendingConnection.name]
          secretProc.running = true
        } else {
          root.finalizeSave()
        }
      } else {
        root.pendingSecrets = ""
        var current = String(root.configureStatus)
        if (current.indexOf("Error:") !== 0) root.configureStatus = "Failed (exit " + exitCode + ")"
      }
    }

    function prepare(script) {
      configureStatus = "Writing connection…"
      command = ["bash", "-c", script]
      running = true
    }
  }

  // Provisions VPN secrets through the nmcli interactive editor. Secrets travel
  // over the process stdin pipe, never through argv or the shell.
  Process {
    id: secretProc
    stdinEnabled: true
    command: ["nmcli", "connection", "edit", ""]
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
    onStarted: write(root.pendingSecrets)
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.finalizeSave()
      } else {
        root.pendingSecrets = ""
        root.configureStatus = "Failed to store secrets (exit " + exitCode + ")"
      }
    }
  }

  Process {
    id: deleteProc
    command: ["nmcli", "connection", "delete", ""]
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.deleteError = String(text).trim()
        var message = String(text).trim()
        if (message) root.configureStatus = "Delete error: " + message
      }
    }
    onExited: function(exitCode) {
      root.deleteArmedIndex = -1
      if (exitCode === 0) {
        var index = root.pendingDeleteIndex
        var list = JSON.parse(JSON.stringify(root.connectionsModel || []))
        if (index >= 0 && index < list.length) list.splice(index, 1)
        root.configureStatus = "Deleting connection…"
        root.persistConnections(list, "delete")
      } else if (root.deleteError.indexOf("nknown connection") >= 0 && root.pendingDeleteIndex >= 0) {
        // NetworkManager doesn't know this entry (e.g. wrong case): drop it
        // from the list anyway so it can't get stuck.
        var idx = root.pendingDeleteIndex
        var kept = JSON.parse(JSON.stringify(root.connectionsModel || []))
        if (idx >= 0 && idx < kept.length) kept.splice(idx, 1)
        root.configureStatus = "Not found in NetworkManager — removed from list"
        root.persistConnections(kept, "delete")
      } else {
        var current = String(root.configureStatus)
        if (current.indexOf("Delete") !== 0) root.configureStatus = "Delete failed (exit " + exitCode + ")"
      }
      root.deleteError = ""
    }
  }

  IpcHandler {
    target: "vpn.toggle"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleVpn() { root.toggleAll() }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.anyConnected
    tooltipText: "VPN: " + root.statusText
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAll()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nameField.activeFocus || serverField.activeFocus || userField.activeFocus
        || passField.activeFocus || pskField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "v" || t === "V") root.toggleAll()
        else if (t === "a" || t === "A") root.openAdd()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // strongSwan 6.1+ dropped IKEv1 (breaks NetworkManager-L2TP)
        Text {
          visible: root.ipsecWarning !== ""
          textFormat: Text.PlainText
          text: root.ipsecWarning
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: parent.width
          wrapMode: Text.WordWrap
        }

        // Hero: VPN icon + status
        Item {
          visible: root.hasAnyConnection
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, toggleBtn.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.icon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.anyConnected ? 1.0 : 0.5
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Button {
            id: toggleBtn
            text: root.anyConnected ? "Disconnect all" : "Connect all"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.toggleAll()
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: toggleBtn.width + Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "VPN"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: {
                if (root.activeCount > 1) return root.activeCount + " CONNECTED"
                return root.statusText.toUpperCase()
              }
              color: root.anyConnected ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator {
          visible: root.hasAnyConnection
          foreground: root.bar.foreground
        }

        Text {
          visible: root.hasAnyConnection
          textFormat: Text.PlainText
          text: root.editing ? "Press A for a new connection" : "Press V to toggle all, A to add"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          width: parent.width
        }

        PanelSeparator {
          visible: root.hasAnyConnection
          foreground: root.bar.foreground
        }

        // ---- Connection list ----
        PanelSectionHeader {
          visible: root.hasAnyConnection && !root.editing
          text: "CONNECTIONS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          width: parent.width
        }

        ListView {
          id: connectionList
          visible: root.hasAnyConnection && !root.editing
          width: parent.width
          height: Math.min(contentHeight, Style.space(240))
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.connectionsModel

          delegate: Item {
            required property var modelData
            required property int index
            readonly property var conn: modelData
            width: ListView.view.width
            height: row.implicitHeight

            Item {
              id: row
              width: parent.width
              implicitHeight: Math.max(nameCol.implicitHeight, controls.implicitHeight)

              Column {
                id: nameCol
                anchors.left: parent.left
                anchors.right: controls.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: String(conn.name || "")
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: root.isActive(String(conn.name))
                  elide: Text.ElideMiddle
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.isActive(String(conn.name)) ? "Connected" : "Disconnected"
                  color: root.isActive(String(conn.name)) ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  width: parent.width
                }
              }

              Row {
                id: controls
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Button {
                  text: root.isActive(String(conn.name)) ? "Down" : "Up"
                  fontSize: Style.font.bodySmall
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.toggleConnection(index)
                }

                Button {
                  text: "Edit"
                  fontSize: Style.font.bodySmall
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.openEdit(index)
                }

                Button {
                  text: root.deleteArmedIndex === index ? "Confirm" : "Del"
                  fontSize: Style.font.bodySmall
                  foreground: root.deleteArmedIndex === index ? root.bar.urgent : root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: {
                    if (root.deleteArmedIndex === index) {
                      root.pendingDeleteIndex = index
                      root.deleteError = ""
                      deleteProc.command = ["nmcli", "connection", "delete", String(conn.name || "").trim()]
                      root.deleteArmedIndex = -1
                      root.configureStatus = "Deleting connection…"
                      deleteProc.running = true
                    } else {
                      root.deleteArmedIndex = index
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          visible: root.hasAnyConnection && !root.editing && root.configureStatus !== ""
          textFormat: Text.PlainText
          text: root.configureStatus
          color: root.configureError ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: parent.width
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.deleteArmedIndex >= 0
          textFormat: Text.PlainText
          text: "Deletes the NetworkManager connection. Click Confirm to proceed."
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          width: parent.width
          wrapMode: Text.WordWrap
        }

        Button {
          visible: root.hasAnyConnection && !root.editing
          text: "Add connection"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          width: parent.width
          onClicked: root.openAdd()
        }

        // ---- Form ----
        PanelSectionHeader {
          visible: !root.hasAnyConnection || root.editing
          text: root.editingIndex >= 0 ? "EDIT VPN" : "ADD VPN"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          width: parent.width
        }

        TextField {
          id: nameField
          visible: !root.hasAnyConnection || root.editing
          width: parent.width
          placeholderText: "VPN connection name"
          foreground: root.bar.foreground
          accent: root.bar.urgent
        }

        TextField {
          id: serverField
          visible: !root.hasAnyConnection || root.editing
          width: parent.width
          placeholderText: "Server IP / gateway"
          foreground: root.bar.foreground
          accent: root.bar.urgent
        }

        TextField {
          id: userField
          visible: !root.hasAnyConnection || root.editing
          width: parent.width
          placeholderText: "Username"
          foreground: root.bar.foreground
          accent: root.bar.urgent
        }

        TextField {
          id: passField
          visible: !root.hasAnyConnection || root.editing
          width: parent.width
          placeholderText: "Password"
          password: true
          foreground: root.bar.foreground
          accent: root.bar.urgent
        }

        TextField {
          id: pskField
          visible: !root.hasAnyConnection || root.editing
          width: parent.width
          placeholderText: "Pre-shared key"
          password: true
          foreground: root.bar.foreground
          accent: root.bar.urgent
        }

        Text {
          textFormat: Text.PlainText
          visible: (!root.hasAnyConnection || root.editing) && root.configureStatus !== ""
          text: root.configureStatus
          color: root.configureError ? root.bar.urgent : Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: parent.width
          wrapMode: Text.WordWrap
        }

        Row {
          visible: !root.hasAnyConnection || root.editing
          anchors.right: parent.right
          spacing: Style.space(8)

          Button {
            visible: root.editing
            text: "Cancel"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.cancelEdit()
          }

          Button {
            visible: root.editing
            text: "Reset"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.editingIndex >= 0 ? root.fillFormFrom(root.editingIndex) : root.clearFields()
          }

          Button {
            text: root.editing ? "Save" : "Add"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: root.saveAll()
          }
        }
      }
    }
  }
}