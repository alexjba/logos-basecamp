// Levels B and C: a WKWebView whose page speaks logos-protocol's plain
// transport message shapes as JSON over WKScriptMessageHandler, relayed to
// in-process LogosAPI calls (page -> native) and back (native -> page).
#pragma once

#include <core/interface.h> // PluginInterface

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QRect>
#include <QString>
#include <QVariant>
#include <QVariantList>

#include <functional>

class LogosAPI;
class LogosObject;
class QWindow;

class WebRelay : public QObject
{
    Q_OBJECT
public:
    // clientApi: the LogosAPI identity the page calls THROUGH ("web").
    explicit WebRelay(LogosAPI* clientApi, QObject* parent = nullptr);
    ~WebRelay() override;

    // Creates the WKWebView as a subview of the Qt window's UIView.
    void attach(QWindow* window, const QRect& frame);
    void loadHtml(const QString& html);

    // The token the page presents on every CallMessage. The host mints it
    // and the counter provider saves it under the caller name "web".
    void setAmbientToken(const QString& moduleName, const QString& token);

    // Level C: native -> page. The page answers with a ResultMessage.
    using PageResult = std::function<void(bool ok, const QVariant& value, const QString& err)>;
    void callPage(const QString& object, const QString& method, const QVariantList& args, PageResult cb);
    bool pageProvides(const QString& object) const { return m_provided.contains(object); }

    // Entry point from the WKScriptMessageHandler (main thread).
    void onMessageFromPage(const QString& json);

signals:
    void log(const QString& line);
    void pageReady();
    void pageProvided(const QString& object, const QStringList& methods);
    void displayed(const QString& what);

private:
    void postToPage(const QJsonObject& o);
    void handleCall(const QJsonObject& m);
    void handleSubscribe(const QJsonObject& m);
    void handleResult(const QJsonObject& m);

    LogosAPI* m_api;
    QString m_tokenModule;
    QString m_token;
    QHash<QString, LogosObject*> m_objects;
    QHash<quint64, PageResult> m_pending;
    QHash<QString, QStringList> m_provided;
    quint64 m_nextId = 1;

    struct Impl;
    Impl* d;
};

// Level C, the other half: the page as a LogosAPI PROVIDER. Every Q_INVOKABLE
// here forwards to the page and waits for its ResultMessage in a nested event
// loop, because QtProviderObject dispatches synchronously by method name.
class WebPageProvider : public QObject, public PluginInterface
{
    Q_OBJECT
    Q_INTERFACES(PluginInterface)
public:
    explicit WebPageProvider(WebRelay* relay, QString object, QObject* parent = nullptr);

    QString name() const override { return m_object; }
    QString version() const override { return QStringLiteral("0.1.0"); }
    Q_INVOKABLE void initLogos(LogosAPI* api) { logosAPI = api; }

    Q_INVOKABLE QString upper(const QString& text);

signals:
    void eventResponse(const QString& eventName, const QVariantList& data);

private:
    QVariant callSync(const QString& method, const QVariantList& args);

    WebRelay* m_relay;
    QString m_object;
};
