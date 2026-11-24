#!/bin/sh
# One command to see what Pip's index knows — every kind of file, read-only.
#
#   Scripts/why.sh                     progress: how much is read, by kind
#   Scripts/why.sh yellow dress        why a search finds (or misses) things:
#                                      files holding ALL the words, then each word alone
#   Scripts/why.sh IMG_1234            everything saved for files whose name contains this
#   Scripts/why.sh ~/Desktop/photo.png everything saved for that exact file
#   Scripts/why.sh read fee statement  the FULL text Pip read from a document
#                                      (scanned PDFs and photos: the OCR'd words)
#   Scripts/why.sh view                the whole index as a page you can browse
#                                      → ~/Downloads/pip-index.html (opens in your browser)
#   Scripts/why.sh export [Desktop]    every picture + its caption, labels, text and meaning
#                                      vectors → ~/Downloads/pip-pictures-<date>.csv
#
# Labels = what a picture shows ("suit", "person"); text = words inside a file;
# caption = Pip's one-sentence description of a photo ("Photo: …", written while idle).

DIR="$HOME/Library/Application Support/Pip"
DB="$DIR/content.db"
[ -f "$DB" ] || { echo "No index yet at $DB"; exit 1; }
Q() { sqlite3 -readonly -header -column "$DB" "$1"; }
esc() { printf "%s" "$1" | sed "s/'/''/g"; }
WHERE_HAS() {   # SQL: this file's name, title, labels or text contains $1
  w=$(esc "$1")
  echo "(lower(d.path) LIKE lower('%$w%') OR lower(coalesce(d.title,'')) LIKE lower('%$w%')
         OR lower(coalesce(d.headings,'')) LIKE lower('%$w%') OR lower(d.text) LIKE lower('%$w%'))"
}
SHOW="substr(replace(d.path, '$HOME', '~'), -60) AS file,
      CASE WHEN d.text LIKE 'Picture of:%' OR d.text LIKE 'Photo:%' THEN 'picture' ELSE lower(replace(d.path, rtrim(d.path, replace(d.path, '.', '')), '')) END AS kind,
      substr(replace(coalesce(nullif(d.headings,''), d.title, ''), char(10), ', '), 1, 50) AS labels_or_title"

# --- view: the whole index as one interactive page in the browser ----------
#   Scripts/why.sh view    → ~/Downloads/pip-index.html (local file, nothing uploaded)
if [ "$1" = "view" ]; then
  OUT="$HOME/Downloads/pip-index.html"
  /usr/bin/python3 - "$DB" "$DIR/semantic.db" "$OUT" <<'PY'
import json, os, sqlite3, sys
db, sem, out = sys.argv[1:4]
home = os.path.expanduser("~")
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
cols = [r[1] for r in c.execute("PRAGMA table_info(documents)")]
cap = "d.caption" if "caption" in cols else "''"
rows = c.execute(f"""
  SELECT f.path, f.kind, f.size, f.mtime,
         CASE WHEN d.path IS NULL THEN (CASE WHEN u.path IS NULL THEN 'waiting' ELSE 'nothing inside' END)
              WHEN d.mtime = -1 THEN 'waiting' ELSE 'read' END,
         coalesce(d.title,''), replace(coalesce(d.headings,''), char(10), ', '),
         coalesce({cap},''), substr(replace(coalesce(d.text,''), char(10), ' '), 1, 220)
    FROM files f LEFT JOIN documents d ON d.path = f.path LEFT JOIN unreadable u ON u.path = f.path""").fetchall()
passages = {}
if os.path.exists(sem):
    s = sqlite3.connect(f"file:{sem}?mode=ro", uri=True)
    for path, n in s.execute("SELECT path, count(*) FROM passages GROUP BY path"):
        passages[path] = n
images = {"png","jpg","jpeg","heic","webp","gif","tiff"}
data = []
for p, kind, size, mtime, status, title, labels, caption, text in rows:
    folder = os.path.dirname(p).replace(home, "~")
    data.append([p.replace(home, "~"), kind or "", size or 0, int(mtime or 0), status, title, labels,
                 caption or "", text, passages.get(p, 0), folder.split("/")[1] if folder.count("/") >= 1 else folder])
