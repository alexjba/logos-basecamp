#include "SpikeDlopen.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>

#include <QCoreApplication>
#include <QDir>
#include <QDockWidget>
#include <QElapsedTimer>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMainWindow>
#include <QMetaObject>
#include <QMetaProperty>
#include <QQmlContext>
#include <QQmlError>
#include <QQuickWidget>
#include <QTimer>
#include <QUrl>

// The lp_* symbol the bare modules call. Stand-in for logos-protocol's
// lp_protocol_version(): same signature, lives only in the app image.
extern "C" __attribute__((visibility("default"), used)) const char* lp_protocol_version(void)
{
    return "0.8.0+spike-host-standin";
}

namespace {

struct Loaded {
    void* handle = nullptr;
    qint64 dlopenNs = 0;
    QString error;
};

QString frameworkPath(const QString& name)
{
    return QDir::cleanPath(QCoreApplication::applicationDirPath() + "/Frameworks/" + name
                           + ".framework/" + name);
}

Loaded loadFramework(const QString& name)
{
    Loaded l;
    const QString path = frameworkPath(name);
    if (!QFile::exists(path)) {
        l.error = "missing: " + path;
        return l;
    }
    QElapsedTimer t;
    t.start();
    l.handle = dlopen(path.toUtf8().constData(), RTLD_NOW | RTLD_LOCAL);
    l.dlopenNs = t.nsecsElapsed();
    if (!l.handle)
        l.error = QString::fromUtf8(dlerror());
    return l;
}

using dispatch_fn = char* (*)(const char*, const char*);
using methods_fn = char* (*)(void);
using version_fn = const char* (*)(void);
using free_fn = void (*)(char*);
using create_fn = QObject* (*)(QObject*);
using url_fn = const char* (*)(void);

struct BareResult {
    bool ok = false;
    QString tag;
    QString hostProtocol;
    void* dispatchAddr = nullptr;
    QString detail;
};

BareResult callBare(const QString& name, void* handle)
{
    BareResult r;
    auto dispatch = reinterpret_cast<dispatch_fn>(dlsym(handle, "logos_module_dispatch"));
    auto methods = reinterpret_cast<methods_fn>(dlsym(handle, "logos_module_get_methods"));
    auto version = reinterpret_cast<version_fn>(dlsym(handle, "logos_module_get_protocol_version"));
    auto strfree = reinterpret_cast<free_fn>(dlsym(handle, "logos_module_string_free"));
    if (!dispatch || !methods || !version || !strfree) {
        r.detail = QString("%1: dlsym failed: %2").arg(name, QString::fromUtf8(dlerror()));
        return r;
    }
    r.dispatchAddr = reinterpret_cast<void*>(dispatch);
    char* m = methods();
    const QString methodsJson = QString::fromUtf8(m ? m : "(null)");
    strfree(m);
    const QString protocol = QString::fromUtf8(version());
    char* out = dispatch("whoami", "[]");
    if (!out) {
        r.detail = name + ": dispatch(whoami) returned NULL";
        return r;
    }
    const QJsonObject o = QJsonDocument::fromJson(out).object();
    strfree(out);
    r.tag = o.value("module").toString();
    r.hostProtocol = o.value("host_protocol").toString();
    r.ok = !r.tag.isEmpty() && r.hostProtocol == QString::fromUtf8(lp_protocol_version());
    r.detail = QString("%1: dispatch=%2 methods=%3 module_protocol=%4 whoami.module=%5 "
                       "whoami.host_protocol=%6 (host has %7)")
                   .arg(name)
                   .arg(reinterpret_cast<quintptr>(dispatch), 0, 16)
                   .arg(methodsJson, protocol, r.tag, r.hostProtocol,
                        QString::fromUtf8(lp_protocol_version()));
    return r;
}

const char* verdict(bool ok) { return ok ? "PASS" : "FAIL"; }

} // namespace

void SpikeReportSink::onReported(const QString& what)
{
    ++reports;
    last = what;
    qInfo("[spike] host received SpikeUi signal reported(): %s", qUtf8Printable(what));
}

