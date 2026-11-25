#!/usr/bin/env python3
"""Copy the monthly Usertreffen minutes from Etherpad into DokuWiki (docker04).

Salt state dokuwiki-treffen-sync, weekly systemd timer ffmuc-treffen-sync.timer.

Meetings are the last Wednesday of a month. For each one after the newest wiki page
treffen:<YYMMDD> that is at least 7 days old (so the pad is closed), the pad HTML export
becomes the page treffen:<YYMMDD>, and an entry goes on top of its year column on
treffen:start. Gaps within the last six months are filled the same way.

Never overwrites a page (create only). The start page is written only if it is
unchanged since it was read. Pages are saved with DokuWiki's own saveWikiText as uid
1000 inside the container (history, attic; minor edit, so nobody gets mail). Rerunning
is safe: with nothing to do it only logs that.

Usage: ffmuc-treffen-sync [--dry-run] [--today YYYY-MM-DD] [--data DIR] [--pads DIR]
                          [--docker CMD]
  --data    DokuWiki pages directory (default: the host path of the container storage)
  --pads    read <pad>.html from this directory instead of the pad export (tests)
  --docker  docker binary (tests)
"""

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser

DATA = "/srv/docker/dokuwiki/storage/data/pages"
CONTAINER = "dokuwiki-dokuwiki-1"
PAD_URL = "https://ffmuc.net/pad/p/{pad}/export/html"
UA = {"User-Agent": "ffmuc-treffen-sync"}
LOCK = "/run/ffmuc-treffen-sync.lock"
BULLET = "{{:bulletpoint.png?nolink&14|Bild: Freifunk München Logo}} "
BACKFILL_DAYS = 183
MAX_BYTES = 500_000  # pad export
MAX_LINKS = 40
MAX_HOSTS = 15

# DokuWiki writer: JSON list on stdin [{id, mode create|update, text, old, summary}]; no
# single quotes in here (the script is passed as one shell argument).
PHP = """if (!defined("DOKU_INC")) define("DOKU_INC", "/var/www/html/");
define("NOSESSION", 1);
require_once DOKU_INC . "inc/init.php";
$_SERVER["REMOTE_USER"] = "treffen-sync";
$rc = 0;
foreach (json_decode(stream_get_contents(STDIN), true) as $p) {
    $id = cleanID($p["id"]); $cur = rawWiki($id); $m = $p["mode"];
    if (page_exists($id) && $cur === cleanText($p["text"])) { echo "OK already $id\\n"; continue; }
    if ($m === "create" ? page_exists($id) : $cur !== cleanText($p["old"])) {
        echo "SKIP ", ($m === "create" ? "exists with other text" : "changed since read"), " $id\\n"; $rc = 1; continue;
    }
    saveWikiText($id, $p["text"], $p["summary"], true);
    echo "OK $m $id ", strlen(rawWiki($id)), " bytes\\n";
}
exit($rc);"""

# Copy of the converter in infra ops/ffmuc_treffen_lib.py (Etherpad HTML -> DokuWiki).
URL = re.compile(r"(https?://\S+)")
PADURL = re.compile(r"https://ffmuc\.net/pad/p/(treffen\d{6})(?!\d)\S*")
MARK = re.compile(
    r"\*\*|//|__|''|\[\[|\]\]|\{\{|\}\}|\(\(|\)\)|~~|<|>|\^|\||==|----|\\\\|%%"
)


SAFE_URL = re.compile(r"https?://[A-Za-z0-9\-._~:/?#@!$&'()*+,;=%]+")
BAD_URL = re.compile(r"\{\{|\}\}|\[\[|\]\]|~~|<|>|\||\\\\|''|%%")


def safe_url(u):
    """Pads are publicly editable: only plain http(s) URLs may stay or become links."""
    return bool(SAFE_URL.fullmatch(u)) and not BAD_URL.search(u)


def esc_plain(p):
    if not MARK.search(p):
        return p
    if "%%" in p:
        return "<nowiki>" + p.replace("</nowiki>", "</ nowiki>") + "</nowiki>"
    return "%%" + p + "%%"


