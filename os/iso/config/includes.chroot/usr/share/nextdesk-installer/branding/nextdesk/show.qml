/* NextDesk OS installer slideshow (Calamares, slideshowAPI 2) */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    function nextSlide() { presentation.goToNextSlide(); }

    Timer {
        id: advanceTimer
        interval: 12000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0a1630" }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: "#ffffff"
            font.pixelSize: 22
            text: "<b>Installing NextDesk OS</b><br/><br/>A desktop that is just your Nextcloud: its apps on the shelf, one sign-in for everything."
        }
    }

    Slide {
        Rectangle { anchors.fill: parent; color: "#0a1630" }
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: "#ffffff"
            font.pixelSize: 20
            text: "<b>Nothing lives on this computer</b><br/><br/>Files, mail and calendars stay in Nextcloud. Sign in with your Nextcloud account, set a PIN for unlocking, and you're done."
        }
    }

    function onActivate() { }
    function onLeave() { }
}
