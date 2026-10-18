// meet-reserve hands out signed, self-expiring Jitsi room names plus host and
// speaker tokens. Nothing is stored: Prosody verifies the Ed25519 signature
// embedded in the room name and in the tokens. A proof-of-work challenge
// (stateless, HMAC-protected) gates each reservation.
package main

import (
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
	"math/bits"
	"net/http"
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
	roomPrefix     = "r-"
	roomSigContext = "ffmuc-room-v1\x00"
	payloadVersion = 1
	flagViewers    = 1
	challengeTTL   = 10 * time.Minute
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

type config struct {
	listen        string
	metricsListen string
	keyID         byte
	priv          ed25519.PrivateKey
	powKey        []byte
	domain        string
	publicURL     string
	basePath      string
	durations     []time.Duration // allowed room lifetimes
	defaultDur    time.Duration
	maxExtension  time.Duration // how far past the name's expiry tokens may be extended
	difficulty    int
}

type server struct {
	cfg    config
	powKey []byte

	mu     sync.Mutex
	used   map[string]time.Time // spent challenges -> expiry
	active map[string]time.Time // reserved rooms -> expiry

	reserved   atomic.Uint64
	extended   atomic.Uint64
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

func loadConfig() (config, error) {
	var c config
	c.listen = env("RESERVE_LISTEN", ":8095")
	c.metricsListen = env("RESERVE_METRICS_LISTEN", "127.0.0.1:9195")
	c.domain = env("RESERVE_DOMAIN", "meet.ffmuc.net")
	c.publicURL = strings.TrimRight(env("RESERVE_PUBLIC_URL", "https://"+c.domain), "/")
	c.basePath = "/" + strings.Trim(env("RESERVE_BASE_PATH", "/reserve"), "/")

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

	// Separate from the signing key so either can be rotated on its own. Must be
	// identical on all signers behind the load balancer.
	if c.powKey, err = base64.StdEncoding.DecodeString(os.Getenv("RESERVE_POW_KEY")); err != nil || len(c.powKey) < 32 {
		return c, errors.New("RESERVE_POW_KEY must be base64 with at least 32 bytes")
	}

	for _, d := range strings.Split(env("RESERVE_DURATIONS", "24h,72h,168h"), ",") {
		v, err := time.ParseDuration(strings.TrimSpace(d))
		if err != nil || v <= 0 || v > 31*24*time.Hour {
			return c, fmt.Errorf("RESERVE_DURATIONS: invalid %q", d)
		}
		c.durations = append(c.durations, v)
	}
	if c.defaultDur, err = time.ParseDuration(env("RESERVE_DEFAULT_DURATION", "72h")); err != nil || !slices.Contains(c.durations, c.defaultDur) {
		return c, errors.New("RESERVE_DEFAULT_DURATION must be one of RESERVE_DURATIONS")
	}
	if c.maxExtension, err = time.ParseDuration(env("RESERVE_MAX_EXTENSION", "720h")); err != nil || c.maxExtension < 0 {
		return c, errors.New("RESERVE_MAX_EXTENSION invalid")
	}
	if c.difficulty, err = strconv.Atoi(env("RESERVE_POW_DIFFICULTY", "18")); err != nil || c.difficulty < 0 || c.difficulty > 32 {
		return c, errors.New("RESERVE_POW_DIFFICULTY must be 0..32")
	}
	return c, nil
}

func newServer(c config) *server {
	return &server{
		cfg:      c,
		powKey:   c.powKey,
		used:     map[string]time.Time{},
		active:   map[string]time.Time{},
		rejected: map[string]uint64{},
	}
}

// ---- room + token signing ----

func (s *server) newRoom(exp time.Time) (string, error) {
	p := make([]byte, 15)
	p[0] = payloadVersion
	p[1] = s.cfg.keyID
	p[2] = flagViewers
	binary.BigEndian.PutUint32(p[3:7], uint32(exp.Unix()))
	if _, err := rand.Read(p[7:]); err != nil {
		return "", err
	}
	sig := ed25519.Sign(s.cfg.priv, append([]byte(roomSigContext), p...))
	return roomPrefix + strings.ToLower(b32.EncodeToString(append(p, sig...))), nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func (s *server) token(room, role string, moderator bool, now, exp time.Time) (string, error) {
	hdr, _ := json.Marshal(map[string]string{"alg": "EdDSA", "typ": "JWT", "kid": strconv.Itoa(int(s.cfg.keyID))})
	claims, err := json.Marshal(map[string]any{
		"iss":       "ffmuc-reserve",
		"aud":       "jitsi",
		"sub":       s.cfg.domain,
		"room":      room,
		"iat":       now.Unix(),
		"nbf":       now.Unix() - 60,
		"exp":       exp.Unix(),
		"moderator": moderator,
		"context":   map[string]any{"user": map[string]any{"id": role + ":" + room}},
	})
	if err != nil {
		return "", err
	}
	in := b64url(hdr) + "." + b64url(claims)
	return in + "." + b64url(ed25519.Sign(s.cfg.priv, []byte(in))), nil
}

// ---- proof of work ----

func (s *server) mac(msg string) string {
	m := hmac.New(sha256.New, s.powKey)
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
		for k, exp := range s.active {
			if now.After(exp) {
				delete(s.active, k)
			}
		}
		s.mu.Unlock()
	}
}

// ---- HTTP ----

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
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
		"challenge":  s.newChallenge(time.Now()),
		"difficulty": s.cfg.difficulty,
		"durations":  hours,
		"default":    int(s.cfg.defaultDur.Hours()),
	})
}