void spikeRunAll(QMainWindow* window)
{
    qInfo("[spike] ---- iOS dlopen spike: app image lp_protocol_version()=%s at %p, "
          "executable=%s",
          lp_protocol_version(), reinterpret_cast<void*>(&lp_protocol_version),
          qUtf8Printable(QCoreApplication::applicationFilePath()));
    const int before = static_cast<int>(_dyld_image_count());

    // ---------------- Level 1: BareA alone ----------------
    bool level1 = false;
    Loaded a = loadFramework("BareA");
    if (!a.handle) {
        qWarning("[spike] L1 dlopen(BareA) FAILED: %s", qUtf8Printable(a.error));
    } else {
        qInfo("[spike] L1 dlopen(BareA) ok in %.3f ms", a.dlopenNs / 1e6);
        BareResult ra = callBare("BareA", a.handle);
        qInfo("[spike] L1 %s", qUtf8Printable(ra.detail));
        level1 = ra.ok && ra.tag == "A";
    }
    qInfo("[spike] L1 verdict: %s", verdict(level1));

    // ---------------- Level 3: BareB beside BareA, same symbol names ----------------
    bool level3 = false;
    Loaded b = loadFramework("BareB");
    if (!b.handle) {
        qWarning("[spike] L3 dlopen(BareB) FAILED: %s", qUtf8Printable(b.error));
    } else if (a.handle) {
        qInfo("[spike] L3 dlopen(BareB) ok in %.3f ms", b.dlopenNs / 1e6);
        BareResult ra = callBare("BareA", a.handle);
        BareResult rb = callBare("BareB", b.handle);
        qInfo("[spike] L3 %s", qUtf8Printable(ra.detail));
        qInfo("[spike] L3 %s", qUtf8Printable(rb.detail));
        void* global = dlsym(RTLD_DEFAULT, "logos_module_dispatch");
        qInfo("[spike] L3 dlsym(RTLD_DEFAULT, logos_module_dispatch) = %p (expect null: RTLD_LOCAL)",
              global);
        level3 = ra.ok && rb.ok && ra.tag == "A" && rb.tag == "B"
                 && ra.dispatchAddr != rb.dispatchAddr && global == nullptr;
    }
    qInfo("[spike] L3 verdict: %s", verdict(level3));

    // ---------------- Level 2: SpikeUi (QObject + moc + Q_PROPERTY + qrc QML) ----------------
    bool level2 = false;
    const bool qrcBefore = QFile::exists(":/spike/SpikeView.qml");
    Loaded ui = loadFramework("SpikeUi");
    if (!ui.handle) {
        qWarning("[spike] L2 dlopen(SpikeUi) FAILED: %s", qUtf8Printable(ui.error));
    } else {
        qInfo("[spike] L2 dlopen(SpikeUi) ok in %.3f ms", ui.dlopenNs / 1e6);
        const bool qrcAfter = QFile::exists(":/spike/SpikeView.qml");
        qInfo("[spike] L2 qrc:/spike/SpikeView.qml registered: before=%d after=%d "
              "(static initializer -> qRegisterResourceData in the app)",
              qrcBefore, qrcAfter);
        auto create = reinterpret_cast<create_fn>(dlsym(ui.handle, "spike_ui_create"));
        auto url = reinterpret_cast<url_fn>(dlsym(ui.handle, "spike_ui_qml_url"));
        if (!create || !url) {
            qWarning("[spike] L2 dlsym failed: %s", dlerror());
        } else {
            QObject* obj = create(nullptr);
            const QMetaObject* mo = obj->metaObject();
            qInfo("[spike] L2 created %s (metaobject %p, superclass %s), %d properties, %d methods",
                  mo->className(), static_cast<const void*>(mo), mo->superClass()->className(),
                  mo->propertyCount(), mo->methodCount());
            const QString g0 = obj->property("greeting").toString();
            obj->setProperty("greeting", QStringLiteral("set by host via QObject::setProperty"));
            const QString g1 = obj->property("greeting").toString();
            qInfo("[spike] L2 Q_PROPERTY greeting: initial=\"%s\" after set=\"%s\"",
                  qUtf8Printable(g0), qUtf8Printable(g1));
            const bool isQObject = qobject_cast<QObject*>(obj) != nullptr
                                   && obj->inherits("QObject");

            auto* sink = new SpikeReportSink(obj);
            const bool connected = QObject::connect(obj, SIGNAL(reported(QString)), sink,
                                                    SLOT(onReported(QString)));
            QString invoked;
            const bool invokeOk = QMetaObject::invokeMethod(obj, "imageAddress",
                                                            Q_RETURN_ARG(QString, invoked));
            qInfo("[spike] L2 connect(reported)=%d invokeMethod(imageAddress)=%d -> %s",
                  connected, invokeOk, qUtf8Printable(invoked));

            auto* view = new QQuickWidget(window);
            view->rootContext()->setContextProperty("spikeModule", obj);
            view->setResizeMode(QQuickWidget::SizeRootObjectToView);
            QElapsedTimer t;
            t.start();
            view->setSource(QUrl(QString::fromUtf8(url())));
            qInfo("[spike] L2 setSource(%s) status=%d in %.3f ms", url(),
                  static_cast<int>(view->status()), t.nsecsElapsed() / 1e6);
            for (const QQmlError& e : view->errors())
                qWarning("[spike] L2 QML error: %s", qUtf8Printable(e.toString()));
            const bool qmlReady = view->status() == QQuickWidget::Ready && view->rootObject();
            auto* dock = new QDockWidget("spike", window);
            dock->setWidget(view);
            dock->setMinimumHeight(140);
            window->addDockWidget(Qt::BottomDockWidgetArea, dock);

            level2 = qrcAfter && isQObject && g0 != g1 && connected && invokeOk && qmlReady
                     && sink->reports >= 1 && QString(mo->className()) == "SpikeUiModule";
            qInfo("[spike] L2 QML Component.onCompleted reports received by host: %d (last: %s)",
                  sink->reports, qUtf8Printable(sink->last));

            // The QML Timer bumps the counter through the framework's metacall;
            // read it back later to show the binding is live.
            QTimer::singleShot(2500, obj, [obj, view]() {
                qInfo("[spike] L2 after 2.5 s: counter=%d (bumped from QML), view status=%d",
                      obj->property("counter").toInt(), static_cast<int>(view->status()));
            });
        }
    }
    qInfo("[spike] L2 verdict: %s", verdict(level2));

    qInfo("[spike] dyld images: %d before, %d after", before, static_cast<int>(_dyld_image_count()));
    qInfo("SPIKE RESULT level1=%s level2=%s level3=%s dlopen_ms bareA=%.3f bareB=%.3f spikeUi=%.3f",
          verdict(level1), verdict(level2), verdict(level3), a.dlopenNs / 1e6, b.dlopenNs / 1e6,
          ui.dlopenNs / 1e6);
}
