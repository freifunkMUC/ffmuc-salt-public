package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

var testSeed = bytes.Repeat([]byte{7}, 32)

func testServer(t *testing.T, peers ...string) (*server, *http.ServeMux) {
	t.Helper()
	cfg := config{
		keyID:        1,
		priv:         ed25519.NewKeyFromSeed(testSeed),
		powKey:       bytes.Repeat([]byte{1}, 32),
		syncKey:      bytes.Repeat([]byte{2}, 32),
		deriveKey:    bytes.Repeat([]byte{4}, 32),
		peers:        peers,
		dataDir:      t.TempDir(),
		domain:       "meet.example",
		publicURL:    "https://meet.example",
		basePath:     "/reserve",
		durations:    []time.Duration{72 * time.Hour, 168 * time.Hour, 720 * time.Hour, 2160 * time.Hour},
		defaultDur:   72 * time.Hour,
		maxAhead:     2160 * time.Hour,
		linkTTL:      12 * time.Hour,
		legacyMaxExt: 720 * time.Hour,
		difficulty:   0,
	}
	st := newStore(cfg.dataDir)
	ps := newPeerSet(cfg.peers, cfg.syncKey, cfg.basePath, st)
	st.onLocal = ps.push
	s := &server{cfg: cfg, store: st, peers: ps, used: map[string]time.Time{}, rejected: map[string]uint64{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/reserve/api/reserve", s.handleReserve)
	mux.HandleFunc("/reserve/api/manage", s.handleManage)
	mux.HandleFunc("/reserve/api/extend", s.handleExtend)
	mux.HandleFunc("/reserve/api/rotate", s.handleRotate)
	mux.HandleFunc("/reserve/api/delete", s.handleDelete)
	mux.HandleFunc("/reserve/api/room/", s.handleRoom)
	mux.HandleFunc("/reserve/h/", s.handleJoin(roleHost))
	mux.HandleFunc("/reserve/s/", s.handleJoin(roleSpeaker))
	mux.HandleFunc("/reserve/_peer/sync", ps.handleSync)
	mux.HandleFunc("/reserve/_peer/push", ps.handlePush)
	mux.HandleFunc("/reserve/_admin/revoke", s.handleAdminRevoke)
	return s, mux
}

func call(t *testing.T, mux http.Handler, path string, body any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader
	method := http.MethodGet
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
		method = http.MethodPost
	} else {
		rd = bytes.NewReader(nil)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(method, path, rd))
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func (s *server) pow(t *testing.T) (string, string) {
	t.Helper()
	return s.newChallenge(time.Now()), "x"
}

func reserve(t *testing.T, s *server, mux http.Handler, hours int) map[string]any {
	t.Helper()
	c, n := s.pow(t)
	code, out := call(t, mux, "/reserve/api/reserve", map[string]any{"challenge": c, "nonce": n, "hours": hours})
	if code != 200 {
		t.Fatalf("reserve: %d %v", code, out)
	}
	return out
}

func secretOf(u string) string { return u[strings.LastIndex(u, "/")+1:] }

func join(t *testing.T, mux http.Handler, link string) *url.URL {
	t.Helper()
	u, _ := url.Parse(link)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, u.Path, nil))
	if rec.Code != http.StatusFound {
		t.Fatalf("join %s: %d", u.Path, rec.Code)
	}
	loc, _ := url.Parse(rec.Header().Get("Location"))
	return loc
}

func claims(t *testing.T, tok string) map[string]any {
	t.Helper()
	p := strings.Split(tok, ".")
	b, _ := base64.RawURLEncoding.DecodeString(p[1])
	var c map[string]any
	json.Unmarshal(b, &c)
	return c
}