// parseRoom verifies a room name and returns its embedded expiry.
func (s *server) parseRoom(room string) (time.Time, error) {
	if !strings.HasPrefix(room, roomPrefix) {
		return time.Time{}, errors.New("not a reserved room")
	}
	raw, err := b32.DecodeString(strings.ToUpper(room[len(roomPrefix):]))
	if err != nil || len(raw) != 15+ed25519.SignatureSize || raw[0] != payloadVersion || raw[1] != s.cfg.keyID {
		return time.Time{}, errors.New("not a reserved room")
	}
	if !ed25519.Verify(s.cfg.priv.Public().(ed25519.PublicKey), append([]byte(roomSigContext), raw[:15]...), raw[15:]) {
		return time.Time{}, errors.New("bad room signature")
	}
	return time.Unix(int64(binary.BigEndian.Uint32(raw[3:7])), 0), nil
}

// parseHostToken accepts a host link or bare token, checks our signature and
// returns the room. Expired tokens are fine, the extension window is checked
// against the room name.
func (s *server) parseHostToken(in string) (string, time.Time, error) {
	in = strings.TrimSpace(in)
	for _, marker := range []string{"jwt=", "#m="} {
		if i := strings.Index(in, marker); i >= 0 {
			in = in[i+len(marker):]
		}
	}
	if i := strings.IndexAny(in, "&#"); i >= 0 {
		in = in[:i]
	}
	parts := strings.Split(in, ".")
	if len(parts) != 3 {
		return "", time.Time{}, errors.New("no host token found")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !ed25519.Verify(s.cfg.priv.Public().(ed25519.PublicKey), []byte(parts[0]+"."+parts[1]), sig) {
		return "", time.Time{}, errors.New("invalid host link")
	}
	body, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", time.Time{}, errors.New("invalid host link")
	}
	var c struct {
		Exp     int64  `json:"exp"`
		Room    string `json:"room"`
		Context struct {
			User struct {
				ID string `json:"id"`
			} `json:"user"`
		} `json:"context"`
	}
	if json.Unmarshal(body, &c) != nil || c.Context.User.ID != "host:"+c.Room {
		return "", time.Time{}, errors.New("this is not a host link")
	}
	return c.Room, time.Unix(c.Exp, 0), nil
}

