package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	syncAuthHeader = "X-Reserve-Auth"
	syncMaxSkew    = 2 * time.Minute
	syncOverlap    = 10 * time.Second // re-fetch a little, merging is idempotent
	syncInterval   = 30 * time.Second
	syncMaxBody    = 32 << 20
	syncMaxPages   = 200 // per peer and round, the rest follows next round
)

// syncPageSize is the number of records per sync response, far below
// syncMaxBody. A variable for tests.
var syncPageSize = 2000

// syncMAC authenticates peer and admin requests: HMAC over time, method, URI and body.
func syncMAC(key []byte, ts, method, uri string, body []byte) string {
	m := hmac.New(sha256.New, key)
	fmt.Fprintf(m, "%s\n%s\n%s\n", ts, method, uri)
	m.Write(body)
	return hex.EncodeToString(m.Sum(nil))
}

func signRequest(req *http.Request, key, body []byte) {
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	req.Header.Set(syncAuthHeader, ts+":"+syncMAC(key, ts, req.Method, req.URL.RequestURI(), body))
}

// verifySync reads the body and checks the request signature.
func verifySync(r *http.Request, key []byte) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, syncMaxBody))
	if err != nil {
		return nil, err
	}
	ts, mac, ok := strings.Cut(r.Header.Get(syncAuthHeader), ":")
	if !ok {
		return nil, errors.New("unsigned")
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return nil, errors.New("bad timestamp")
	}
	if d := time.Since(time.Unix(sec, 0)); d > syncMaxSkew || d < -syncMaxSkew {
		return nil, errors.New("stale request")
	}
	if !hmac.Equal([]byte(mac), []byte(syncMAC(key, ts, r.Method, r.URL.RequestURI(), body))) {
		return nil, errors.New("bad signature")
	}
	return body, nil
}

type peer struct {
	url      string
	cursor   int64 // peer clock in ms
	lastOK   atomic.Int64
	failures atomic.Uint64
}

type peerSet struct {
	key      []byte
	basePath string
	store    *store
	peers    []*peer
	client   *http.Client

	pullMu   sync.Mutex // one pull round at a time
	lastPull atomic.Int64
	pushed   atomic.Uint64
	merged   atomic.Uint64
}

func newPeerSet(urls []string, key []byte, basePath string, st *store) *peerSet {
	ps := &peerSet{key: key, basePath: basePath, store: st, client: &http.Client{Timeout: 5 * time.Second}}
	for _, u := range urls {
		ps.peers = append(ps.peers, &peer{url: strings.TrimRight(u, "/")})
	}
	return ps
}

type syncResponse struct {
	Now   int64     `json:"now"`
	Rooms []*record `json:"rooms"`
	More  bool      `json:"more,omitempty"` // page full, continue after the last record's Updated
}

func (ps *peerSet) pullOne(ctx context.Context, p *peer) error {
	for range syncMaxPages {
		more, err := ps.pullPage(ctx, p)
		if err != nil || !more {
			return err
		}
	}
	return nil
}

func (ps *peerSet) pullPage(ctx context.Context, p *peer) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("%s%s/_peer/sync?since=%d", p.url, ps.basePath, p.cursor), nil)
	if err != nil {
		return false, err
	}
	signRequest(req, ps.key, nil)
	resp, err := ps.client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	var sr syncResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, syncMaxBody)).Decode(&sr); err != nil {
		return false, err
	}
	if n := ps.store.mergeRemote(sr.Rooms); n > 0 {
		ps.merged.Add(uint64(n))
	}
	if sr.More && len(sr.Rooms) > 0 {
		p.cursor = sr.Rooms[len(sr.Rooms)-1].Updated
		return true, nil
	}
	// a peer clock (or peer) far ahead must not make us skip its later changes
	p.cursor = max(0, min(sr.Now, time.Now().UnixMilli())-syncOverlap.Milliseconds())
	return false, nil
}

// pullAll fetches changes from every peer in parallel.
func (ps *peerSet) pullAll(ctx context.Context) {
	ps.pullMu.Lock()
	defer ps.pullMu.Unlock()
	ps.pullLocked(ctx)
}

func (ps *peerSet) pullLocked(ctx context.Context) {
	var wg sync.WaitGroup
	for _, p := range ps.peers {
		wg.Add(1)
		go func(p *peer) {
			defer wg.Done()
			if err := ps.pullOne(ctx, p); err != nil {
				p.failures.Add(1)
				log.Printf("sync: pull from %s failed: %v", p.url, err)
				return
			}
			p.lastOK.Store(time.Now().Unix())
		}(p)
	}
	wg.Wait()
	ps.lastPull.Store(time.Now().UnixMilli())
}

// pullSoon is used when something is unknown locally, maybe because a push from
// the signer that created it got lost. Rate-limited, public requests trigger it.
func (ps *peerSet) pullSoon() {
	last, now := ps.lastPull.Load(), time.Now().UnixMilli()
	if len(ps.peers) == 0 || now-last < 2000 || !ps.lastPull.CompareAndSwap(last, now) {
		return
	}
	// a round already running brings the news anyway, don't hold the request
	if !ps.pullMu.TryLock() {
		return
	}
	defer ps.pullMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ps.pullLocked(ctx)
}

func (ps *peerSet) loop() {
	for range time.Tick(syncInterval) {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		ps.pullAll(ctx)
		cancel()
	}
}

// push sends a changed record to all peers, best effort: missed pushes are
// caught up by the next pull.
func (ps *peerSet) push(r *record) {
	body, err := json.Marshal(syncResponse{Now: time.Now().UnixMilli(), Rooms: []*record{r}})
	if err != nil {
		return
	}
	for _, p := range ps.peers {
		go func(p *peer) {
			req, err := http.NewRequest(http.MethodPost, p.url+ps.basePath+"/_peer/push", bytes.NewReader(body))
			if err != nil {
				return
			}
			req.Header.Set("Content-Type", "application/json")
			signRequest(req, ps.key, body)
			resp, err := ps.client.Do(req)
			if err != nil {
				p.failures.Add(1)
				log.Printf("sync: push to %s failed: %v", p.url, err)
				return
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				p.failures.Add(1)
				log.Printf("sync: push to %s failed: HTTP %d", p.url, resp.StatusCode)
				return
			}
			ps.pushed.Add(1)
		}(p)
	}
}

func (ps *peerSet) handleSync(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if _, err := verifySync(r, ps.key); err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	now := time.Now().UnixMilli()
	rooms, more := ps.store.since(since, syncPageSize)
	writeJSON(w, 200, syncResponse{Now: now, Rooms: rooms, More: more})
}

func (ps *peerSet) handlePush(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := verifySync(r, ps.key)
	if err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	var sr syncResponse
	if err := json.Unmarshal(body, &sr); err != nil {
		http.Error(w, "malformed", http.StatusBadRequest)
		return
	}
	if n := ps.store.mergeRemote(sr.Rooms); n > 0 {
		ps.merged.Add(uint64(n))
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
