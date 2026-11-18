# Rspamd BAD_SUBJECT_BL: regexp map on the Subject header (multimap.conf).
# One term per line, /.../i. Only terms that are close to always spam in a
# German/English mailbox; words that occur in normal mail (auto, geld, ki, etf,
# aktien, reich, einkommen, marketing, seo, kapital, unternehmer, bitcoin,
# malware, apotheke, tabletten, pillen ...) are deliberately not listed.
# Use \b, never bare substrings. Review with the hit counts of the symbol
# (rspamc stat / history) before adding anything.

# Pharma and health spam
/\bviagra\b/i
/\bcialis\b/i
/\bpharma(?:cy)?\b/i
/\bpotenzmittel\b/i
/\btestost\w*/i
/\brezeptfrei\w*/i
/\br[.\-_*:]{0,2}e[.\-_*:]{0,2}z[.\-_*:]{0,2}e[.\-_*:]{0,2}p[.\-_*:]{0,2}t[.\-_*:]{0,2}f[.\-_*:]{0,2}r[.\-_*:]{0,2}e[.\-_*:]{0,2}i/i
/\bpillenversand\b/i
/\bpsoriasis\b/i
/\bprostatitis\b/i
/\bpapillome\b/i
/\bh[aä]morrhoiden\b/i
/\bharninkontinenz\b/i
/\bgelenkschmerzen\b/i
/\bh[öo]rverm[öo]gens\b/i
/\bstabilisierung.{1,40}blutdrucks\b/i
/\bentgiftungsprogramm\b/i
/\bgewichtsverlust\b/i
/\bderila\b/i
/\bhondrostrong\b/i
/\bmuama\b/i
/\bryoko\b/i
/\bnubuu\b/i
/\bnuubu\b/i

# Adult
/\berotic\b/i
/\berection\b/i
/\bsexy\b/i
/\bporn\w*/i
/\bsperm\b/i
/\bslut\b/i
/\btit(?:s|ty|ties)\b/i
/\bvagina\b/i
/\bpenis\b/i
/\bmasturbieren\b/i

# Gambling, loans, get-rich
/\blotto\b/i
/\blottery\b/i
/\bjackpot\b/i
/\bkredithilfe\b/i
/\bpreissturz\b/i
/\bchance.{1,40}kostenlos\b/i

# Product spam
/\bantihaftbeschichtung\b/i
/\bbambusseide\b/i
/\bluxusseide\b/i
/\beinlegesohlen\b/i
/\bm[üu]helose[sn]?.{1,40}reinigen\b/i
/\bzukunft.{1,40}sauberkeit\b/i
/\bsprach[üu]bersetzer\b/i
/\btest your iq now\b/i

# Web development and SEO cold mail
/\bweb development\b/i
