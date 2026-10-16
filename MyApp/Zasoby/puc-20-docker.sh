# Docker: tylko informacja o uruchomionych obrazach (bez pobierania czegokolwiek).
# Do sprawdzania nowych wersji obrazów polecane: Diun albo What's Up Docker.
command -v docker >/dev/null 2>&1 || exit 0
imgs=$(docker ps --format '{{.Image}}' 2>/dev/null | sort -u | tr '\n' ' ')
[ -n "$imgs" ] && echo "INFO Docker – uruchomione obrazy: $imgs"
exit 0
