#!/usr/bin/env bash
# Runs notify.sh against a local mock endpoint and checks the request it sends
# and the warn-and-exit-0 paths. Usable locally and in CI: bash notify-dou/test/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../notify.sh"
work="$(mktemp -d)"
trap 'kill "${server_pid:-}" 2>/dev/null; wait "${server_pid:-}" 2>/dev/null || true; rm -rf "$work"' EXIT

port=$((20000 + RANDOM % 20000))
python3 "$here/mock_server.py" "$port" "$work" &
server_pid=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$port/" -o /dev/null && break; sleep 0.1; done
curl -s "http://127.0.0.1:$port/" -o /dev/null || { echo 'FAIL: mock server did not start' >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

base_env() {
    export GITHUB_REPOSITORY=lemoncloud-io/sample-app GITHUB_SERVER_URL=https://github.com GITHUB_RUN_ID=42 GITHUB_RUN_NUMBER=7 \
        GITHUB_SHA=0123456789abcdef GITHUB_REF_NAME=develop GITHUB_ACTOR=octo GITHUB_WORKFLOW='Deploy Dev' \
        GITHUB_OUTPUT="$work/output" HEAD_COMMIT_MESSAGE=$'feat: ship it\n\nlong body' \
        INPUT_TOKEN=test-token INPUT_CHANNEL_ID=9990001 INPUT_URL="http://127.0.0.1:$port/ok" \
        INPUT_STATUS=success INPUT_STAGE=dev INPUT_TITLE='' INPUT_TEXT='' INPUT_BLOCKS='' INPUT_RELEASE_NOTES='' \
        INPUT_FIELDS=$'URL=https://dev.example.com/?a=b\r\n Env = dev \n =no key\nnot a field'
    : >"$work/output"
}

# 1. success: the request carries the documented body.
base_env
out=$(bash "$script" 2>&1)
req="$work/request.json"
[[ -f "$req" ]] || fail 'no request reached the mock'
jq -e '
    .token == "test-token" and .channelId == "9990001" and .content == "sample-app dev 배포 완료"
    and .meta.color == "good" and .meta.title == .content and .meta.text == "feat: ship it"
    and (.meta | has("username") | not) and .meta.footer == "sample-app · by octo · run #7"
    and .meta.sourceUrl == "https://github.com/lemoncloud-io/sample-app/actions/runs/42"
    and (.meta.ts | type) == "number"
    and (.meta.fields[0].title == "배포 시각" and (.meta.fields[0].value | test("^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$")))
    and .meta.fields[1:] == [
        {title: "커밋", value: "0123456"},
        {title: "URL", value: "https://dev.example.com/?a=b"},
        {title: "Env", value: "dev"}
    ]' "$req" >/dev/null || { cat "$req"; fail 'request body does not match the contract'; }
grep -qx 'chat-id=9990001:1' "$work/output" || fail "chat-id output missing: $(cat "$work/output")"
[[ "$out" != *test-token* ]] || fail 'token leaked to stdout'

# 2. failure status, explicit title/text, no version.
base_env
rm -f "$req"
INPUT_STATUS=failure INPUT_TITLE='Custom title' INPUT_TEXT='*bold* <https://x.dev|웹> &lt;b&gt;' INPUT_FIELDS='' \
    INPUT_RELEASE_NOTES=$'## 🚀 Features\r\n\r\n- **New** [thing](https://x.dev/1) @a (#1)\n* fix' bash "$script" >/dev/null
jq -e '.meta.color == "danger" and .meta.title == "Custom title"
    and .meta.text == "*bold* 웹 <b>\n\n*Release Notes*\n*🚀 Features*\n\n• *New* thing @a (#1)\n• fix"
    and (.meta.fields | map(.title)) == ["배포 시각", "커밋"]' "$req" >/dev/null || { cat "$req"; fail 'failure card'; }

# 3. blocks: section texts and fields become the body; header, divider, context and the 배포 시각 row do not.
base_env
rm -f "$req"
INPUT_BLOCKS='[
  {"type":"header","text":{"type":"plain_text","text":"old header"}},
  {"type":"section","text":{"type":"mrkdwn","text":"*배포 완료:* 1개"}},
  {"type":"divider"},
  {"type":"section","fields":[{"type":"mrkdwn","text":"*웹* <https://x.dev|개발 서버>"},{"type":"mrkdwn","text":"*랜딩* ok"}]},
  {"type":"section","fields":[{"type":"mrkdwn","text":"*배포 시각*\n2026"},{"type":"mrkdwn","text":"*커밋*\nabc"}]},
  {"type":"context","elements":[{"type":"mrkdwn","text":"by octo"}]}
]' bash "$script" >/dev/null
jq -e '.meta.text == "*배포 완료:* 1개\n*웹* 개발 서버\n*랜딩* ok"' "$req" >/dev/null || { cat "$req"; fail 'blocks body'; }

# 4. invalid blocks fall back to the commit subject with a warning.
base_env
rm -f "$req"
got=$(INPUT_BLOCKS='not json' bash "$script")
[[ "$got" == *'blocks is not a JSON array'* ]] || fail "no blocks warning: $got"
jq -e '.meta.text == "feat: ship it"' "$req" >/dev/null || { cat "$req"; fail 'blocks fallback'; }

# 5. skipped status, and no GITHUB_OUTPUT / GITHUB_* at all (act, local runs) still posts and exits 0.
base_env
rm -f "$req"
env -u GITHUB_OUTPUT -u GITHUB_REPOSITORY -u GITHUB_RUN_ID -u GITHUB_SHA INPUT_STATUS=skipped bash "$script" >/dev/null ||
    fail 'missing GITHUB_* vars made the script fail'
jq -e '.meta.color == "warning" and (.meta.title | endswith("배포 건너뜀"))' "$req" >/dev/null || { cat "$req"; fail 'skipped card'; }

# 6. warn-and-exit-0 paths: missing token, missing channel, HTTP error, unreachable host.
expect_warning() {
    local name="$1" want="$2"; shift 2
    base_env
    local got
    got=$(env "$@" bash "$script" 2>&1) || fail "$name exited non-zero"
    [[ "$got" == *"::warning title=notify-dou::"*"$want"* ]] || fail "$name: no warning containing '$want' in: $got"
    [[ "$got" != *test-token* ]] || fail "$name: token leaked"
    grep -q 'chat-id=.' "$work/output" && fail "$name: chat-id set on a failed post"
    return 0
}
expect_warning 'empty url' 'url is empty' INPUT_URL=
expect_warning 'empty token' 'token is empty' INPUT_TOKEN=
expect_warning 'empty channel' 'channel-id is empty' INPUT_CHANNEL_ID=
expect_warning 'HTTP 500' 'HTTP 500' INPUT_URL="http://127.0.0.1:$port/fail"
expect_warning 'unreachable' 'HTTP 000' INPUT_URL='http://127.0.0.1:1/'

echo 'notify-dou: all checks passed'