func TestRecordMergeCommutes(t *testing.T) {
	a := &record{Room: "r-x", Created: 10, Expires: 100, Secrets: map[string]*secretEntry{"h1": {Role: "host"}}}
	b := &record{Room: "r-x", Created: 5, Expires: 90, Gen: 1 << 32, Secrets: map[string]*secretEntry{"h1": {Role: "host"}, "h2": {Role: "host", Gen: 1 << 32}}}
	c := &record{Room: "r-x", Revoked: 70, Legacy: true}
	orders := [][]*record{{a, b, c}, {c, b, a}, {b, c, a}, {a, c, b}}
	var want []byte
	for i, o := range orders {
		r := &record{Room: "r-x"}
		for _, x := range o {
			r.merge(x.clone())
			r.merge(x.clone()) // idempotent
		}
		got, _ := json.Marshal(r)
		if i == 0 {
			want = got
		} else if !bytes.Equal(got, want) {
			t.Fatalf("order %d: %s != %s", i, got, want)
		}
	}
	var r record
	json.Unmarshal(want, &r)
	if r.Created != 5 || r.Expires != 100 || r.Gen != 1<<32 || r.Revoked != 70 || !r.Legacy || r.current(r.Secrets["h1"]) || !r.current(r.Secrets["h2"]) || len(r.Secrets) != 2 {
		t.Fatalf("merged: %s", want)
	}
}

func TestRoomNames(t *testing.T) {
	for range 100 {
		n, err := newRoomName()
		if err != nil || !isShortName(n) || isLegacyName(n) {
			t.Fatalf("bad name %q", n)
		}
		for _, v := range "aeiou01l" {
			if strings.ContainsRune(n[2:], v) {
				t.Fatalf("name %q contains %q", n, v)
			}
		}
	}
	for _, bad := range []string{"r-", "r-bcdfghjkmnpqra", "R-BCDFGHJKMNPQRS", "x-bcdfghjkmnpqrs", "r-bcdfghjkmnpqr/"} {
		if validRoomName(bad) {
			t.Fatalf("%q accepted", bad)
		}
	}
}

