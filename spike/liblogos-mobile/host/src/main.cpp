// liblogos smoke host for iOS: Level A (core up in-process), Level B (a web
// page calls a statically linked native module through LogosAPI in Local
// mode and receives its events), Level C (the page is a provider the host
// invokes by name through LogosAPI).
#include <QtGlobal>

#include "CounterModule.h"
#include "SmokeRunner.h"
#if defined(Q_OS_IOS)
#include "WebRelay.h"
#endif

#include <logos_api.h>
#include <logos_api_client.h>
#include <logos_api_provider.h>
#include <token_manager.h>

#include <QApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QMainWindow>
#include <QPlainTextEdit>
#include <QPluginLoader>
#include <QScreen>
#include <QTimer>
#include <QUuid>
#include <QWindow>

#include <cstdio>
#if defined(Q_OS_ANDROID)
#include <android/log.h>
#endif

Q_IMPORT_PLUGIN(CounterModule)

namespace {

QPlainTextEdit* g_log = nullptr;

void console(const char* tag, const QString& line)
{
#if defined(Q_OS_ANDROID)
    __android_log_print(ANDROID_LOG_INFO, "smoke", "[%s] %s", tag, qUtf8Printable(line));
#else
    std::fprintf(stderr, "[%s] %s\n", tag, qUtf8Printable(line));
    std::fflush(stderr);
#endif
}

void say(const QString& line)
{
    console("smoke", line);
    if (g_log) g_log->appendPlainText(line);
}

void qtMessages(QtMsgType type, const QMessageLogContext&, const QString& msg)
{
    // Qt's own debug is loud (LogosAPI traces every call); keep warnings and
    // above on the screen, everything on the console.
    console("qt", msg);
    // QtRemoteObjects repeats this one on every socket on Android.
    if (msg.contains("localabstract")) return;
    if (g_log && type >= QtWarningMsg) g_log->appendPlainText("qt: " + msg);
}

} // namespace

int main(int argc, char* argv[])
{
    QApplication app(argc, argv);
    app.setOrganizationName("Logos");
    app.setApplicationName("LiblogosSmoke");
    qInstallMessageHandler(qtMessages);

    QMainWindow window;
    auto* logView = new QPlainTextEdit;
    logView->setReadOnly(true);
    g_log = logView;
    window.setCentralWidget(logView);
    window.showFullScreen();

    // ── Level A ────────────────────────────────────────────────────────────
    SmokeRunner runner;
    QObject::connect(&runner, &SmokeRunner::log, &say);
    QElapsedTimer total;
    total.start();
    runner.run(argc, argv);
    say(QStringLiteral("LEVEL A: core up (%1 ms since main)").arg(total.elapsed()));

    // ── Level B: native side ───────────────────────────────────────────────
    CounterModule* counter = nullptr;
    for (QObject* o : QPluginLoader::staticInstances())
        if (auto* c = qobject_cast<CounterModule*>(o)) counter = c;
    if (!counter) {
        say("LEVEL B: no static CounterModule instance; Q_IMPORT_PLUGIN missing?");
        return app.exec();
    }
    say(QStringLiteral("static plugins: %1").arg(QPluginLoader::staticInstances().size()));

    // Provider: the counter, published in Local mode (PluginRegistry).
    LogosAPI counterApi("counter");
    counterApi.getProvider()->registerObject("counter", counter);
    // Ambient tokens: no capability_module is loaded, so the host mints the
    // tokens and installs them on both sides itself.
    const QString hostToken = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QString webToken = QUuid::createUuid().toString(QUuid::WithoutBraces);
    counterApi.getProvider()->saveToken("host", hostToken);
    counterApi.getProvider()->saveToken("web", webToken);

    // A native caller first, to separate transport problems from WebKit ones.
    LogosAPI hostApi("host");
    hostApi.getTokenManager()->saveToken("counter", hostToken);
    {
        QElapsedTimer t;
        t.start();
        const QVariant r = hostApi.getClient("counter")->invokeRemoteMethod("counter", "add", 1, 2);
        say(QStringLiteral("native host -> counter.add(1,2) = %1 in %2 ms").arg(r.toString()).arg(t.elapsed()));
    }

#if defined(Q_OS_IOS)
    // ── Level B: web side ──────────────────────────────────────────────────
    LogosAPI webApi("web");
    WebRelay relay(&webApi);
    QObject::connect(&relay, &WebRelay::log, &say);
    relay.setAmbientToken("counter", webToken);

    const QRect screen = app.primaryScreen()->geometry();
    const int webH = screen.height() * 45 / 100;
    relay.attach(window.windowHandle(), QRect(0, screen.height() - webH, screen.width(), webH));

    QFile html(":/web/index.html");
    if (!html.open(QIODevice::ReadOnly)) {
        say("cannot open :/web/index.html");
        return app.exec();
    }
    relay.loadHtml(QString::fromUtf8(html.readAll()));

    QObject::connect(&relay, &WebRelay::displayed, [](const QString& what) {
        say(QStringLiteral("LEVEL B: page displays \"%1\"").arg(what));
    });

    // ── Level C ────────────────────────────────────────────────────────────
    LogosAPI pageApi("webpage");
    WebPageProvider pageProvider(&relay, "webpage");
    LogosAPI hostApi2("host2");
    QObject::connect(&relay, &WebRelay::pageProvided, [&](const QString& object, const QStringList&) {
        if (object != "webpage") return;
        pageApi.getProvider()->registerObject("webpage", &pageProvider);
        const QString tok = QUuid::createUuid().toString(QUuid::WithoutBraces);
        pageApi.getProvider()->saveToken("host2", tok);
        hostApi2.getTokenManager()->saveToken("webpage", tok);
        QTimer::singleShot(0, [&]() {
            QElapsedTimer t;
            t.start();
            const QVariant r = hostApi2.getClient("webpage")->invokeRemoteMethod("webpage", "upper", "hello from native");
            say(QStringLiteral("LEVEL C: host -> webpage.upper(\"hello from native\") = \"%1\" in %2 ms")
                    .arg(r.toString()).arg(t.elapsed()));
        });
    });

#else
    say("LEVEL B/C web half: iOS only in this spike (no WebView here)");
#endif
    return app.exec();
}
