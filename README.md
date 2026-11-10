# actions

Shared GitHub Actions for lemoncloud-io repositories. Pin a major tag (`@v1`); breaking input changes move to `@v2`.

| Action | What it does |
| --- | --- |
| [`notify-dou`](#notify-dou) | Posts a deploy result card to a DoU channel through its webhook |

## notify-dou

Replaces the Slack deploy notifications (`slackapi/slack-github-action`). One step builds and sends the card, so a repo
only passes what is specific to it: the stage, a body text and, for a release, its notes.

```yaml
notify:
    needs: [build-and-deploy]
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    steps:
        - uses: lemoncloud-io/actions/notify-dou@v1
          with:
              url: ${{ secrets.DOU_WEBHOOK_URL }}
              token: ${{ secrets.DOU_WEBHOOK_TOKEN }}
              channel-id: ${{ secrets.DOU_CHANNEL_ID }}
              status: ${{ needs.build-and-deploy.result }}
              stage: dev
              text: |
                  • *웹* 개발 서버 `v1.2.3`
```

### The card

```
🟢 <repo> <stage> 배포 완료               header — success 🟢 완료 · failure 🔴 실패 · cancelled/skipped 🟠
<text>                                   body — `text`, else `blocks` flattened, else the head commit subject
*Release Notes* …                        only when `release-notes` is set
배포 시각 · 커밋 · <fields>               KST time, short sha, then your own fields
<repo> · by <actor> · run #<n> 원문 보기   context — 원문 보기 opens the workflow run
```

The sender shows as "Webhook". `content` (push preview, search) is the header text.

DoU renders `*bold*` and `` `code` `` but not `<url|label>` links or HTML entities inside the card, so the action turns
links into their label (`<https://x|개발 서버>` → `개발 서버`) and unescapes `&lt;` `&gt;` `&amp;`. Slack emoji
codes do not render either: `:warning:` `:mag:` `:x:` `:white_check_mark:` `:rocket:` `:wrench:` become the emoji, and any
other code standing alone between spaces (the Slack workspace's own `:deploy:`, `:<product>-logo:`) is dropped. Release notes in
GitHub markdown are converted too: headings and `**bold**` become `*bold*`, `[text](url)` becomes `text`, list markers
become `•`. No `slackify-markdown-action` step is needed.

### Inputs

| Input | Default | Notes |
| --- | --- | --- |
| `url` | — | Webhook endpoint. Secret `DOU_WEBHOOK_URL` |
| `token` | — | Channel webhook token. Secret `DOU_WEBHOOK_TOKEN` |
| `channel-id` | — | Target channel. Secret `DOU_CHANNEL_ID` |
| `status` | `success` | `success` · `failure` · `cancelled`; pass `needs.<job>.result` or `job.status` |
| `stage` | — | Shown after the repo name in the header |
| `title` | `<repo> <stage> 배포 <완료\|실패\|취소>` | Replaces the whole header text |
| `text` | head commit subject (push events only) | mrkdwn; links are reduced to their label |
| `blocks` | — | Block Kit JSON array a workflow already builds; used for the body when `text` is empty. Section texts and fields are kept; header, divider, context and a section with a `*… 시각` field (배포 시각, 실패 시각) are dropped (the card has its own) |
| `release-notes` | — | GitHub markdown, e.g. `steps.<release-drafter id>.outputs.body`; appended under *Release Notes* |
| `fields` | — | Extra fields, one `Label=value` per line (split on the first `=`) |

Output `chat-id` — the created message id (`<channelId>:<chatNo>`), empty when nothing was posted.

### Secrets

All three come from **organization secrets** by default. A repository secret with the same name overrides the org value,
which is how a repo that reports to another DoU environment (its own host, token and channel) is configured.

A token belongs to one channel, so `DOU_WEBHOOK_TOKEN` and `DOU_CHANNEL_ID` are always changed together.

### It never fails a deploy

A missing secret, a non-2xx answer or a timeout (15 s) prints a `::warning` annotation and the step succeeds — the card is
lost, the deploy is not. There is no retry: a POST that timed out may still have been stored, and a retry would post it
twice. Look for `notify-dou` warnings in the run summary when a card did not arrive. The request body carries the token
and is never printed.

### Testing

- `bash notify-dou/test/run.sh` — runs the script against a local mock endpoint and checks the request body and every
  warn-and-skip path. Runs on every pull request.
- Actions → **Test** → *Run workflow* — posts one real card through this repository's `DOU_*` secrets and fails unless a
  message id comes back.

### Releasing

Merge to `main`, then move the major tag: `git tag -f v1 && git push -f origin v1` (and add a `v1.x.y` tag for the record).
