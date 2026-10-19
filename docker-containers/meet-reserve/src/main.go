// meet-reserve hands out reserved Jitsi rooms with three roles (host, speaker,
// viewer). Each room is a small record (expiry, revocation, hashes of the host
// and speaker link secrets) replicated between all signers as a CRDT. Short
// links redirect to Jitsi with a freshly signed, short-lived EdDSA token;
// Prosody verifies the token and asks /api/room/<name> whether the room is
// still active. A proof-of-work challenge gates creating and extending rooms.
//
// Rooms from the stateless v1 (long signed names, long-lived tokens) keep
// working and are migrated the first time their manage or host link is used.
package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"math/bits"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

//go:embed index.html
var indexHTML []byte

//go:embed logo.png
var logoPNG []byte

//go:embed favicon.png
var faviconPNG []byte

const (
	roomPrefix = "r-"
	// No vowels, no 0/1/l: random names can't spell words (and trip the haproxy
	// abuse maps) and are easy to read out. 14 chars = 66 bits.
	roomAlphabet   = "bcdfghjkmnpqrstvwxz23456789"
	roomIDLen      = 14
	legacyContext  = "ffmuc-room-v1\x00"
	legacyVersion  = 1
	legacyRawLen   = 15 + ed25519.SignatureSize
	challengeTTL   = 10 * time.Minute
	secretBytes    = 16
	gcKeep         = 30 * 24 * time.Hour // keep expired rooms this long; deleted ones stay as tombstones
	roleHost       = "host"
	roleSpeaker    = "speaker"
	maxRequestBody = 4096
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

type config struct {
	listen        string
	syncListen    string // peer sync and admin, never behind haproxy
	metricsListen string
	keyID         byte
	priv          ed25519.PrivateKey
	powKey        []byte
	syncKey       []byte
	deriveKey     []byte // from the signing seed, see derive
	peers         []string
	dataDir       string
	domain        string
	publicURL     string
	basePath      string
	durations     []time.Duration // choices for create and extend
	defaultDur    time.Duration
	maxAhead      time.Duration // an extension never reaches further than now + maxAhead
	linkTTL       time.Duration // lifetime of tokens behind the short links
	legacyMaxExt  time.Duration // v1: how far past the name's expiry tokens could be extended
	difficulty    int
}

type server struct {
	cfg   config
	store *store
	peers *peerSet

	mu   sync.Mutex
	used map[string]time.Time // spent challenges -> expiry

	reserved   atomic.Uint64
	extended   atomic.Uint64
	migrated   atomic.Uint64
	rotated    atomic.Uint64
	deleted    atomic.Uint64
	redirects  atomic.Uint64
	lookups    atomic.Uint64
	challenges atomic.Uint64
	rejMu      sync.Mutex
	rejected   map[string]uint64
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func b64key(name string) ([]byte, error) {
	k, err := base64.StdEncoding.DecodeString(os.Getenv(name))
	if err != nil || len(k) < 32 {
		return nil, fmt.Errorf("%s must be base64 with at least 32 bytes", name)
	}
	return k, nil
}

func loadConfig() (config, error) {
	var c config
	var err error
	c.listen = env("RESERVE_LISTEN", ":8095")
	c.syncListen = env("RESERVE_SYNC_LISTEN", ":8096")
	c.metricsListen = env("RESERVE_METRICS_LISTEN", "127.0.0.1:9195")
	c.domain = env("RESERVE_DOMAIN", "meet.ffmuc.net")
	c.publicURL = strings.TrimRight(env("RESERVE_PUBLIC_URL", "https://"+c.domain), "/")
	c.basePath = "/" + strings.Trim(env("RESERVE_BASE_PATH", "/reserve"), "/")
	c.dataDir = env("RESERVE_DATA_DIR", "/data")

	kid, err := strconv.Atoi(env("RESERVE_KEY_ID", "1"))
	if err != nil || kid < 0 || kid > 255 {
		return c, errors.New("RESERVE_KEY_ID must be 0..255")
	}
	c.keyID = byte(kid)

	seed, err := base64.StdEncoding.DecodeString(os.Getenv("RESERVE_PRIVATE_KEY"))
	if err != nil || len(seed) != ed25519.SeedSize {
		return c, errors.New("RESERVE_PRIVATE_KEY must be a base64 32-byte Ed25519 seed")
	}
	c.priv = ed25519.NewKeyFromSeed(seed)
	dk := hmac.New(sha256.New, seed)
	dk.Write([]byte("ffmuc-reserve-derive-v1"))
	c.deriveKey = dk.Sum(nil)

	// Each key has one job so it can be rotated on its own. All must be
	// identical on every signer.
	if c.powKey, err = b64key("RESERVE_POW_KEY"); err != nil {
		return c, err
	}
	if c.syncKey, err = b64key("RESERVE_SYNC_KEY"); err != nil {
		return c, err
	}
	if hmac.Equal(c.syncKey, c.powKey) {
		return c, errors.New("RESERVE_SYNC_KEY must differ from RESERVE_POW_KEY")
	}
	for _, p := range strings.Split(os.Getenv("RESERVE_PEERS"), ",") {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		u, err := url.Parse(p)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return c, fmt.Errorf("RESERVE_PEERS: invalid %q", p)
		}
		c.peers = append(c.peers, p)
	}

	if c.maxAhead, err = time.ParseDuration(env("RESERVE_MAX_AHEAD", "8760h")); err != nil || c.maxAhead <= 0 {
		return c, errors.New("RESERVE_MAX_AHEAD invalid")
	}
	for _, d := range strings.Split(env("RESERVE_DURATIONS", "72h,168h,720h,2160h,8760h"), ",") {
		v, err := time.ParseDuration(strings.TrimSpace(d))
		if err != nil || v <= 0 || v > c.maxAhead || v%time.Hour != 0 {
			return c, fmt.Errorf("RESERVE_DURATIONS: invalid %q (whole hours, at most RESERVE_MAX_AHEAD)", d)
		}
		c.durations = append(c.durations, v)
	}
	if c.defaultDur, err = time.ParseDuration(env("RESERVE_DEFAULT_DURATION", "72h")); err != nil || !slices.Contains(c.durations, c.defaultDur) {
		return c, errors.New("RESERVE_DEFAULT_DURATION must be one of RESERVE_DURATIONS")
	}
	if c.linkTTL, err = time.ParseDuration(env("RESERVE_LINK_TTL", "12h")); err != nil || c.linkTTL < 5*time.Minute {
		return c, errors.New("RESERVE_LINK_TTL invalid (at least 5m)")
	}
	if c.legacyMaxExt, err = time.ParseDuration(env("RESERVE_LEGACY_MAX_EXTENSION", "720h")); err != nil || c.legacyMaxExt < 0 {
		return c, errors.New("RESERVE_LEGACY_MAX_EXTENSION invalid")
	}
	if c.difficulty, err = strconv.Atoi(env("RESERVE_POW_DIFFICULTY", "18")); err != nil || c.difficulty < 0 || c.difficulty > 32 {
		return c, errors.New("RESERVE_POW_DIFFICULTY must be 0..32")
	}
	return c, nil
}

// ---- names, secrets, tokens ----

func newRoomName() (string, error) {
	var b strings.Builder
	b.WriteString(roomPrefix)
	n := big.NewInt(int64(len(roomAlphabet)))
	for range roomIDLen {
		i, err := rand.Int(rand.Reader, n)
		if err != nil {
			return "", err
		}
		b.WriteByte(roomAlphabet[i.Int64()])
	}
	return b.String(), nil
}

func isShortName(room string) bool {
	if len(room) != len(roomPrefix)+roomIDLen || !strings.HasPrefix(room, roomPrefix) {
		return false
	}
	for _, c := range room[len(roomPrefix):] {
		if !strings.ContainsRune(roomAlphabet, c) {
			return false
		}
	}
	return true
}

func isLegacyName(room string) bool {
	if !strings.HasPrefix(room, roomPrefix) || len(room) != len(roomPrefix)+b32.EncodedLen(legacyRawLen) {
		return false
	}
	for _, c := range room[len(roomPrefix):] {
		if !(c >= 'a' && c <= 'z' || c >= '2' && c <= '7') {
			return false
		}
	}
	return true
}

func validRoomName(room string) bool { return isShortName(room) || isLegacyName(room) }

// parseLegacyRoom verifies a v1 room name and returns its embedded expiry.
func (s *server) parseLegacyRoom(room string) (time.Time, error) {
	if !isLegacyName(room) {
		return time.Time{}, errors.New("not a reserved room")
	}
	raw, err := b32.DecodeString(strings.ToUpper(room[len(roomPrefix):]))
	if err != nil || len(raw) != legacyRawLen || raw[0] != legacyVersion || raw[1] != s.cfg.keyID {
		return time.Time{}, errors.New("not a reserved room")
	}
	if !ed25519.Verify(s.cfg.priv.Public().(ed25519.PublicKey), append([]byte(legacyContext), raw[:15]...), raw[15:]) {
		return time.Time{}, errors.New("bad room signature")
	}
	return time.Unix(int64(binary.BigEndian.Uint32(raw[3:7])), 0), nil
}

// hardEnd is when a room stops being usable no matter what.
func (s *server) hardEnd(r *record) int64 {
	if r.Revoked != 0 {
		return min(r.Revoked, r.Expires)
	}
	return r.Expires
}

func (s *server) legacyLimit(r *record) int64 {
	if !r.Legacy {
		return 0
	}
	exp, err := s.parseLegacyRoom(r.Room)
	if err != nil {
		return 0
	}
	return exp.Add(s.cfg.legacyMaxExt).Unix()
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func hashSecret(secret string) string {
	h := sha256.Sum256([]byte("ffmuc-reserve-secret\x00" + secret))
	return hex.EncodeToString(h[:])
}

// derive makes speaker and migrated v1 secrets. Its key comes from the signing
// seed, not the sync key, so the sync key can be rotated without breaking
// links; whoever has the seed can forge tokens anyway. Replacing the signing
// key breaks speaker links and migrated v1 manage links, so keep the old seed
// as RESERVE_PRIVATE_KEY and only add the new key id in that case.
func (s *server) derive(label, in string) string {
	m := hmac.New(sha256.New, s.cfg.deriveKey)
	m.Write([]byte(label + "\x00" + in))
	return b64url(m.Sum(nil)[:secretBytes])
}

// The speaker secret is derived from the host secret, so the manage page can
// show both while only hashes are stored. Holders of the speaker link can't go
// the other way.
func (s *server) speakerSecret(host string) string { return s.derive("speaker", host) }

// Migrated v1 rooms get deterministic secrets, so using an old link twice
// yields the same new links instead of piling up secrets.
func (s *server) legacyHostSecret(room string) string { return s.derive("legacy-host", room) }

func newSecret() (string, error) {
	b := make([]byte, secretBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return b64url(b), nil
}

func validSecret(v string) bool {
	if len(v) != base64.RawURLEncoding.EncodedLen(secretBytes) {
		return false
	}
	_, err := base64.RawURLEncoding.DecodeString(v)
	return err == nil
}

// genClaim is how a generation travels in tokens and to Prosody: hex, 0 is "0"
// so v1 tokens (no gen claim) match rooms that were never rotated.
func genClaim(g uint64) string { return strconv.FormatUint(g, 16) }

// nextGen is the generation after a rotation: counter up, fresh random low bits.
func nextGen(g uint64) uint64 {
	var b [4]byte
	rand.Read(b[:])
	return ((g>>32)+1)<<32 | uint64(binary.BigEndian.Uint32(b[:]))
}

func (s *server) token(room, role string, gen uint64, iat, exp time.Time) (string, error) {
	hdr, _ := json.Marshal(map[string]string{"alg": "EdDSA", "typ": "JWT", "kid": strconv.Itoa(int(s.cfg.keyID))})
	claims, err := json.Marshal(map[string]any{
		"iss":       "ffmuc-reserve",
		"aud":       "jitsi",
		"sub":       s.cfg.domain,
		"room":      room,
		"iat":       iat.Unix(),
		"nbf":       iat.Unix() - 60,
		"exp":       exp.Unix(),
		"moderator": role == roleHost,
		"gen":       genClaim(gen),
		"context":   map[string]any{"user": map[string]any{"id": role + ":" + room}},
	})
	if err != nil {
		return "", err
	}
	in := b64url(hdr) + "." + b64url(claims)
	return in + "." + b64url(ed25519.Sign(s.cfg.priv, []byte(in))), nil
}

type legacyClaims struct {
	Iat     int64  `json:"iat"`
	Exp     int64  `json:"exp"`
	Room    string `json:"room"`
	Context struct {
		User struct {
			ID string `json:"id"`
		} `json:"user"`
	} `json:"context"`
}

// parseLegacyHostToken checks a v1 host token (bare or inside a link). Expired
// tokens are fine: the record or the v1 extension window decides.
func (s *server) parseLegacyHostToken(in string) (*legacyClaims, error) {
	parts := strings.Split(in, ".")
	if len(parts) != 3 {
		return nil, errors.New("no host link found")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !ed25519.Verify(s.cfg.priv.Public().(ed25519.PublicKey), []byte(parts[0]+"."+parts[1]), sig) {
		return nil, errors.New("invalid host link")
	}
	body, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, errors.New("invalid host link")
	}
	var c legacyClaims
	if json.Unmarshal(body, &c) != nil || c.Context.User.ID != roleHost+":"+c.Room {
		return nil, errors.New("this is not a host link")
	}
	if _, err := s.parseLegacyRoom(c.Room); err != nil {
		return nil, err
	}
	return &c, nil
}

// extractKey pulls the credential out of whatever the user pasted: a manage
// link (#k=… or v1 #m=…), a short host link (/h/…), a v1 host link (?jwt=…) or
// the bare value.
func (s *server) extractKey(in string) string {
	in = strings.TrimSpace(in)
	for _, marker := range []string{"#k=", "#m=", "jwt=", s.cfg.basePath + "/h/"} {
		if i := strings.LastIndex(in, marker); i >= 0 {
			in = in[i+len(marker):]
		}
	}
	if i := strings.IndexAny(in, "&#?/ "); i >= 0 {
		in = in[:i]
	}
	return in
}

// ---- proof of work ----

func (s *server) mac(msg string) string {
	m := hmac.New(sha256.New, s.cfg.powKey)
	m.Write([]byte(msg))
	return hex.EncodeToString(m.Sum(nil)[:16])
}

func (s *server) newChallenge(now time.Time) string {
	r := make([]byte, 12)
	rand.Read(r)
	msg := strconv.FormatInt(now.Unix(), 10) + "." + hex.EncodeToString(r)
	return msg + "." + s.mac(msg)
}

func leadingZeroBits(h []byte) int {
	n := 0
	for _, b := range h {
		if b == 0 {
			n += 8
			continue
		}
		return n + bits.LeadingZeros8(b)
	}
	return n
}

func (s *server) checkPoW(challenge, nonce string, now time.Time) (string, bool) {
	parts := strings.Split(challenge, ".")
	if len(parts) != 3 || len(nonce) == 0 || len(nonce) > 32 {
		return "malformed", false
	}
	if !hmac.Equal([]byte(s.mac(parts[0]+"."+parts[1])), []byte(parts[2])) {
		return "bad_mac", false
	}
	ts, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return "malformed", false
	}
	age := now.Sub(time.Unix(ts, 0))
	if age < -time.Minute || age > challengeTTL {
		return "expired", false
	}
	h := sha256.Sum256([]byte(challenge + ":" + nonce))
	if leadingZeroBits(h[:]) < s.cfg.difficulty {
		return "insufficient", false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.used[challenge]; ok {
		return "replay", false
	}
	s.used[challenge] = time.Unix(ts, 0).Add(challengeTTL + time.Minute)
	return "", true
}

func (s *server) reject(reason string) {
	s.rejMu.Lock()
	s.rejected[reason]++
	s.rejMu.Unlock()
}

func (s *server) gc() {
	for range time.Tick(time.Minute) {
		now := time.Now()
		s.mu.Lock()
		for k, exp := range s.used {
			if now.After(exp) {
				delete(s.used, k)
			}
		}
		s.mu.Unlock()
		s.store.gc(now, gcKeep, s.legacyLimit)
	}
}

// ---- HTTP helpers ----

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

type apiError struct {
	code   int
	reason string // metrics label
	msg    string
}

func (e *apiError) Error() string { return e.msg }

func fail(code int, reason, msg string) error { return &apiError{code, reason, msg} }

func (s *server) writeErr(w http.ResponseWriter, err error) {
	var ae *apiError
	if !errors.As(err, &ae) {
		log.Printf("internal error: %v", err)
		ae = &apiError{500, "internal", "internal"}
	}
	s.reject(ae.reason)
	writeJSON(w, ae.code, map[string]string{"error": ae.msg})
}

func decode(w http.ResponseWriter, r *http.Request, v any) error {
	if r.Method != http.MethodPost {
		return fail(http.StatusMethodNotAllowed, "malformed", "method not allowed")
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxRequestBody)).Decode(v); err != nil {
		return fail(400, "malformed", "malformed")
	}
	return nil
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != s.cfg.basePath && r.URL.Path != s.cfg.basePath+"/" {
		http.NotFound(w, r)
		return
	}
	// Relative asset URLs (logo.png) only resolve correctly with a trailing slash.
	if r.URL.Path == s.cfg.basePath {
		target := s.cfg.basePath + "/"
		if r.URL.RawQuery != "" {
			target += "?" + r.URL.RawQuery
		}
		http.Redirect(w, r, target, http.StatusMovedPermanently)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline' blob:; worker-src blob:; style-src 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Write(indexHTML)
}

func staticPNG(b []byte) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "public, max-age=86400")
		w.Write(b)
	}
}