page = """<!doctype html><meta charset="utf-8"><title>Pip's index</title>
<style>
body{font:14px -apple-system,system-ui;margin:24px;color:#1d1d1f;background:#fbfbfd}
h1{font-size:22px;font-weight:600;margin:0 0 4px}.sub{color:#86868b;margin-bottom:20px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:20px}.card{background:#fff;border:1px solid #e5e5ea;border-radius:12px;padding:12px 16px;min-width:130px}
.card b{display:block;font-size:22px}.card span{color:#86868b;font-size:12px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:20px}.box{background:#fff;border:1px solid #e5e5ea;border-radius:12px;padding:14px}
.box h2{font-size:14px;margin:0 0 10px}.bar{display:flex;align-items:center;gap:8px;margin:4px 0;font-size:12px}
.bar i{display:block;height:10px;border-radius:5px;background:#0a84ff}.bar .w{background:#e5e5ea}.bar em{font-style:normal;width:70px;color:#555}
.tag{display:inline-block;background:#f2f2f7;border-radius:10px;padding:2px 8px;margin:2px;font-size:12px;cursor:pointer}
input,select{font:14px -apple-system;padding:6px 10px;border:1px solid #d2d2d7;border-radius:8px}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e5e5ea;border-radius:12px;overflow:hidden;margin-top:10px}
td,th{padding:6px 8px;border-bottom:1px solid #f2f2f7;text-align:left;vertical-align:top;font-size:12px}th{background:#f5f5f7}
.st-read{color:#248a3d}.st-waiting{color:#b25000}.st-nothing{color:#86868b}.small{color:#86868b}
tr:hover{background:#f9f9fb;cursor:pointer}.detail{white-space:pre-wrap;background:#f9f9fb;font-size:12px}
</style>
<h1>Pip's index</h1><div class="sub">Everything Pip knows about your files — built on your Mac, nothing uploaded.</div>
<div class="cards" id="cards"></div>
<div class="grid"><div class="box"><h2>By kind (read vs waiting)</h2><div id="kinds"></div></div>
<div class="box"><h2>By folder (read vs waiting)</h2><div id="folders"></div></div></div>
<div class="box" style="margin-bottom:16px"><h2>Most common picture labels (click to filter)</h2><div id="labels"></div></div>
<div><input id="q" placeholder="Search names, labels, captions, text…" size="40">
<select id="kind"><option value="">All kinds</option></select>
<select id="status"><option value="">Any status</option><option>read</option><option>waiting</option><option>nothing inside</option></select>
<select id="pics"><option value="">All files</option><option value="cap">Pictures with caption</option><option value="nocap">Pictures without caption</option></select>
<span class="small" id="count"></span></div>
<table><thead><tr><th>File</th><th>Kind</th><th>Status</th><th>Labels / title</th><th>Caption</th><th>Vectors</th><th>Modified</th></tr></thead><tbody id="rows"></tbody></table>
<div class="small" style="margin-top:8px">Click a row for the text Pip saved. Showing the first 300 matches.</div>
<script>
const D = __DATA__; const IMG = new Set(["png","jpg","jpeg","heic","webp","gif","tiff"]);
const esc = s => String(s).replace(/[&<>]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));
const read = D.filter(r => r[4]=="read").length, waiting = D.filter(r => r[4]=="waiting").length;
const pics = D.filter(r => IMG.has(r[1])), capd = pics.filter(r => r[7]).length;
const card = (n, l) => `<div class="card"><b>${n.toLocaleString()}</b><span>${l}</span></div>`;
document.getElementById("cards").innerHTML = card(D.length,"files known") + card(read,"read") + card(waiting,"waiting to be read")
  + card(pics.length,"pictures") + card(capd,"pictures captioned") + card(D.filter(r=>r[9]>0).length,"with meaning vectors");
function bars(el, key) {
  const g = {}; D.forEach(r => { const k = key(r); g[k] = g[k] || [0,0]; g[k][r[4]=="read"?0:1]++; });
  const top = Object.entries(g).sort((a,b)=>(b[1][0]+b[1][1])-(a[1][0]+a[1][1])).slice(0,12);
  const max = Math.max(...top.map(([,v])=>v[0]+v[1]));
  document.getElementById(el).innerHTML = top.map(([k,[a,b]]) => `<div class="bar"><em>${esc(k||"?")}</em>
    <i style="width:${a/max*220}px"></i><i class="w" style="width:${b/max*220}px"></i><span class="small">${a}/${a+b}</span></div>`).join("");
}
bars("kinds", r => r[1]); bars("folders", r => r[10]);
const lc = {}; pics.forEach(r => r[6].split(", ").forEach(l => { if (l) lc[l] = (lc[l]||0)+1; }));
document.getElementById("labels").innerHTML = Object.entries(lc).sort((a,b)=>b[1]-a[1]).slice(0,80)
  .map(([l,n]) => `<span class="tag" data-l="${esc(l)}">${esc(l)} ${n}</span>`).join("");
document.querySelectorAll(".tag").forEach(t => t.onclick = () => { q.value = t.dataset.l; draw(); });
const kinds = [...new Set(D.map(r=>r[1]))].sort(); kind.innerHTML += kinds.map(k=>`<option>${esc(k)}</option>`).join("");
function draw() {
  const w = q.value.toLowerCase().split(/\\s+/).filter(Boolean);
  const out = D.filter(r => (!kind.value || r[1]==kind.value) && (!status.value || r[4]==status.value)
    && (!pics.value || (IMG.has(r[1]) && (pics.value=="cap" ? r[7] : !r[7])))
    && w.every(x => (r[0]+" "+r[5]+" "+r[6]+" "+r[7]+" "+r[8]).toLowerCase().includes(x)));
  document.getElementById("count").textContent = out.length.toLocaleString() + " matching";
  rows.innerHTML = out.slice(0,300).map((r,i) => `<tr data-i="${D.indexOf(r)}"><td>${esc(r[0])}</td><td>${esc(r[1])}</td>
    <td class="st-${r[4].split(" ")[0]}">${esc(r[4])}</td><td>${esc((r[6]||r[5]).slice(0,90))}</td><td>${esc(r[7].slice(0,90))}</td>
    <td>${r[9]}</td><td class="small">${r[3]?new Date(r[3]*1000).toLocaleDateString():""}</td></tr>`).join("");
  rows.querySelectorAll("tr").forEach(tr => tr.onclick = () => {
    const r = D[tr.dataset.i], n = tr.nextSibling;
    if (n && n.classList && n.classList.contains("d")) { n.remove(); return; }
    tr.insertAdjacentHTML("afterend", `<tr class="d"><td colspan="7" class="detail">${esc(
      "Title: "+r[5]+"\\nLabels: "+r[6]+"\\nCaption: "+r[7]+"\\nText saved: "+r[8]+"\\nMeaning vectors: "+r[9]+"\\nSize: "+r[2]+" bytes")}</td></tr>`);
  });
}
[q,kind,status,pics].forEach(e => e.oninput = draw); draw();
</script>"""
with open(out, "w") as f:
    f.write(page.replace("__DATA__", json.dumps(data)))
