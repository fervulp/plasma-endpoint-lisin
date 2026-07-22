.pragma library

// ФОРМАТ ВРЕМЕНИ ДЛЯ ИНТЕРФЕЙСА.
//
// В хранилищах время лежит в UTC (`2026-07-21T09:34:02Z`) и это правильно:
// на сортируемой UTC-строке держатся дедупликация по event_id, окна
// корреляции, retention и сравнение «больше/меньше» прямо в SQL. Менять
// хранение нельзя.
//
// Но ПОКАЗЫВАТЬ UTC пользователю — значит врать на величину его часового
// пояса: в UTC+3 события выглядели отставшими на 3 часа. Поэтому перевод в
// местное время делается ровно здесь, на границе отображения.
//
// Разбор устойчив к обоим видам записи: с «Z» и без него (без суффикса
// считаем, что это всё равно UTC — так пишет конвейер).

function _pad(n) { return n < 10 ? "0" + n : "" + n }

function _parse(ts) {
    if (ts === undefined || ts === null) return null
    var s = String(ts).trim()
    if (s === "") return null
    // нет явной зоны — дописываем Z, иначе движок считает строку местной
    if (s.indexOf("Z") < 0 && s.indexOf("+") < 0 && !/-\d{2}:\d{2}$/.test(s))
        s += "Z"
    var d = new Date(s)
    return isNaN(d.getTime()) ? null : d
}

// «2026-07-21 12:34:02» — местное время, полная дата
function local(ts) {
    var d = _parse(ts)
    if (d === null) return ts === undefined || ts === null ? "" : String(ts)
    return d.getFullYear() + "-" + _pad(d.getMonth() + 1) + "-" + _pad(d.getDate())
         + " " + _pad(d.getHours()) + ":" + _pad(d.getMinutes())
         + ":" + _pad(d.getSeconds())
}

// «12:34:02» — только время, когда дата очевидна из контекста
function localTime(ts) {
    var d = _parse(ts)
    if (d === null) return ""
    return _pad(d.getHours()) + ":" + _pad(d.getMinutes()) + ":" + _pad(d.getSeconds())
}

// «12:34» — часы и минуты местного времени (для тесных подписей графа)
function localHM(ts) {
    var d = _parse(ts)
    if (d === null) return ""
    return _pad(d.getHours()) + ":" + _pad(d.getMinutes())
}

// «2026-07-21 12:34» — без секунд
function localShort(ts) {
    var s = local(ts)
    return s.length > 16 ? s.substring(0, 16) : s
}
