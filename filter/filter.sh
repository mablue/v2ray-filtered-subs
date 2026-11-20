#!/usr/bin/env bash
set -euo pipefail

SUB_URLS="${SUB_URLS:-https://raw.githubusercontent.com/v2FreeHub/v2hub-configs/refs/heads/main/Sub-AutoUpdate}"
XRAY_VER="${XRAY_VER:-25.4.30}"
PARALLEL_TCP="${PARALLEL_TCP:-32}"
PARALLEL_HTTP="${PARALLEL_HTTP:-10}"
PARALLEL_SPEED="${PARALLEL_SPEED:-4}"
STAGE2_SAMPLE="${STAGE2_SAMPLE:-300}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-5}"
SPEED_TIMEOUT="${SPEED_TIMEOUT:-10}"
SPEED_MIN_KBPS="${SPEED_MIN_KBPS:-50}"
OUT_FILE="${OUT_FILE:-subs.txt}"

ORIG_DIR="$(pwd)"
WORK="$(mktemp -d)"
export WORK
cleanup() {
    pkill -P $$ xray 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"

ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64) ZIP="Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv8l) ZIP="Xray-linux-arm32-v7a.zip" ;;
    x86_64|amd64)  ZIP="Xray-linux-64.zip" ;;
    i686|i386)     ZIP="Xray-linux-32.zip" ;;
    *) echo "[!] Unsupported arch: $ARCH"; exit 1 ;;
esac
echo "[*] Platform: $ARCH"
echo "[*] Fetching Xray v$XRAY_VER..."
curl -fsSL --retry 3 --max-time 60 -o xray.zip \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/${ZIP}"
command -v unzip >/dev/null || { echo "[!] install unzip"; exit 1; }
unzip -oq xray.zip xray
chmod +x xray
echo "[+] $(./xray version | head -n1)"

