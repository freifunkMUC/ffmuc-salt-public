-- FFMUC reserved viewers-only rooms.
--
-- meet-reserve hands out "r-" rooms and EdDSA tokens (host/speaker). Prosody
-- verifies the tokens with the public keys and turns the room into a visitors
-- room where only the host and speakers join the main room.
--
-- Two room formats:
--  * short "r-" + 14 chars: a record replicated between the meet-reserve
--    signers decides whether the room is active, and which tokens count
--    (only those with the room's current rotation "gen"). Prosody asks
--    <lookup_url><room> and caches the answer for lookup_ttl. While
--    meet-reserve is unreachable the last answer is used for up to
--    lookup_grace, after that the room is refused.
--  * v1 "r-<base32(payload || ed25519 sig)>": the signed name carries the
--    expiry. Once migrated, the record overrides it; unmigrated rooms and
--    lookup failures fall back to the signature.
--
-- The lookup happens when a client asks jicofo for a conference (like
-- mod_reservations), only in that client's session, so jicofo never waits.
-- Rooms deleted by their host are closed within a sweep interval.
--
-- Load on the main VirtualHost (authentication = "token", allow_empty_token = true).
--
--   ffmuc_signed_rooms_public_keys = { ["1"] = "<base64 raw ed25519 public key>" }
--   ffmuc_signed_rooms_max_extension = 30 * 86400
--   ffmuc_signed_rooms_auto_promote_unsigned = true
--   ffmuc_signed_rooms_lookup_url = "https://meet.example/reserve/api/room/"
--   ffmuc_signed_rooms_lookup_ttl = 60
--   ffmuc_signed_rooms_lookup_grace = 600

local async = require "util.async";
local cache = require "util.cache";
local crypto = require "util.crypto";
local http = require "net.http";
local timer = require "util.timer";
local base64 = require "util.encodings".base64;
local json = require "util.json";
local jid_bare = require "util.jid".bare;
local jid_node = require "util.jid".node;
local jid_split = require "util.jid".split;
local st = require "util.stanza";

local util = module:require "util";
local process_host_module = util.process_host_module;
local is_healthcheck_room = util.is_healthcheck_room;

local ISSUER = "ffmuc-reserve";
local AUDIENCE = "jitsi";
local ROOM_PREFIX = "r-";
local ROOM_CONTEXT = "ffmuc-room-v1\0";
local PAYLOAD_LEN, SIG_LEN = 15, 64;
local SHORT_ALPHABET = "bcdfghjkmnpqrstvwxz23456789";
local SHORT_LEN = 14;
local LEGACY_LEN = 127; -- base32 of 15 + 64 bytes, unpadded
local FOCUS_NS = "http://jitsi.org/protocol/focus";
local SPKI_PREFIX = "\48\42\48\5\6\3\43\101\112\3\33\0";

local muc_domain = module:get_option_string("ffmuc_signed_rooms_muc",
    module:get_option_string("main_muc", "conference." .. module.host));
local focus_jid = module:get_option_string("ffmuc_signed_rooms_focus_jid", "focus@auth." .. module.host);
local max_extension = module:get_option_number("ffmuc_signed_rooms_max_extension", 30 * 86400);
local auto_promote_unsigned = module:get_option_boolean("ffmuc_signed_rooms_auto_promote_unsigned", true);
local clock_skew = module:get_option_number("ffmuc_signed_rooms_clock_skew", 60);
local focus_host = module:get_option_string("ffmuc_signed_rooms_focus_component", "focus." .. module.host);
local lookup_url = module:get_option_string("ffmuc_signed_rooms_lookup_url");
local lookup_ttl = module:get_option_number("ffmuc_signed_rooms_lookup_ttl", 60);
local lookup_grace = math.max(lookup_ttl, module:get_option_number("ffmuc_signed_rooms_lookup_grace", 600));
local lookup_timeout = module:get_option_number("ffmuc_signed_rooms_lookup_timeout", 3);
local sweep_interval = module:get_option_number("ffmuc_signed_rooms_sweep_interval", 60);

local measure_rooms = module:measure("rooms_created", "counter");
local measure_rejected_rooms = module:measure("rooms_rejected", "counter");
local measure_tokens = module:measure("tokens_accepted", "counter");
local measure_rejected_tokens = module:measure("tokens_rejected", "counter");
local measure_lookups = module:measure("lookups", "counter");
local measure_lookup_failures = module:measure("lookup_failures", "counter");
local measure_closed = module:measure("rooms_closed", "counter");

if not lookup_url then
    module:log("warn", "ffmuc_signed_rooms_lookup_url not set, short reserved rooms will be refused");
end

local keys, key_count = {}, 0;
for kid, b64 in pairs(module:get_option("ffmuc_signed_rooms_public_keys", {})) do
    local raw = base64.decode(b64);
    if not raw or #raw ~= 32 then
        module:log("error", "public key %s is not 32 raw bytes, ignoring", tostring(kid));
    else
        local pem = "-----BEGIN PUBLIC KEY-----\n" .. base64.encode(SPKI_PREFIX .. raw) .. "\n-----END PUBLIC KEY-----\n";
        local key, err = crypto.import_public_pem(pem);
        if key then
            keys[tostring(kid)] = key;
            key_count = key_count + 1;
        else
            module:log("error", "cannot import public key %s: %s", tostring(kid), tostring(err));
        end
    end
end
if key_count == 0 then
    module:log("warn", "no public keys configured, every signed room will be refused");
end

local B32 = "abcdefghijklmnopqrstuvwxyz234567";
local b32_map = {};
for i = 1, #B32 do b32_map[B32:byte(i)] = i - 1; end

local function b32_decode(s)
    local out, bits, value = {}, 0, 0;
    for i = 1, #s do
        local v = b32_map[s:byte(i)];
        if not v then return nil; end
        -- Arithmetic instead of bitwise ops: Prosody may run on Lua 5.2.
        value = value * 32 + v;
        bits = bits + 5;
        if bits >= 8 then
            bits = bits - 8;
            out[#out + 1] = string.char(math.floor(value / 2 ^ bits) % 256);
        end
        value = value % 2 ^ bits;
    end
    return table.concat(out);
end

local function b64url_decode(s)
    if type(s) ~= "string" or s:find("[^%w%-_]") then return nil; end
    s = s:gsub("-", "+"):gsub("_", "/");
    local pad = #s % 4;
    if pad == 1 then return nil; end
    if pad > 0 then s = s .. string.rep("=", 4 - pad); end
    return base64.decode(s);
end

local function is_signed_name(name)
    return type(name) == "string" and name:sub(1, #ROOM_PREFIX) == ROOM_PREFIX;
end

local function is_short_name(name)
    if not is_signed_name(name) or #name ~= #ROOM_PREFIX + SHORT_LEN then return false; end
    for i = #ROOM_PREFIX + 1, #name do
        if not SHORT_ALPHABET:find(name:sub(i, i), 1, true) then return false; end
    end
    return true;
end

-- Returns the name expiry (unix seconds) if the room name carries a valid signature.
local function parse_room(name)
    if not is_signed_name(name) then return nil, "not signed"; end
    local raw = b32_decode(name:sub(#ROOM_PREFIX + 1));
    if not raw or #raw ~= PAYLOAD_LEN + SIG_LEN or raw:byte(1) ~= 1 then return nil, "malformed"; end
    local key = keys[tostring(raw:byte(2))];
    if not key then return nil, "unknown key"; end
    local payload = raw:sub(1, PAYLOAD_LEN);
    if not crypto.ed25519_verify(key, ROOM_CONTEXT .. payload, raw:sub(PAYLOAD_LEN + 1)) then
        return nil, "bad signature";
    end
    local b1, b2, b3, b4 = payload:byte(4, 7);
    return ((b1 * 256 + b2) * 256 + b3) * 256 + b4;
end

-- room -> { status = "active"|"deleted"|"expired"|"legacy"|"unknown", expires, gen, at }
-- gen is the rotation generation as a hex string, "0" for never rotated rooms
-- and in v1 tokens, which carry no gen claim.
local states = cache.new(4096);

-- v1 rooms meet-reserve has a record for (migrated or deleted) -> end of their
-- v1 window. Kept outside the cache: once a room has a record, the signature
-- alone must never authorise it again, even when lookups fail. Only validly
-- signed v1 names get here, so the table stays small; the sweep prunes it.
local migrated = {};

-- whether meet-reserve has a record for the room (statuses legacy and unknown mean no)
local function has_record(state)
    return state.status ~= "legacy" and state.status ~= "unknown";
end

local function fetch_state(name, callback)
    local done = false;
    local function finish(state)
        if done then return; end
        done = true;
        if state then
            state.at = os.time();
            states:set(name, state);
            if has_record(state) and #name == #ROOM_PREFIX + LEGACY_LEN then
                local exp = parse_room(name);
                if exp then migrated[name] = exp + max_extension; end
            end
        else
            measure_lookup_failures(1);
        end
        callback(state);
    end
    measure_lookups(1);
    local req = http.request(lookup_url .. name, { method = "GET", headers = { Accept = "application/json" } },
        function(body, code)
            local data = code == 200 and json.decode(body or "");
            if type(data) == "table" and type(data.status) == "string" then
                finish({
                    status = data.status,
                    expires = tonumber(data.expires),
                    gen = type(data.gen) == "string" and data.gen or "0",
                });
            else
                module:log("warn", "room lookup for %s failed: %s", name, tostring(code));
                finish(nil);
            end
        end);
    timer.add_task(lookup_timeout, function()
        if done then return; end
        module:log("warn", "room lookup for %s timed out", name);
        if req and http.destroy_request then http.destroy_request(req); end
        finish(nil);
    end);
end

-- Cached state of a room. With may_wait it refreshes a stale entry, which
-- needs an async context and holds only the current session. On lookup
-- failure the last known state is used, but only for lookup_grace.
local function room_state(name, may_wait)
    local cached = states:get(name);
    local age = cached and os.time() - cached.at;
    if cached and age < lookup_ttl then return cached; end
    if cached and age >= lookup_grace then cached = nil; end
    if not lookup_url or not may_wait or not async.ready() then return cached; end
    local wait, done = async.waiter();
    local fresh;
    fetch_state(name, function(state) fresh = state; done(); end);
    wait();
    return fresh or cached;
end

local function claim_gen(claims)
    local g = claims.gen;
    if g == nil then return "0"; end
    return tostring(g);
end

-- Whether a room may exist. Returns ok, reason, state.
local function room_usable(name, may_wait)
    if is_short_name(name) then
        local state = room_state(name, may_wait);
        if not state then return false, "lookup failed"; end
        if state.status ~= "active" then return false, state.status, state; end
        if state.expires and state.expires < os.time() then return false, "expired", state; end
        return true, nil, state;
    end
    if #name ~= #ROOM_PREFIX + LEGACY_LEN then return false, "malformed"; end
    local exp, err = parse_room(name);
    if not exp then return false, err; end
    local state = room_state(name, may_wait);
    -- once migrated, the record decides alone, the signature no longer counts
    if state and has_record(state) then
        if state.status ~= "active" then return false, state.status, state; end
        if state.expires and state.expires < os.time() then return false, "expired", state; end
        return true, nil, state;
    end
    if not state and migrated[name] then return false, "lookup failed"; end
    if exp + max_extension < os.time() then return false, "expired"; end
    return true, nil, state;
end

-- Returns claims + role for a valid meet-reserve token, nil + reason for a
-- broken one, and false for tokens that are not ours.
local function verify_token(token)
    local h, c, s = token:match("^([^.]+)%.([^.]+)%.([^.]+)$");
    if not h then return false; end
    local header = json.decode(b64url_decode(h) or "");
    if type(header) ~= "table" or header.alg ~= "EdDSA" then return false; end
    local claims = json.decode(b64url_decode(c) or "");
    if type(claims) ~= "table" or claims.iss ~= ISSUER then return false; end

    local key = keys[tostring(header.kid)];
    if not key then return nil, "unknown key id"; end
    local sig = b64url_decode(s);
    if not sig or #sig ~= SIG_LEN or not crypto.ed25519_verify(key, h .. "." .. c, sig) then
        return nil, "bad signature";
    end

    local now = os.time();
    if claims.aud ~= AUDIENCE then return nil, "bad audience"; end
    if type(claims.exp) ~= "number" or claims.exp + clock_skew < now then return nil, "token expired"; end
    if type(claims.nbf) == "number" and claims.nbf - clock_skew > now then return nil, "token not yet valid"; end
    if claims.sub ~= module.host then return nil, "wrong domain"; end

    local room = claims.room;
    if type(room) ~= "string" then return nil, "no room"; end
    local ok, why, state = room_usable(room, true);
    if not ok then return nil, "room " .. tostring(why); end
    -- after a rotation only tokens of the new generation count
    if state and state.status == "active" and claim_gen(claims) ~= (state.gen or "0") then
        return nil, "token was replaced";
    end

    local user = type(claims.context) == "table" and claims.context.user;
    local id = type(user) == "table" and user.id;
    local role = type(id) == "string" and id:match("^(%a+):");
    if (role ~= "host" and role ~= "speaker") or id ~= role .. ":" .. room then
        return nil, "bad user claim";
    end
    if (role == "host") ~= (claims.moderator == true) then return nil, "bad role"; end
    return claims, role;
end

module:hook_global("pre-jitsi-authentication-fetch-key", function(session)
    if session.host ~= module.host or type(session.auth_token) ~= "string" or session.auth_token == "" then return; end
    local claims, role = verify_token(session.auth_token);
    -- Never fall through to the token util: with app_secret = "" it would accept
    -- HS256 tokens signed with an empty key and their forged context.user.id.
    if claims == false then role = "foreign token"; end
    if not claims then
        measure_rejected_tokens(1);
        module:log("info", "rejecting signed-room token: %s", role);
        return { res = false, error = "not-allowed", reason = role };
    end

    measure_tokens(1);
    session.jitsi_meet_room = claims.room;
    session.jitsi_meet_domain = claims.sub;
    session.jitsi_meet_auth_issuer = claims.iss;
    session.jitsi_meet_context_user = claims.context.user;
    session.ffmuc_signed = { room = claims.room, role = role, exp = claims.exp, gen = claim_gen(claims) };
    -- the token util only knows HS256 here; with allow_empty_token it now lets
    -- the session through, room binding comes from the "<role>:<room>" user id
    session.auth_token = nil;
end, 10);

-- Whether a signed session still counts: the room is usable and was not
-- rotated since the session authenticated. Without may_wait only the cache is
-- used, and a missing or too old entry counts as no.
local function session_valid(s, may_wait)
    if s.exp + clock_skew < os.time() then return false, "expired"; end
    local ok, why, state = room_usable(s.room, may_wait);
    if not ok then return false, why; end
    if state and state.status == "active" and state.gen ~= s.gen then return false, "replaced"; end
    return true;
end

local function is_host_of(session, room)
    local s = session and session.ffmuc_signed;
    return s and s.role == "host" and s.room == jid_node(room.jid) and session_valid(s, false) or false;
end

process_host_module(muc_domain, function(host_module, host)
    module:log("info", "signed rooms active on %s with %d key(s)", host, key_count);

    host_module:hook("muc-room-pre-create", function(event)
        local name = jid_node(event.room.jid);
        if not is_signed_name(name) then return; end
        -- no waiting here: this usually runs in jicofo's session, the
        -- conference request hook below has filled the cache
        local ok, why = room_usable(name, false);
        if ok then return; end
        measure_rejected_rooms(1);
        module:log("info", "refusing signed room %s: %s", name, why);
        event.origin.send(st.error_reply(event.stanza, "cancel", "not-allowed", "Invalid or expired room"));
        return true;
    end, 100);

    -- after room_metadata (-1) and visitors (-2) initialised the room
    host_module:hook("muc-room-created", function(event)
        local room = event.room;
        if is_healthcheck_room(room.jid) then return; end
        local name = jid_node(room.jid);
        if is_signed_name(name) then
            room._data.ffmuc_signed = true;
            room._data.moderators = { "host:" .. name };
            room._data.participants = { "host:" .. name, "speaker:" .. name };
            measure_rooms(1);
        elseif auto_promote_unsigned then
            room.jitsiMetadata = room.jitsiMetadata or {};
            room.jitsiMetadata.visitors = room.jitsiMetadata.visitors or {};
            room.jitsiMetadata.visitors.autoPromote = true;
        end
    end, -10);

    -- Recheck host and speaker sessions on every join, in the joining
    -- client's session: a rotation or deletion since login refuses them.
    host_module:hook("muc-occupant-pre-join", function(event)
        local s = event.origin and event.origin.ffmuc_signed;
        if not s or s.room ~= jid_node(event.room.jid) then return; end
        local ok, why = session_valid(s, true);
        if ok then return; end
        module:log("info", "refusing %s session in %s: %s", s.role, s.room, tostring(why));
        local text = why == "replaced" and "This link was replaced by new links."
            or why == "lookup failed" and "Room check failed, please try again in a minute."
            or "This room does not exist or has expired.";
        event.origin.send(st.error_reply(event.stanza, "cancel", "not-allowed", text));
        return true;
    end, 100);

    host_module:hook("muc-occupant-joined", function(event)
        local room, occupant = event.room, event.occupant;
        if not room._data.ffmuc_signed or not is_host_of(event.origin, room) then return; end
        if room:get_affiliation(occupant.bare_jid) ~= "owner" then
            room:set_affiliation(true, occupant.bare_jid, "owner");
        end
    end, -10);

    -- jicofo makes the first main-room member owner; in signed rooms jicofo may
    -- only promote hosts, human moderators can still promote anyone
    host_module:hook("muc-pre-set-affiliation", function(event)
        local room = event.room;
        if not room._data.ffmuc_signed or event.affiliation ~= "owner" then return; end
        if type(event.actor) ~= "string" or jid_bare(event.actor) ~= focus_jid then return; end
        for _, occupant in room:each_occupant() do
            if occupant.bare_jid == event.jid then
                for real_jid in occupant:each_session() do
                    if is_host_of(prosody.full_sessions[real_jid], room) then return; end
                end
            end
        end
        module:log("debug", "not letting jicofo make %s owner of %s", event.jid, room.jid);
        event.allowed = false;
        event.error = { type = "cancel", condition = "not-allowed" };
    end);

    -- Close rooms their host deleted (or that were revoked for abuse).
    if lookup_url then
        module:add_timer(sweep_interval, function()
            local now = os.time();
            for name, until_ in pairs(migrated) do
                if until_ < now then migrated[name] = nil; end
            end
            local muc = prosody.hosts[host] and prosody.hosts[host].modules.muc;
            if not muc then return sweep_interval; end
            for room in muc.each_room(true) do
                local name = jid_node(room.jid);
                if room._data.ffmuc_signed and not room._data.destroyed then
                    fetch_state(name, function(state)
                        if state and state.status == "deleted" and not room._data.destroyed then
                            module:log("info", "closing deleted room %s", name);
                            measure_closed(1);
                            room:destroy(nil, "This room was deleted by its host.");
                        end
                    end);
                end
            end
            return sweep_interval;
        end);
    end
end);

-- A client asks jicofo for a conference before anyone joins the room: check
-- the room here, in the client's session, so jicofo never waits on a lookup.
module:hook("pre-iq/host", function(event)
    local stanza, origin = event.stanza, event.origin;
    if stanza.attr.type ~= "set" or stanza.attr.to ~= focus_host or origin.type ~= "c2s" then return; end
    local conference = stanza:get_child("conference", FOCUS_NS);
    local node, host = jid_split(conference and conference.attr.room);
    if host ~= muc_domain or not is_signed_name(node) then return; end
    local ok, why = room_usable(node, true);
    local s = origin.ffmuc_signed;
    if ok and s and s.room == node then ok, why = session_valid(s, false); end
    if ok then return; end
    measure_rejected_rooms(1);
    module:log("info", "refusing conference for reserved room %s: %s", node, tostring(why));
    local text = why == "deleted" and "This room was deleted by its host."
        or why == "replaced" and "This link was replaced by new links."
        or why == "lookup failed" and "Room check failed, please try again in a minute."
        or "This room does not exist or has expired.";
    origin.send(st.iq({ type = "error", to = stanza.attr.from, from = stanza.attr.to, id = stanza.attr.id })
        :tag("error", { type = "cancel" })
            :tag("service-unavailable", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }):up()
            :tag("text", { xmlns = "urn:ietf:params:xml:ns:xmpp-stanzas" }):text(text):up()
            :tag("reservation-error", { xmlns = FOCUS_NS, ["error-code"] = why == "lookup failed" and "503" or "403" }));
    return true;
end, 10);
