package main

import (
	"cmp"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

// Records are replicated between all signers and merged as a CRDT, so every
// field only moves in one direction and any merge order gives the same result:
// Created min, Expires max, Gen max, Revoked earliest non-zero, Legacy sticky,
// secrets the union cut down to the maxSecrets newest (a deterministic top-k).
//
// Gen is the rotation generation: rotation counter in the high 32 bits, random
// tiebreak in the low ones. Only secrets and tokens of the current Gen count,
// so two concurrent rotations on different signers end with exactly one
// winner instead of two valid sets of links. Deleted rooms are tombstones that
// are never collected (only their secrets are), so a signer that missed the
// delete can't bring the room back later.
type secretEntry struct {
	Role string `json:"role"` // host or speaker
	Gen  uint64 `json:"gen,omitempty"`
}

type record struct {
	Room    string                  `json:"room"`
	Created int64                   `json:"created"`
	Expires int64                   `json:"expires"`
	Gen     uint64                  `json:"gen,omitempty"`
	Revoked int64                   `json:"revoked,omitempty"` // room deleted at
	Legacy  bool                    `json:"legacy,omitempty"`  // long signed v1 name
	Secrets map[string]*secretEntry `json:"secrets,omitempty"` // sha256 hex of the secret
	Updated int64                   `json:"updated"`           // local change time in ms, sync cursor only
}

// maxSecrets bounds the secret history: the current host and speaker secret
// plus a few replaced ones, so their links say "replaced" instead of "invalid".
const maxSecrets = 8

// current reports whether a secret of this room still works.
func (r *record) current(e *secretEntry) bool { return e != nil && e.Gen == r.Gen }

func (r *record) clone() *record {
	c := *r
	c.Secrets = make(map[string]*secretEntry, len(r.Secrets))
	for h, s := range r.Secrets {
		v := *s
		c.Secrets[h] = &v
	}
	return &c
}

// merge folds o into r and reports whether r changed.
func (r *record) merge(o *record) bool {
	changed := false
	if o.Created != 0 && (r.Created == 0 || o.Created < r.Created) {
		r.Created, changed = o.Created, true
	}
	if o.Expires > r.Expires {
		r.Expires, changed = o.Expires, true
	}
	if o.Gen > r.Gen {
		r.Gen, changed = o.Gen, true
	}
	if o.Revoked != 0 && (r.Revoked == 0 || o.Revoked < r.Revoked) {
		r.Revoked, changed = o.Revoked, true
	}
	if o.Legacy && !r.Legacy {
		r.Legacy, changed = true, true
	}
	if r.Secrets == nil {
		r.Secrets = map[string]*secretEntry{}
	}
	for h, s := range o.Secrets {
		cur, ok := r.Secrets[h]
		if !ok {
			r.Secrets[h] = &secretEntry{Role: s.Role, Gen: s.Gen}
			changed = true
		} else if s.Gen > cur.Gen {
			// a hash is one random secret, so this only repairs bad data
			cur.Gen, changed = s.Gen, true
		}
	}
	if r.prune() {
		changed = true
	}
	return changed
}

// prune keeps the maxSecrets entries with the highest Gen (hash as tiebreak).
func (r *record) prune() bool {
	if len(r.Secrets) <= maxSecrets {
		return false
	}
	hs := make([]string, 0, len(r.Secrets))
	for h := range r.Secrets {
		hs = append(hs, h)
	}
	slices.SortFunc(hs, func(a, b string) int {
		if c := cmp.Compare(r.Secrets[b].Gen, r.Secrets[a].Gen); c != 0 {
			return c
		}
		return cmp.Compare(a, b)
	})
	for _, h := range hs[maxSecrets:] {
		delete(r.Secrets, h)
	}
	return true
}

type store struct {
	path string

	mu      sync.RWMutex
	rooms   map[string]*record
	secrets map[string]string // secret hash -> room
	dirty   bool
	last    int64 // last Updated handed out, keeps the cursor strictly increasing

	onLocal func(*record) // called with a copy after every local change
}

type snapshot struct {
	Rooms []*record `json:"rooms"`
}

func newStore(dir string) *store {
	return &store{
		path:    filepath.Join(dir, "rooms.json"),
		rooms:   map[string]*record{},
		secrets: map[string]string{},
	}
}

func (s *store) load() error {
	b, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var snap snapshot
	if err := json.Unmarshal(b, &snap); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range snap.Rooms {
		if r.Room == "" {
			continue
		}
		if r.Secrets == nil {
			r.Secrets = map[string]*secretEntry{}
		}
		r.prune()
		s.rooms[r.Room] = r
		s.index(r, nil)
		if r.Updated > s.last {
			s.last = r.Updated
		}
	}
	return nil
}

// saveLocked writes an atomic snapshot. Caller holds s.mu.
func (s *store) saveLocked() error {
	snap := snapshot{Rooms: make([]*record, 0, len(s.rooms))}
	for _, r := range s.rooms {
		snap.Rooms = append(snap.Rooms, r)
	}
	b, err := json.Marshal(snap)
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err = f.Write(b); err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		return err
	}
	s.dirty = false
	return nil
}