func (s *server) handleReserve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Challenge string `json:"challenge"`
		Nonce     string `json:"nonce"`
		Hours     int    `json:"hours"`
		Extend    string `json:"extend"` // host link of an existing room
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		s.reject("malformed")
		writeJSON(w, 400, map[string]string{"error": "malformed"})
		return
	}
	ttl := s.cfg.defaultDur
	if req.Hours != 0 {
		ttl = 0
		for _, d := range s.cfg.durations {
			if int(d.Hours()) == req.Hours {
				ttl = d
			}
		}
		if ttl == 0 {
			s.reject("malformed")
			writeJSON(w, 400, map[string]string{"error": "duration not allowed"})
			return
		}
	}

	now := time.Now()
	var room string
	var limit, from time.Time
	if req.Extend != "" {
		var err error
		if room, from, err = s.parseHostToken(req.Extend); err == nil {
			var nameExp time.Time
			if nameExp, err = s.parseRoom(room); err == nil {
				limit = nameExp.Add(s.cfg.maxExtension)
				if !now.Before(limit) {
					err = errors.New("room can't be extended any further")
				}
			}
		}
		if err != nil {
			s.reject("bad_extend")
			writeJSON(w, 400, map[string]string{"error": err.Error()})
			return
		}
	}

	if reason, ok := s.checkPoW(req.Challenge, req.Nonce, now); !ok {
		s.reject(reason)
		writeJSON(w, 403, map[string]string{"error": reason})
		return
	}

	if from.Before(now) {
		from = now
	}
	exp := from.Add(ttl).Truncate(time.Second)
	if room == "" {
		var err error
		if room, err = s.newRoom(exp); err != nil {
			writeJSON(w, 500, map[string]string{"error": "internal"})
			return
		}
		s.reserved.Add(1)
	} else {
		if exp.After(limit) {
			exp = limit
		}
		s.extended.Add(1)
	}
	host, err1 := s.token(room, "host", true, now, exp)
	speaker, err2 := s.token(room, "speaker", false, now, exp)
	if err1 != nil || err2 != nil {
		writeJSON(w, 500, map[string]string{"error": "internal"})
		return
	}
	s.mu.Lock()
	s.active[room] = exp
	s.mu.Unlock()

	nameExp, _ := s.parseRoom(room)
	res := s.links(room, host, speaker, exp, nameExp)
	res["extended"] = req.Extend != ""
	writeJSON(w, 200, res)
}

func (s *server) links(room, host, speaker string, exp, nameExp time.Time) map[string]any {
	base := s.cfg.publicURL + "/" + room
	return map[string]any{
		"room":             room,
		"expires":          exp.UTC().Format(time.RFC3339),
		"extendable_until": nameExp.Add(s.cfg.maxExtension).UTC().Format(time.RFC3339),
		"host_url":         base + "?jwt=" + host,
		"speaker_url":      base + "?jwt=" + speaker,
		"guest_url":        base,
		"manage_url":       s.cfg.publicURL + s.cfg.basePath + "/#m=" + host,
	}
}

