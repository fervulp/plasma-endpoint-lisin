.pragma library

// TIME FORMATTING FOR THE INTERFACE.
//
// In the stores the time is kept in UTC (`2026-07-21T09:34:02Z`) and that is
// right: deduplication by event_id, correlation windows, retention and
// "greater/less" comparisons straight in SQL all rest on a sortable UTC string.
// The storage must not be changed.
//
// But SHOWING UTC to the user means lying by the size of their time zone: in
// UTC+3 the events looked three hours behind. So the conversion to local time
// happens exactly here, at the display boundary.
//
// Parsing tolerates both forms: with "Z" and without it (without a suffix we
// still treat it as UTC - that is how the pipeline writes it).

function _pad(n) { return n < 10 ? "0" + n : "" + n }

function _parse(ts) {
    if (ts === undefined || ts === null) return null
    var s = String(ts).trim()
    if (s === "") return null
    // no explicit zone - append Z, otherwise the engine treats the string as local
    if (s.indexOf("Z") < 0 && s.indexOf("+") < 0 && !/-\d{2}:\d{2}$/.test(s))
        s += "Z"
    var d = new Date(s)
    return isNaN(d.getTime()) ? null : d
}

// "2026-07-21 12:34:02" - local time, full date
function local(ts) {
    var d = _parse(ts)
    if (d === null) return ts === undefined || ts === null ? "" : String(ts)
    return d.getFullYear() + "-" + _pad(d.getMonth() + 1) + "-" + _pad(d.getDate())
         + " " + _pad(d.getHours()) + ":" + _pad(d.getMinutes())
         + ":" + _pad(d.getSeconds())
}

// "12:34:02" - only the time, when the date is obvious from the context
function localTime(ts) {
    var d = _parse(ts)
    if (d === null) return ""
    return _pad(d.getHours()) + ":" + _pad(d.getMinutes()) + ":" + _pad(d.getSeconds())
}

// "12:34" - hours and minutes of local time (for tight graph labels)
function localHM(ts) {
    var d = _parse(ts)
    if (d === null) return ""
    return _pad(d.getHours()) + ":" + _pad(d.getMinutes())
}

// "2026-07-21 12:34" - without seconds
function localShort(ts) {
    var s = local(ts)
    return s.length > 16 ? s.substring(0, 16) : s
}
