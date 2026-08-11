import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.plasma.core as PlasmaCore

PlasmoidItem {
    id: root

    property real primaryPercent: 0
    property real secondaryPercent: 0
    property bool hasSecondary: false
    property string primaryWindowLabel: ""
    property string secondaryWindowLabel: ""
    property var primaryResetTime: null
    property var secondaryResetTime: null
    property string planName: ""
    property string creditsInfo: ""
    property string lastUpdate: ""
    property string errorMsg: ""
    property bool isLoggedOut: false
    property bool isLoading: false
    property double lastSuccessTime: 0
    property bool isStale: false
    readonly property int staleThresholdMs: Math.max(Plasmoid.configuration.refreshInterval || 1, 1) * 60000 * 3

    // Cache writer - saves last successful data to file
    Plasma5Support.DataSource {
        id: cacheWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) { disconnectSource(sourceName) }
    }

    // Cache reader - loads cached data on startup
    Plasma5Support.DataSource {
        id: cacheReader
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = (data["stdout"] || "").trim()
            disconnectSource(sourceName)
            if (stdout.length > 10) {
                try {
                    var cache = JSON.parse(stdout)
                    var age = Date.now() - (cache.timestamp || 0)
                    if (age < 86400000) { // less than 24 hours old
                        root.primaryPercent = cache.primary || 0
                        root.secondaryPercent = cache.secondary || 0
                        root.hasSecondary = cache.hasSecondary || false
                        root.primaryWindowLabel = cache.primaryWindowLabel || ""
                        root.secondaryWindowLabel = cache.secondaryWindowLabel || ""
                        root.planName = cache.plan || ""
                        root.creditsInfo = cache.credits || ""
                        root.primaryResetTime = cache.primaryResetTs ? new Date(cache.primaryResetTs) : null
                        root.secondaryResetTime = cache.secondaryResetTs ? new Date(cache.secondaryResetTs) : null
                        root.lastSuccessTime = cache.timestamp
                        root.lastUpdate = Qt.formatTime(new Date(cache.timestamp), "hh:mm:ss") + " *"
                        root.isStale = age > root.staleThresholdMs
                        console.log("Codex Usage: Loaded cache, age:", Math.round(age / 60000), "min, stale:", root.isStale)
                    } else {
                        console.log("Codex Usage: Cache too old, ignoring")
                    }
                } catch (e) {
                    console.log("Codex Usage: Cache parse error:", e)
                }
            }
        }
    }

    function saveCache() {
        var cache = {
            primary: root.primaryPercent,
            secondary: root.secondaryPercent,
            hasSecondary: root.hasSecondary,
            primaryWindowLabel: root.primaryWindowLabel,
            secondaryWindowLabel: root.secondaryWindowLabel,
            plan: root.planName,
            credits: root.creditsInfo,
            primaryResetTs: root.primaryResetTime ? root.primaryResetTime.getTime() : null,
            secondaryResetTs: root.secondaryResetTime ? root.secondaryResetTime.getTime() : null,
            timestamp: Date.now()
        }
        var json = JSON.stringify(cache)
        cacheWriter.connectSource("echo '" + json.replace(/'/g, "'\\''") + "' > $HOME/.local/share/codex-usage-cache.json")
    }

    // Stale checker - updates isStale flag periodically
    Timer {
        id: staleTimer
        interval: 60000
        running: true
        repeat: true
        onTriggered: {
            if (root.lastSuccessTime > 0) {
                root.isStale = (Date.now() - root.lastSuccessTime) > root.staleThresholdMs
            }
        }
    }

    // Fetches rate limits by driving codex app-server's JSON-RPC stdio protocol
    // (contents/code/fetch_usage.py speaks initialize -> initialized -> account/rateLimits/read)
    Plasma5Support.DataSource {
        id: usageFetcher
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = (data["stdout"] || "").trim()
            disconnectSource(sourceName)
            root.isLoading = false

            if (stdout.length === 0) {
                root.errorMsg = i18n("No response from codex")
                return
            }

            try {
                var resp = JSON.parse(stdout)
            } catch (e) {
                console.log("Codex Usage: JSON parse error:", e, stdout)
                root.errorMsg = i18n("Parse error")
                return
            }

            if (!resp.ok) {
                var msg = resp.error || "unknown error"
                console.log("Codex Usage: fetch error:", msg)
                if (msg.indexOf("not found") !== -1) {
                    root.errorMsg = i18n("codex CLI not found")
                    root.isLoggedOut = false
                } else {
                    root.isLoggedOut = true
                    root.errorMsg = ""
                }
                return
            }

            root.isLoggedOut = false
            root.errorMsg = ""

            var rl = (resp.data || {}).rateLimits || {}
            var primary = rl.primary || null
            var secondary = rl.secondary || null

            root.primaryPercent = primary ? (primary.usedPercent || 0) : 0
            root.primaryWindowLabel = primary ? windowLabel(primary.windowDurationMins) : ""
            root.primaryResetTime = (primary && primary.resetsAt) ? new Date(primary.resetsAt * 1000) : null

            root.hasSecondary = !!secondary
            root.secondaryPercent = secondary ? (secondary.usedPercent || 0) : 0
            root.secondaryWindowLabel = secondary ? windowLabel(secondary.windowDurationMins) : ""
            root.secondaryResetTime = (secondary && secondary.resetsAt) ? new Date(secondary.resetsAt * 1000) : null

            root.planName = rl.planType || ""

            var credits = rl.credits || null
            if (credits && !credits.unlimited && credits.hasCredits) {
                root.creditsInfo = i18n("Credits:") + " " + (credits.balance || "0")
            } else {
                root.creditsInfo = ""
            }

            root.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
            root.lastSuccessTime = Date.now()
            root.isStale = false
            saveCache()

            console.log("Codex Usage: fetch success - primary:", root.primaryPercent, "secondary:", root.secondaryPercent)
        }
    }

    // Data source for launching codex in a terminal (to log in)
    Plasma5Support.DataSource {
        id: codexLauncher
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) { disconnectSource(sourceName) }
    }

    function windowLabel(mins) {
        if (!mins) return ""
        if (mins % (24 * 60) === 0) {
            return (mins / (24 * 60)) + "d"
        }
        if (mins % 60 === 0) {
            return (mins / 60) + "h"
        }
        return mins + "m"
    }

    function fetchUsage() {
        root.isLoading = true
        var scriptPath = Qt.resolvedUrl("../code/fetch_usage.py").toString().replace("file://", "")
        usageFetcher.connectSource("python3 '" + scriptPath + "'")
    }

    function refresh() {
        fetchUsage()
    }

    function getUsageColor(percent) {
        if (percent < 50) return Kirigami.Theme.positiveTextColor
        if (percent < 80) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function formatTimeRemaining(resetTime) {
        if (!resetTime) return ""
        var diff = resetTime.getTime() - Date.now()
        if (diff <= 0) return ""

        var hours = Math.floor(diff / (1000 * 60 * 60))
        var minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60))

        if (hours > 24) {
            var days = Math.floor(hours / 24)
            hours = hours % 24
            return days + i18n("d") + " " + hours + i18n("h")
        } else if (hours > 0) {
            return hours + i18n("h") + " " + minutes + i18n("m")
        } else {
            return minutes + i18n("m")
        }
    }

    // Compact representation (panel)
    compactRepresentation: Item {
        Layout.minimumWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.preferredHeight: -1

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: usageRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            Item {
                visible: Plasmoid.configuration.showIcon !== false
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                Layout.rightMargin: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    anchors.fill: parent
                    source: Qt.resolvedUrl("../icons/codex.svg")
                }

                Rectangle {
                    visible: root.isLoggedOut || root.errorMsg !== ""
                    width: 8
                    height: 8
                    radius: 4
                    color: Kirigami.Theme.negativeTextColor
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: -2
                    anchors.bottomMargin: -2
                }
            }

            PlasmaComponents.Label {
                visible: root.errorMsg !== "" && !root.isLoggedOut
                text: "⚠"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }

            Rectangle {
                visible: !root.isLoggedOut && (root.errorMsg === "")
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getUsageColor(root.primaryPercent)
                opacity: root.isStale ? 0.6 : 1.0
            }

            PlasmaComponents.Label {
                visible: !root.isLoggedOut && (root.errorMsg === "")
                text: Math.round(root.primaryPercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
                opacity: root.isStale ? 0.6 : 1.0
            }

            PlasmaComponents.Label {
                visible: root.hasSecondary && !root.isLoggedOut && (root.errorMsg === "")
                text: "|"
                opacity: root.isStale ? 0.35 : 0.5
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
            }

            Rectangle {
                visible: root.hasSecondary && !root.isLoggedOut && (root.errorMsg === "")
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getUsageColor(root.secondaryPercent)
                opacity: root.isStale ? 0.6 : 1.0
            }

            PlasmaComponents.Label {
                visible: root.hasSecondary && !root.isLoggedOut && (root.errorMsg === "")
                text: Math.round(root.secondaryPercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
                opacity: root.isStale ? 0.6 : 1.0
            }
        }
    }

    // Full representation (popup)
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredWidth: Kirigami.Units.gridUnit * 16
        Layout.preferredHeight: Kirigami.Units.gridUnit * 15

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.mediumSpacing

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: i18n("Codex Usage")
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.3
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    visible: root.planName !== ""
                    Layout.preferredWidth: planLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                    Layout.preferredHeight: planLabel.implicitHeight + Kirigami.Units.smallSpacing
                    radius: 3
                    color: Kirigami.Theme.highlightColor
                    PlasmaComponents.Label {
                        id: planLabel
                        anchors.centerIn: parent
                        text: root.planName
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.highlightedTextColor
                    }
                }
            }

            Rectangle {
                visible: root.errorMsg !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: errorColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.negativeBackgroundColor

                ColumnLayout {
                    id: errorColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: "⚠ " + root.errorMsg
                        color: Kirigami.Theme.negativeTextColor
                        font.bold: true
                    }
                }
            }

            Rectangle {
                visible: root.isLoggedOut
                Layout.fillWidth: true
                Layout.preferredHeight: loggedOutColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.neutralBackgroundColor

                ColumnLayout {
                    id: loggedOutColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: i18n("Not logged in")
                        color: Kirigami.Theme.neutralTextColor
                        font.bold: true
                    }

                    PlasmaComponents.Button {
                        text: i18n("Open Codex")
                        icon.name: "utilities-terminal"
                        onClicked: {
                            codexLauncher.connectSource("bash -c 'cd $HOME && if command -v konsole >/dev/null; then konsole --hold -e bash -lc codex; elif command -v gnome-terminal >/dev/null; then gnome-terminal -- bash -lc \"codex; exec bash\"; elif command -v xfce4-terminal >/dev/null; then xfce4-terminal --hold -e \"bash -lc codex\"; elif command -v xterm >/dev/null; then xterm -hold -e bash -lc codex; fi &'")
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            ColumnLayout {
                visible: !root.isLoggedOut && root.errorMsg === ""
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: i18n("Primary") + (root.primaryWindowLabel !== "" ? " (" + root.primaryWindowLabel + ")" : "")
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: Math.round(root.primaryPercent) + "%"
                        color: getUsageColor(root.primaryPercent)
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.primaryPercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getUsageColor(root.primaryPercent)
                    }
                }

                PlasmaComponents.Label {
                    visible: root.primaryResetTime !== null
                    text: i18n("Resets in") + " " + formatTimeRemaining(root.primaryResetTime)
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            ColumnLayout {
                visible: root.hasSecondary && !root.isLoggedOut && root.errorMsg === ""
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: i18n("Secondary") + (root.secondaryWindowLabel !== "" ? " (" + root.secondaryWindowLabel + ")" : "")
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: Math.round(root.secondaryPercent) + "%"
                        color: getUsageColor(root.secondaryPercent)
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.secondaryPercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getUsageColor(root.secondaryPercent)
                    }
                }

                PlasmaComponents.Label {
                    visible: root.secondaryResetTime !== null
                    text: i18n("Resets in") + " " + formatTimeRemaining(root.secondaryResetTime)
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            PlasmaComponents.Label {
                visible: root.creditsInfo !== "" && !root.isLoggedOut && root.errorMsg === ""
                text: root.creditsInfo
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.disabledTextColor
            }

            Item { Layout.fillHeight: true }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: root.lastUpdate !== "" ? i18n("Updated:") + " " + root.lastUpdate : i18n("Loading...")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Button {
                    icon.name: "view-refresh"
                    text: i18n("Refresh")
                    onClicked: refresh()
                }
            }
        }
    }

    Timer {
        id: refreshTimer
        interval: Math.max(Plasmoid.configuration.refreshInterval || 5, 1) * 60000
        running: true
        repeat: true
        onTriggered: fetchUsage()
    }

    // Install icon to system theme for the about page
    Plasma5Support.DataSource {
        id: iconInstaller
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) { disconnectSource(sourceName) }
    }

    Component.onCompleted: {
        console.log("Codex Usage: Widget loaded")
        var iconSource = Qt.resolvedUrl("../icons/codex-usage-widget.svg").toString().replace("file://", "")
        iconInstaller.connectSource("bash -c 'ICON_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps && mkdir -p $ICON_DIR && cp \"" + iconSource + "\" $ICON_DIR/codex-usage-widget.svg && chmod 644 $ICON_DIR/codex-usage-widget.svg 2>/dev/null'")
        cacheReader.connectSource("cat $HOME/.local/share/codex-usage-cache.json 2>/dev/null")
        fetchUsage()
    }

    readonly property bool isOnPanel: Plasmoid.location === PlasmaCore.Types.TopEdge
        || Plasmoid.location === PlasmaCore.Types.BottomEdge
        || Plasmoid.location === PlasmaCore.Types.LeftEdge
        || Plasmoid.location === PlasmaCore.Types.RightEdge

    Plasmoid.backgroundHints: isOnPanel ? PlasmaCore.Types.DefaultBackground : PlasmaCore.Types.NoBackground

    Rectangle {
        visible: !root.isOnPanel
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
        opacity: Plasmoid.configuration.backgroundOpacity
        radius: Kirigami.Units.cornerRadius
    }

    Plasmoid.icon: "codex-usage-widget"
    toolTipMainText: i18n("Codex Usage")
    toolTipSubText: {
        var parts = []
        parts.push(i18n("Primary") + ": " + Math.round(root.primaryPercent) + "%")
        if (root.hasSecondary)
            parts.push(i18n("Secondary") + ": " + Math.round(root.secondaryPercent) + "%")
        return parts.join(" | ")
    }
}