// handleLinks re-derives all links of a room from its host token, so the
// manage link can show everything again. The speaker token is re-issued with
// the host token's expiry; no proof of work since it grants nothing new.
func (s *server) handleLinks(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		Host string `json:"host"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		writeJSON(w, 400, map[string]string{"error": "malformed"})
		return
	}
	room, exp, err := s.parseHostToken(req.Host)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	nameExp, err := s.parseRoom(room)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	tok := strings.TrimSpace(req.Host)
	for _, marker := range []string{"jwt=", "#m="} {
		if i := strings.Index(tok, marker); i >= 0 {
			tok = tok[i+len(marker):]
		}
	}
	if i := strings.IndexAny(tok, "&#"); i >= 0 {
		tok = tok[:i]
	}
	now := time.Now()
	iat := now
	if exp.Before(now) {
		iat = exp.Add(-time.Minute)
	}
	speaker, err := s.token(room, "speaker", false, iat, exp)
	if err != nil {
		writeJSON(w, 500, map[string]string{"error": "internal"})
		return
	}
	writeJSON(w, 200, s.links(room, tok, speaker, exp, nameExp))
}

func (s *server) handleMetrics(w http.ResponseWriter, r *http.Request) {
	now := time.Now()
	s.mu.Lock()
	active := 0
	for _, exp := range s.active {
		if now.Before(exp) {
			active++
		}
	}
	s.mu.Unlock()

	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP ffmuc_reserve_rooms_reserved_total Rooms reserved since start.\n# TYPE ffmuc_reserve_rooms_reserved_total counter\nffmuc_reserve_rooms_reserved_total %d\n", s.reserved.Load())
	fmt.Fprintf(w, "# HELP ffmuc_reserve_rooms_extended_total Room extensions since start.\n# TYPE ffmuc_reserve_rooms_extended_total counter\nffmuc_reserve_rooms_extended_total %d\n", s.extended.Load())
	fmt.Fprintf(w, "# HELP ffmuc_reserve_rooms_active Unexpired rooms reserved by this instance since start.\n# TYPE ffmuc_reserve_rooms_active gauge\nffmuc_reserve_rooms_active %d\n", active)
	fmt.Fprintf(w, "# HELP ffmuc_reserve_challenges_issued_total Proof-of-work challenges issued.\n# TYPE ffmuc_reserve_challenges_issued_total counter\nffmuc_reserve_challenges_issued_total %d\n", s.challenges.Load())
	fmt.Fprintf(w, "# HELP ffmuc_reserve_pow_rejected_total Rejected reservation attempts.\n# TYPE ffmuc_reserve_pow_rejected_total counter\n")
	s.rejMu.Lock()
	for _, reason := range []string{"malformed", "bad_mac", "expired", "insufficient", "replay", "bad_extend"} {
		fmt.Fprintf(w, "ffmuc_reserve_pow_rejected_total{reason=%q} %d\n", reason, s.rejected[reason])
	}
	s.rejMu.Unlock()
	fmt.Fprintf(w, "# HELP ffmuc_reserve_pow_difficulty_bits Required leading zero bits.\n# TYPE ffmuc_reserve_pow_difficulty_bits gauge\nffmuc_reserve_pow_difficulty_bits %d\n", s.cfg.difficulty)
	fmt.Fprintf(w, "# HELP ffmuc_reserve_info Signer info.\n# TYPE ffmuc_reserve_info gauge\nffmuc_reserve_info{key_id=\"%d\"} 1\n", s.cfg.keyID)
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "genkey" {
		pub, priv, _ := ed25519.GenerateKey(rand.Reader)
		fmt.Printf("private (RESERVE_PRIVATE_KEY): %s\npublic  (prosody):             %s\n",
			base64.StdEncoding.EncodeToString(priv.Seed()), base64.StdEncoding.EncodeToString(pub))
		return
	}
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	s := newServer(cfg)
	go s.gc()

	bp := cfg.basePath
	mux := http.NewServeMux()
	mux.HandleFunc(bp, s.handleIndex)
	mux.HandleFunc(bp+"/", s.handleIndex)
	mux.HandleFunc(bp+"/api/challenge", s.handleChallenge)
	mux.HandleFunc(bp+"/api/reserve", s.handleReserve)
	mux.HandleFunc(bp+"/api/links", s.handleLinks)
	mux.HandleFunc(bp+"/logo.png", staticPNG(logoPNG))
	mux.HandleFunc(bp+"/favicon.png", staticPNG(faviconPNG))
	mux.HandleFunc(bp+"/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })

	mmux := http.NewServeMux()
	mmux.HandleFunc("/metrics", s.handleMetrics)
	go func() {
		log.Fatal((&http.Server{Addr: cfg.metricsListen, Handler: mmux, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe())
	}()

	log.Printf("meet-reserve kid=%d difficulty=%d durations=%v listen=%s metrics=%s pub=%s",
		cfg.keyID, cfg.difficulty, cfg.durations, cfg.listen, cfg.metricsListen,
		base64.StdEncoding.EncodeToString(cfg.priv.Public().(ed25519.PublicKey)))
	srv := &http.Server{Addr: cfg.listen, Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
