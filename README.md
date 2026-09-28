# brevo-script

> Keep Brevo SMTP and API keys from expiring after 90 days of inactivity — one dummy email per SMTP key, one `GET /v3/account` per API key, pure `bash` + `curl`.

[![License](https://img.shields.io/github/license/pavlojs/brevo-script)](LICENSE)
[![lint](https://github.com/pavlojs/brevo-script/actions/workflows/lint.yml/badge.svg)](https://github.com/pavlojs/brevo-script/actions/workflows/lint.yml)

Brevo expires SMTP keys and API keys that have seen no activity for 90 days.
If a key is wired into a side project that only sends mail occasionally, it
quietly stops working. [`brevo-keepalive.sh`](brevo-keepalive.sh) resets that
clock: for an SMTP key it sends a single throwaway message through the relay,
for an API key it makes one read-only `GET /v3/account` request. Either kind,
or both, can be handled in one run.

## Requirements

`bash` 4+ and `curl`. No package manager, no runtime, no dependencies — `curl`
speaks SMTP itself.

## Quick start

```bash
git clone https://github.com/pavlojs/brevo-script
cd brevo-script
cp .env.example .env   # fill in login, key, from, to
./brevo-keepalive.sh
```

```
relay:  smtp://smtp-relay.brevo.com:587
login:  you@example.com
from:   noreply@yourdomain.tld
to:     you@example.com
keys:   1

sending with key ****a1b2 ... ok

all 1 key(s) used, expiry clock reset
```

API keys need no sender or recipient, just the key:

```bash
BREVO_API_KEY=xkeysib-... ./brevo-keepalive.sh
```

```
api url:   https://api.brevo.com/v3/account
api keys:  1

pinging API with key ****c3d4 ... ok

all 1 key(s) used, expiry clock reset
```

Check the message before sending anything:

```bash
./brevo-keepalive.sh --dry-run
```

The recipient can also be passed as an argument, which overrides `MAIL_TO`:

```bash
./brevo-keepalive.sh someone@example.com
```

## Configuration

Read from the environment, or from a `.env` file next to the script. Environment
variables win over `.env`. Credentials come from the Brevo dashboard under
**SMTP & API**. At least one of `BREVO_SMTP_KEY` or `BREVO_API_KEY` must be set.

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `BREVO_SMTP_KEY` | one of | — | The SMTP key. Comma-separate to keep several keys alive in one run. |
| `BREVO_API_KEY` | one of | — | The API key. Comma-separate for several. Needs no other variables. |
| `BREVO_API_URL` | no | `https://api.brevo.com/v3/account` | Endpoint pinged per API key. Any authenticated request counts as activity; this one is read-only and needs no special permission. |
| `BREVO_SMTP_LOGIN` | with SMTP | — | The SMTP login shown next to your keys, usually your account email. |
| `MAIL_FROM` | with SMTP | — | Sender address. Must be a verified sender or domain in Brevo, otherwise the relay answers `550`. |
| `MAIL_TO` | with SMTP | — | Where the dummy message lands. Your own inbox is fine. |
| `BREVO_SMTP_HOST` | no | `smtp-relay.brevo.com` | |
| `BREVO_SMTP_PORT` | no | `587` | `587`/`2525` use STARTTLS, `465` uses implicit TLS. |
| `MAIL_SUBJECT` | no | `Brevo SMTP keep-alive` | |

Every key needs its own send, so several keys mean several messages:

```bash
BREVO_SMTP_KEY=xsmtpsib-key-one,xsmtpsib-key-two ./brevo-keepalive.sh
```

API keys and SMTP keys can be combined in one run:

```bash
BREVO_SMTP_KEY=xsmtpsib-... BREVO_API_KEY=xkeysib-one,xkeysib-two ./brevo-keepalive.sh
```

Exit codes: `0` all keys used, `1` configuration error, `2` at least one key
failed (a send was rejected or the API answered with an error such as `401`).

## Scheduling

Monthly is plenty for a 90-day window and leaves room for two missed runs.

Create the log directory first. Cron's shell opens the `>>` target before it
starts the script, so if the directory is missing the job fails silently and
the script never runs:

```bash
mkdir -p ~/.local/log
```

```cron
0 6 1 * * /home/you/brevo-script/brevo-keepalive.sh >> /home/you/.local/log/brevo-keepalive.log 2>&1
```

The script resolves its `.env` relative to its own location, so it does not care
about cron's working directory.

A scheduled GitHub Actions workflow deliberately is not offered here: GitHub
disables `schedule:` triggers in a repository after 60 days without commit
activity, which is exactly the "set it and forget it" case this script exists
for. It would go quiet before the keys it protects do.

## Security

SMTP and API keys are credentials — treat them like passwords. Details and the
disclosure policy are in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
