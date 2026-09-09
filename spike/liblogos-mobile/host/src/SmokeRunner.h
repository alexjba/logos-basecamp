// Level A of the spike: bring liblogos_core up inside the app sandbox and
// report what it sees. No modules dir contents, no capability_module.
#pragma once

#include <QObject>
#include <QString>

class SmokeRunner : public QObject
{
    Q_OBJECT
public:
    explicit SmokeRunner(QObject* parent = nullptr);

    // Blocks for the duration of logos_core_start(); returns the elapsed ms.
    qint64 run(int argc, char* argv[]);

    QString baseDir() const { return m_baseDir; }

signals:
    void log(const QString& line);

private:
    QString m_baseDir;
};
