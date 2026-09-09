#include "SmokeRunner.h"

#include <logos_core.h>
#include <logos_protocol.h>
#include <logos_mode.h>

#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QStandardPaths>

SmokeRunner::SmokeRunner(QObject* parent)
    : QObject(parent)
{
}

qint64 SmokeRunner::run(int argc, char* argv[])
{
    // In-process transport for every LogosAPI in this image; the
    // QtRemoteObjects registry and local sockets are never dialled.
    LogosModeConfig::setMode(LogosMode::Local);
    // LogosModeConfig's storage is an inline static: one copy per image.
    // With a shared liblogos_protocol (Android) the line above only sets the
    // app's copy and every LogosAPI inside the protocol library stays in
    // Remote mode (seen on the SM-G990B: "RemoteTransportHost: Created
    // registry host with URL: local:logos_counter_..."); the C ABI setter
    // runs inside that image.
    lp_set_mode("local");

    m_baseDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/logos";
    const QString modulesDir = m_baseDir + "/modules";
    const QString persistDir = m_baseDir + "/persistence";
    QDir().mkpath(modulesDir);
    QDir().mkpath(persistDir);
    emit log(QStringLiteral("base dir: %1").arg(m_baseDir));
    emit log(QStringLiteral("protocol: %1 (abi major %2)")
                 .arg(QString::fromUtf8(lp_protocol_version()))
                 .arg(lp_protocol_abi_major()));

    QElapsedTimer t;
    t.start();
    logos_core_init(argc, argv);
    logos_core_set_persistence_base_path(persistDir.toUtf8().constData());
    logos_core_add_modules_dir(modulesDir.toUtf8().constData());
    logos_core_start();
    const qint64 ms = t.elapsed();
    emit log(QStringLiteral("logos_core_start: %1 ms").arg(ms));

    char* info = logos_core_get_modules_info();
    emit log(QStringLiteral("modules_info: %1").arg(info ? QString::fromUtf8(info) : QStringLiteral("<null>")));
    delete[] info; // new[] in ModuleManager::getModulesInfoCStr

    char** known = logos_core_get_known_modules();
    int n = 0;
    if (known) {
        for (char** p = known; *p; ++p) {
            emit log(QStringLiteral("known: %1").arg(QString::fromUtf8(*p)));
            delete[] *p;
            ++n;
        }
        delete[] known;
    }
    emit log(QStringLiteral("known modules: %1").arg(n));
    return ms;
}