def esc_part(part, padmap):
    """Plain text: safe URLs stay (pad links become wiki pages), markup gets %%..%%."""
    out = []
    for p in URL.split(part):
        if URL.fullmatch(p) and safe_url(p):
            pm = PADURL.fullmatch(p)
            out.append(f"[[{padmap[pm[1]]}]]" if pm and pm[1] in padmap else p)
        else:
            out.append(esc_plain(p))
    return "".join(out)


class PadHtml(HTMLParser):
    FMT = {
        "strong": ("**", "**"),
        "b": ("**", "**"),
        "em": ("//", "//"),
        "i": ("//", "//"),
        "u": ("__", "__"),
        "s": ("<del>", "</del>"),
        "strike": ("<del>", "</del>"),
        "del": ("<del>", "</del>"),
    }

    def __init__(self, padmap):
        super().__init__(convert_charrefs=True)
        self.padmap, self.lines, self.cur, self.stack, self.fmts = (
            padmap,
            [],
            [],
            [],
            [],
        )
        self.item = None  # (marker, depth) while inside an <li> of a real list
        self.body = self.after_list = False
        self.skip = 0
        self.href = self.abuf = None

    def depth(self):
        return sum(k != "indent" for k in self.stack)

    def flush(self):
        s = "".join(self.cur).strip()
        s = re.sub(r"(\s*\\\\)+$", "", s).strip()
        s = re.sub(r"^(\\\\\s*)+", "", s)
        self.cur = []
        if not s:
            return
        if self.item:
            self.lines.append(("item", self.item[1], self.item[0], s))
        else:
            self.lines.append(("text", s))

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "body":
            self.body = True
        elif tag in ("style", "script", "title"):
            self.skip += 1
        if not self.body or self.skip:
            return
        if tag in ("ul", "ol"):
            self.flush()
            self.item = None
            self.after_list = False
            if "indent" in (a.get("class") or ""):
                self.stack.append("indent")
            else:
                self.stack.append("bullet" if tag == "ul" else "number")
        elif tag == "li":
            self.flush()
            self.after_list = False
            k = self.stack[-1] if self.stack else "indent"
            if k == "indent":
                self.item = None
            else:
                self.item = ("*" if k == "bullet" else "-", self.depth())
        elif tag == "br":
            if self.item:
                self.cur.append(" \\\\ ")
            elif not "".join(self.cur).strip() and self.after_list:
                self.after_list = False
            elif "".join(self.cur).strip():
                self.flush()
            else:
                self.lines.append(("blank",))
        elif tag in self.FMT:
            self.fmts.append(tag)
        elif tag == "a" and a.get("href"):
            self.href, self.abuf = a["href"], []

    def handle_endtag(self, tag):
        if tag in ("style", "script", "title"):
            self.skip = max(0, self.skip - 1)
        if tag == "body":
            self.flush()
            self.body = False
        if not self.body or self.skip:
            return
        if tag in ("ul", "ol"):
            self.flush()
            if self.stack:
                self.stack.pop()
            self.item = None
            self.after_list = True
        elif tag == "li":
            self.flush()
        elif tag in self.FMT and tag in self.fmts:
            del self.fmts[len(self.fmts) - 1 - self.fmts[::-1].index(tag)]
        elif tag == "a" and self.href is not None:
            txt = "".join(self.abuf).replace("\xa0", " ").strip()
            href = self.href
            self.href = self.abuf = None
            if not txt or URL.fullmatch(txt) or txt == href:
                self.text(txt or href)
            elif not safe_url(href):
                self.text(txt)
            else:
                pm = PADURL.fullmatch(href)
                tgt = self.padmap[pm[1]] if pm and pm[1] in self.padmap else href
                self.emit(f"[[{tgt}|" + esc_plain(txt.replace("|", "¦")) + "]]")

    def emit(self, s):
        for t in self.fmts[::-1]:
            s = self.FMT[t][0] + s + self.FMT[t][1]
        self.cur.append(s)
        self.after_list = False

    def text(self, data):
        data = data.replace("\xa0", " ")
        if not data.strip():
            if self.cur and data:
                self.cur.append(" ")
            return
        lead, core, trail = re.match(r"(\s*)(.*?)(\s*)$", data, re.S).groups()
        self.cur.append(" " if lead else "")
        self.emit(esc_part(re.sub(r"\s+", " ", core), self.padmap))
        self.cur.append(" " if trail else "")

    def handle_data(self, data):
        if not self.body or self.skip:
            return
        if self.href is not None:
            self.abuf.append(data)
        else:
            self.text(data)

    def result(self):
        self.flush()
        out, ls = [], self.lines
        for i, line in enumerate(ls):
            if line[0] == "blank":
                out.append("")
            elif line[0] == "item":
                out.append("  " * line[1] + f"{line[2]} " + line[3])
            else:
                nxt = ls[i + 1] if i + 1 < len(ls) else None
                out.append(line[1] + (" \\\\" if nxt and nxt[0] == "text" else ""))
        return "\n".join(out).strip("\n")


