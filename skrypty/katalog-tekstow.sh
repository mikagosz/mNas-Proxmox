#!/bin/bash
# Odświeża MyApp/Localizable.xcstrings z kodu i liczy, co zostało do przetłumaczenia.
#
# Polskie teksty są w kodzie kluczami (decyzja 2026-10-04), angielski jest tłumaczeniem.
# Kolejność:
#   1. build Debug — kompilator Swifta z SWIFT_EMIT_LOC_STRINGS zapisuje hasła do *.stringsdata;
#   2. `xcstringstool sync` dopisuje nowe hasła do katalogu i oznacza usunięte z kodu jako stale;
#   3. każde hasło dostaje jawny wpis `pl` równy kluczowi — bez tego kompilator katalogu
#      nie tworzy pl.lproj (język źródłowy uważa za zapisany w kodzie) i polski system
#      dostawał angielski (zmierzone 2026-10-04);
#   4. raport: ile haseł, ile z angielskim, ile bez.
#
# Użycie: skrypty/katalog-tekstow.sh [katalog-na-build]
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${1:-${TMPDIR:-/tmp}/mnas-katalog-tekstow}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
KATALOG=MyApp/Localizable.xcstrings

xcodebuild -project mNas.xcodeproj -scheme mNas -configuration Debug -derivedDataPath "$DD" build \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | sort -u

args=()
while IFS= read -r f; do args+=(--stringsdata "$f"); done \
  < <(find "$DD" -name "*.stringsdata" -path "*mNas.build*" -not -path "*Tests*")
xcrun xcstringstool sync "$KATALOG" "${args[@]}"

python3 - "$KATALOG" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
s = d["strings"]
for k, v in s.items():
    if not k.strip():
        continue
    loc = v.setdefault("localizations", {})
    loc.setdefault("pl", {"stringUnit": {"state": "translated", "value": k}})
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2, sort_keys=True)
open(p, "a").write("\n")
zywe = {k: v for k, v in s.items() if v.get("extractionState") != "stale" and k.strip()}
def ma_en(v):
    en = v["localizations"].get("en", {})
    if en.get("stringUnit", {}).get("state") == "translated":
        return True
    # hasła z odmianą po liczbie (1 disk / 2 disks) trzymają angielski w wariantach
    warianty = en.get("variations", {}).get("plural", {})
    return bool(warianty) and all(w.get("stringUnit", {}).get("state") == "translated" for w in warianty.values())
en = [k for k, v in zywe.items() if ma_en(v)]
print(f"hasła: {len(zywe)}  z angielskim: {len(en)}  bez: {len(zywe) - len(en)}  "
      f"nieużywane (stale): {sum(1 for v in s.values() if v.get('extractionState') == 'stale')}")
EOF