decode_b64() {
    local s="$1"
    [ -z "$s" ] && return 0
    s="$(printf '%s' "$s" | tr '_-' '/+')"
    while (( ${#s} % 4 )); do s="${s}="; done
    printf '%s' "$s" | base64 -d 2>/dev/null || true
}

extract_host_port() {
    local link="$1"
    case "$link" in
        ss://*)
            local b="${link#ss://}"
            b="${b%%#*}"
            if [[ "$b" == *"@"* ]]; then
                local hp="${b#*@}"
                hp="${hp%%\?*}"
                hp="${hp%/}"
                printf '%s' "$hp"
            else
                local dec
                dec="$(decode_b64 "$b")"
                printf '%s' "${dec##*@}"
            fi
            ;;
        vmess://*)
            local b h p
            b="$(decode_b64 "${link#vmess://}")"
            h="$(printf '%s' "$b" | sed -n 's/.*"add"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            p="$(printf '%s' "$b" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"*\([0-9]*\).*/\1/p')"
            printf '%s:%s' "$h" "$p"
            ;;
        vless://*|trojan://*)
            local rest hp
            rest="${link#*://}"
            rest="${rest%%#*}"
            rest="${rest%%\?*}"
            hp="${rest##*@}"
            printf '%s' "$hp"
            ;;
    esac
}
export -f decode_b64 extract_host_port

echo "[*] Fetching subscriptions..."
: > raw_all.txt
SUB_URLS_CLEAN="$(printf '%s' "$SUB_URLS" | tr ',' '\n')"
while IFS= read -r url; do
    url="$(printf '%s' "$url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$url" ] && continue
    echo "  -> $url"
    curl -fsSL --retry 2 --max-time 20 -A "Mozilla/5.0" "$url" >> raw_all.txt 2>/dev/null || echo "    (failed)"
done <<< "$SUB_URLS_CLEAN"

echo "[*] Parsing..."
: > configs.txt
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in
        ss://*|vmess://*|vless://*|trojan://*)
            printf '%s\n' "$line" >> configs.txt
            ;;
        *)
            dec="$(decode_b64 "$line")"
            if [ -n "$dec" ] && [[ "$dec" == *"://"* ]]; then
                printf '%s\n' "$dec" | grep -E '^(ss|vmess|vless|trojan)://' >> configs.txt || true
            fi
            ;;
    esac
done < raw_all.txt
awk '!seen[$0]++' configs.txt | grep -v '^[[:space:]]*$' > unique.txt || true
TOTAL=$(wc -l < unique.txt)
echo "[+] unique configs: $TOTAL"
if [ "$TOTAL" -eq 0 ]; then
    echo "[!] No configs fetched; aborting without touching $OUT_FILE"
    exit 0
fi

tcp_ok() {
    local link="$1" hp h p
    hp="$(extract_host_port "$link")"
    h="${hp%:*}"; p="${hp##*:}"
    if [ -z "$h" ] || [ -z "$p" ]; then return 1; fi
    timeout 2 bash -c "echo > /dev/tcp/$h/$p" 2>/dev/null
}
export -f tcp_ok

echo "[*] Stage 1: TCP ($PARALLEL_TCP parallel)..."
xargs -d '\n' -I{} -P "$PARALLEL_TCP" bash -c '
    if tcp_ok "$1"; then printf "%s\n" "$1"; fi
' _ {} < unique.txt > stage1.txt 2>/dev/null || true
N1=$(wc -l < stage1.txt)
echo "[+] after stage 1: $N1"
if [ "$N1" -eq 0 ]; then
    echo "[!] No config survived Stage 1; aborting"
    exit 0
fi

build_cfg() {
    local link="$1" port="$2"
    case "$link" in
        ss://*)
            local b ui m pw hp h p dec
            b="${link#ss://}"; b="${b%%#*}"
            if [[ "$b" == *"@"* ]]; then
                ui="${b%%@*}"
                local hpq="${b#*@}"
                hpq="${hpq%%\?*}"
                hpq="${hpq%/}"
                h="${hpq%:*}"; p="${hpq##*:}"
                if [[ "$ui" == *:* ]]; then
                    m="${ui%%:*}"; pw="${ui#*:}"
                else
                    dec="$(decode_b64 "$ui")"
                    m="${dec%%:*}"; pw="${dec#*:}"
                fi
            else
                dec="$(decode_b64 "$b")"
                ui="${dec%%@*}"
                local hpq="${dec##*@}"
                m="${ui%%:*}"; pw="${ui#*:}"
                h="${hpq%:*}"; p="${hpq##*:}"
            fi
            printf '%s\n' "{\"log\":{\"loglevel\":\"error\"},\"inbounds\":[{\"port\":$port,\"listen\":\"127.0.0.1\",\"protocol\":\"socks\",\"settings\":{\"auth\":\"noauth\",\"udp\":false}}],\"outbounds\":[{\"protocol\":\"shadowsocks\",\"settings\":{\"servers\":[{\"address\":\"$h\",\"port\":$p,\"method\":\"$m\",\"password\":\"$pw\"}]}}]}"
            ;;
        vmess://*)
            local b h p uid aid net tls hostH sni path stream
            b="$(decode_b64 "${link#vmess://}")"
            h="$(printf '%s' "$b" | sed -n 's/.*"add"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            p="$(printf '%s' "$b" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"*\([0-9]*\).*/\1/p')"
            uid="$(printf '%s' "$b" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            aid="$(printf '%s' "$b" | sed -n 's/.*"aid"[[:space:]]*:[[:space:]]*"*\([0-9]*\).*/\1/p')"; aid=${aid:-0}
            net="$(printf '%s' "$b" | sed -n 's/.*"net"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"; net=${net:-tcp}
            tls="$(printf '%s' "$b" | sed -n 's/.*"tls"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            hostH="$(printf '%s' "$b" | sed -n 's/.*"host"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            sni="$(printf '%s' "$b" | sed -n 's/.*"sni"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            path="$(printf '%s' "$b" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"; path=${path:-/}
            stream=",\"streamSettings\":{\"network\":\"$net\""
            if [ "$net" = "ws" ]; then
                stream+=",\"wsSettings\":{\"path\":\"$path\",\"headers\":{\"Host\":\"${hostH:-$h}\"}}"
            fi
            if [ "$tls" = "tls" ] || [ "$tls" = "1" ] || [ "$tls" = "true" ]; then
                stream+=",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"${sni:-${hostH:-$h}}\",\"fingerprint\":\"chrome\"}"
            fi
            stream+="}"
            printf '%s\n' "{\"log\":{\"loglevel\":\"error\"},\"inbounds\":[{\"port\":$port,\"listen\":\"127.0.0.1\",\"protocol\":\"socks\",\"settings\":{\"auth\":\"noauth\",\"udp\":false}}],\"outbounds\":[{\"protocol\":\"vmess\",\"settings\":{\"vnext\":[{\"address\":\"$h\",\"port\":$p,\"users\":[{\"id\":\"$uid\",\"alterId\":$aid,\"security\":\"auto\"}]}]}$stream}]}"
            ;;
        vless://*)
            local u uid rest qs hp h p sni fp net path hostH sec flow extra stream kv parts
            u="${link#vless://}"
            uid="${u%%@*}"
            rest="${u#*@}"
            rest="${rest%%#*}"
            qs=""; hp="$rest"
            if [[ "$rest" == *"?"* ]]; then hp="${rest%%\?*}"; qs="${rest#*\?}"; fi
            h="${hp%:*}"; p="${hp##*:}"; p=${p:-443}
            sni=""; fp=""; net="tcp"; path="/"; hostH=""; sec="tls"; flow=""
            IFS='&' read -ra parts <<< "$qs"
            for kv in "${parts[@]}"; do
                case "${kv%%=*}" in
                    sni) sni="${kv#*=}";;
                    fp)  fp="${kv#*=}";;
                    type) net="${kv#*=}";;
                    path) path="${kv#*=}";;
                    host) hostH="${kv#*=}";;
                    security) sec="${kv#*=}";;
                    flow) flow="${kv#*=}";;
                esac
            done
            fp=${fp:-chrome}; sni=${sni:-$h}
            extra=""
            [ -n "$flow" ] && extra=",\"flow\":\"$flow\""
            stream=",\"streamSettings\":{\"network\":\"$net\""
            if [ "$net" = "ws" ]; then
                stream+=",\"wsSettings\":{\"path\":\"$path\",\"headers\":{\"Host\":\"${hostH:-$h}\"}}"
            fi
            if [ "$sec" = "tls" ]; then
                stream+=",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"$sni\",\"fingerprint\":\"$fp\"}"
            fi
            stream+="}"
            printf '%s\n' "{\"log\":{\"loglevel\":\"error\"},\"inbounds\":[{\"port\":$port,\"listen\":\"127.0.0.1\",\"protocol\":\"socks\",\"settings\":{\"auth\":\"noauth\",\"udp\":false}}],\"outbounds\":[{\"protocol\":\"vless\",\"settings\":{\"vnext\":[{\"address\":\"$h\",\"port\":$p,\"users\":[{\"id\":\"$uid\",\"encryption\":\"none\"$extra}]}]}$stream}]}"
            ;;
        trojan://*)
            local pw hp h p
            pw="${link#trojan://}"; pw="${pw%%@*}"; pw="${pw%%\?*}"
            hp="$(extract_host_port "$link")"
            h="${hp%:*}"; p="${hp##*:}"; p=${p:-443}
            printf '%s\n' "{\"log\":{\"loglevel\":\"error\"},\"inbounds\":[{\"port\":$port,\"listen\":\"127.0.0.1\",\"protocol\":\"socks\",\"settings\":{\"auth\":\"noauth\",\"udp\":false}}],\"outbounds\":[{\"protocol\":\"trojan\",\"settings\":{\"servers\":[{\"address\":\"$h\",\"port\":$p,\"password\":\"$pw\"}]},\"streamSettings\":{\"network\":\"tcp\",\"security\":\"tls\",\"tlsSettings\":{\"serverName\":\"$h\",\"fingerprint\":\"chrome\"}}}]}"
            ;;
        *) return 1 ;;
    esac
}
export -f build_cfg