func TestLifecycle(t *testing.T) {
	s, mux := testServer(t)
	out := reserve(t, s, mux, 72)
	room := out["room"].(string)
	host := secretOf(out["host_url"].(string))
	speaker := secretOf(out["speaker_url"].(string))
	if !isShortName(room) || out["guest_url"] != "https://meet.example/"+room {
		t.Fatalf("view: %v", out)
	}
	if host == speaker || s.speakerSecret(host) != speaker {
		t.Fatal("speaker secret not derived from host")
	}
	stored, _ := json.Marshal(s.store.get(room))
	if bytes.Contains(stored, []byte(host)) || bytes.Contains(stored, []byte(speaker)) {
		t.Fatal("plain secret stored")
	}

	// short links -> fresh token with the right role
	loc := join(t, mux, out["host_url"].(string))
	if loc.Path != "/"+room {
		t.Fatalf("redirect %v", loc)
	}
	c := claims(t, loc.Query().Get("jwt"))
	if c["moderator"] != true || c["room"] != room || c["context"].(map[string]any)["user"].(map[string]any)["id"] != "host:"+room {
		t.Fatalf("host claims %v", c)
	}
	if exp := int64(c["exp"].(float64)); exp > time.Now().Add(12*time.Hour+time.Minute).Unix() {
		t.Fatal("token outlives link TTL")
	}
	c = claims(t, join(t, mux, out["speaker_url"].(string)).Query().Get("jwt"))
	if c["moderator"] != false || c["context"].(map[string]any)["user"].(map[string]any)["id"] != "speaker:"+room {
		t.Fatalf("speaker claims %v", c)
	}
	// a speaker secret on the host path must not work
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/reserve/h/"+speaker, nil))
	if !strings.Contains(rec.Header().Get("Location"), "#gone=invalid") {
		t.Fatalf("speaker as host: %v", rec.Header())
	}

	// manage accepts any form of the host link, never the speaker link
	for _, k := range []string{host, out["manage_url"].(string), out["host_url"].(string)} {
		if code, m := call(t, mux, "/reserve/api/manage", map[string]any{"key": k}); code != 200 || m["room"] != room {
			t.Fatalf("manage %q: %d %v", k, code, m)
		}
	}
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": speaker}); code != 404 {
		t.Fatalf("speaker could manage: %d", code)
	}

	// rolling extension, capped at now + 90 days
	exp0 := s.store.get(room).Expires
	ch, n := s.pow(t)
	if code, m := call(t, mux, "/reserve/api/extend", map[string]any{"key": host, "challenge": ch, "nonce": n, "hours": 720}); code != 200 {
		t.Fatalf("extend: %d %v", code, m)
	}
	if got := s.store.get(room).Expires; got != exp0+720*3600 {
		t.Fatalf("extend: %d want %d", got, exp0+720*3600)
	}
	for range 3 {
		ch, n = s.pow(t)
		call(t, mux, "/reserve/api/extend", map[string]any{"key": host, "challenge": ch, "nonce": n, "hours": 2160})
	}
	if got, cap := s.store.get(room).Expires, time.Now().Add(2160*time.Hour).Unix(); got > cap || got < cap-5 {
		t.Fatalf("not capped: %d vs %d", got, cap)
	}
	ch, n = s.pow(t)
	if code, _ := call(t, mux, "/reserve/api/extend", map[string]any{"key": host, "challenge": ch, "nonce": n, "hours": 5}); code != 400 {
		t.Fatalf("odd duration accepted: %d", code)
	}
	ch, n = s.pow(t)
	call(t, mux, "/reserve/api/extend", map[string]any{"key": host, "challenge": ch, "nonce": n, "hours": 72})
	if code, _ := call(t, mux, "/reserve/api/extend", map[string]any{"key": host, "challenge": ch, "nonce": n, "hours": 72}); code != 403 {
		t.Fatalf("challenge replay accepted: %d", code)
	}

	// rotate: old links die, room and guest link stay, old tokens are void
	code, rot := call(t, mux, "/reserve/api/rotate", map[string]any{"key": host})
	if code != 200 || rot["room"] != room || rot["host_url"] == out["host_url"] {
		t.Fatalf("rotate: %d %v", code, rot)
	}
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": host}); code != 410 {
		t.Fatalf("old host key after rotate: %d", code)
	}
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/reserve/s/"+speaker, nil))
	if !strings.Contains(rec.Header().Get("Location"), "#gone=replaced") {
		t.Fatalf("old speaker after rotate: %v", rec.Header())
	}
	gen := genClaim(s.store.get(room).Gen)
	if gen == "0" || gen == c["gen"] {
		t.Fatalf("rotation kept gen %s", gen)
	}
	c = claims(t, join(t, mux, rot["host_url"].(string)).Query().Get("jwt"))
	if c["gen"] != gen {
		t.Fatalf("token gen %v, room gen %s", c["gen"], gen)
	}
	_, info := call(t, mux, "/reserve/api/room/"+room, nil)
	if info["status"] != "active" || info["gen"] != gen {
		t.Fatalf("lookup: %v", info)
	}

	// delete
	newHost := secretOf(rot["host_url"].(string))
	if code, _ := call(t, mux, "/reserve/api/delete", map[string]any{"key": newHost}); code != 200 {
		t.Fatalf("delete: %d", code)
	}
	if _, info := call(t, mux, "/reserve/api/room/"+room, nil); info["status"] != "deleted" {
		t.Fatalf("after delete: %v", info)
	}
	ch, n = s.pow(t)
	if code, _ := call(t, mux, "/reserve/api/extend", map[string]any{"key": newHost, "challenge": ch, "nonce": n, "hours": 72}); code != 410 {
		t.Fatalf("extend deleted room: %d", code)
	}
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/reserve/h/"+newHost, nil))
	if !strings.Contains(rec.Header().Get("Location"), "#gone=deleted") {
		t.Fatalf("join deleted: %v", rec.Header())
	}

	// persisted
	st := newStore(s.cfg.dataDir)
	if err := st.load(); err != nil || st.get(room) == nil || st.get(room).Revoked == 0 {
		t.Fatalf("reload: %v %v", err, st.get(room))
	}
}

