// Show a translated "Enter room name" hint in the welcome page input.
// Upstream leaves the placeholder empty when room name generation is off.
(function () {
    var cache = {};

    function text(lang) {
        if (!cache[lang]) {
            var url = lang === 'en' ? 'lang/main.json' : 'lang/main-' + lang + '.json';
            cache[lang] = fetch(url)
                .then(function (r) { return r.json(); })
                .then(function (j) { return j.welcomepage && j.welcomepage.roomname; })
                .catch(function () { return null; })
                .then(function (t) { return t || (lang === 'en' ? 'Enter room name' : text('en')); });
        }
        return cache[lang];
    }

    function apply() {
        var input = document.getElementById('enter_room_field');
        var lang = document.documentElement.lang || 'en';
        if (!input || input.dataset.ffmLang === lang) {
            return;
        }
        input.dataset.ffmLang = lang;
        text(lang).then(function (t) { input.placeholder = t; });
    }

    var obs = new MutationObserver(apply);
    function start() {
        obs.observe(document.body, { childList: true, subtree: true });
        obs.observe(document.documentElement, { attributes: true, attributeFilter: [ 'lang' ] });
        apply();
    }
    if (document.body) {
        start();
    } else {
        document.addEventListener('DOMContentLoaded', start);
    }
})();