// ---- rooms ----

// view is what the manage page gets back. Only ever sent to holders of the
// host secret.
func (s *server) view(r *record, host string, now time.Time) map[string]any {
	base := s.cfg.publicURL + s.cfg.basePath
	hours := make([]int, len(s.cfg.durations))
	for i, d := range s.cfg.durations {
		hours[i] = int(d.Hours())
	}
	status := "active"
	switch {
	case r.Revoked != 0:
		status = "deleted"
	case r.Expires <= now.Unix():
		status = "expired"
	}
	return map[string]any{
		"room":        r.Room,
		"status":      status,
		"expires":     time.Unix(r.Expires, 0).UTC().Format(time.RFC3339),
		"max_ahead_h": int(s.cfg.maxAhead.Hours()),
		"durations":   hours,
		"host_url":    base + "/h/" + host,
		"speaker_url": base + "/s/" + s.speakerSecret(host),
		"guest_url":   s.cfg.publicURL + "/" + r.Room,
		"manage_url":  base + "/#k=" + host,
	}
}

// resolve authenticates a manage request. It accepts the host secret of a
// stored room, or a v1 host token, which migrates the room on first use.
func (s *server) resolve(raw string, now time.Time) (*record, string, bool, error) {
	key := s.extractKey(raw)
	if validSecret(key) {
		r, e := s.store.bySecret(hashSecret(key))
		if r == nil {
			s.peers.pullSoon()
			r, e = s.store.bySecret(hashSecret(key))
		}
		if r == nil || e.Role != roleHost {
			return nil, "", false, fail(404, "bad_key", "unknown room or not a host link")
		}
		if !r.current(e) {
			return nil, "", false, fail(410, "bad_key", "this link was replaced by new links")
		}
		return r, key, false, nil
	}

	c, err := s.parseLegacyHostToken(key)
	if err != nil {
		return nil, "", false, fail(400, "bad_key", err.Error())
	}
	host := s.legacyHostSecret(c.Room)
	speaker := s.speakerSecret(host)
	nameExp, _ := s.parseLegacyRoom(c.Room)
	exp := min(c.Exp, nameExp.Add(s.cfg.legacyMaxExt).Unix())
	if cur := s.store.get(c.Room); cur != nil {
		if cur.Revoked != 0 {
			return nil, "", false, fail(410, "bad_key", "room was deleted")
		}
		if !cur.current(cur.Secrets[hashSecret(host)]) {
			return nil, "", false, fail(410, "bad_key", "this link was replaced by new links")
		}
		if exp <= cur.Expires {
			return cur, host, false, nil
		}
		// A newer v1 link (extended in v1) than the one used for the migration.
		r, err := s.store.update(c.Room, func(cur *record) (*record, error) {
			cur.Expires = exp
			return cur, nil
		})
		return r, host, false, err
	}
	if exp <= now.Unix() {
		return nil, "", false, fail(410, "bad_key", "room expired")
	}
	r, err := s.store.update(c.Room, func(_ *record) (*record, error) {
		return &record{
			Created: now.Unix(),
			Expires: exp,
			Legacy:  true,
			Secrets: map[string]*secretEntry{
				hashSecret(host):    {Role: roleHost},
				hashSecret(speaker): {Role: roleSpeaker},
			},
		}, nil
	})
	if err != nil {
		return nil, "", false, err
	}
	s.migrated.Add(1)
	log.Printf("migrated v1 room %s…", c.Room[:12])
	return r, host, true, nil
}

