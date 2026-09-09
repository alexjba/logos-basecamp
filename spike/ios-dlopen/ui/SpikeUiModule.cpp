#include "SpikeUiModule.h"

#include <QDebug>

SpikeUiModule::SpikeUiModule(QObject* parent)
    : QObject(parent)
    , m_greeting(QStringLiteral("hello from SpikeUi.framework"))
{
}

SpikeUiModule::~SpikeUiModule() = default;

void SpikeUiModule::setGreeting(const QString& g)
{
    if (g == m_greeting)
        return;
    m_greeting = g;
    emit greetingChanged();
}

void SpikeUiModule::report(const QString& what)
{
    qInfo("[spike][SpikeUi.framework] report: %s", qUtf8Printable(what));
    emit reported(what);
}

void SpikeUiModule::bump()
{
    ++m_counter;
    emit counterChanged();
}

QString SpikeUiModule::imageAddress() const
{
    return QString::asprintf("%p", reinterpret_cast<const void*>(&spike_ui_create));
}

extern "C" QObject* spike_ui_create(QObject* parent)
{
    return new SpikeUiModule(parent);
}

extern "C" const char* spike_ui_qml_url(void)
{
    return "qrc:/spike/SpikeView.qml";
}
