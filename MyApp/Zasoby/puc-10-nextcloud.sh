# Nextcloud (instalacja klasyczna i snap): wersja + "occ update:check"
# (nowa wersja serwera i aktualizacje aplikacji Nextclouda).
nc_parse() {
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        case $l in
            *"is available"*) echo "UPD Nextcloud: $l" ;;
            *) echo "APP Nextcloud: $l" ;;
        esac
    done
}
for occ in /var/www/nextcloud/occ /var/www/html/nextcloud/occ /var/www/html/occ /usr/share/nextcloud/occ /srv/nextcloud/occ; do
    [ -f "$occ" ] || continue
    dir=${occ%/occ}
    owner=$(stat -c %U "$dir/config/config.php" 2>/dev/null || echo www-data)
    v=$(su -s /bin/sh "$owner" -c "php '$occ' -V" 2>/dev/null)
    [ -n "$v" ] && echo "APP Nextcloud: zainstalowany $v ($dir)"
    su -s /bin/sh "$owner" -c "php '$occ' update:check" 2>&1 | nc_parse
    break
done
if command -v nextcloud.occ >/dev/null 2>&1; then
    echo "APP Nextcloud (snap): $(nextcloud.occ -V 2>/dev/null)"
    nextcloud.occ update:check 2>&1 | nc_parse
fi
