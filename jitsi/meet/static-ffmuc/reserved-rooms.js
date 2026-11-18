// "Reserved rooms" box and donation banner on the welcome page, above the
// FFMUC card (welcomePageAdditionalCard.html).
// The reserve page (stacks/build/meet-reserve/index.html) adds rooms to the
// list in localStorage when the user ticks "Remember on this device". An entry
// has only the room name, the host secret, a local label and the end date.
(function () {
    var KEY = 'ffmuc-reserved-rooms';
    var CHECKED = 'ffmuc-reserved-rooms-checked';
    var RESERVE = 'https://meet.ffmuc.net/reserve/';
    // The list and the reserve API exist only on the origin of the reserve page.
    var home = location.origin + '/reserve/' === RESERVE;
    var notes = [];
    var adding = false;

    function de() { return /^de(-|$)/.test(document.documentElement.lang || ''); }
    function t(d, e) { return de() ? d : e; }
    function esc(s) {
        return String(s).replace(/[&<>"]/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
        });
    }
    function day(iso) {
        return new Date(iso).toLocaleDateString(de() ? 'de-DE' : 'en-GB',
            { day: '2-digit', month: '2-digit', year: 'numeric' });
    }

    function load() {
        try { return JSON.parse(localStorage.getItem(KEY)) || []; } catch (e) { return []; }
    }
    function store(a) {
        try { localStorage.setItem(KEY, JSON.stringify(a)); } catch (e) {}
    }
    function drop(room) {
        store(load().filter(function (r) { return r.room !== room; }));
    }
    // j is a room from the reserve API. Without a label, keep the saved label.
    function put(j, label) {
        var a = load(), m = /#k=([^&\s]+)/.exec(j.manage_url || '');
        var r = { room: j.room, key: m ? m[1] : '', label: label || '', expires: j.expires };
        var i = a.findIndex(function (x) { return x.room === j.room; });
        if (i < 0) {
            a.unshift(r);
        } else {
            r.label = label === undefined ? a[i].label : r.label;
            a[i] = r;
        }
        store(a);
    }
    function manage(key) {
        return fetch('/reserve/api/manage', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ key: key })
        }).then(function (r) {
            return r.json().catch(function () { return {}; }).then(function (j) { j.code = r.status; return j; });
        });
    }
    function why(j) {
        return j.status || j.reason || (j.code === 410 ? 'replaced' : 'unknown');
    }

    function btn(cls, a, text) {
        return '<button type="button" class="ffm-btn' + cls + '" data-a="' + a + '">' + text + '</button>';
    }
    function link(cls, href, text, more) {
        return '<a class="ffm-btn' + cls + '" href="' + href + '"' + (more || '') + '>' + text + '</a>';
    }

    function render() {
        var el = document.querySelector('.ffm-rooms');
        if (!el) {
            return;
        }
        var form = el.querySelector('.ffm-rooms-add'), url = form ? form.elements.link.value : '',
            name = form ? form.elements.name.value : '', err = form ? form.querySelector('.ffm-rooms-err').textContent : '';
        var h = '<div class="ffm-rooms-head"><h2>' + t('Reservierte Räume', 'Reserved rooms') + '</h2><div class="ffm-rooms-actions">'
            + (home ? btn(' ffm-outline', 'add', t('Link hinzufügen', 'Add link')) : '')
            + link('', RESERVE, t('Raum reservieren', 'Reserve a room')) + '</div></div>'
            + '<p class="ffm-lead">' + t('Dein eigener Raum mit festen Links, Moderation, Sprecher:innen und Zuschauer:innen. Ohne Konto.',
                'Your own room with fixed links, moderators, speakers and viewers. No account.') + '</p>';
        if (!home) {
            el.innerHTML = h;
            return;
        }
        if (adding) {
            h += '<form class="ffm-rooms-add"><input name="link" autocomplete="off" spellcheck="false" placeholder="'
                + t('Moderations- oder Verwaltungslink einfügen', 'Paste a host or manage link') + '" value="' + esc(url) + '">'
                + '<input name="name" maxlength="60" placeholder="' + t('Name (optional)', 'Name (optional)') + '" value="' + esc(name) + '">'
                + '<button class="ffm-btn">' + t('Hinzufügen', 'Add') + '</button>'
                + btn(' ffm-outline', 'cancel', t('Abbrechen', 'Cancel'))
                + '<div class="ffm-rooms-err">' + esc(err) + '</div></form>';
        }
        notes.forEach(function (n) {
            h += '<p class="ffm-rooms-note">' + esc(n.name) + ' ' + ({
                expired: t('ist abgelaufen und wurde von der Liste entfernt.', 'has expired and was removed from the list.'),
                deleted: t('wurde gelöscht und von der Liste entfernt.', 'was deleted and was removed from the list.'),
                replaced: t('hat neue Links bekommen. Füge den neuen Link hinzu.', 'got new links. Add the new link.')
            }[n.why] || t('ist unbekannt und wurde von der Liste entfernt.', 'is unknown and was removed from the list.')) + '</p>';
        });
        var rooms = load();
        if (!rooms.length) {
            h += '<p class="ffm-rooms-small">' + t('Noch keine Räume auf diesem Gerät gespeichert. Beim Reservieren „Auf diesem Gerät merken“ anhaken.',
                'No rooms saved on this device yet. Tick “Remember on this device” when you reserve a room.') + '</p>';
            el.innerHTML = h;
            return;
        }
        h += '<ul class="ffm-rooms-list">';
        rooms.forEach(function (r) {
            var days = (new Date(r.expires) - Date.now()) / 864e5, n = Math.max(1, Math.ceil(days)), soon = days < 3;
            h += '<li data-room="' + esc(r.room) + '"><div class="ffm-rooms-name">'
                + '<button type="button" data-a="rename" title="' + t('Klicken zum Umbenennen', 'Click to rename') + '">' + esc(r.label || r.room) + '</button><small>'
                + (soon ? '<span class="ffm-rooms-soon">' + t('Läuft in ' + n + (n === 1 ? ' Tag' : ' Tagen') + ' ab',
                    'Expires in ' + n + (n === 1 ? ' day' : ' days')) + '</span> · ' : '')
                + t('Gültig bis ', 'Valid until ') + day(r.expires) + (r.label ? ' · ' + esc(r.room) : '') + '</small></div>'
                + link(' ffm-rooms-join', '/reserve/h/' + esc(r.key), t('Als Moderation beitreten', 'Join as host'), ' target="_blank" rel="noopener"')
                + link(' ffm-outline ffm-rooms-manage', '/reserve/#k=' + esc(r.key), soon ? t('Verlängern', 'Extend') : t('Verwalten', 'Manage'))
                + '<button type="button" class="ffm-rooms-x" data-a="remove" title="' + t('Von diesem Gerät entfernen', 'Remove from this device') + '">×</button></li>';
        });
        el.innerHTML = h + '</ul><p class="ffm-rooms-small">'
            + t('Nur auf diesem Gerät gespeichert. Entfernen löscht den Raum nicht.', 'Saved only on this device. Removing does not delete the room.') + '</p>';
    }

    // Get the current end date and links of each room, at most once per hour
    // and tab: each POST counts for the rate limit of the reserve API.
    function refresh() {
        var rooms = load(), now = Date.now(), last = 0;
        try { last = +sessionStorage.getItem(CHECKED) || 0; } catch (e) {}
        var ended = rooms.some(function (r) { return new Date(r.expires) <= now; });
        if (!home || !rooms.length || (now - last < 36e5 && !ended)) {
            return;
        }
        try { sessionStorage.setItem(CHECKED, now); } catch (e) {}
        Promise.all(rooms.map(function (r) {
            return manage(r.key).then(function (j) {
                if (j.code === 200 && j.status === 'active') {
                    put(j);
                } else if (j.code === 200 || j.code === 404 || j.code === 410) {
                    notes.push({ name: r.label || r.room, why: why(j) });
                    drop(r.room);
                }
            }, function () {});
        })).then(render);
    }

    function add(form) {
        var out = form.querySelector('.ffm-rooms-err');
        out.textContent = '';
        manage(form.elements.link.value.trim()).then(function (j) {
            if (j.code === 200 && j.status === 'active') {
                put(j, form.elements.name.value.trim().slice(0, 60) || undefined);
                adding = false;
                render();
                return;
            }
            out.textContent = {
                expired: t('Der Raum ist abgelaufen.', 'The room has expired.'),
                deleted: t('Der Raum wurde gelöscht.', 'The room was deleted.'),
                replaced: t('Dieser Link wurde durch neue Links ersetzt.', 'This link was replaced by new links.')
            }[why(j)] || t('Kein gültiger Moderations- oder Verwaltungslink. Gastlinks gehen nicht.',
                'Not a valid host or manage link. Guest links do not work.');
        }, function () {
            out.textContent = t('Keine Verbindung. Versuche es später noch einmal.', 'No connection. Try again later.');
        });
    }

    document.addEventListener('click', function (e) {
        var b = e.target.closest('.ffm-rooms [data-a]');
        if (!b) {
            return;
        }
        var a = b.dataset.a, li = b.closest('li'), room = li && li.dataset.room;
        if (a === 'add' || a === 'cancel') {
            adding = a === 'add';
            render();
            if (adding) {
                document.querySelector('.ffm-rooms-add input').focus();
            }
        } else if (a === 'remove') {
            if (confirm(t('Raum von diesem Gerät entfernen? Der Raum selbst bleibt bestehen.',
                'Remove the room from this device? The room itself stays.'))) {
                drop(room);
                render();
            }
        } else if (a === 'rename') {
            var all = load(), r = all.find(function (x) { return x.room === room; });
            var v = r && prompt(t('Name für diesen Raum (nur auf diesem Gerät):', 'Name for this room (only on this device):'), r.label || '');
            if (r && v !== null) {
                r.label = v.trim().slice(0, 60);
                store(all);
                render();
            }
        }
    });
    document.addEventListener('submit', function (e) {
        if (e.target.matches('.ffm-rooms-add')) {
            e.preventDefault();
            add(e.target);
        }
    });

    function card(cls, html) {
        var d = document.createElement('div');
        d.className = cls;
        d.innerHTML = html;
        return d;
    }

    function mount() {
        var info = document.querySelector('.ffm-card:not(.ffm-rooms)');
        if (!info || document.querySelector('.ffm-rooms')) {
            return;
        }
        var outer = info.closest('.welcome-card') || info.parentElement;
        outer.before(
            card('welcome-card welcome-card--dark', '<div class="welcome-card-text ffm-card ffm-rooms"></div>'),
            card('ffm-donate', '<span class="ffm-donate-icon" aria-hidden="true">💛</span><p>'
                + '<span class="ffm-de"><b>Freifunk Meet ist kostenlos – aber nicht umsonst.</b><br>Ehrenamtliche betreiben die Server. Mit einer Spende hältst du Meet frei und werbefrei.</span>'
                + '<span class="ffm-en"><b>Freifunk Meet is free – but it is not free to run.</b><br>Volunteers operate the servers. A donation keeps Meet free and without ads.</span></p>'
                + '<a href="https://spende.ffmuc.net" target="_blank" rel="noopener"><span class="ffm-de">Jetzt spenden</span><span class="ffm-en">Donate now</span></a>'));
        render();
        refresh();
    }

    function start() {
        new MutationObserver(mount).observe(document.body, { childList: true, subtree: true });
        new MutationObserver(render).observe(document.documentElement, { attributes: true, attributeFilter: [ 'lang' ] });
        mount();
    }
    if (document.body) {
        start();
    } else {
        document.addEventListener('DOMContentLoaded', start);
    }
})();