func TestExpiredCannotBeExtended(t *testing.T) {
	s, mux := testServer(t)
	out := reserve(t, s, mux, 72)
	room := out["room"].(string)
	s.store.mu.Lock()
	s.store.rooms[room].Expires = time.Now().Unix() - 1
	s.store.mu.Unlock()
	ch, n := s.pow(t)
	if code, _ := call(t, mux, "/reserve/api/extend", map[string]any{"key": secretOf(out["host_url"].(string)), "challenge": ch, "nonce": n, "hours": 72}); code != 410 {
		t.Fatalf("extended expired room: %d", code)
	}
	if _, info := call(t, mux, "/reserve/api/room/"+room, nil); info["status"] != "expired" {
		t.Fatalf("lookup: %v", info)
	}
}

// v1 helpers, same format as the old stateless signer
func legacyRoom(s *server, exp time.Time) string {
	raw := make([]byte, 15)
	raw[0], raw[1] = legacyVersion, s.cfg.keyID
	binary.BigEndian.PutUint32(raw[3:7], uint32(exp.Unix()))
	rand.Read(raw[7:])
	sig := ed25519.Sign(s.cfg.priv, append([]byte(legacyContext), raw...))
	return roomPrefix + strings.ToLower(b32.EncodeToString(append(raw, sig...)))
}

func TestLegacyMigration(t *testing.T) {
	s, mux := testServer(t)
	now := time.Now()
	room := legacyRoom(s, now.Add(72*time.Hour))
	if !isLegacyName(room) {
		t.Fatal("legacy name not recognised")
	}
	if _, info := call(t, mux, "/reserve/api/room/"+room, nil); info["status"] != "legacy" {
		t.Fatalf("lookup before migration: %v", info)
	}
	tok, _ := s.token(room, roleHost, 0, now.Add(-time.Hour), now.Add(72*time.Hour))
	spk, _ := s.token(room, roleSpeaker, 0, now.Add(-time.Hour), now.Add(72*time.Hour))
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": "https://meet.example/" + room + "?jwt=" + spk}); code != 400 {
		t.Fatalf("v1 speaker link could manage: %d", code)
	}

	code, out := call(t, mux, "/reserve/api/manage", map[string]any{"key": "https://meet.example/reserve/#m=" + tok})
	if code != 200 || out["room"] != room || out["migrated"] != true {
		t.Fatalf("migrate: %d %v", code, out)
	}
	_, again := call(t, mux, "/reserve/api/manage", map[string]any{"key": "https://meet.example/" + room + "?jwt=" + tok})
	if again["host_url"] != out["host_url"] || again["migrated"] != false {
		t.Fatalf("second use gave different links: %v", again)
	}
	if _, info := call(t, mux, "/reserve/api/room/"+room, nil); info["status"] != "active" {
		t.Fatalf("lookup after migration: %v", info)
	}
	// new short links work for the old room, and the room can be extended
	if loc := join(t, mux, out["host_url"].(string)); loc.Path != "/"+room {
		t.Fatalf("redirect %v", loc)
	}
	ch, n := s.pow(t)
	if code, _ := call(t, mux, "/reserve/api/extend", map[string]any{"key": tok, "challenge": ch, "nonce": n, "hours": 2160}); code != 200 {
		t.Fatalf("extend migrated: %d", code)
	}
	// rotation voids the old v1 manage link
	call(t, mux, "/reserve/api/rotate", map[string]any{"key": tok})
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": tok}); code != 410 {
		t.Fatalf("v1 link after rotate: %d", code)
	}

	// a newer v1 link raises the expiry of an already migrated room
	room2 := legacyRoom(s, now.Add(24*time.Hour))
	old, _ := s.token(room2, roleHost, 0, now.Add(-2*time.Hour), now.Add(24*time.Hour))
	newer, _ := s.token(room2, roleHost, 0, now.Add(-time.Hour), now.Add(240*time.Hour))
	call(t, mux, "/reserve/api/manage", map[string]any{"key": old})
	call(t, mux, "/reserve/api/manage", map[string]any{"key": newer})
	if got := s.store.get(room2).Expires; got != now.Add(240*time.Hour).Unix() {
		t.Fatalf("expiry not raised: %d", got)
	}

	// expired v1 rooms are not imported, forged ones never
	dead := legacyRoom(s, now.Add(-800*time.Hour))
	deadTok, _ := s.token(dead, roleHost, 0, now.Add(-900*time.Hour), now.Add(-800*time.Hour))
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": deadTok}); code != 410 {
		t.Fatalf("expired v1 room imported: %d", code)
	}
	other := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{9}, 32))
	forged := &server{cfg: s.cfg}
	forged.cfg.priv = other
	fTok, _ := forged.token(room, roleHost, 0, now, now.Add(time.Hour))
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": fTok}); code != 400 {
		t.Fatalf("forged token accepted: %d", code)
	}
}