func (s *server) pickDuration(hours int) (time.Duration, error) {
	if hours == 0 {
		return s.cfg.defaultDur, nil
	}
	for _, d := range s.cfg.durations {
		if int(d.Hours()) == hours {
			return d, nil
		}
	}
	return 0, fail(400, "malformed", "duration not allowed")
}

func (s *server) handleChallenge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.challenges.Add(1)
	hours := make([]int, len(s.cfg.durations))
	for i, d := range s.cfg.durations {
		hours[i] = int(d.Hours())
	}
	writeJSON(w, 200, map[string]any{
		"challenge":   s.newChallenge(time.Now()),
		"difficulty":  s.cfg.difficulty,
		"durations":   hours,
		"default":     int(s.cfg.defaultDur.Hours()),
		"max_ahead_h": int(s.cfg.maxAhead.Hours()),
	})
}

func (s *server) handleReserve(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Challenge string `json:"challenge"`
		Nonce     string `json:"nonce"`
		Hours     int    `json:"hours"`
	}
	if err := decode(w, r, &req); err != nil {
		s.writeErr(w, err)
		return
	}
	ttl, err := s.pickDuration(req.Hours)
	if err != nil {
		s.writeErr(w, err)
		return
	}
	now := time.Now()
	if reason, ok := s.checkPoW(req.Challenge, req.Nonce, now); !ok {
		s.writeErr(w, fail(403, reason, reason))
		return
	}
	host, err := newSecret()
	if err != nil {
		s.writeErr(w, err)
		return
	}
	var rec *record
	for range 5 {
		room, err := newRoomName()
		if err != nil {
			s.writeErr(w, err)
			return
		}
		rec, err = s.store.update(room, func(cur *record) (*record, error) {
			if cur != nil {
				return nil, errors.New("collision")
			}
			return &record{
				Created: now.Unix(),
				Expires: now.Add(ttl).Unix(),
				Secrets: map[string]*secretEntry{
					hashSecret(host):                  {Role: roleHost},
					hashSecret(s.speakerSecret(host)): {Role: roleSpeaker},
				},
			}, nil
		})
		if err == nil {
			break
		}
	}
	if rec == nil {
		s.writeErr(w, errors.New("no free room name"))
		return
	}
	s.reserved.Add(1)
	writeJSON(w, 200, s.view(rec, host, now))
}

