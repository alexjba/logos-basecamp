// JSON shapes mirrored from logos-protocol's plain transport
// (cpp/implementations/plain/rpc_message.h, json_mapping.cpp): the same field
// names, plus a "type" discriminator because the WebKit channel carries one
// JSON object per message rather than a framed byte stream.
//
//   Call        {type:"call",        id, authToken, object, method, args:[...]}
//   Result      {type:"result",      id, ok, value | err, errCode}
//   Subscribe   {type:"subscribe",   object, event}
//   Unsubscribe {type:"unsubscribe", object, event}
//   Event       {type:"event",       object, event, data:[...]}
#pragma once

#include <QJsonObject>
#include <QString>
#include <QVariant>
#include <QVariantList>

namespace jsonrpc {

QJsonObject resultOk(quint64 id, const QVariant& value);
QJsonObject resultErr(quint64 id, const QString& err, const QString& errCode);
QJsonObject event(const QString& object, const QString& eventName, const QVariantList& data);
QJsonObject call(quint64 id, const QString& authToken, const QString& object,
                 const QString& method, const QVariantList& args);

QString serialize(const QJsonObject& o);
QJsonObject parse(const QString& text, bool* ok);

} // namespace jsonrpc
