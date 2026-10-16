# Kontenery postawione skryptami community-scripts (dawniej tteck) zapisują wersję
# aplikacji w /opt/<APP>_version.txt – pokazujemy ją w raporcie jako informację.
# Porównanie z najnowszą wersją dodaj w apps.conf (np. "cat /opt/X_version.txt").
for f in /opt/*_version.txt; do
    [ -f "$f" ] || continue
    app=${f##*/}; app=${app%_version.txt}
    echo "APP $app: $(head -n1 "$f") (wg $f)"
done
