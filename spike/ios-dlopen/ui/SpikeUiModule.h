// Level 2: a QObject subclass living in a framework that links NO Qt. Its
// moc-generated metaobject, Q_PROPERTY and the qrc'd QML file resolve every
// Qt symbol upward into the app's static Qt.
#pragma once

#include <QObject>
#include <QString>

class SpikeUiModule : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QString greeting READ greeting WRITE setGreeting NOTIFY greetingChanged)
    Q_PROPERTY(int counter READ counter NOTIFY counterChanged)
public:
    explicit SpikeUiModule(QObject* parent = nullptr);
    ~SpikeUiModule() override;

    QString greeting() const { return m_greeting; }
    void setGreeting(const QString& g);
    int counter() const { return m_counter; }

    // Called from QML: the call travels through this framework's
    // qt_static_metacall, i.e. moc output resolved against the app's Qt.
    Q_INVOKABLE void report(const QString& what);
    Q_INVOKABLE void bump();
    Q_INVOKABLE QString imageAddress() const;

signals:
    void greetingChanged();
    void counterChanged();
    void reported(const QString& what);

private:
    QString m_greeting;
    int m_counter = 0;
};

extern "C" {
__attribute__((visibility("default"))) QObject* spike_ui_create(QObject* parent);
__attribute__((visibility("default"))) const char* spike_ui_qml_url(void);
}
