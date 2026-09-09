#include "CounterModule.h"

CounterModule::CounterModule(QObject* parent)
    : QObject(parent)
{
}

int CounterModule::add(int a, int b)
{
    const int r = a + b;
    emit eventResponse(QStringLiteral("added"), QVariantList{a, b, r});
    return r;
}

int CounterModule::increment()
{
    ++m_value;
    emit eventResponse(QStringLiteral("valueChanged"), QVariantList{m_value});
    return m_value;
}
