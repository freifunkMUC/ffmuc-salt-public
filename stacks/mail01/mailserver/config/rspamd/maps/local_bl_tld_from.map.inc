# Rspamd SENDER_TLD_FROM: regexp map on the registered domain of the envelope
# sender (filter email:domain:tld, multimap.conf), e.g. "example.top".
# Only TLDs with a long abuse record (Spamhaus "most abused", Freenom ccTLDs
# and the cheap new gTLDs); common or ambiguous ones (.co, .biz, .online, .site,
# .cloud, .pro, .life, .world, .art, .ir, .id ...) are deliberately not listed.
# Our own domains and partners must not match: add an exception in the
# lookahead of the first line, not a new line.
#
# Our own domains (and any subdomain, as the registered domain is matched).
/^(?!(?:fnmuc\.net|ffmuc\.net|ffmuc\.bayern)$).+\.(?:accountant|bid|cf|click|cricket|date|download|faith|ga|gdn|gq|icu|kim|loan|ml|party|pw|racing|review|science|stream|tk|top|trade|webcam|win|work|xyz)$/i
