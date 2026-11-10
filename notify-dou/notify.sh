#!/usr/bin/env bash
# Builds the DoU webhook body from INPUT_* env vars and posts it.
# A notification must never fail a deploy, so every failure path warns and exits 0.
set -uo pipefail

# Workflow-command escaping, so a server answer cannot garble or split the annotation.
escape() {
    local s="$1"
    s="${s//'%'/'%25'}"
    s="${s//$'\r'/'%0D'}"
    s="${s//$'\n'/'%0A'}"
    printf '%s' "$s"
}

warn() {
    echo "::warning title=notify-dou::$(escape "$1")"
    exit 0
}

# DoU renders neither <url|label> links nor HTML entities inside the card, so keep the words only.
to_plain() {
    sed -E 's/<[^|>]+\|([^>]+)>/\1/g; s/<(https?:[^>]+)>/\1/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'
}

# GitHub-flavoured release notes (release-drafter body) to DoU mrkdwn.
markdown_to_mrkdwn() {
    sed -E 's/\r$//; s/^#+ +(.*)$/*\1*/; s/\*\*([^*]+)\*\*/*\1*/g; s/__([^_]+)__/*\1*/g; s/\[([^]]+)\]\([^)]+\)/\1/g; s/^([[:space:]]*)[-*+] +/\1• /'
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

[[ -n "${INPUT_URL:-}" ]] || warn 'skipped: url is empty (set DOU_WEBHOOK_URL)'
[[ -n "${INPUT_TOKEN:-}" ]] || warn 'skipped: token is empty (set DOU_WEBHOOK_TOKEN)'
[[ -n "${INPUT_CHANNEL_ID:-}" ]] || warn 'skipped: channel-id is empty (set DOU_CHANNEL_ID)'
command -v jq >/dev/null || warn 'skipped: jq is not installed on this runner'

full_repo="${GITHUB_REPOSITORY:-}"
sha="${GITHUB_SHA:-}"
server="${GITHUB_SERVER_URL:-https://github.com}"
run_url="$server/$full_repo/actions/runs/${GITHUB_RUN_ID:-}"

status="${INPUT_STATUS:-success}"
case "$status" in
    success) color=good word='배포 완료' ;;
    failure) color=danger word='배포 실패' ;;
    cancelled) color=warning word='배포 취소' ;;
    skipped) color=warning word='배포 건너뜀' ;;
    *) color=warning word="배포 $status" ;;
esac

title="${INPUT_TITLE:-}"
if [[ -z "$title" ]]; then
    title="${full_repo##*/}"
    [[ -n "${INPUT_STAGE:-}" ]] && title="$title $INPUT_STAGE"
    title="$title $word"
fi

text="${INPUT_TEXT:-}"
if [[ -z "$text" && -n "${INPUT_BLOCKS:-}" ]]; then
    # A workflow that already assembles Block Kit keeps its builder: its sections become the body.
    # Header, divider and context are the card's own job, and a section carrying a time (배포/실패 시각) repeats
    # the branch/commit fields the card always has.
    text=$(jq -r '
        [ .[]? | select(.type == "section")
          | select([.fields[]?.text // "" | test("^\\*[^*\\n]*시각")] | any | not)
          | (.text.text // empty), ([.fields[]?.text] | select(length > 0) | join("\n")) ]
        | join("\n")' <<<"$INPUT_BLOCKS" 2>/dev/null) ||
        echo '::warning title=notify-dou::blocks is not a JSON array of blocks, ignored'
fi
# The subject line only: a full commit body would bury the card. Push events only carry one.
if [[ -z "$text" ]]; then
    text="${HEAD_COMMIT_MESSAGE:-}"
    text="${text%%$'\n'*}"
    text="${text%$'\r'}"
fi

text=$(printf '%s' "$text" | to_plain)
if [[ -n "${INPUT_RELEASE_NOTES:-}" ]]; then
    notes=$(printf '%s\n' "$INPUT_RELEASE_NOTES" | markdown_to_mrkdwn | to_plain)
    text="${text:+$text$'\n\n'}*Release Notes*"$'\n'"$notes"
fi

fields=$(jq -n \
    --arg timestamp "$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S')" \
    --arg commit "${sha:0:7}" \
    '[ {title: "배포 시각", value: $timestamp}, {title: "커밋", value: $commit} ]')

while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ "$line" == *=* ]] || continue
    key=$(trim "${line%%=*}")
    [[ -n "$key" ]] || continue
    fields=$(jq --arg t "$key" --arg v "$(trim "${line#*=}")" '. + [{title: $t, value: $v}]' <<<"$fields")
done <<<"${INPUT_FIELDS:-}"

# The token is read from the environment inside jq, so it never appears in a process argv.
body=$(jq -n \
    --arg color "$color" \
    --arg title "$title" \
    --arg text "$text" \
    --arg footer "${full_repo##*/} · by ${GITHUB_ACTOR:-} · run #${GITHUB_RUN_NUMBER:-}" \
    --arg source "$run_url" \
    --argjson fields "$fields" \
    '{token: $ENV.INPUT_TOKEN, channelId: $ENV.INPUT_CHANNEL_ID, content: $title,
      meta: ({color: $color, title: $title, footer: $footer,
              sourceUrl: $source, ts: now | floor, fields: $fields}
             + (if $text != "" then {text: $text} else {} end))}') ||
    warn 'skipped: could not build the request body'

response=$(mktemp) || warn 'skipped: mktemp failed'
errors=$(mktemp) || warn 'skipped: mktemp failed'
code=$(curl -sS -o "$response" --stderr "$errors" -w '%{http_code}' --max-time 15 \
    -X POST -H 'Content-Type: application/json' --data-binary @- "$INPUT_URL" <<<"$body") || code=000

if [[ "$code" != 2* ]]; then
    # Never print the request body: it carries the token. The response head and curl's reason are enough.
    warn "post failed: HTTP $code $(head -c 200 "$response") $(head -c 200 "$errors")"
fi

chat_id=$(jq -r '.id | strings' "$response" 2>/dev/null | head -n 1)
[[ "$chat_id" =~ ^[0-9A-Za-z:_-]+$ ]] || chat_id=''
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "chat-id=$chat_id" >>"$GITHUB_OUTPUT"
echo "notify-dou: posted ${chat_id:-(no id in the response)}"
