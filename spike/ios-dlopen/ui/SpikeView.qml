// Shipped inside SpikeUi.framework's qrc; evaluated by the app's QML engine.
import QtQuick

Rectangle {
    id: root
    color: "#1e2a38"

    Column {
        anchors.centerIn: parent
        spacing: 6
        Text {
            color: "#9be7a0"
            font.pixelSize: 18
            text: "Level 2: QML from SpikeUi.framework"
        }
        Text {
            color: "white"
            font.pixelSize: 16
            text: "greeting = " + spikeModule.greeting
        }
        Text {
            color: "white"
            font.pixelSize: 16
            text: "counter = " + spikeModule.counter + "  (image " + spikeModule.imageAddress() + ")"
        }
    }

    Timer {
        interval: 500
        running: true
        repeat: true
        onTriggered: spikeModule.bump()
    }

    Component.onCompleted: spikeModule.report("SpikeView.qml completed; greeting=" + spikeModule.greeting)
}