func (s *server) handleManage(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Key string `json:"key"`
	}
	if err := decode(w, r, &req); err != nil {
		s.writeErr(w, err)
		return
	}
	now := time.Now()
	rec, host, migrated, err := s.resolve(req.Key, now)
	if err != nil {
		s.writeErr(w, err)
		return
	}
	v := s.view(rec, host, now)
	v["migrated"] = migrated
	writeJSON(w, 200, v)
}

func (s *server) handleExtend(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Challenge string `json:"challenge"`
		Nonce     string `json:"nonce"`
		Hours     int    `json:"hours"`
		Key       string `json:"key"`
	}
	if err := decode(w, r, &req); err != nil {
		s.writeErr(w, err)
		return
	}
	ttl, err := s.pickDuration(req.Hours)
	if err != nil {
		s.writeErr(w, err)
		return
	}
	now := time.Now()
	rec, host, _, err := s.resolve(req.Key, now)
	if err != nil {
		s.writeErr(w, err)
		return
	}
	if rec.Revoked != 0 {
		s.writeErr(w, fail(410, "bad_key", "room was deleted"))
		return
	}
	if rec.Expires <= now.Unix() {
		s.writeErr(w, fail(410, "bad_key", "room expired"))
		return
	}
	if reason, ok := s.checkPoW(req.Challenge, req.Nonce, now); !ok {
		s.writeErr(w, fail(403, reason, reason))
		return
	}
	rec, err = s.store.update(rec.Room, func(cur *record) (*record, error) {
		if cur == nil || cur.Revoked != 0 {
			return nil, fail(410, "bad_key", "room was deleted")
		}
		if cur.Expires <= now.Unix() {
			return nil, fail(410, "bad_key", "room expired")
		}
		cur.Expires = max(cur.Expires, min(cur.Expires+int64(ttl.Seconds()), now.Add(s.cfg.maxAhead).Unix()))
		return cur, nil
	})
	if err != nil {
		s.writeErr(w, err)
		return
	}
	s.extended.Add(1)
	writeJSON(w, 200, s.view(rec, host, now))
}