print(f"{len(data)} files → {out}")
PY
  open "$OUT" 2>/dev/null
  exit 0
fi

# --- export: every picture and its vectors into one CSV ---------------------
#   Scripts/why.sh export [folder-part]   e.g. "Desktop" — writes ~/Downloads/pip-pictures-<date>.csv
if [ "$1" = "export" ]; then
  OUT="$HOME/Downloads/pip-pictures-$(date +%F).csv"
  /usr/bin/python3 - "$DB" "$DIR/semantic.db" "$OUT" "${2:-}" <<'PY'
import csv, math, sqlite3, struct, sys, os
db, sem, out, only = sys.argv[1:5]
home = os.path.expanduser("~")
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
pictures = c.execute("""
  SELECT f.path, f.mtime,
         CASE WHEN d.path IS NULL THEN (CASE WHEN u.path IS NULL THEN 'not read yet' ELSE 'read - nothing found' END)
              WHEN d.mtime = -1 THEN 'waiting to be read again' ELSE 'read' END,
         replace(coalesce(d.headings, ''), char(10), ', '), replace(coalesce(d.text, ''), char(10), ' '),
         coalesce(d.caption, '')
    FROM files f LEFT JOIN documents d ON d.path = f.path LEFT JOIN unreadable u ON u.path = f.path
   WHERE f.kind IN ('png','jpg','jpeg','heic','webp','gif','tiff') AND f.path LIKE ?
   ORDER BY f.path""", (f"%{only}%",)).fetchall()
