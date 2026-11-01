# meet-reserve

Signer for reserved rooms on meet.ffmuc.net. It runs behind
`https://meet.ffmuc.net/reserve`. The source comment in `main.go` explains the
design. `stacks/README.md` explains the deployment.

## Join API for apps

`POST /reserve/api/join` gives a token for a room. The desktop and mobile apps
use it. It needs no proof of work.

Request:

```json
{"key": "https://meet.ffmuc.net/reserve/h/…", "role": "speaker"}
```

- `key`: a host or speaker link in any form: the bare secret, the `/h/` or
  `/s/` link, the manage link (`#k=`), or a v1 host link. A v1 host link
  migrates the room, like on the manage page.
- `role` (optional): `host` or `speaker`. The default is the role of the link.
  A host link can join as `speaker`. A speaker link cannot join as `host`
  (HTTP 403, `forbidden`).

Response (HTTP 200, `Cache-Control: no-store`):

```json
{
  "server": "https://meet.ffmuc.net",
  "room": "r-…",
  "role": "host",
  "jwt": "…",
  "jwt_expires": "2026-11-01T12:00:00Z",
  "room_expires": "2026-12-01T12:00:00Z"
}
```

The token is the same as the token of the short links: it is valid for
`RESERVE_LINK_TTL`, but not after the room expires. To join, open
`<server>/<room>?jwt=<jwt>`. Get a new token before `jwt_expires`.

Errors: see below. Each `/api/join` POST counts for the haproxy POST limit.

The metric `ffmuc_reserve_api_joins_total{role}` counts the tokens.

## API errors

All errors from `/reserve/api/*` are JSON:

```json
{"error": "room expired", "reason": "expired"}
```

- `error` is text for humans. It can change.
- `reason` is stable. Clients must use `reason`.

| `reason` | HTTP | Meaning |
|---|---|---|
| `malformed` | 400, 405 | The request is not correct (body, method, duration). |
| `invalid` | 400 | The key is not a valid link. |
| `unknown` | 400, 404 | No room has this key, or the link has the wrong type. |
| `forbidden` | 403 | The link does not give the requested role. |
| `replaced` | 410 | New links replaced this link. |
| `deleted` | 410 | The room was deleted. |
| `expired` | 410 | The room expired. |
| `pow_malformed`, `pow_bad_mac`, `pow_expired`, `pow_insufficient`, `pow_replay` | 403 | The proof of work is not correct. Get a new challenge. |
| `too_many_requests` | 429 | Too many POST requests from this IP. haproxy sends this error. |
| `internal` | 500 | Server error. |