// handleRotate replaces the host and speaker links and voids every token
// issued so far. The viewer link (room name) stays.
func (s *server) handleRotate(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Key string `json:"key"`
	}
	if err := decode(w, r, &req); err != nil {
		s.writeErr(w, err)
		return
	}
	now := time.Now()
	rec, _, _, err := s.resolve(req.Key, now)
	if err != nil {
		s.writeErr(w, err)
		return
	}
	host, err := newSecret()
	if err != nil {
		s.writeErr(w, err)
		return
	}
	rec, err = s.store.update(rec.Room, func(cur *record) (*record, error) {
		if cur == nil || cur.Revoked != 0 {
			return nil, fail(410, "bad_key", "room was deleted")
		}
		// The new gen voids all older secrets and tokens. If another signer
		// rotates at the same time, the higher gen wins everywhere.
		cur.Gen = nextGen(cur.Gen)
		cur.Secrets[hashSecret(host)] = &secretEntry{Role: roleHost, Gen: cur.Gen}
		cur.Secrets[hashSecret(s.speakerSecret(host))] = &secretEntry{Role: roleSpeaker, Gen: cur.Gen}
		return cur, nil
	})
	if err != nil {
		s.writeErr(w, err)
		return
	}
	s.rotated.Add(1)
	writeJSON(w, 200, s.view(rec, host, now))
}