vectors = {}
if os.path.exists(sem):
    s = sqlite3.connect(f"file:{sem}?mode=ro", uri=True)
    for path, text, blob in s.execute("SELECT path, text, vec FROM passages ORDER BY path, idx"):
        vectors.setdefault(path, []).append((text, blob))
with open(out, "w", newline="") as handle:
    w = csv.writer(handle)
    w.writerow(["file", "status", "caption", "labels", "text_in_picture", "meaning_passages",
                "vector_dims", "vector_length", "vector_first_8", "passage_text"])
    for path, mtime, status, labels, text, caption in pictures:
        rows = vectors.get(path, [])
        if rows:
            ptext, blob = rows[0]
            floats = struct.unpack(f"<{len(blob)//4}f", blob)
            dims, length = len(floats), math.sqrt(sum(x * x for x in floats))
            first = " ".join(f"{x:.3f}" for x in floats[:8])
        else:
            ptext, dims, length, first = "", 0, 0, ""
        w.writerow([path.replace(home, "~"), status, caption, labels, text[:300], len(rows),
                    dims, f"{length:.3f}" if dims else "", first, ptext[:200]])
print(f"{len(pictures)} pictures → {out}")
PY
  exit 0
fi

# --- No arguments: progress -------------------------------------------------
if [ $# -eq 0 ]; then
  Q "SELECT (SELECT count(*) FROM files) AS files_known,
            (SELECT count(*) FROM documents WHERE mtime <> -1) AS read,
            (SELECT count(*) FROM unreadable) AS nothing_inside,
            (SELECT count(*) FROM documents WHERE mtime = -1) AS waiting_reread,
            (SELECT count(*) FROM documents WHERE text LIKE 'Picture of:%' OR text LIKE 'Photo:%') AS pictures_labelled,
            (SELECT count(*) FROM documents WHERE caption <> '') AS pictures_captioned;"
  # Photo vectors (MobileCLIP): how many pictures can be found by what they look like.
  [ -f "$DIR/photo.db" ] && sqlite3 -readonly -header -column "$DIR/photo.db" \
    "SELECT count(*) FILTER (WHERE length(vec) > 0) AS photo_vectors, count(*) FILTER (WHERE length(vec) = 0) AS photo_unreadable FROM photos;"
  echo
  Q "SELECT f.kind, count(*) AS files,
            sum(d.path IS NOT NULL AND d.mtime <> -1) AS read,
            count(*) - sum(d.path IS NOT NULL AND d.mtime <> -1) - sum(u.path IS NOT NULL) AS waiting
       FROM files f LEFT JOIN documents d ON d.path = f.path LEFT JOIN unreadable u ON u.path = f.path
      GROUP BY f.kind ORDER BY files DESC LIMIT 20;"
  exit 0
fi

# --- read: the full text Pip saved for one document ---------------------------
#   Scripts/why.sh read "fee statement"     (part of the name, or a full path)
if [ "$1" = "read" ] && [ $# -ge 2 ]; then
  shift
  /usr/bin/python3 - "$DB" "$DIR/semantic.db" "$DIR/photo.db" "$*" <<'PY'
import os, sqlite3, sys, datetime
db, sem, photo, want = sys.argv[1:5]
home = os.path.expanduser("~")
want = os.path.expanduser(want)
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
cols = [r[1] for r in c.execute("PRAGMA table_info(documents)")]
cap = "d.caption" if "caption" in cols else "NULL"
rows = c.execute(f"""
  SELECT f.path, f.mtime, d.mtime, d.read_at, d.title, d.headings, {cap}, d.text, u.path IS NOT NULL
    FROM files f LEFT JOIN documents d ON d.path = f.path LEFT JOIN unreadable u ON u.path = f.path
   WHERE f.path = ? OR lower(f.name) LIKE lower(?)
   ORDER BY f.mtime DESC""", (want, "%" + "%".join(want.split()) + "%")).fetchall()
if not rows:
    sys.exit(f"No file in the index matches “{want}”.")
if len(rows) > 5:
    print(f"{len(rows)} files match — showing the 5 newest. Use more of the name or the full path.\n")
def when(t): return datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M") if t and t > 0 else "—"
s = sqlite3.connect(f"file:{sem}?mode=ro", uri=True) if os.path.exists(sem) else None
p = sqlite3.connect(f"file:{photo}?mode=ro", uri=True) if os.path.exists(photo) else None
for path, fm, dm, read_at, title, headings, caption, text, empty in rows[:5]:
    bar = "=" * 72
    print(bar); print(path.replace(home, "~")); print(bar)
    if text is None:
        status = "read — nothing inside (or dropped to save space)" if empty else "NOT READ YET"
    elif dm == -1:
        status = "waiting to be read again"
    else:
        status = f"read {when(read_at)}"
    print(f"Status    : {status}\nModified  : {when(fm)}")
    if title: print(f"Title     : {title}")
    if headings: print(f"Headings  : {headings.replace(chr(10), ' · ')}")
    if caption is not None: print(f"Caption   : {caption or '(looked — too small to caption)'}")
    if s:
        n = s.execute("SELECT count(*) FROM passages WHERE path = ?", (path,)).fetchone()[0]
        print(f"Meaning   : {n} passage(s) with vectors")
    if p:
        r = p.execute("SELECT length(vec) FROM photos WHERE path = ?", (path,)).fetchone()
        if r: print(f"Photo vec : {'yes (512 numbers)' if r[0] else 'empty — under 200 px or unreadable'}")
    if text:
        print(f"\n--- Text Pip saved ({len(text)} characters; at most 4,000 are kept) ---\n")
        print(text)
    print()
PY
  exit $?
fi

# --- One argument that is a file, or part of a file name: what was saved ----
if [ $# -eq 1 ]; then
  ARG=$(esc "$1")
  case "$1" in ~*|/*) ARG=$(esc "$(eval echo "$1")") ;; esac
  N=$(sqlite3 -readonly "$DB" "SELECT count(*) FROM files WHERE path = '$ARG' OR name LIKE '%$ARG%';")
  if [ "$N" -gt 0 ] && [ "$N" -le 25 ]; then
    sqlite3 -readonly -line "$DB" "
      SELECT replace(f.path, '$HOME', '~') AS file,
             datetime(f.mtime, 'unixepoch', 'localtime') AS modified,
             CASE WHEN d.path IS NULL THEN (CASE WHEN u.path IS NULL THEN 'NOT READ YET' ELSE 'read — nothing inside' END)
                  WHEN d.mtime = -1 THEN 'waiting to be read again'
                  ELSE 'read ' || datetime(d.read_at, 'unixepoch', 'localtime') END AS status,
             coalesce(d.title, '') AS title,
             CASE WHEN d.caption IS NULL THEN '' WHEN d.caption = '' THEN '(too small to caption)' ELSE d.caption END AS caption,
             replace(coalesce(d.headings, ''), char(10), ', ') AS labels_or_headings,
             substr(replace(coalesce(d.text, ''), char(10), ' '), 1, 300) AS text_start
        FROM files f LEFT JOIN documents d ON d.path = f.path LEFT JOIN unreadable u ON u.path = f.path
       WHERE f.path = '$ARG' OR f.name LIKE '%$ARG%' LIMIT 25;"
    exit 0
  fi
fi

# --- Words: why a search finds or misses things ------------------------------
ALL=""
for word in "$@"; do
  [ -n "$ALL" ] && ALL="$ALL AND "
  ALL="$ALL$(WHERE_HAS "$word")"
done
echo "== Files holding ALL of: $*"
Q "SELECT $SHOW FROM documents d WHERE $ALL ORDER BY d.read_at DESC LIMIT 25;"
for word in "$@"; do
  echo; echo "== '$word' alone (count, then a few)"
  sqlite3 -readonly "$DB" "SELECT count(*) || ' files' FROM documents d WHERE $(WHERE_HAS "$word");"
  Q "SELECT $SHOW FROM documents d WHERE $(WHERE_HAS "$word") ORDER BY d.read_at DESC LIMIT 8;"
done
echo
echo "Tip: no picture under a word means no photo was labelled with it — Apple's labels"
echo "name things (dress, person, beach), not colours, unless colour labels were added."
