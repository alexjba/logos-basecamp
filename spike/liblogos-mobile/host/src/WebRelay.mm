#include "WebRelay.h"
#include "JsonRpc.h"

#include <logos_api.h>
#include <logos_api_client.h>
#include <logos_object.h>
#include <token_manager.h>

#include <QElapsedTimer>
#include <QEventLoop>
#include <QJsonArray>
#include <QJsonDocument>
#include <QTimer>
#include <QWindow>

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// ── Channel ──────────────────────────────────────────────────────────────────
//
// Not WKScriptMessageHandler: deserializing a script message creates a
// JSContext in the app process, and JavaScriptCore traps in
// JSC::sanitizeStackForVM under Qt's iOS run-loop integration (main() runs on
// a separate stack with RLIMIT_STACK lowered; see SPIKE-REPORT.md). A custom
// URL scheme keeps every byte of the page <-> native traffic out of
// JavaScriptCore on the app side:
//
//   page -> native   fetch("logos://host/msg", {method:"POST", body: <one JSON message>})
//   native -> page   fetch("logos://host/inbox")  long-poll, answered with a JSON array
//                    of messages as soon as any are queued.
//   the page itself  logos://host/index.html, so both are same-origin.

@interface LogosSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, assign) WebRelay* relay;
@property (nonatomic, strong) NSString* html;
@property (nonatomic, strong) id<WKURLSchemeTask> inboxTask;
@property (nonatomic, strong) NSMutableArray<NSString*>* outbox;
- (void)flushInbox;
@end

static void respond(id<WKURLSchemeTask> task, NSString* mime, NSData* body)
{
    NSHTTPURLResponse* r = [[NSHTTPURLResponse alloc]
        initWithURL:task.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{ @"Content-Type": mime, @"Cache-Control": @"no-store",
                        @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length] }];
    [task didReceiveResponse:r];
    [task didReceiveData:body];
    [task didFinish];
}

@implementation LogosSchemeHandler
- (instancetype)init
{
    self = [super init];
    self.outbox = [NSMutableArray array];
    return self;
}

- (void)webView:(WKWebView*)webView startURLSchemeTask:(id<WKURLSchemeTask>)task
{
    NSString* path = task.request.URL.path;
    if ([path isEqualToString:@"/index.html"] || [path isEqualToString:@"/"]) {
        respond(task, @"text/html; charset=utf-8", [self.html dataUsingEncoding:NSUTF8StringEncoding]);
    } else if ([path isEqualToString:@"/msg"]) {
        NSData* body = task.request.HTTPBody;
        if (!body && task.request.HTTPBodyStream) {
            NSInputStream* s = task.request.HTTPBodyStream;
            [s open];
            NSMutableData* m = [NSMutableData data];
            uint8_t buf[4096];
            while ([s hasBytesAvailable]) {
                NSInteger n = [s read:buf maxLength:sizeof buf];
                if (n <= 0) break;
                [m appendBytes:buf length:(NSUInteger)n];
            }
            [s close];
            body = m;
        }
        NSString* json = body ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : @"";
        respond(task, @"application/json", [@"{}" dataUsingEncoding:NSUTF8StringEncoding]);
        if (self.relay) self.relay->onMessageFromPage(QString::fromNSString(json));
    } else if ([path isEqualToString:@"/inbox"]) {
        self.inboxTask = task;
        [self flushInbox];
    } else {
        NSError* e = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
        [task didFailWithError:e];
    }
}

- (void)webView:(WKWebView*)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task
{
    if (task == self.inboxTask) self.inboxTask = nil;
}

- (void)flushInbox
{
    if (!self.inboxTask || self.outbox.count == 0) return;
    NSString* array = [NSString stringWithFormat:@"[%@]", [self.outbox componentsJoinedByString:@","]];
    [self.outbox removeAllObjects];
    id<WKURLSchemeTask> task = self.inboxTask;
    self.inboxTask = nil;
    respond(task, @"application/json", [array dataUsingEncoding:NSUTF8StringEncoding]);
}
@end

struct WebRelay::Impl {
    WKWebView* webView = nil;
    LogosSchemeHandler* handler = nil;
};

// ── WebRelay ─────────────────────────────────────────────────────────────────

WebRelay::WebRelay(LogosAPI* clientApi, QObject* parent)
    : QObject(parent), m_api(clientApi), d(new Impl)
{
}

WebRelay::~WebRelay()
{
    for (LogosObject* o : m_objects) if (o) o->release();
    if (d->webView) [d->webView removeFromSuperview];
    delete d;
}

void WebRelay::attach(QWindow* window, const QRect& frame)
{
    UIView* host = (__bridge UIView*)reinterpret_cast<void*>(window->winId());
    WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];
    d->handler = [[LogosSchemeHandler alloc] init];
    d->handler.relay = this;
    [cfg setURLSchemeHandler:d->handler forURLScheme:@"logos"];
    d->webView = [[WKWebView alloc] initWithFrame:CGRectMake(frame.x(), frame.y(), frame.width(), frame.height())
                                    configuration:cfg];
    d->webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [host addSubview:d->webView];
    emit log(QStringLiteral("WKWebView attached (%1x%2), channel logos:// URL scheme").arg(frame.width()).arg(frame.height()));
}

void WebRelay::loadHtml(const QString& html)
{
    d->handler.html = html.toNSString();
    [d->webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"logos://host/index.html"]]];
}

void WebRelay::setAmbientToken(const QString& moduleName, const QString& token)
{
    m_tokenModule = moduleName;
    m_token = token;
}

