.pragma library

// SHARED ROW MATCHER for the dashboard views. Events runs its filter in the
// database; the dashboards compute their rows in Python and cannot, so the same
// filter is applied to each row HERE - but with the SAME multi-condition logic,
// not the single-condition regex each view used to carry. A view keeps the
// QueryBar's structured conditions and the quick text and asks rowMatches().

function _num(x) { var n = parseFloat(x); return isNaN(n) ? null : n }

function _cmp(cell, op, want) {
    var v = String(cell === undefined || cell === null ? "" : cell)
    var vl = v.toLowerCase(), wl = String(want).toLowerCase()
    switch (op) {
    case "=": case "==": return vl === wl
    case "<>": case "!=": return vl !== wl
    case "LIKE": case "MATCH": return vl.indexOf(wl.replace(/%/g, "")) >= 0
    case "NOT LIKE": case "NOT MATCH": return vl.indexOf(wl.replace(/%/g, "")) < 0
    case ">":  { var a = _num(v), b = _num(want); return a !== null && b !== null && a > b }
    case "<":  { var c = _num(v), d = _num(want); return c !== null && d !== null && c < d }
    case ">=": { var e = _num(v), f = _num(want); return e !== null && f !== null && e >= f }
    case "<=": { var g = _num(v), h = _num(want); return g !== null && h !== null && g <= h }
    case "IS NULL": return v === ""
    case "IS NOT NULL": return v !== ""
    }
    return true
}

function _keys(row, fields) {
    var keys = []
    if (fields && fields.length)
        for (var i = 0; i < fields.length; i++)
            keys.push(fields[i].name || fields[i].k || fields[i])
    else
        for (var k in row) keys.push(k)
    return keys
}

// A row passes when it contains the quick text (in ANY field) AND satisfies the
// conditions, evaluated left to right with their AND/OR join (as SQL does,
// without operator precedence - the same as the query bar builds).
function rowMatches(row, conditions, quick, fields) {
    var keys = _keys(row, fields)
    var qq = (quick || "").trim().toLowerCase()
    if (qq !== "") {
        var any = false
        for (var a = 0; a < keys.length; a++)
            if (String(row[keys[a]] === undefined ? "" : row[keys[a]])
                    .toLowerCase().indexOf(qq) >= 0) { any = true; break }
        if (!any) return false
    }
    if (!conditions || !conditions.length) return true
    var res = null
    for (var i = 0; i < conditions.length; i++) {
        var cd = conditions[i]
        if (!cd.field) continue
        var noVal = cd.op === "IS NULL" || cd.op === "IS NOT NULL"
        if (!noVal && (cd.value === "" || cd.value === undefined || cd.value === null))
            continue
        var hit = _cmp(row[cd.field], cd.op, cd.value)
        var j = cd.join || "AND"
        if (j.indexOf("NOT") >= 0) hit = !hit
        if (res === null) res = hit
        else if (j.indexOf("OR") === 0) res = res || hit
        else res = res && hit
    }
    return res === null ? true : res
}

// parse a hand-typed WHERE into conditions (AND/OR separated; no nested parens -
// hand-written SQL is the advanced path, the builder is the common one)
function parseWhere(where) {
    var t = (where || "").trim()
    if (t === "") return []
    var parts = t.split(/\s+(AND|OR)\s+/i)
    var out = [], join = "AND"
    for (var i = 0; i < parts.length; i++) {
        var tok = parts[i].trim()
        if (/^(AND|OR)$/i.test(tok)) { join = tok.toUpperCase(); continue }
        var m = tok.match(/^\(?\s*"?(\w+)"?\s*(<>|!=|>=|<=|=|>|<|NOT\s+LIKE|LIKE|IS\s+NOT\s+NULL|IS\s+NULL)\s*'?([^')]*)'?\s*\)?$/i)
        if (m) {
            var op = m[2].toUpperCase().replace(/\s+/g, " ")
            out.push({ field: m[1], op: op, value: (m[3] || "").trim(),
                       join: out.length ? join : "AND" })
        }
    }
    return out
}