// index maps the record's secrets to it and forgets pruned ones.
func (s *store) index(r *record, before []string) {
	for _, h := range before {
		if _, ok := r.Secrets[h]; !ok && s.secrets[h] == r.Room {
			delete(s.secrets, h)
		}
	}
	for h := range r.Secrets {
		s.secrets[h] = r.Room
	}
}

func secretHashes(r *record) []string {
	out := make([]string, 0, len(r.Secrets))
	for h := range r.Secrets {
		out = append(out, h)
	}
	return out
}

func (s *store) stamp() int64 {
	now := time.Now().UnixMilli()
	if now <= s.last {
		now = s.last + 1
	}
	s.last = now
	return now
}

func (s *store) get(room string) *record {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if r, ok := s.rooms[room]; ok {
		return r.clone()
	}
	return nil
}

// bySecret returns the room a secret belongs to plus the secret's entry.
func (s *store) bySecret(hash string) (*record, *secretEntry) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.rooms[s.secrets[hash]]
	if !ok {
		return nil, nil
	}
	if _, ok := r.Secrets[hash]; !ok {
		return nil, nil
	}
	r = r.clone()
	return r, r.Secrets[hash]
}

// update applies fn to a copy of the room's record (nil if unknown) under the
// store lock. The result is merged, persisted and pushed to the peers.
func (s *store) update(room string, fn func(r *record) (*record, error)) (*record, error) {
	s.mu.Lock()
	var cur *record
	if r, ok := s.rooms[room]; ok {
		cur = r.clone()
	}
	next, err := fn(cur)
	if err != nil {
		s.mu.Unlock()
		return nil, err
	}
	next.Room = room
	// Merge instead of replacing so a local change can never move a field
	// backwards, which peers would not accept anyway.
	stored, ok := s.rooms[room]
	if !ok {
		stored = &record{Room: room, Secrets: map[string]*secretEntry{}}
		s.rooms[room] = stored
	}
	before := secretHashes(stored)
	stored.merge(next)
	stored.Updated = s.stamp()
	s.index(stored, before)
	s.dirty = true
	if err := s.saveLocked(); err != nil {
		log.Printf("store: save failed: %v", err)
	}
	out := stored.clone()
	s.mu.Unlock()
	if s.onLocal != nil {
		s.onLocal(out.clone())
	}
	return out, nil
}

// mergeRemote folds records from a peer in and returns how many changed.
func (s *store) mergeRemote(recs []*record) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, o := range recs {
		if o == nil || o.Room == "" || !validRoomName(o.Room) {
			continue
		}
		cur, ok := s.rooms[o.Room]
		if !ok {
			cur = &record{Room: o.Room, Secrets: map[string]*secretEntry{}}
		}
		before := secretHashes(cur)
		if cur.merge(o) || !ok {
			cur.Updated = s.stamp()
			s.rooms[o.Room] = cur
			s.index(cur, before)
			n++
		}
	}
	if n > 0 {
		s.dirty = true
	}
	return n
}

// since returns copies of up to limit records changed locally after ms, oldest
// change first, and whether more are left. Updated is unique per store, so the
// last record's Updated is an exact cursor for the next page.
func (s *store) since(ms int64, limit int) ([]*record, bool) {
	s.mu.RLock()
	var out []*record
	for _, r := range s.rooms {
		if r.Updated > ms {
			out = append(out, r)
		}
	}
	slices.SortFunc(out, func(a, b *record) int { return cmp.Compare(a.Updated, b.Updated) })
	more := len(out) > limit
	if more {
		out = out[:limit]
	}
	for i, r := range out {
		out[i] = r.clone()
	}
	s.mu.RUnlock()
	return out, more
}

// gc drops records that ended more than keep ago and flushes pending merges.
// Deleted rooms stay as small tombstones without secrets, forever.
func (s *store) gc(now time.Time, keep time.Duration, legacyLimit func(*record) int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	cut := now.Add(-keep).Unix()
	for name, r := range s.rooms {
		end := max(r.Expires, r.Revoked, legacyLimit(r))
		if end >= cut {
			continue
		}
		for h := range r.Secrets {
			delete(s.secrets, h)
		}
		if r.Revoked != 0 {
			if len(r.Secrets) > 0 {
				r.Secrets = map[string]*secretEntry{}
				s.dirty = true
			}
			continue
		}
		delete(s.rooms, name)
		s.dirty = true
	}
	if s.dirty {
		if err := s.saveLocked(); err != nil {
			log.Printf("store: save failed: %v", err)
		}
	}
}

type roomStats struct{ total, active, legacy, revoked int }

func (s *store) stats(now int64, hard func(*record) int64) roomStats {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var st roomStats
	for _, r := range s.rooms {
		st.total++
		switch {
		case r.Revoked != 0:
			st.revoked++
		case hard(r) > now:
			st.active++
			if r.Legacy {
				st.legacy++
			}
		}
	}
	return st
}