func TestAdminRevokeLegacyTombstone(t *testing.T) {
	s, mux := testServer(t)
	room := legacyRoom(s, time.Now().Add(72*time.Hour))
	body, _ := json.Marshal(map[string]string{"room": room})
	req := httptest.NewRequest(http.MethodPost, "/reserve/_admin/revoke", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != 403 {
		t.Fatalf("unsigned admin revoke: %d", rec.Code)
	}
	req = httptest.NewRequest(http.MethodPost, "/reserve/_admin/revoke", bytes.NewReader(body))
	signRequest(req, s.cfg.syncKey, body)
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("admin revoke: %d %s", rec.Code, rec.Body)
	}
	if _, info := call(t, mux, "/reserve/api/room/"+room, nil); info["status"] != "deleted" {
		t.Fatalf("lookup: %v", info)
	}
	tok, _ := s.token(room, roleHost, 0, time.Now(), time.Now().Add(time.Hour))
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": tok}); code != 410 {
		t.Fatalf("manage revoked v1: %d", code)
	}
	// the tombstone outlives the v1 window, so gc must keep it
	s.store.gc(time.Now().Add(31*24*time.Hour), gcKeep, s.legacyLimit)
	if s.store.get(room) == nil {
		t.Fatal("tombstone collected too early")
	}
}

// mesh starts n signers that all peer with each other, like docker04 to 07.
func mesh(t *testing.T, n int) ([]*server, []*http.ServeMux) {
	t.Helper()
	ss := make([]*server, n)
	muxes := make([]*http.ServeMux, n)
	urls := make([]string, n)
	for i := range n {
		ss[i], muxes[i] = testServer(t)
		srv := httptest.NewServer(muxes[i])
		t.Cleanup(srv.Close)
		urls[i] = srv.URL
	}
	for i, s := range ss {
		var others []string
		for j, u := range urls {
			if j != i {
				others = append(others, u)
			}
		}
		s.peers = newPeerSet(others, s.cfg.syncKey, "/reserve", s.store)
		s.store.onLocal = s.peers.push
	}
	return ss, muxes
}

func pullEverywhere(ss []*server) {
	for _, s := range ss {
		s.peers.lastPull.Store(0)
		s.peers.pullAll(context.Background())
	}
}

func assertConverged(t *testing.T, ss []*server, room string) *record {
	t.Helper()
	var want []byte
	for i, s := range ss {
		r := s.store.get(room)
		if r == nil {
			t.Fatalf("signer %d misses %s", i, room)
		}
		got, _ := json.Marshal(clearUpdated(r))
		if i == 0 {
			want = got
		} else if !bytes.Equal(got, want) {
			t.Fatalf("signer %d diverged:\n%s\n%s", i, got, want)
		}
	}
	return ss[0].store.get(room)
}