func (s *server) handleDelete(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Key string `json:"key"`
	}
	if err := decode(w, r, &req); err != nil {
		s.writeErr(w, err)
		return
	}
	now := time.Now()
	rec, _, _, err := s.resolve(req.Key, now)
	if err != nil {
		s.writeErr(w, err)
		return
	}
	if _, err := s.revoke(rec.Room, now); err != nil {
		s.writeErr(w, err)
		return
	}
	s.deleted.Add(1)
	writeJSON(w, 200, map[string]any{"deleted": true})
}

func (s *server) revoke(room string, now time.Time) (*record, error) {
	return s.store.update(room, func(cur *record) (*record, error) {
		if cur == nil {
			// Unmigrated v1 room: a tombstone is enough to block it.
			if _, err := s.parseLegacyRoom(room); err != nil {
				return nil, fail(404, "bad_key", "unknown room")
			}
			cur = &record{Created: now.Unix(), Legacy: true}
		}
		if cur.Revoked == 0 {
			cur.Revoked = now.Unix()
		}
		return cur, nil
	})
}

// handleJoin turns a short host or speaker link into a Jitsi URL with a fresh
// token. Errors go to the manage page, which explains them.
func (s *server) handleJoin(role string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		secret := strings.TrimPrefix(r.URL.Path, s.cfg.basePath+"/"+role[:1]+"/")
		gone := func(why string) {
			http.Redirect(w, r, s.cfg.basePath+"/#gone="+why, http.StatusFound)
		}
		if !validSecret(secret) {
			gone("invalid")
			return
		}
		rec, e := s.store.bySecret(hashSecret(secret))
		if rec == nil {
			s.peers.pullSoon()
			rec, e = s.store.bySecret(hashSecret(secret))
		}
		now := time.Now()
		switch {
		case rec == nil || e.Role != role:
			gone("invalid")
			return
		case rec.Revoked != 0:
			gone("deleted")
			return
		case !rec.current(e):
			gone("replaced")
			return
		case rec.Expires <= now.Unix():
			gone("expired")
			return
		}
		exp := min(now.Add(s.cfg.linkTTL).Unix(), rec.Expires)
		tok, err := s.token(rec.Room, role, rec.Gen, now, time.Unix(exp, 0))
		if err != nil {
			http.Error(w, "internal", 500)
			return
		}
		s.redirects.Add(1)
		http.Redirect(w, r, s.cfg.publicURL+"/"+rec.Room+"?jwt="+tok, http.StatusFound)
	}
}

