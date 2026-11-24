#!/bin/bash
#
# What does Spotlight already know?
#
# The whole question behind lazy semantic search is how much work macOS has
# already done for us. Spotlight indexes every file on the machine and extracts
# text from anything that takes real effort to read — so if kMDItemTextContent
# is populated for PDFs, we never have to parse a PDF at all.
#
# This prints the attributes that are actually present, per file type, on this
# Mac. Guessing at that from documentation is how you end up building an
# indexer for something the system already indexed.
#
#   ./Scripts/probe-metadata.sh [folder]      default: ~/Downloads
#
set -uo pipefail

FOLDER="${1:-$HOME/Downloads}"
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

say "Folder: $FOLDER"
echo "$(find "$FOLDER" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') files at the top level"

# ---------------------------------------------------------------- what's here
say "What's in here, by kind"
mdfind -onlyin "$FOLDER" 'kMDItemFSName == "*"' 2>/dev/null \
  | head -2000 \
  | while read -r f; do mdls -name kMDItemKind -raw "$f" 2>/dev/null; echo; done \
  | sort | uniq -c | sort -rn | head -15

# --------------------------------------------------- does text extraction work
say "kMDItemTextContent — is the text already extracted?"
printf '%-28s %-10s %s\n' "FILE" "CHARS" "FIRST LINE"
for ext in pdf png jpg jpeg heic docx txt md pptx xlsx; do
  file=$(find "$FOLDER" -maxdepth 1 -type f -iname "*.$ext" 2>/dev/null | head -1)
  [[ -z "$file" ]] && continue
  text=$(mdls -name kMDItemTextContent -raw "$file" 2>/dev/null)
  if [[ "$text" == "(null)" || -z "$text" ]]; then
    printf '%-28s %-10s %s\n' ".$ext" "—" "not extracted"
  else
    printf '%-28s %-10s %s\n' ".$ext" "${#text}" "$(echo "$text" | tr '\n' ' ' | cut -c1-40)"
  fi
done

# ------------------------------------------------------- attributes by type
for ext in pdf png jpg; do
  file=$(find "$FOLDER" -maxdepth 1 -type f -iname "*.$ext" 2>/dev/null | head -1)
  [[ -z "$file" ]] && continue
  say "Every attribute Spotlight holds for a .$ext"
  echo "($(basename "$file"))"
  mdls "$file" 2>/dev/null \
    | grep -v '= (null)$' \
    | sed 's/kMDItem//' \
    | cut -c1-110
done

# ------------------------------------------------ the one that matters for ~/Downloads
say "kMDItemWhereFroms — where did these come from?"
echo "(the URL a file was downloaded from, which is searchable text nobody thinks of)"
find "$FOLDER" -maxdepth 1 -type f 2>/dev/null | head -8 | while read -r f; do
  from=$(mdls -name kMDItemWhereFroms -raw "$f" 2>/dev/null | tr -d '\n' | cut -c1-90)
  [[ "$from" == "(null)" ]] && continue
  printf '  %-30s %s\n' "$(basename "$f" | cut -c1-28)" "$from"
done

# ------------------------------------------------------------- how fast is it
say "How fast is a Spotlight query?"
start=$(python3 -c 'import time; print(time.time())')
count=$(mdfind -onlyin "$FOLDER" "kMDItemTextContent == '*a*'c" 2>/dev/null | wc -l | tr -d ' ')
end=$(python3 -c 'import time; print(time.time())')
python3 -c "print(f'  content search over the folder: {($end - $start)*1000:.0f} ms, $count hits')"

say "Is Vision OCR available?"
python3 - <<'PY' 2>/dev/null || echo "  (couldn't check — needs pyobjc, not important)"
print("  Vision.framework ships with macOS; the app will call it directly from Swift.")
PY

say "Done"
echo "Paste the output back and we'll design against what's actually there."

# ---------------------------------------------------------------- PDF internals
say "What a PDF says about itself (nothing to do with Spotlight)"
echo "(these live inside the file, and PDFKit reads them in about a millisecond)"
file=$(find "$FOLDER" -maxdepth 1 -type f -iname "*.pdf" 2>/dev/null | head -1)
if [[ -n "$file" ]]; then
  echo "  $(basename "$file")"
  mdls -name kMDItemTitle -name kMDItemAuthors -name kMDItemSubject \
       -name kMDItemKeywords -name kMDItemNumberOfPages \
       -name kMDItemContentCreationDate -name kMDItemWhereFroms \
       "$file" 2>/dev/null | sed 's/^/    /'
  echo
  echo "  Spotlight's copy is above. The file's own copy is below —"
  echo "  they can differ, and only the second one survives a broken index:"
  python3 - "$file" <<'PY' 2>/dev/null || echo "    (install pyobjc to read these, or just trust the app)"
import sys
try:
    from Quartz import PDFDocument
    from Foundation import NSURL
    doc = PDFDocument.alloc().initWithURL_(NSURL.fileURLWithPath_(sys.argv[1]))
    attrs = doc.documentAttributes() if doc else None
    if attrs:
        for key in ("Title", "Author", "Subject", "Keywords", "Creator", "Producer"):
            value = attrs.get(key)
            if value:
                print(f"    {key:10s} {value}")
    outline = doc.outlineRoot() if doc else None
    if outline:
        n = outline.numberOfChildren()
        print(f"    Outline    {n} top-level entries")
        for i in range(min(n, 5)):
            print(f"               - {outline.childAtIndex_(i).label()}")
except Exception as e:
    print(f"    (couldn't read: {e})")
PY
else
  echo "  no PDFs in $FOLDER"
fi