func TestPeerSync(t *testing.T) {
	ss, muxes := mesh(t, 4)

	// created on one signer, pushed to all three others
	out := reserve(t, ss[0], muxes[0], 168)
	room := out["room"].(string)
	host := secretOf(out["host_url"].(string))
	waitFor(t, func() bool {
		for _, s := range ss {
			if s.store.get(room) == nil {
				return false
			}
		}
		return true
	})
	// every signer serves the links (haproxy may send the user anywhere)
	for i, mux := range muxes {
		if loc := join(t, mux, out["host_url"].(string)); loc.Path != "/"+room {
			t.Fatalf("signer %d redirect %v", i, loc)
		}
	}

	// concurrent changes on different signers, with pushes lost, converge via pulls
	for _, s := range ss {
		s.store.onLocal = nil
	}
	ch, n := ss[1].pow(t)
	if code, m := call(t, muxes[1], "/reserve/api/extend", map[string]any{"key": host, "challenge": ch, "nonce": n, "hours": 720}); code != 200 {
		t.Fatalf("extend on 1: %d %v", code, m)
	}
	ch, n = ss[2].pow(t)
	if code, m := call(t, muxes[2], "/reserve/api/extend", map[string]any{"key": host, "challenge": ch, "nonce": n, "hours": 168}); code != 200 {
		t.Fatalf("extend on 2: %d %v", code, m)
	}
	code, rot := call(t, muxes[3], "/reserve/api/rotate", map[string]any{"key": host})
	if code != 200 {
		t.Fatalf("rotate on 3: %d %v", code, rot)
	}
	pullEverywhere(ss)
	r := assertConverged(t, ss, room)
	if r.Gen == 0 || r.Expires <= time.Now().Add(168*time.Hour+720*time.Hour-time.Minute).Unix() {
		t.Fatalf("lost a change: %+v", r)
	}
	// the rotated links work everywhere, the old ones nowhere
	for i, mux := range muxes {
		if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": host}); code != 410 {
			t.Fatalf("signer %d still accepts old link: %d", i, code)
		}
		if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": rot["manage_url"]}); code != 200 {
			t.Fatalf("signer %d rejects new link: %d", i, code)
		}
	}

	// delete on one signer while another extends: deletion wins everywhere
	newHost := secretOf(rot["host_url"].(string))
	call(t, muxes[0], "/reserve/api/delete", map[string]any{"key": newHost})
	ch, n = ss[3].pow(t)
	call(t, muxes[3], "/reserve/api/extend", map[string]any{"key": newHost, "challenge": ch, "nonce": n, "hours": 2160})
	pullEverywhere(ss)
	assertConverged(t, ss, room)
	for i, mux := range muxes {
		if _, info := call(t, mux, "/reserve/api/room/"+room, nil); info["status"] != "deleted" {
			t.Fatalf("signer %d: %v", i, info)
		}
	}

	// a signer that was down catches up after restarting from its snapshot
	down := ss[3]
	down.store.gc(time.Now(), gcKeep, down.legacyLimit) // flush merged records to disk
	for i := range 6 {
		reserve(t, ss[i%3], muxes[i%3], 72)
	}
	restarted := newStore(down.cfg.dataDir)
	if err := restarted.load(); err != nil {
		t.Fatal(err)
	}
	if restarted.get(room) == nil {
		t.Fatal("snapshot lost merged room")
	}
	down.store = restarted
	down.peers = newPeerSet(urlsOf(down.peers), down.cfg.syncKey, "/reserve", restarted)
	down.peers.pullAll(context.Background())
	if n := len(restarted.rooms); n != 7 {
		t.Fatalf("restarted signer has %d rooms, want 7", n)
	}
	pullEverywhere(ss)
	for i, s := range ss {
		if n := len(s.store.rooms); n != 7 {
			t.Fatalf("signer %d has %d rooms, want 7", i, n)
		}
	}

	// pull on miss: a room unknown locally is fetched on demand
	out2 := reserve(t, ss[2], muxes[2], 72)
	ss[0].peers.lastPull.Store(0)
	if code, m := call(t, muxes[0], "/reserve/api/manage", map[string]any{"key": secretOf(out2["host_url"].(string))}); code != 200 {
		t.Fatalf("pull on miss: %d %v", code, m)
	}

	// one peer down: the others still sync, and the failure is counted
	dead := ss[0].peers.peers[0]
	dead.url = "http://127.0.0.1:1"
	pullEverywhere(ss[:1])
	if dead.failures.Load() == 0 {
		t.Fatal("dead peer not counted")
	}

	// wrong key is refused
	bad := newPeerSet([]string{ss[1].peers.peers[0].url}, bytes.Repeat([]byte{3}, 32), "/reserve", newStore(t.TempDir()))
	if err := bad.pullOne(context.Background(), bad.peers[0]); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("bad key pull: %v", err)
	}
}