// handleRoom answers Prosody: may this room exist, and which tokens count?
// Room names are public (viewer link), so this reveals nothing secret.
func (s *server) handleRoom(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.lookups.Add(1)
	room := strings.TrimPrefix(r.URL.Path, s.cfg.basePath+"/api/room/")
	if !validRoomName(room) {
		writeJSON(w, 200, map[string]any{"status": "unknown"})
		return
	}
	rec := s.store.get(room)
	if rec == nil && isShortName(room) {
		s.peers.pullSoon()
		rec = s.store.get(room)
	}
	now := time.Now().Unix()
	res := map[string]any{}
	switch {
	case rec == nil && isLegacyName(room):
		// Not migrated yet: Prosody applies the v1 rules (signature and token expiry).
		res["status"] = "legacy"
	case rec == nil:
		res["status"] = "unknown"
	case rec.Revoked != 0:
		res["status"] = "deleted"
	case rec.Expires <= now:
		res["status"] = "expired"
	default:
		res["status"] = "active"
		res["expires"] = rec.Expires
		res["gen"] = genClaim(rec.Gen)
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, res)
}

// handleAdminRevoke deletes a room by name, for abuse handling. Signed like
// peer requests, see "meet-reserve revoke".
func (s *server) handleAdminRevoke(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := verifySync(r, s.cfg.syncKey)
	if err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	var req struct {
		Room string `json:"room"`
	}
	if json.Unmarshal(body, &req) != nil || !validRoomName(req.Room) {
		http.Error(w, "malformed", http.StatusBadRequest)
		return
	}
	if _, err := s.revoke(req.Room, time.Now()); err != nil {
		s.writeErr(w, err)
		return
	}
	s.deleted.Add(1)
	log.Printf("admin: revoked room %s", req.Room)
	writeJSON(w, 200, map[string]bool{"revoked": true})
}

func (s *server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	st := s.store.stats(time.Now().Unix(), func(r *record) int64 { return max(s.hardEnd(r), s.legacyLimit(r)) })
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	counter := func(name, help string, v uint64) {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s counter\n%s %d\n", name, help, name, name, v)
	}
	gauge := func(name, help string, v int) {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s gauge\n%s %d\n", name, help, name, name, v)
	}
	counter("ffmuc_reserve_rooms_reserved_total", "Rooms reserved on this signer since start.", s.reserved.Load())
	counter("ffmuc_reserve_rooms_extended_total", "Room extensions on this signer since start.", s.extended.Load())
	counter("ffmuc_reserve_rooms_migrated_total", "v1 rooms migrated on this signer since start.", s.migrated.Load())
	counter("ffmuc_reserve_rooms_rotated_total", "Link rotations on this signer since start.", s.rotated.Load())
	counter("ffmuc_reserve_rooms_deleted_total", "Rooms deleted on this signer since start.", s.deleted.Load())
	counter("ffmuc_reserve_link_redirects_total", "Short link redirects since start.", s.redirects.Load())
	counter("ffmuc_reserve_room_lookups_total", "Prosody room lookups since start.", s.lookups.Load())
	counter("ffmuc_reserve_challenges_issued_total", "Proof-of-work challenges issued.", s.challenges.Load())
	gauge("ffmuc_reserve_rooms_stored", "Room records in the replicated store.", st.total)
	gauge("ffmuc_reserve_rooms_active", "Usable rooms in the replicated store.", st.active)
	gauge("ffmuc_reserve_rooms_active_legacy", "Usable migrated v1 rooms.", st.legacy)
	gauge("ffmuc_reserve_rooms_deleted", "Deleted rooms still kept as tombstones.", st.revoked)
	fmt.Fprintf(w, "# HELP ffmuc_reserve_pow_rejected_total Rejected requests.\n# TYPE ffmuc_reserve_pow_rejected_total counter\n")
	s.rejMu.Lock()
	for _, reason := range []string{"malformed", "bad_mac", "expired", "insufficient", "replay", "bad_key", "internal"} {
		fmt.Fprintf(w, "ffmuc_reserve_pow_rejected_total{reason=%q} %d\n", reason, s.rejected[reason])
	}
	s.rejMu.Unlock()
	fmt.Fprintf(w, "# HELP ffmuc_reserve_peer_last_sync_seconds Unix time of the last successful pull per peer.\n# TYPE ffmuc_reserve_peer_last_sync_seconds gauge\n")
	for _, p := range s.peers.peers {
		fmt.Fprintf(w, "ffmuc_reserve_peer_last_sync_seconds{peer=%q} %d\n", p.url, p.lastOK.Load())
	}
	fmt.Fprintf(w, "# HELP ffmuc_reserve_peer_failures_total Failed pulls and pushes per peer.\n# TYPE ffmuc_reserve_peer_failures_total counter\n")
	for _, p := range s.peers.peers {
		fmt.Fprintf(w, "ffmuc_reserve_peer_failures_total{peer=%q} %d\n", p.url, p.failures.Load())
	}
	counter("ffmuc_reserve_sync_pushed_total", "Records pushed to peers.", s.peers.pushed.Load())
	counter("ffmuc_reserve_sync_merged_total", "Records changed by peer updates.", s.peers.merged.Load())
	gauge("ffmuc_reserve_pow_difficulty_bits", "Required leading zero bits.", s.cfg.difficulty)
	fmt.Fprintf(w, "# HELP ffmuc_reserve_info Signer info.\n# TYPE ffmuc_reserve_info gauge\nffmuc_reserve_info{key_id=\"%d\"} 1\n", s.cfg.keyID)
}

