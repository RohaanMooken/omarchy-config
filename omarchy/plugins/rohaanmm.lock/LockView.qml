import QtQuick
import QtQuick.Effects
import qs.Commons

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false

  // Circuit-board footprint. The fractions are the share of the screen it may
  // spread across; the maximums are a hard ceiling in logical pixels so it does
  // not sprawl on a large display. Raising the box gives the router more room,
  // so the same password draws a looser, wider net; shrinking it packs tighter.
  property real circuitWidthFraction: 0.9
  property real circuitHeightFraction: 0.8
  property real circuitMaxWidth: 2000
  property real circuitMaxHeight: 1500

  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property bool errorState: failureMessage.length > 0
  // Only speak up when there is something the circuit alone cannot say.
  readonly property string statusText: authenticatingPassword ? "Checking…" : failureMessage

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && wallpaper.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    PasswordCircuit {
      id: circuit
      anchors.centerIn: parent
      width: Math.min(parent.width * root.circuitWidthFraction, root.circuitMaxWidth)
      height: Math.min(parent.height * root.circuitHeightFraction, root.circuitMaxHeight)
      count: passwordInput.text.length
      ink: root.errorState ? Color.lock.borderError : Color.lock.borderActive
    }

    // The field is gone: the circuit is the only password feedback. This input
    // still does the real work, it just never paints. Keep it opacity-0 rather
    // than visible:false — an invisible item can still hold focus, a hidden one
    // cannot. echoMode stays Password so no keystroke can ever surface here.
    TextInput {
      id: passwordInput
      width: 1
      height: 1
      anchors.centerIn: parent
      opacity: 0
      activeFocusOnPress: true
      // Focus IS the UI here — there is no visible field to click back into.
      // `enabled` goes false while PAM checks a password, and Qt drops active
      // focus off a disabled item; nothing put it back, so the next attempt
      // typed into nowhere until you clicked. Take focus back whenever it is
      // lost while we can hold it, and again the moment input re-enables.
      focus: true
      onActiveFocusChanged: if (!activeFocus && enabled) Qt.callLater(root.forcePasswordFocus)
      onEnabledChanged: if (enabled) Qt.callLater(root.forcePasswordFocus)
      enabled: root.inputEnabled && !root.authenticatingPassword
      readOnly: root.authenticatingPassword
      echoMode: TextInput.Password
      passwordCharacter: "\u25CF"
      passwordMaskDelay: 0
      cursorVisible: false
      font.family: Style.font.family
      font.pixelSize: 1

      onTextChanged: {
        if (!root.syncingPasswordText) root.passwordTextEdited(text)
        if (text.length > 0) {
          root.wakeRequested()
        }
        if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
      }

      onAccepted: {
        var submitted = root.passwordText
        circuit.surge()
        root.passwordTextEdited("")
        if (submitted.length > 0) root.submitPassword(submitted)
      }

      Keys.onPressed: function(event) {
        root.wakeRequested()
        if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
          root.passwordTextEdited("")
          event.accepted = true
        }
      }
    }

    // Sits under the circuit with no chrome around it, and only while there is
    // something to report — the red trace colour carries the rest.
    Text {
      id: statusLabel
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: circuit.bottom
      anchors.topMargin: 28
      text: root.statusText
      visible: text.length > 0
      color: root.authenticatingPassword ? Color.lock.text : Color.lock.textError
      font.family: Style.font.family
      font.pixelSize: root.fieldFontSize
      font.italic: !root.authenticatingPassword
      horizontalAlignment: Text.AlignHCenter
    }

    // Fingerprint hint, recentred under the circuit now that there is no field
    // edge to pin it inside.
    Text {
      id: fingerprintIcon
      objectName: "fingerprintIndicator"
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: statusLabel.visible ? statusLabel.bottom : circuit.bottom
      anchors.topMargin: statusLabel.visible ? 16 : 28
      visible: root.fingerprintConfigured
      text: "󰈷"
      color: Color.lock.placeholder
      font.family: Style.font.family
      font.pixelSize: Math.round(root.fieldFontSize * 1.1)
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