func urlsOf(ps *peerSet) []string {
	var out []string
	for _, p := range ps.peers {
		out = append(out, p.url)
	}
	return out
}

func clearUpdated(r *record) *record { r.Updated = 0; return r }

func waitFor(t *testing.T, f func() bool) {
	t.Helper()
	for range 100 {
		if f() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("timeout")
}

func TestSyncSignatureBindsRequest(t *testing.T) {
	key := bytes.Repeat([]byte{2}, 32)
	body := []byte(`{"room":"r-x"}`)
	req := httptest.NewRequest(http.MethodPost, "/reserve/_admin/revoke", bytes.NewReader(body))
	signRequest(req, key, body)
	h := req.Header.Get(syncAuthHeader)
	for name, r := range map[string]*http.Request{
		"body":   httptest.NewRequest(http.MethodPost, "/reserve/_admin/revoke", strings.NewReader(`{"room":"r-y"}`)),
		"path":   httptest.NewRequest(http.MethodPost, "/reserve/_peer/push", bytes.NewReader(body)),
		"method": httptest.NewRequest(http.MethodPut, "/reserve/_admin/revoke", bytes.NewReader(body)),
	} {
		r.Header.Set(syncAuthHeader, h)
		if _, err := verifySync(r, key); err == nil {
			t.Fatalf("%s change accepted", name)
		}
	}
	old := httptest.NewRequest(http.MethodPost, "/reserve/_admin/revoke", bytes.NewReader(body))
	ts := "1000"
	old.Header.Set(syncAuthHeader, ts+":"+syncMAC(key, ts, http.MethodPost, "/reserve/_admin/revoke", body))
	if _, err := verifySync(old, key); err == nil {
		t.Fatal("stale request accepted")
	}
}

func TestConcurrentRotationsOneWinner(t *testing.T) {
	ss, muxes := mesh(t, 4)
	for _, s := range ss {
		s.store.onLocal = nil
	}
	out := reserve(t, ss[0], muxes[0], 168)
	room, host := out["room"].(string), secretOf(out["host_url"].(string))
	pullEverywhere(ss)
	// all four signers rotate with the same host link before they hear of each other
	var rots []map[string]any
	for i, mux := range muxes {
		code, rot := call(t, mux, "/reserve/api/rotate", map[string]any{"key": host})
		if code != 200 {
			t.Fatalf("rotate on %d: %d %v", i, code, rot)
		}
		rots = append(rots, rot)
	}
	pullEverywhere(ss)
	r := assertConverged(t, ss, room)
	winners := 0
	for _, rot := range rots {
		ok := 0
		for _, mux := range muxes {
			if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": rot["manage_url"]}); code == 200 {
				ok++
			}
		}
		switch ok {
		case len(muxes):
			winners++
		case 0:
		default:
			t.Fatalf("rotation valid on %d of %d signers", ok, len(muxes))
		}
	}
	if winners != 1 {
		t.Fatalf("%d rotations survived, want 1", winners)
	}
	if r.Gen>>32 != 1 {
		t.Fatalf("gen %x", r.Gen)
	}
}

