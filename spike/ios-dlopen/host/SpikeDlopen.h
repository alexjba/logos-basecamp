// Host side of the iOS dlopen spike. Compiled into the shell-preview iOS app
// when SPIKE_IOS_DLOPEN is ON; runs the three levels at startup and prints
// one "SPIKE RESULT ..." line.
#pragma once

#include <QObject>
#include <QString>

class QMainWindow;

class SpikeReportSink : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;
    int reports = 0;
    QString last;
public slots:
    void onReported(const QString& what);
};

// Runs Level 1, 3 and 2 (in that order), attaches the Level-2 QML view to the
// window as a dock, logs everything with the [spike] prefix.
void spikeRunAll(QMainWindow* window);
