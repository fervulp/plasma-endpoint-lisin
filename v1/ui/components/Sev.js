.pragma library

// ONE SEVERITY PALETTE for every table's accent stripe, so the same severity is
// the same colour in every section (principle 17: the tables look alike). Before
// this each view carried its own hex - "critical" was #c0392b in one table and
// #e74c3c in another. A .pragma library cannot read Kirigami.Theme, so the
// palette is fixed; a thin saturated stripe reads the same in light and dark.

var CRITICAL = "#c0392b"   // dark red - the top tier
var HIGH     = "#e74c3c"   // red
var MEDIUM   = "#e67e22"   // orange
var LOW      = "#f1c40f"   // amber

// a 0-100 event-severity SCORE -> colour, on the shared 70/45/25 tiers
function byScore(n) {
    var s = Number(n)
    if (isNaN(s) || s <= 0) return ""
    return s >= 70 ? HIGH : s >= 45 ? MEDIUM : s >= 25 ? LOW : ""
}

// THE COMPREHENSIVE ACCENT for a state/events row: it looks at whichever
// severity field the row carries (event_severity, severity/cvss_rating, risk,
// exposure, status, deleted). Used by the "Data" table for every tab.
function stateAccent(r) {
    if (!r) return ""
    if (String(r.event_kind || "") === "alert") return HIGH
    var byS = byScore(r.event_severity)
    if (byS !== "") return byS
    var s = String(r.severity || r.cvss_rating || "").toLowerCase()
    if (s.indexOf("critical") >= 0) return CRITICAL
    if (s.indexOf("important") >= 0 || s.indexOf("high") >= 0) return HIGH
    if (s.indexOf("moderate") >= 0 || s.indexOf("medium") >= 0) return MEDIUM
    if (s.indexOf("low") >= 0) return LOW
    var risk = String(r.risk || "").toLowerCase()
    if (risk === "high") return HIGH
    if (risk === "medium") return MEDIUM
    var exp = String(r.exposure || "")
    if (exp.indexOf("OPEN") >= 0) return HIGH
    if (exp.indexOf("filtered") >= 0) return MEDIUM
    var st = String(r.status || "").toLowerCase()
    if (st === "open" || st === "differs") return MEDIUM
    if (String(r.deleted || "") === "yes") return HIGH
    return ""
}
