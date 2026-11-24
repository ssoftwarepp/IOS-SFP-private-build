#!/var/jb/bin/sh
DIRECTORY=/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime
DATE=/var/jb/usr/bin/date
if [ ! -x "$DATE" ]; then DATE=/usr/bin/date; fi
if [ ! -x "$DATE" ]; then DATE=/bin/date; fi
log_line() {
    today=$($DATE '+%Y-%m-%d')
    printf '%s: %s\n' "$($DATE '+%m-%d-%Y %T')" "$1" >> "$DIRECTORY/output-$today.log"
    if [ "$today" != "$last_cleanup" ]; then
        last_cleanup=$today
        keep=""
        for offset in 0 1 2 3 4; do
            keep="$keep $($DATE -v-${offset}d '+%Y-%m-%d')"
        done
        legacy="$DIRECTORY/output"
        if [ -f "$legacy" ]; then
            old=$($DATE -r "$(stat -f '%m' "$legacy")" '+%Y-%m-%d')
            case " $keep " in
                *" $old "*) ;;
                *) rm -f "$legacy" ;;
            esac
        fi
        for file in "$DIRECTORY"/output-????-??-??.log; do
            [ -f "$file" ] || continue
            day=${file##*/output-}
            day=${day%.log}
            case " $keep " in
                *" $day "*) ;;
                *) rm -f "$file" ;;
            esac
        done
    fi
}
log_line "Start running script. Script path: $1"
while IFS= read -r line; do
    log_line "$line"
done
