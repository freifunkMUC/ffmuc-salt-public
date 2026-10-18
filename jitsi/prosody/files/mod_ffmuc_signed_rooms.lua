-- FFMUC signed viewers-only rooms.
--
-- Rooms named "r-<base32(payload || ed25519 sig)>" are minted by meet-reserve.
-- Prosody only holds the public keys: it refuses unsigned or expired "r-" rooms,
-- accepts meet-reserve EdDSA tokens (host/speaker) and turns the room into a
-- visitors room where only the host and speakers join the main room.
--
-- Load on the main VirtualHost (authentication = "token", allow_empty_token = true).
--
--   ffmuc_signed_rooms_public_keys = { ["1"] = "<base64 raw ed25519 public key>" }
--   ffmuc_signed_rooms_max_extension = 30 * 86400
--   ffmuc_signed_rooms_auto_promote_unsigned = true

local crypto = require "util.crypto";
local base64 = require "util.encodings".base64;
local json = require "util.json";
local jid_bare = require "util.jid".bare;
local jid_node = require "util.jid".node;
local st = require "util.stanza";

local util = module:require "util";
local process_host_module = util.process_host_module;
local is_healthcheck_room = util.is_healthcheck_room;

local ISSUER = "ffmuc-reserve";
local AUDIENCE = "jitsi";
local ROOM_PREFIX = "r-";
local ROOM_CONTEXT = "ffmuc-room-v1\0";
local PAYLOAD_LEN, SIG_LEN = 15, 64;
local SPKI_PREFIX = "\48\42\48\5\6\3\43\101\112\3\33\0";

local muc_domain = module:get_option_string("ffmuc_signed_rooms_muc",
    module:get_option_string("main_muc", "conference." .. module.host));
local focus_jid = module:get_option_string("ffmuc_signed_rooms_focus_jid", "focus@auth." .. module.host);
local max_extension = module:get_option_number("ffmuc_signed_rooms_max_extension", 30 * 86400);
local auto_promote_unsigned = module:get_option_boolean("ffmuc_signed_rooms_auto_promote_unsigned", true);
local clock_skew = module:get_option_number("ffmuc_signed_rooms_clock_skew", 60);

local measure_rooms = module:measure("rooms_created", "counter");
local measure_rejected_rooms = module:measure("rooms_rejected", "counter");
local measure_tokens = module:measure("tokens_accepted", "counter");
local measure_rejected_tokens = module:measure("tokens_rejected", "counter");

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

local function room_usable(name)
    local exp, err = parse_room(name);
    if not exp then return false, err; end
    if exp + max_extension < os.time() then return false, "expired"; end
    return true;
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
    local ok, why = room_usable(room);
    if not ok then return nil, "room " .. tostring(why); end

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
    if session.host ~= module.host or type(session.auth_token) ~= "string" then return; end
    local claims, role = verify_token(session.auth_token);
    if claims == false then return; end
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
    session.ffmuc_signed = { room = claims.room, role = role, exp = claims.exp };
    -- the token util only knows HS256 here; with allow_empty_token it now lets
    -- the session through, room binding comes from the "<role>:<room>" user id
    session.auth_token = nil;
end, 10);

local function is_host_of(session, room)
    local s = session and session.ffmuc_signed;
    return s and s.role == "host" and s.room == jid_node(room.jid) and s.exp + clock_skew >= os.time() or false;
end

process_host_module(muc_domain, function(host_module, host)
    module:log("info", "signed rooms active on %s with %d key(s)", host, key_count);

    host_module:hook("muc-room-pre-create", function(event)
        local name = jid_node(event.room.jid);
        if not is_signed_name(name) then return; end
        local ok, why = room_usable(name);
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
end);