// adminRevoke implements "meet-reserve revoke <room or viewer link>" against
// the local instance.
func adminRevoke(cfg config, arg string) error {
	room := arg
	if i := strings.LastIndex(room, "/"); i >= 0 {
		room = room[i+1:]
	}
	if i := strings.IndexAny(room, "?#"); i >= 0 {
		room = room[:i]
	}
	room = strings.ToLower(room)
	if !validRoomName(room) {
		return fmt.Errorf("%q is not a reserved room", arg)
	}
	body, _ := json.Marshal(map[string]string{"room": room})
	addr := cfg.syncListen
	if strings.HasPrefix(addr, ":") {
		addr = "127.0.0.1" + addr
	}
	req, err := http.NewRequest(http.MethodPost, "http://"+addr+cfg.basePath+"/_admin/revoke", bytes.NewReader(body))
	if err != nil {
		return err
	}
	signRequest(req, cfg.syncKey, body)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	fmt.Println("revoked", room)
	return nil
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "genkey" {
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		k := make([]byte, 32)
		rand.Read(k)
		fmt.Printf("private (RESERVE_PRIVATE_KEY): %s\npublic  (prosody):             %s\nrandom 32 bytes (POW/SYNC):    %s\n",
			base64.StdEncoding.EncodeToString(priv.Seed()), base64.StdEncoding.EncodeToString(pub), base64.StdEncoding.EncodeToString(k))
		return
	}
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	if len(os.Args) == 3 && os.Args[1] == "revoke" {
		if err := adminRevoke(cfg, os.Args[2]); err != nil {
			log.Fatal(err)
		}
		return
	}

	st := newStore(cfg.dataDir)
	if err := st.load(); err != nil {
		log.Fatalf("store: %v", err)
	}
	ps := newPeerSet(cfg.peers, cfg.syncKey, cfg.basePath, st)
	st.onLocal = ps.push
	s := &server{cfg: cfg, store: st, peers: ps, used: map[string]time.Time{}, rejected: map[string]uint64{}}

	bp := cfg.basePath
	mux := http.NewServeMux()
	mux.HandleFunc(bp, s.handleIndex)
	mux.HandleFunc(bp+"/", s.handleIndex)
	mux.HandleFunc(bp+"/api/challenge", s.handleChallenge)
	mux.HandleFunc(bp+"/api/reserve", s.handleReserve)
	mux.HandleFunc(bp+"/api/manage", s.handleManage)
	mux.HandleFunc(bp+"/api/extend", s.handleExtend)
	mux.HandleFunc(bp+"/api/rotate", s.handleRotate)
	mux.HandleFunc(bp+"/api/delete", s.handleDelete)
	mux.HandleFunc(bp+"/api/room/", s.handleRoom)
	mux.HandleFunc(bp+"/h/", s.handleJoin(roleHost))
	mux.HandleFunc(bp+"/s/", s.handleJoin(roleSpeaker))
	mux.HandleFunc(bp+"/logo.png", staticPNG(logoPNG))
	mux.HandleFunc(bp+"/favicon.png", staticPNG(faviconPNG))
	mux.HandleFunc(bp+"/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })

	// Signed with RESERVE_SYNC_KEY, on its own port so the public proxy can't reach it.
	smux := http.NewServeMux()
	smux.HandleFunc(bp+"/_peer/sync", ps.handleSync)
	smux.HandleFunc(bp+"/_peer/push", ps.handlePush)
	smux.HandleFunc(bp+"/_admin/revoke", s.handleAdminRevoke)
	go func() {
		log.Fatal((&http.Server{Addr: cfg.syncListen, Handler: smux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 60 * time.Second}).ListenAndServe())
	}()

	mmux := http.NewServeMux()
	mmux.HandleFunc("/metrics", s.handleMetrics)
	go func() {
		log.Fatal((&http.Server{Addr: cfg.metricsListen, Handler: mmux, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe())
	}()

	// Catch up before serving, so a signer that was down doesn't answer from
	// stale data. Peers that are down too are skipped after the timeout.
	if len(ps.peers) > 0 {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		ps.pullAll(ctx)
		cancel()
	}
	go ps.loop()
	go s.gc()

	log.Printf("meet-reserve kid=%d difficulty=%d durations=%v max_ahead=%s peers=%d rooms=%d listen=%s pub=%s",
		cfg.keyID, cfg.difficulty, cfg.durations, cfg.maxAhead, len(cfg.peers), len(st.rooms), cfg.listen,
		base64.StdEncoding.EncodeToString(cfg.priv.Public().(ed25519.PublicKey)))
	srv := &http.Server{Addr: cfg.listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 30 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