def html_to_doku(html, padmap):
    p = PadHtml(padmap)
    p.feed(html)
    p.close()
    return p.result()


def page_text(pad, date, body, today):
    d = f"{date:%d.%m.%Y}"
    return (
        "{{htmlmetatags>metatag-robots=(index,nofollow)\n"
        f"metatag-description=(Usertreffen {d} - 19:30 Uhr online via "
        "meet.ffmuc.net/ffmuctreffen)\n}}\n"
        "~~NOTOC~~\n\n/* *** Titelbalken mit ffmuc Logo *** */\n"
        "<WRAP center round box 100%>\n"
        "<fs xx-large><fc #de2c68> FREIFUNK - MÜNCHEN</fc></fs>\n"
        "{{ :ffmuc_logo.png?nolink&125|Bild: Freifunk-München-Logo}}\n</WRAP>\n\n"
        f"====== Usertreffen {d} um 19:30 Uhr ======\n\n"
        f"//Übernommen aus dem Etherpad ''{pad}'' (Revision letzte) am "
        f"{today:%d.%m.%Y}.//\n\n{body}\n"
    )


def last_wednesday(year, month):
    first_next = dt.date(year + month // 12, month % 12 + 1, 1)
    last = first_next - dt.timedelta(days=1)
    return last - dt.timedelta(days=(last.weekday() - 2) % 7)


def candidates(newest, today):
    """Last Wednesdays from six months before the newest page up to 7 days ago."""
    out = []
    y, m = (newest - dt.timedelta(days=BACKFILL_DAYS)).timetuple()[:2]
    while dt.date(y, m, 1) <= today:
        d = last_wednesday(y, m)
        if d <= today - dt.timedelta(days=7):
            out.append(d)
        y, m = y + m // 12, m % 12 + 1
    return out


def fetch_pad(pad, pads_dir):
    """-> HTML or None (missing, empty, or still the Etherpad welcome text)."""
    try:
        if pads_dir:
            with open(f"{pads_dir}/{pad}.html", encoding="utf-8") as f:
                html = f.read()
        else:
            req = urllib.request.Request(PAD_URL.format(pad=pad), headers=UA)
            with urllib.request.urlopen(req, timeout=30) as r:
                html = r.read(MAX_BYTES + 1).decode("utf-8")
    except (OSError, urllib.error.URLError) as e:
        log(f"{pad}: export failed ({e.__class__.__name__}), will retry next run")
        return None
    return None if "Welcome to Etherpad" in html else html


def insane(html, body):
    """Reason to refuse a pad (publicly editable), or None. Run on the converted body."""
    if len(html) > MAX_BYTES:
        return f"export larger than {MAX_BYTES} bytes"
    urls = re.findall(r"https?://[^\s%\]|]+", body)
    hosts = {u.split("/")[2] for u in urls}
    if len(urls) > MAX_LINKS or len(hosts) > MAX_HOSTS:
        return f"{len(urls)} links to {len(hosts)} hosts"
    rest = re.sub(r"%%.*?%%|<nowiki>.*?</nowiki>", "", body, flags=re.S)
    for m in re.finditer(r"\[\[([^\]|]*)(?:\|[^\]]*)?\]\]", rest):
        if not re.fullmatch(r"treffen:\d{6}", m[1]) and not safe_url(m[1]):
            return "unexpected link target"
    rest = (
        re.sub(r"\[\[[^\]]*\]\]", "", rest).replace("<del>", "").replace("</del>", "")
    )
    if re.search(r"\{\{|\}\}|<|>|~~|\[\[|\]\]", rest):
        return "embed, HTML or control markup outside escapes"
    return None


def log(msg):
    print(msg, flush=True)


def wiki_write(docker, ops):
    cmd = [docker, "exec", "-i", "-u", "1000", CONTAINER, "php", "-r", PHP]
    r = subprocess.run(
        cmd, input=json.dumps(ops), capture_output=True, text=True, check=False
    )
    for line in r.stdout.splitlines() + r.stderr.splitlines():
        log(f"writer: {line}")
    return r.returncode


def add_entry(start, date, pid):
    label = f"{date:%d.%m.%Y} 19:30 Uhr (online Usertreffen)"
    hdr = re.search(
        r"<fs large><fc #de2c68>" + f"{date:%Y}" + r"</fc></fs>\n\\\\\n", start
    )
    if not hdr:
        log(f"WARNING no year column {date:%Y} on treffen:start, add {pid} by hand")
        return start
    entry = f"{BULLET}**[[{pid}|{label}]]** \\\\\n"
    return start[: hdr.end()] + entry + start[hdr.end() :]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--today", type=dt.date.fromisoformat, default=dt.date.today())
    ap.add_argument("--data", default=DATA)
    ap.add_argument("--pads")
    ap.add_argument("--docker", default="docker")
    a = ap.parse_args()

    lock = open(LOCK if os.access("/run", os.W_OK) else "/tmp/ffmuc-treffen.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another run is active, skipping")
        return 0

    tdir = f"{a.data}/treffen"
    with open(f"{tdir}/start.txt", encoding="utf-8") as f:
        start = f.read()
    ids = {n[:-4] for n in os.listdir(tdir) if re.fullmatch(r"\d{6}\.txt", n)}
    dates = {}
    for i in ids:
        try:
            dates[i] = dt.datetime.strptime(i, "%y%m%d").date()
        except ValueError:
            pass
    if not dates:
        log("no treffen:<YYMMDD> page found, refusing to guess the start")
        return 1
    newest = max(dates.values())
    padmap = {f"treffen{i}": f"treffen:{i}" for i in ids}

    ops, new_start, created, failed = [], start, [], False
    for d in candidates(newest, a.today):
        i, pad = f"{d:%y%m%d}", f"treffen{d:%y%m%d}"
        if i not in ids:
            html = fetch_pad(pad, a.pads)
            if html is None:
                log(f"{pad}: no pad content, skipped")
                continue
            body = html_to_doku(html, padmap | {pad: f"treffen:{i}"})
            why = insane(html, body)
            if why:
                log(f"{pad}: REFUSED ({why}), not written")
                failed = True
                continue
            if not body.strip():
                log(f"{pad}: pad is empty, skipped")
                continue
            ops.append(
                dict(
                    id=f"treffen:{i}",
                    mode="create",
                    text=page_text(pad, d, body, a.today),
                    old="",
                    summary=f"Protokoll aus dem Etherpad {pad} übernommen",
                )
            )
            created.append(i)
            padmap[pad] = f"treffen:{i}"
        if f"[[treffen:{i}|" not in start and (i in ids or i in created):
            new_start = add_entry(new_start, d, f"treffen:{i}")
    if new_start != start:
        ops.append(
            dict(
                id="treffen:start",
                mode="update",
                text=new_start,
                old=start,
                summary="Protokolle aus dem Etherpad ins Wiki übernommen",
            )
        )
    if not ops:
        log(f"nothing to do (newest page {newest:%d.%m.%Y}, today {a.today})")
        return 2 if failed else 0
    log(
        f"{len(created)} new page(s), start page "
        f"{'changed' if new_start != start else 'unchanged'}"
    )
    if a.dry_run:
        for o in ops:
            log(f"dry run: {o['mode']} {o['id']} ({len(o['text'])} bytes)")
        return 2 if failed else 0
    return wiki_write(a.docker, ops) or (2 if failed else 0)


if __name__ == "__main__":
    sys.exit(main())