func TestSecretsBounded(t *testing.T) {
	s, mux := testServer(t)
	out := reserve(t, s, mux, 72)
	host := secretOf(out["host_url"].(string))
	first := host
	for range 20 {
		_, rot := call(t, mux, "/reserve/api/rotate", map[string]any{"key": host})
		host = secretOf(rot["host_url"].(string))
	}
	r := s.store.get(out["room"].(string))
	if len(r.Secrets) != maxSecrets || len(s.store.secrets) != maxSecrets {
		t.Fatalf("secrets %d, index %d", len(r.Secrets), len(s.store.secrets))
	}
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": host}); code != 200 {
		t.Fatalf("current link: %d", code)
	}
	// a pruned link is unknown, a recent one replaced
	if code, _ := call(t, mux, "/reserve/api/manage", map[string]any{"key": first}); code != 404 {
		t.Fatalf("pruned link: %d", code)
	}
}

func TestTombstoneSurvivesGC(t *testing.T) {
	ss, muxes := mesh(t, 4)
	for _, s := range ss {
		s.store.onLocal = nil
	}
	out := reserve(t, ss[0], muxes[0], 72)
	room, host := out["room"].(string), secretOf(out["host_url"].(string))
	pullEverywhere(ss)
	// signer 3 is partitioned and misses the delete
	stale := ss[3].store.get(room)
	call(t, muxes[0], "/reserve/api/delete", map[string]any{"key": host})
	for _, s := range ss[:3] {
		s.peers.pullAll(context.Background())
	}
	later := time.Now().Add(gcKeep + 200*24*time.Hour)
	for _, s := range ss[:3] {
		s.store.gc(later, gcKeep, s.legacyLimit)
		r := s.store.get(room)
		if r == nil || r.Revoked == 0 || len(r.Secrets) != 0 {
			t.Fatalf("tombstone: %+v", r)
		}
	}
	// signer 3 comes back with its old copy; the room stays deleted everywhere
	ss[0].store.mergeRemote([]*record{stale})
	pullEverywhere(ss)
	for i, s := range ss {
		s.store.gc(later, gcKeep, s.legacyLimit)
		if r := s.store.get(room); r == nil || r.Revoked == 0 {
			t.Fatalf("signer %d resurrected %s: %+v", i, room, r)
		}
		if _, info := call(t, muxes[i], "/reserve/api/room/"+room, nil); info["status"] != "deleted" {
			t.Fatalf("signer %d: %v", i, info)
		}
	}
	// expired rooms that were never deleted are still collected
	out2 := reserve(t, ss[0], muxes[0], 72)
	ss[0].store.gc(later, gcKeep, ss[0].legacyLimit)
	if ss[0].store.get(out2["room"].(string)) != nil {
		t.Fatal("expired room kept")
	}
}

func TestSyncPagination(t *testing.T) {
	old := syncPageSize
	syncPageSize = 3
	defer func() { syncPageSize = old }()
	ss, muxes := mesh(t, 4)
	for _, s := range ss {
		s.store.onLocal = nil
	}
	for i := range 20 {
		reserve(t, ss[i%4], muxes[i%4], 72)
	}
	pullEverywhere(ss)
	for i, s := range ss {
		if n := len(s.store.rooms); n != 20 {
			t.Fatalf("signer %d has %d rooms, want 20", i, n)
		}
	}
	page, more := ss[0].store.since(0, 3)
	if len(page) != 3 || !more || page[0].Updated >= page[1].Updated {
		t.Fatalf("page %d more %v", len(page), more)
	}
}

func TestSyncKeyRotationKeepsLinks(t *testing.T) {
	a, _ := testServer(t)
	b, _ := testServer(t)
	b.cfg.syncKey = bytes.Repeat([]byte{9}, 32)
	if a.speakerSecret("x") != b.speakerSecret("x") || a.legacyHostSecret("r-y") != b.legacyHostSecret("r-y") {
		t.Fatal("derived secrets depend on the sync key")
	}
}
