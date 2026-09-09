#include "JsonRpc.h"

#include <QJsonArray>
#include <QJsonDocument>

namespace jsonrpc {

QJsonObject resultOk(quint64 id, const QVariant& value)
{
    QJsonObject o;
    o["type"] = "result";
    o["id"] = static_cast<double>(id);
    o["ok"] = true;
    o["value"] = QJsonValue::fromVariant(value);
    return o;
}

QJsonObject resultErr(quint64 id, const QString& err, const QString& errCode)
{
    QJsonObject o;
    o["type"] = "result";
    o["id"] = static_cast<double>(id);
    o["ok"] = false;
    o["err"] = err;
    o["errCode"] = errCode;
    return o;
}

QJsonObject event(const QString& object, const QString& eventName, const QVariantList& data)
{
    QJsonObject o;
    o["type"] = "event";
    o["object"] = object;
    o["event"] = eventName;
    o["data"] = QJsonArray::fromVariantList(data);
    return o;
}

QJsonObject call(quint64 id, const QString& authToken, const QString& object,
                 const QString& method, const QVariantList& args)
{
    QJsonObject o;
    o["type"] = "call";
    o["id"] = static_cast<double>(id);
    o["authToken"] = authToken;
    o["object"] = object;
    o["method"] = method;
    o["args"] = QJsonArray::fromVariantList(args);
    return o;
}

QString serialize(const QJsonObject& o)
{
    return QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact));
}

QJsonObject parse(const QString& text, bool* ok)
{
    QJsonParseError e;
    const QJsonDocument d = QJsonDocument::fromJson(text.toUtf8(), &e);
    if (ok) *ok = (e.error == QJsonParseError::NoError && d.isObject());
    return d.object();
}

} // namespace jsonrpc