start_xray() {
    local cfg="$1" port="$2"
    ./xray run -c "$cfg" >/dev/null 2>&1 &
    local xp=$!
    local ready=0 i
    for i in $(seq 1 20); do
        if (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then ready=1; break; fi
        sleep 0.05
    done
    printf '%s %s' "$xp" "$ready"
}
export -f start_xray

test_one_http() {
    local idx="$1" link="$2"
    local port=$((20000 + idx))
    local cfg="cfg_http_$idx.json"
    if ! build_cfg "$link" "$port" > "$cfg" 2>/dev/null; then rm -f "$cfg"; return 1; fi
    if [ ! -s "$cfg" ]; then rm -f "$cfg"; return 1; fi
    ./xray run -c "$cfg" >/dev/null 2>&1 &
    local xp=$!
    local ready=0 i
    for i in $(seq 1 20); do
        if (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then ready=1; break; fi
        sleep 0.05
    done
    local ok=1
    if [ $ready -eq 1 ]; then
        local probe code
        for probe in "http://cp.cloudflare.com/generate_204" "http://www.gstatic.com/generate_204" "http://1.1.1.1/cdn-cgi/trace"; do
            code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$HTTP_TIMEOUT" --socks5-hostname "127.0.0.1:$port" "$probe" 2>/dev/null || echo 000)
            if [ "$code" = "204" ] || [ "$code" = "200" ]; then ok=0; break; fi
        done
    fi
    kill "$xp" 2>/dev/null || true
    wait "$xp" 2>/dev/null || true
    rm -f "$cfg"
    [ $ok -eq 0 ] && printf '%s\n' "$link"
    return $ok
}
export -f test_one_http
export HTTP_TIMEOUT

head -n "$STAGE2_SAMPLE" stage1.txt > stage2_in.txt || true
awk '{printf "%d|%s\n", NR, $0}' stage2_in.txt > stage2_lines.txt
N2IN=$(wc -l < stage2_lines.txt)
echo "[*] Stage 2: HTTP ($PARALLEL_HTTP parallel, up to $N2IN)..."
: > stage2.txt
if [ "$N2IN" -gt 0 ]; then
    xargs -d '\n' -I{} -P "$PARALLEL_HTTP" bash -c '
        cd "$WORK"
        line="$1"
        idx="${line%%|*}"
        link="${line#*|}"
        test_one_http "$idx" "$link" || true
    ' _ {} < stage2_lines.txt > stage2.txt 2>/dev/null || true
fi
N2=$(wc -l < stage2.txt)
echo "[+] after stage 2: $N2"
if [ "$N2" -eq 0 ]; then
    echo "[!] No config survived Stage 2; aborting without touching $OUT_FILE"
    exit 0
fi

test_one_speed() {
    local idx="$1" link="$2"
    local port=$((30000 + idx))
    local cfg="cfg_speed_$idx.json"
    if ! build_cfg "$link" "$port" > "$cfg" 2>/dev/null; then rm -f "$cfg"; return 1; fi
    if [ ! -s "$cfg" ]; then rm -f "$cfg"; return 1; fi
    ./xray run -c "$cfg" >/dev/null 2>&1 &
    local xp=$!
    local ready=0 i
    for i in $(seq 1 20); do
        if (echo > /dev/tcp/127.0.0.1/"$port") 2>/dev/null; then ready=1; break; fi
        sleep 0.05
    done
    local ok=1
    if [ $ready -eq 1 ]; then
        local bytes kbps
        bytes=$(curl -s -o /dev/null -w '%{speed_download}' --max-time "$SPEED_TIMEOUT" --socks5-hostname "127.0.0.1:$port" "https://speed.cloudflare.com/__down?bytes=200000" 2>/dev/null || echo 0)
        kbps=$(awk -v b="$bytes" 'BEGIN{print int(b/1024)}')
        if [ "$kbps" -gt "$SPEED_MIN_KBPS" ]; then ok=0; fi
    fi
    kill "$xp" 2>/dev/null || true
    wait "$xp" 2>/dev/null || true
    rm -f "$cfg"
    [ $ok -eq 0 ] && printf '%s\n' "$link"
    return $ok
}
export -f test_one_speed
export SPEED_TIMEOUT SPEED_MIN_KBPS

awk '{printf "%d|%s\n", NR, $0}' stage2.txt > stage2_num.txt
N3IN=$(wc -l < stage2_num.txt)
echo "[*] Stage 3: speed ($PARALLEL_SPEED parallel, $N3IN configs)..."
: > best.txt
if [ "$N3IN" -gt 0 ]; then
    xargs -d '\n' -I{} -P "$PARALLEL_SPEED" bash -c '
        cd "$WORK"
        line="$1"
        idx="${line%%|*}"
        link="${line#*|}"
        test_one_speed "$idx" "$link" || true
    ' _ {} < stage2_num.txt > best.txt 2>/dev/null || true
fi
N3=$(wc -l < best.txt)
echo "[+] after stage 3: $N3"

if [ "$N3" -gt 0 ]; then
    cp best.txt "$ORIG_DIR/$OUT_FILE"
    echo "[DONE] $N3 configs written to $OUT_FILE"
    exit 0
else
    echo "[!] Stage 3 produced 0 configs; preserving existing $OUT_FILE"
    exit 0
fi
