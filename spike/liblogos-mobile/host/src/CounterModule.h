// Level B: a throwaway native module, linked into the app as a STATIC Qt
// plugin (Q_IMPORT_PLUGIN in main.cpp) and found through
// QPluginLoader::staticInstances() -- the static-table fallback. It is not
// discovered by ModuleManager (no .lgx, no metadata); the host registers it
// with a LogosAPI provider in LogosMode::Local so that every other LogosAPI
// client in the process can reach it by name.
#pragma once

#include <core/interface.h> // PluginInterface, what QtProviderObject dispatches to

#include <QObject>
#include <QVariantList>
#include <QtPlugin>

class CounterModule : public QObject, public PluginInterface
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID PluginInterface_iid)
    Q_INTERFACES(PluginInterface)
public:
    explicit CounterModule(QObject* parent = nullptr);

    QString name() const override { return QStringLiteral("counter"); }
    QString version() const override { return QStringLiteral("0.1.0"); }
    // QtProviderObject::init calls this by name and refuses every call
    // until PluginInterface::logosAPI is set.
    Q_INVOKABLE void initLogos(LogosAPI* api) { logosAPI = api; }

    Q_INVOKABLE int add(int a, int b);
    Q_INVOKABLE int increment();
    Q_INVOKABLE int value() const { return m_value; }

signals:
    // The one signal QtProviderObject forwards as module events.
    void eventResponse(const QString& eventName, const QVariantList& data);

private:
    int m_value = 0;
};
