# meet-reserve

Signer for reserved rooms on meet.ffmuc.net. It runs behind
`https://meet.ffmuc.net/reserve`. The source comment in `main.go` explains the
design. `stacks/README.md` explains the deployment.

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
| `replaced` | 410 | New links replaced this link. |
| `deleted` | 410 | The room was deleted. |
| `expired` | 410 | The room expired. |
| `pow_malformed`, `pow_bad_mac`, `pow_expired`, `pow_insufficient`, `pow_replay` | 403 | The proof of work is not correct. Get a new challenge. |
| `too_many_requests` | 429 | Too many POST requests from this IP. haproxy sends this error. |
| `internal` | 500 | Server error. |