void WebRelay::postToPage(const QJsonObject& o)
{
    [d->handler.outbox addObject:jsonrpc::serialize(o).toNSString()];
    [d->handler flushInbox];
}

void WebRelay::onMessageFromPage(const QString& json)
{
    bool ok = false;
    const QJsonObject m = jsonrpc::parse(json, &ok);
    if (!ok) {
        emit log(QStringLiteral("page sent non-JSON: %1").arg(json.left(80)));
        return;
    }
    const QString type = m.value("type").toString();
    if (type == "ready") {
        emit log(QStringLiteral("page ready"));
        // TokenMessage shape: {authToken, moduleName, token}
        QJsonObject t;
        t["type"] = "token";
        t["authToken"] = QString();
        t["moduleName"] = m_tokenModule;
        t["token"] = m_token;
        postToPage(t);
        emit pageReady();
    } else if (type == "call") {
        handleCall(m);
    } else if (type == "subscribe") {
        handleSubscribe(m);
    } else if (type == "result") {
        handleResult(m);
    } else if (type == "provide") {
        const QString object = m.value("object").toString();
        QStringList methods;
        for (const auto& v : m.value("methods").toArray()) methods << v.toString();
        m_provided[object] = methods;
        emit log(QStringLiteral("page provides %1: %2").arg(object, methods.join(", ")));
        emit pageProvided(object, methods);
    } else if (type == "display") {
        emit displayed(m.value("text").toString());
    } else {
        emit log(QStringLiteral("page sent unknown type %1").arg(type));
    }
}

void WebRelay::handleCall(const QJsonObject& m)
{
    const quint64 id = static_cast<quint64>(m.value("id").toDouble());
    const QString token = m.value("authToken").toString();
    const QString object = m.value("object").toString();
    const QString method = m.value("method").toString();
    const QVariantList args = m.value("args").toArray().toVariantList();

    // The page's token is what the provider sees: install it in this
    // identity's token store so LogosAPIClient presents it instead of
    // minting one through capability_module (not loaded in this spike).
    if (!token.isEmpty())
        m_api->getTokenManager()->saveToken(object, token);

    QElapsedTimer t;
    t.start();
    LogosAPIClient* client = m_api->getClient(object);
    const QVariant r = client->invokeRemoteMethod(object, method, args, Timeout(5000));
    emit log(QStringLiteral("page -> %1.%2(%3) = %4 in %5 ms")
                 .arg(object, method, QString::fromUtf8(QJsonDocument(QJsonArray::fromVariantList(args)).toJson(QJsonDocument::Compact)),
                      r.isValid() ? r.toString() : QStringLiteral("<invalid>"))
                 .arg(t.elapsed()));
    if (r.isValid())
        postToPage(jsonrpc::resultOk(id, r));
    else
        postToPage(jsonrpc::resultErr(id, QStringLiteral("call failed or unauthorized"), QStringLiteral("unauthorized")));
}

void WebRelay::handleSubscribe(const QJsonObject& m)
{
    const QString object = m.value("object").toString();
    const QString eventName = m.value("event").toString();
    LogosAPIClient* client = m_api->getClient(object);
    LogosObject*& obj = m_objects[object];
    if (!obj) obj = client->requestObject(object);
    if (!obj) {
        emit log(QStringLiteral("subscribe: no object %1").arg(object));
        return;
    }
    client->onEvent(obj, eventName, [this, object](const QString& name, const QVariantList& data) {
        emit log(QStringLiteral("event %1.%2 %3 -> page").arg(object, name,
            QString::fromUtf8(QJsonDocument(QJsonArray::fromVariantList(data)).toJson(QJsonDocument::Compact))));
        postToPage(jsonrpc::event(object, name, data));
    });
    emit log(QStringLiteral("page subscribed to %1.%2").arg(object, eventName));
}

void WebRelay::handleResult(const QJsonObject& m)
{
    const quint64 id = static_cast<quint64>(m.value("id").toDouble());
    auto it = m_pending.find(id);
    if (it == m_pending.end()) {
        emit log(QStringLiteral("result for unknown id %1").arg(id));
        return;
    }
    PageResult cb = it.value();
    m_pending.erase(it);
    cb(m.value("ok").toBool(), m.value("value").toVariant(), m.value("err").toString());
}

void WebRelay::callPage(const QString& object, const QString& method, const QVariantList& args, PageResult cb)
{
    const quint64 id = m_nextId++;
    m_pending[id] = std::move(cb);
    postToPage(jsonrpc::call(id, QString(), object, method, args));
}

// ── WebPageProvider ──────────────────────────────────────────────────────────

WebPageProvider::WebPageProvider(WebRelay* relay, QString object, QObject* parent)
    : QObject(parent), m_relay(relay), m_object(std::move(object))
{
}

QVariant WebPageProvider::callSync(const QString& method, const QVariantList& args)
{
    QEventLoop loop;
    QVariant out;
    bool done = false;
    m_relay->callPage(m_object, method, args, [&](bool ok, const QVariant& v, const QString& err) {
        out = ok ? v : QVariant();
        if (!ok) qWarning() << "WebPageProvider:" << method << "failed:" << err;
        done = true;
        loop.quit();
    });
    QTimer::singleShot(5000, &loop, &QEventLoop::quit);
    loop.exec();
    if (!done) qWarning() << "WebPageProvider:" << method << "timed out";
    return out;
}

QString WebPageProvider::upper(const QString& text)
{
    return callSync(QStringLiteral("upper"), QVariantList{text}).toString();
}
