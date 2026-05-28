# mautrix-gmessages

**Image:** `dock.mau.dev/mautrix/gmessages:v0.2605.0` (CalVer, latest as of 2026-05)
**Port:** `29336` (appservice + provisioning API)
**Bot:** `@gmessagesbot`

## Known issue — frequent disconnects

**Symptom:** `State update: BAD_CREDENTIALS (gm-logged-out-401-polling): Unpaired from Google Messages, please re-link the connection`

**Root cause:** Google removed QR pairing in Apr–May 2026. All remaining login methods (cookies, cURL) produce sessions that die in ~1–2 hours. This is an upstream bug.

**Status:** Open — [mautrix/gmessages#57](https://github.com/mautrix/gmessages/issues/57). No fix yet. When this closes, re-evaluate and remove this file.

## Re-login (fast path — mautrix-manager desktop app)

1. Install [mautrix-manager](https://github.com/mautrix/manager) (Electron, v0.1.3+) on a workstation.
2. Sign in with your Matrix account (server `${MATRIX_DOMAIN}`).
3. The app auto-discovers the gmessages bridge via `/.well-known/matrix/mautrix`.
4. Follow the cookies + emoji-confirmation flow.

## Re-login (fallback — Matrix DM)

1. DM `@gmessagesbot`
2. Send `login`
3. Follow the prompt — paste cookies JSON or cURL command from browser devtools (log in at `https://accounts.google.com/AccountChooser?continue=https://messages.google.com/web/config`, copy request as cURL from Network tab)

## Notes

- E2EE flipped to `default: true` on 2026-05-24 (`b356b5f`). Unrelated to the auth disconnect (the 401 comes from Google's polling channel, not Matrix).
- WUD watches for new CalVer releases from `dock.mau.dev` — requires `MAUDEV_TOKEN` PAT in `.env` (see `.env.example`).
