# v2ray-filtered-subs

Filtered V2Ray / Shadowsocks / Trojan configs. Auto-updated daily.

## Subscription URL

    https://raw.githubusercontent.com/mablue/v2ray-filtered-subs/main/subs.txt

Paste into v2rayNG, NekoBox, or any client that accepts a subscription URL.

## Auto-update

- Scheduled: daily at 03:00 UTC
- Manual: Actions > Filter subs > Run workflow
- On push: when filter/filter.sh or the workflow changes

## Custom sub URLs

Manual trigger accepts comma-separated URLs in the sub_urls input.

## Local use (Termux)

    pkg install curl unzip
    git clone https://github.com/mablue/v2ray-filtered-subs.git
    cd v2ray-filtered-subs
    PARALLEL_TCP=4 PARALLEL_HTTP=2 PARALLEL_SPEED=1 bash filter/filter.sh

## Environment variables

- SUB_URLS - comma-separated sub URLs
- XRAY_VER - Xray core version (default 25.4.30)
- PARALLEL_TCP - stage 1 concurrency (default 32, use 4-8 on Termux)
- PARALLEL_HTTP - stage 2 concurrency (default 10)
- PARALLEL_SPEED - stage 3 concurrency (default 4)
- STAGE2_SAMPLE - max configs to HTTP-test (default 300)
- SPEED_MIN_KBPS - minimum speed to keep (default 50)
- OUT_FILE - output filename (default subs.txt)

## Behavior

- If fetching finds 0 configs, subs.txt is left untouched.
- If Stage 1 finds 0, subs.txt is left untouched.
- If Stage 2 finds 0, subs.txt is left untouched.
- Only a successful Stage 3 with >= 1 config updates subs.txt.
