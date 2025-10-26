# apps/workers/summarizer.py
from __future__ import annotations

import os
import re
from typing import List, Tuple, Optional

# =====================================================================
# Config / knobs
# =====================================================================

# Target CinePulse tone:
# - calm, factual, industry-style
# - ~80-100 words, 1 tight paragraph
# - numbers, dates, platforms, deltas are GOOD
# - hype, clickbait, CTA are BAD

SUMMARY_TARGET = int(os.getenv("SUMMARY_TARGET_WORDS", "100"))
SUMMARY_MIN    = int(os.getenv("SUMMARY_MIN_WORDS", "80"))
SUMMARY_MAX    = int(os.getenv("SUMMARY_MAX_WORDS", "120"))  # keep it tight

# "passthrough mode" basically never fires unless it's extremely short
PASSTHROUGH_MAX_WORDS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_WORDS", "60"))
PASSTHROUGH_MAX_CHARS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_CHARS", "400"))

# Headline constraints
HEADLINE_MAX_CHARS = int(os.getenv("HEADLINE_MAX_CHARS", "110"))

# =====================================================================
# Regex library
# =====================================================================

# Sentences that start like YouTube / promo hooks.
_PROMO_PREFIX_RE = re.compile(
    r"^(watch|watch\s+now|check\s+(this|it)\s+out|don['’]t\s+miss|"
    r"don['’]t\s+forget|follow\s+us|subscribe|hit\s+the\s+bell|"
    r"like\s+and\s+share)\b",
    re.I,
)

# Soft fluff / fanbait intros that sound like "As fans eagerly await..."
_SOFT_FLUFF_RE = re.compile(
    r"^(as\s+fans\s+(eagerly\s+)?await|"
    r"fans\s+are\s+(now\s+)?excited|"
    r"in\s+a\s+surprising\s+turn|"
    r"according\s+to\s+reports|"
    r"meanwhile|"
    r"amid\s+huge\s+buzz|"
    r"creating\s+massive\s+hype|"
    r"setting\s+the\s+stage\s+for)\b",
    re.I,
)

# Filler/redundant words that add no value
_FILLER_WORDS_RE = re.compile(
    r"\b(recently|currently|actually|basically|essentially|"
    r"literally|really|very|quite|rather|somewhat|"
    r"just|simply|merely)\b",
    re.I,
)

# CTA phrases we never want in summary.
_CTA_NOISE_RE = re.compile(
    r"\b(get\s+tickets?|book\s+now|buy\s+now|pre[- ]?order|"
    r"link\s+in\s+bio|watch\s+now|stream\s+now|order\s+now|"
    r"stay\s+tuned|follow\s+for\s+more)\b",
    re.I,
)

# Overhype / gossip / fan-reaction framing that we penalize hard.
_HYPE_RE = re.compile(
    r"\b(buzz(?:ing)?|internet\s+is\s+buzzing|fans\s+are\s+going\s+crazy|"
    r"fans\s+can['’]t\s+keep\s+calm|internet\s+reacts|"
    r"massive\s+showdown|epic\s+clash|who(?:'|’)ll\s+win|who\s+will\s+win|"
    r"promises\s+to\s+deliver|set(?:ting)?\s+the\s+stage\s+for\s+a\s+showdown|"
    r"blockbuster\s+in\s+the\s+making|taking\s+the\s+internet\s+by\s+storm|"
    r"poised\s+to\s+dominate|expected\s+to\s+shatter|"
    r"all\s+set\s+to\s+take\s+over)\b",
    re.I,
)

# Future hype / predictions we don't want in final paragraph.
_FUTURE_HYPE_RE = re.compile(
    r"\b(poised\s+to|expected\s+to|set\s+to\s+dominate|"
    r"all\s+set\s+to\s+take\s+over|will\s+set\s+the\s+box\s+office\s+on\s+fire)\b",
    re.I,
)

# Noise chunks / scrape artefacts to strip pre-split.
_NOISE_CHUNK_RE_LIST = [
    re.compile(r"\(\s*photo\s+credit[^)]*\)", re.I),
    re.compile(r"\(\s*image(?:s)?\s+credit[^)]*\)", re.I),
    re.compile(r"\(\s*pic\s+credit[^)]*\)", re.I),
    re.compile(r"\b(morning\s+report!?)\b", re.I),
    re.compile(r"\b(sunday\s+morning\s+report!?)\b", re.I),
    re.compile(r"(read\s+(also|more)\s*:[^\.!?]+[\.!?])", re.I),
]

# Sentence splitter: ".", "!" or "?" followed by whitespace.
_SENT_SPLIT_RE = re.compile(r"(?<=[\.!?])\s+")

# Weak tail that feels cut-off / unfinished.
_AUX_TAIL_RE = re.compile(
    r"\b(?:has|have|had|is|are|was|were|will|can|could|should|may|"
    r"might|do|does|did)\b[\.…]*\s*$",
    re.I,
)

# Ending words we don't want to end the whole summary on.
_BAD_END_WORD = re.compile(
    r"\b(?:and|but|or|so|because|since|although|though|while|as)\.?$",
    re.I,
)

# Trim dangling ellipsis.
_DANGLING_ELLIPSIS_RE = re.compile(r"(?:…|\.{3})\s*$")

# Words we allow uppercase (acronyms/platforms).
_PROTECTED_ACRONYMS = {
    "IPL", "FIFA", "UCL", "UFC", "NBA", "NFL",
    "OTT", "IMAX", "UHD", "4K", "VFX", "CGI",
    "PVR", "INOX", "SRK", "JIO", "HOTSTAR", "NETFLIX",
}

# We like factual / numeric / distributional info → bonus.
_FACTUAL_BONUS_RE = re.compile(
    r"(\bday\s+\d+\b|"
    r"\bfirst\s+sunday\b|"
    r"\bopening\s+weekend\b|"
    r"₹\s?\d+(\.\d+)?\s*(crore|cr|lakh|million)|"
    r"\b\d+(\.\d+)?\s*crore\b|"
    r"\b\d+(\.\d+)?\s*cr\b|"
    r"\b\d+(\.\d+)?\s*%\b|"
    r"\bpercent\b|"
    r"\bstream(?:ing)?\s+on\b|"
    r"\brelease[sd]?\s+on\b|"
    r"\bon\s+(october|november|december|january|february|march|april|"
    r"may|june|july|august|september)\b|"
    r"\bnetflix\b|"
    r"\bprime\s+video\b|"
    r"\bjio\s*cinema\b|"
    r"\bhotstar\b|"
    r"\bpvr\s+inox\b"
    r")",
    re.I,
)

# =====================================================================
# EXTRA REGEX FOR TITLE CLEANUP
# =====================================================================

_HEADLINE_TAIL_RE = re.compile(
    r"\s*(--|—|–|:|\|)\s*(how\s+it\s+stacks\s+up.*|"
    r"here'?s\s+how.*|"
    r"full\s+report.*|"
    r"detailed\s+report.*|"
    r"explained.*|"
    r"all\s+you\s+need\s+to\s+know.*|"
    r"comparison.*|"
    r"what\s+this\s+means.*|"
    r"what\s+we\s+know.*|"
    r"check\s+it\s+out.*)$",
    re.I,
)

_HEADLINE_HYPE_RE = re.compile(
    r"\b(shatters?|destroys?|goes\s+wild|goes\s+viral|"
    r"unbelievable|insane|massive\s+mayhem|"
    r"takes\s+over\s+the\s+internet|breaks\s+the\s+internet|"
    r"fans\s+go\s+crazy|internet\s+reacts|"
    r"epic\s+showdown|huge\s+clash|explosive\s+showdown|"
    r"poised\s+to\s+dominate|set\s+to\s+rule|"
    r"set\s+the\s+box\s+office\s+on\s+fire)\b",
    re.I,
)

_HEADLINE_SPLIT_RE = re.compile(r"\s+(--|—|–|-{2,}|\||:)\s+")
_HEADLINE_FILLER_RE = _FILLER_WORDS_RE

# =====================================================================
# LEGAL / DEFAMATION / GOSSIP RISK + ON-AIR DRAMA
# =====================================================================

# Crime / lawsuit / scandal / morality play.
_RISKY_RE = re.compile(
    r"\b("
    r"accused|allegations?|allegedly|arrested|detained|custody|in\s+custody|"
    r"police\s+custody|f\.?\s*i\.?\s*r\.?|FIR|police\s+complaint|police\s+case|"
    r"raid(?:ed)?|income\s+tax\s+raid|it\s+raid|ed\s+raid|ncb\s+raid|"
    r"drug\s+case|drugs?\s+case|narcotics|money\s+laundering|scam|fraud|"
    r"cheating\s+case|cheated|extortion|tax\s+evasion|"
    r"harass(?:ment|ed)?|misconduct|assault|violence|molestation|"
    r"backlash|boycott|trolled|slammed|controversy|controversial|leaked\s+chat|"
    r"leaked\s+video|leaked\s+audio|private\s+video|affair"
    r")\b",
    re.I,
)

# Pure off-camera gossip / personal-life / outrage bait
_GOSSIP_RE = re.compile(
    r"\b("
    r"affair|relationship|dating|spotted\s+together|"
    r"cheated\s+on|cheating\s+rumors?|split|break\s*up|divorce|"
    r"leaked\s+chat|leaked\s+video|private\s+video|"
    r"boycott|backlash|trolled|slammed|controversy|controversial"
    r")\b",
    re.I,
)

# Signals that the story is about work / release / business (lets us keep it).
_WORK_INFO_RE = re.compile(
    r"(box\s*office|collection[s]?\b|opening\s+weekend|₹\s?\d|"
    r"\b\d+(\.\d+)?\s*(crore|cr)\b|day\s+\d+\b|"
    r"release(?:d|s|ing)?\s+on|now\s+streaming|"
    r"\bon\s+(Netflix|Prime\s+Video|Jio\s*Cinema|Hotstar|Sony\s*LIV|Apple\s+TV\+|Max)\b|"
    r"\btrailer\b|\bteaser\b|\bcast\b|\bdirector\b|\bbox\s+office\b|"
    r"\bruntime\b|\bbudget\b|\bscreens\b|\bshowtimes?\b|\boccupancy\b)",
    re.I,
)

# === ON-AIR DRAMA: reality shows / televised moments (allowed, but risky → attribution) ===
_ON_AIR_SHOWS_RE = re.compile(
    r"\b("
    r"bigg\s*boss(?:\s*ott)?|khatron\s+ke\s+khi?ladi|indian\s+idol|roadies|splitsvilla|"
    r"jhalak\s+dikhhla\s+jaa|lock\s*upp|dance\s+(?:india|plus)|super\s+singer|"
    r"sa\s*re\s*ga\s*ma\s*pa|nach\s*baliye|shark\s*tank\s*india|the\s+kapil\s+sharma\s+show"
    r")\b",
    re.I,
)

_ON_AIR_TERMS_RE = re.compile(
    r"\b(evict(?:ed|ion)|nomination|nominated|wild[\s-]*card\s+entry|captain(?:cy)?|"
    r"task|immunity|weekend\s+ka\s+vaar|face[-\s]?off|heated\s+argument|"
    r"heated\s+exchange|verbal\s+spat|confronts?|fight|brawl|clash|"
    r"on\s+air|on-air|episode|eliminat(?:ed|ion))\b",
    re.I,
)

def _detect_on_air_drama(title: str, body_text: str) -> Tuple[bool, Optional[str]]:
    """Detect onscreen (televised) drama and return (is_on_air, show_name?)."""
    hay = f"{title or ''}\n{body_text or ''}"
    show = None
    m = _ON_AIR_SHOWS_RE.search(hay)
    if m:
        show = re.sub(r"\s+", " ", m.group(0)).strip().title()
    # Consider it on-air if we have a show OR strong on-air terms (episode/eviction/etc.)
    if m or _ON_AIR_TERMS_RE.search(hay):
        return True, show
    return False, None

# =====================================================================
# Small helpers
# =====================================================================

def _word_list(s: str) -> List[str]:
    return re.findall(r"[A-Za-z0-9]+", s)

def _preclean_body_text(raw: str) -> str:
    if not raw:
        return ""
    text = raw
    for _pat in _NOISE_CHUNK_RE_LIST:
        text = _pat.sub(" ", text)

    # Drop clickbait Qs at the end.
    text = re.sub(r"(how\s+much\s+did\s+[^?]+\?\s*)$", " ", text, flags=re.I | re.M)
    text = re.sub(r"(will\s+it\s+[^?]+\?\s*)$", " ", text, flags=re.I | re.M)
    text = re.sub(r"(what\s+does\s+this\s+mean[^?]*\?\s*)$", " ", text, flags=re.I | re.M)

    # Remove social handle fluff like "(Photo Credit – Instagram)".
    text = re.sub(r"\(\s*(photo|image|pic)[^)]+\)", " ", text, flags=re.I)

    # Remove obvious social plugs mid-body.
    text = re.sub(r"(follow\s+us\s+on\s+instagram[^\.!?]*[\.!?])", " ", text, flags=re.I)

    # Remove vague time refs
    text = re.sub(r"\b(recently|in\s+recent\s+times|lately)\b", "", text, flags=re.I)

    text = re.sub(r"[\r\n\t]+", " ", text)
    text = re.sub(r"\s{2,}", " ", text).strip()
    return text

def _clean_caps(word: str) -> str:
    if len(word) <= 2:
        return word
    if word.upper() == word and word.isalpha():
        return word.upper() if word.upper() in _PROTECTED_ACRONYMS else word.capitalize()
    return word

def _polish_sentence(s: str) -> str:
    original = s.strip()
    s = re.sub(
        r"^(watch|watch\s+now|check\s+this\s+out|check\s+it\s+out|"
        r"don['’]t\s+miss|don['’]t\s+forget\s+to\s+subscribe|"
        r"subscribe\s+now|exclusive\s*:)\s*",
        "",
        original,
        flags=re.I,
    ).strip()
    s = re.sub(r"(subscribe\s+for\s+more.*)$", "", s, flags=re.I).strip()
    s = re.sub(r"(follow\s+us.*)$", "", s, flags=re.I).strip()
    s = re.sub(r"(hit\s+the\s+bell.*)$", "", s, flags=re.I).strip()

    # Normalize phrasings
    s = re.sub(r"\b(\d+)-day\s+([A-Z][a-z]+)\s+schedule\b", r"\1-day schedule in \2", s, re.I)
    s = re.sub(r"\btoo\s+slow\s+and\s+logistically\s+complex\b", "too complex to execute", s, re.I)
    s = re.sub(r"\brecently\s+completed\b", "completed", s, re.I)
    s = re.sub(r"\bcurrently\s+targeted[;,]?\s*the\s+date\s+is\s+not\s+yet\s+officially\s+confirmed\b", "targeted", s, re.I)
    s = re.sub(r"\bcurrently\s+targeted\b", "targeted", s, re.I)

    # Trim weak tails
    s = _DANGLING_ELLIPSIS_RE.sub("", s).strip()
    s = _BAD_END_WORD.sub("", s).strip()
    s = _AUX_TAIL_RE.sub("", s).strip()

    s = _FILLER_WORDS_RE.sub("", s)
    s = re.sub(r"\s+", " ", s).strip()

    fixed_words = [_clean_caps(w) for w in s.split()]
    s = " ".join(fixed_words)

    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"\s+([,.;!?])", r"\1", s)

    if s and s[0].islower():
        s = s[0].upper() + s[1:]
    if s and s[-1] not in ".!?":
        s += "."
    return s

def _similar_enough(a: str, b: str) -> bool:
    aw = set(w.lower() for w in _word_list(a))
    bw = set(w.lower() for w in _word_list(b))
    if not aw or not bw:
        return False
    inter = len(aw & bw)
    union = len(aw | bw)
    if union == 0:
        return False
    return (inter / union) >= 0.7

def _score_sentence(title_kw: set[str], s: str) -> int:
    if not s:
        return -10**9
    if _PROMO_PREFIX_RE.search(s) or _CTA_NOISE_RE.search(s):
        return -10**8
    if _HYPE_RE.search(s) or _SOFT_FLUFF_RE.search(s):
        return -10**7

    overlap = len(title_kw.intersection(w.lower() for w in _word_list(s)))
    verb_bonus = 1 if re.search(
        r"\b(announce[ds]?|confirm(?:ed|s)?|revealed?|unveiled?|"
        r"premieres?|releasing?|release[sd]?|launch(?:es|ed)?|"
        r"earns?|earned|gross(?:ed|es)?|collect(?:ed|s)?|"
        r"beats?|surpass(?:ed|es)?|leads?|leads?\s+with|"
        r"occupancy|stream(?:s|ing)?\s+on|arrives?\s+on|"
        r"opens?\s+on|opens?\s+to|available\s+on)\b",
        s, re.I
    ) else 0
    factual_bonus = 2 if _FACTUAL_BONUS_RE.search(s) else 0

    clarity_bonus = 0
    if re.search(r"\b(instead|after|rather\s+than|in\s+place\s+of)\b", s, re.I):
        clarity_bonus += 1
    if re.search(r"\b(has\s+(built|filmed|completed|cancelled|dropped))\b", s, re.I):
        clarity_bonus += 1

    fluff_penalty = -1 if re.search(r"\b(huge|massive|epic|intense\s+clash|explosive\s+showdown)\b", s, re.I) else 0

    redundancy_penalty = 0
    if re.search(r"\b(currently\s+targeted|not\s+yet\s+officially\s+confirmed)\b", s, re.I):
        redundancy_penalty -= 2
    if re.search(r"\b(too\s+slow\s+and\s+logistically|too\s+slow\s+and)\b", s, re.I):
        redundancy_penalty -= 1

    wc = len(s.split())
    length_penalty = (-2 if wc < 6 else 0) + (-2 if wc > 60 else 0)

    return (
        overlap * 2
        + verb_bonus
        + factual_bonus
        + clarity_bonus
        + fluff_penalty
        + length_penalty
        + redundancy_penalty
    )

def _assemble_paragraph(chosen_sentences: List[str]) -> str:
    if not chosen_sentences:
        return ""
    interim: List[str] = []
    for s in chosen_sentences:
        s = s.strip()
        if not s:
            continue
        if _FUTURE_HYPE_RE.search(s):
            continue
        ps = _polish_sentence(s)
        if ps:
            interim.append(ps)

    final_sents: List[str] = []
    for s in interim:
        if not any(_similar_enough(s, prev) for prev in final_sents):
            final_sents.append(s)

    text = " ".join(final_sents).strip()
    text = re.sub(r"\s+", " ", text).strip()
    if text and text[-1] not in ".!?":
        text += "."
    return text

def _select_sentences(title: str, body_text: str) -> List[str]:
    body_text = _preclean_body_text(body_text or "")
    if not body_text:
        t = (title or "").strip()
        return [t] if t else []

    words_all = body_text.split()
    if len(words_all) <= PASSTHROUGH_MAX_WORDS and len(body_text) <= PASSTHROUGH_MAX_CHARS:
        return [body_text]

    sentences = [s.strip() for s in _SENT_SPLIT_RE.split(body_text) if s.strip()]
    if not sentences:
        return [body_text]

    title_kw = set(w.lower() for w in _word_list(title or ""))

    scored: List[Tuple[int, int, str]] = []
    for i, s in enumerate(sentences):
        score = _score_sentence(title_kw, s)
        scored.append((score, i, s))
    scored.sort(key=lambda x: (-x[0], x[1]))

    candidate_idx = {i for _, i, _ in scored[:12]}

    chosen: List[Tuple[int, str]] = []
    total_words = 0
    for i, s in enumerate(sentences):
        if i not in candidate_idx:
            continue
        wc = len(s.split())
        if wc < 6:
            continue
        if any(_similar_enough(prev_s, s) for _, prev_s in chosen):
            continue
        if _HYPE_RE.search(s) or _CTA_NOISE_RE.search(s) or _SOFT_FLUFF_RE.search(s):
            continue

        if total_words < SUMMARY_MIN or (total_words + wc) <= SUMMARY_MAX:
            chosen.append((i, s))
            total_words += wc

        if total_words >= SUMMARY_MIN and total_words >= SUMMARY_TARGET:
            break

    if not chosen:
        for s in sentences:
            if len(s.split()) >= 6:
                chosen.append((0, s))
                break

    chosen.sort(key=lambda x: x[0])

    if chosen:
        first_idx, first_sent = chosen[0]
        title_kw_set = set(w.lower() for w in _word_list(title or ""))
        first_kw = set(w.lower() for w in _word_list(first_sent))
        if len(title_kw_set & first_kw) < 1:
            for j in range(1, len(chosen)):
                _, cand_sent = chosen[j]
                cand_kw = set(w.lower() for w in _word_list(cand_sent))
                if len(title_kw_set & cand_kw) >= 1:
                    chosen[0], chosen[j] = chosen[j], chosen[0]
                    break

    while len(chosen) > 1:
        tail = chosen[-1][1]
        tail_wc = len(tail.split())
        if (
            tail_wc < 8
            or _AUX_TAIL_RE.search(tail)
            or _BAD_END_WORD.search(tail)
            or re.search(r"not\s+yet\s+officially\s+confirmed", tail, re.I)
            or re.search(r"currently\s+targeted", tail, re.I)
        ):
            chosen.pop()
            continue
        break

    while True:
        words_now = sum(len(s.split()) for _, s in chosen)
        if words_now <= SUMMARY_MAX or len(chosen) <= 1:
            break
        chosen.pop()

    return [s for _, s in chosen]

def summarize_story(title: str, body_text: str) -> str:
    sentences = _select_sentences(title, body_text)
    paragraph = _assemble_paragraph(sentences).strip()
    return paragraph

# =====================================================================
# HEADLINE GENERATION
# =====================================================================

def _shorten_title_chars(t: str, max_chars: int) -> str:
    t = t.strip()
    if len(t) <= max_chars:
        return t
    cut_limit = max_chars - 1
    if cut_limit < 1:
        return t[:max_chars]
    cut_at = t.rfind(" ", 0, cut_limit)
    if cut_at == -1:
        cut_at = cut_limit
    return t[:cut_at].rstrip(" ,;:-") + "…"

def _clean_source_title(raw_title: str) -> str:
    if not raw_title:
        return ""
    t = raw_title.strip()

    parts = _HEADLINE_SPLIT_RE.split(t)
    if parts:
        t = parts[0].strip()

    t = _HEADLINE_TAIL_RE.sub("", t).strip()
    t = _HEADLINE_HYPE_RE.sub("", t)
    t = _HEADLINE_FILLER_RE.sub("", t)

    t = re.sub(r"\s{2,}", " ", t).strip()
    t = re.sub(r"[\s\-\|:]+$", "", t).strip()

    fixed_words = [_clean_caps(w) for w in t.split()]
    t = " ".join(fixed_words).strip()

    if t and t[0].islower():
        t = t[0].upper() + t[1:]

    if t.endswith("?"):
        t = t[:-1].strip()

    return t

def _best_fact_sentence(title: str, body_text: str) -> str:
    clean_body = _preclean_body_text(body_text or "")
    if not clean_body:
        return ""
    sentences = [s.strip() for s in _SENT_SPLIT_RE.split(clean_body) if s.strip()]
    if not sentences:
        return ""

    title_kw = set(w.lower() for w in _word_list(title or ""))

    scored: List[Tuple[int, str]] = []
    for s in sentences:
        scored.append((_score_sentence(title_kw, s), s))
    scored.sort(key=lambda x: -x[0])

    for score, sent in scored:
        if score < 0:
            continue
        wc = len(sent.split())
        if wc < 4:
            continue
        polished = _polish_sentence(sent).strip()
        if polished.endswith("."):
            polished = polished[:-1].strip()
        if polished:
            return polished
    return ""

def generate_clean_title(raw_title: str, body_text: str) -> str:
    base = _clean_source_title(raw_title or "")
    too_short = len(base.split()) < 4
    if not base or too_short:
        fallback = _best_fact_sentence(raw_title, body_text)
        if fallback:
            base = fallback
    if not base:
        base = (raw_title or "").strip()

    base = re.sub(r"\s{2,}", " ", base).strip()
    base = _shorten_title_chars(base, HEADLINE_MAX_CHARS)
    base = re.sub(r"[.:;,\-–—]+$", "", base).strip()

    if base and base[0].islower():
        base = base[0].upper() + base[1:]
    return base

# =====================================================================
# LEGAL / SAFETY WRAPPERS (with on-air drama handling)
# =====================================================================

def _detect_risk_flags(title: str, body_text: str) -> Tuple[bool, bool, bool, Optional[str]]:
    """
    Returns:
        (is_risky, gossip_only, is_on_air, on_air_show_name)
    - is_risky: legal/PR heat or on-air confrontation (we'll attribute)
    - gossip_only: off-camera personal drama with no work context (will be dropped)
    - is_on_air: TV/OTT on-air drama (allowed, but still "risky" => attribution)
    """
    hay = f"{title or ''}\n{body_text or ''}"

    is_risky = bool(_RISKY_RE.search(hay))
    gossip_hit = bool(_GOSSIP_RE.search(hay))
    has_work_info = bool(_WORK_INFO_RE.search(hay))

    is_on_air, show = _detect_on_air_drama(title, body_text)

    # Off-camera gossip becomes "gossip_only" ONLY if it's not about work AND not on-air.
    gossip_only = gossip_hit and not has_work_info and not is_on_air

    # On-air drama is allowed, but handled with attribution → mark risky to enforce tone.
    if is_on_air:
        is_risky = True

    return (bool(is_risky), bool(gossip_only), bool(is_on_air), show)

def _soften_phrases(text: str) -> str:
    if not text:
        return text or ""
    repls: List[Tuple[re.Pattern, str]] = [
        (re.compile(r"\bwas\s+arrested\b", re.I), "was reportedly arrested"),
        (re.compile(r"\bwere\s+arrested\b", re.I), "were reportedly arrested"),
        (re.compile(r"\bwas\s+detained\b", re.I), "was reportedly detained"),
        (re.compile(r"\bwere\s+detained\b", re.I), "were reportedly detained"),
        (re.compile(r"\bin\s+custody\b", re.I), "in custody, according to reports"),
        (re.compile(r"\bfaces?\s+massive\s+backlash\b", re.I), "drew online reaction"),
        (re.compile(r"\bbacklash\b", re.I), "online reaction"),
        (re.compile(r"\bhuge\s+controversy\b", re.I), "a dispute"),
        (re.compile(r"\bcontroversy\b", re.I), "a dispute"),
        (re.compile(r"\bcontroversial\b", re.I), "disputed"),
        (re.compile(r"\bslammed\b", re.I), "criticized"),
        (re.compile(r"\bwent\s+viral\b", re.I), "was widely shared"),
        (re.compile(r"\b(leaked\s+chat)\b", re.I), "what is described as a leaked chat"),
        (re.compile(r"\b(leaked\s+video)\b", re.I), "what is described as a leaked video"),
    ]
    out = text
    for rx, rep in repls:
        out = rx.sub(rep, out)
    return re.sub(r"\s{2,}", " ", out).strip()

def _summary_attribution_prefix(source_domain: Optional[str], source_type: Optional[str]) -> str:
    st = (source_type or "").lower()
    dom = (source_domain or "").strip()
    if st.startswith("youtube"):
        return "A YouTube video claims:"
    if dom:
        return f"According to {dom}:"
    return "According to the report:"

def _headline_attribution_prefix(source_domain: Optional[str], source_type: Optional[str]) -> str:
    st = (source_type or "").lower()
    dom = (source_domain or "").strip()
    if st.startswith("youtube"):
        return "YouTube video claims:"
    if dom:
        return f"{dom}:"
    return "Report:"

def _build_on_air_headline(base: str, show: Optional[str], dom_prefix: str) -> str:
    """
    Prefer: "<Show>: heated on-air exchange reported (domain: Title…)" within char limit.
    But keep simple when needed.
    """
    show_part = (show or "On-air episode").strip()
    core = base
    # If base already contains the show name, don't repeat it twice.
    if show and re.search(re.escape(show), base, re.I):
        headline = f"{dom_prefix} {base}".strip() if dom_prefix else base
    else:
        # Try to prefix with "<Show>: <base>"
        candidate = f"{show_part}: {base}".strip()
        headline = f"{dom_prefix} {candidate}".strip() if dom_prefix else candidate
    headline = _shorten_title_chars(headline, HEADLINE_MAX_CHARS)
    headline = re.sub(r"[.:;,\-–—]+$", "", headline).strip()
    return headline

def summarize_story_safe(
    title: str,
    body_text: str,
    source_domain: Optional[str] = None,
    source_type: Optional[str] = None,
) -> Tuple[str, bool, bool]:
    """
    Safer wrapper around summarize_story().
    - Build neutral ~100-word paragraph.
    - Detect (is_risky, gossip_only, is_on_air).
    - If risky (including on-air), soften phrasing + prepend attribution.
    Returns: (safe_summary, is_risky, gossip_only)
    """
    base_summary = summarize_story(title, body_text)
    is_risky, gossip_only, is_on_air, _show = _detect_risk_flags(title, body_text)

    safe_summary = base_summary
    if is_risky:
        safe_summary = _soften_phrases(safe_summary)
        prefix = _summary_attribution_prefix(source_domain, source_type)
        if not re.match(r"^(According to|A YouTube video claims:)", safe_summary, re.I):
            safe_summary = f"{prefix} {safe_summary}"

    safe_summary = re.sub(r"\s{2,}", " ", safe_summary).strip()
    return (safe_summary, bool(is_risky), bool(gossip_only))

def generate_safe_title(
    raw_title: str,
    body_text: str,
    source_domain: Optional[str] = None,
    source_type: Optional[str] = None,
) -> Tuple[str, bool, bool]:
    """
    Safer wrapper around generate_clean_title().
    - Build clean, professional headline.
    - Detect (is_risky, gossip_only, is_on_air).
    - If risky & NOT on-air → short attribution prefix ("domain:", "YouTube video claims:")
    - If on-air → build "<Show>: <cleaned title>" and still apply domain prefix.
    Returns: (safe_headline, is_risky, gossip_only)
    """
    base_headline = generate_clean_title(raw_title, body_text)
    is_risky, gossip_only, is_on_air, show = _detect_risk_flags(raw_title, body_text)

    safe_headline = base_headline

    if is_on_air:
        prefix = _headline_attribution_prefix(source_domain, source_type)
        safe_headline = _build_on_air_headline(base_headline, show, prefix)
        safe_headline = _shorten_title_chars(safe_headline, HEADLINE_MAX_CHARS)
        safe_headline = re.sub(r"[.:;,\-–—]+$", "", safe_headline).strip()
        return (safe_headline, True, False)  # on-air is allowed; not gossip_only

    if is_risky:
        prefix = _headline_attribution_prefix(source_domain, source_type)

        already_attr = False
        core_prefix = (prefix[:-1].strip().lower() if prefix.endswith(":") else prefix.strip().lower())
        first_words = " ".join(base_headline.lower().split()[:3])
        if core_prefix and core_prefix in first_words:
            already_attr = True
        if base_headline.lower().startswith(("according to", "a youtube video claims")):
            already_attr = True

        if not already_attr:
            safe_headline = f"{prefix} {base_headline}"

        safe_headline = _shorten_title_chars(safe_headline, HEADLINE_MAX_CHARS)
        safe_headline = re.sub(r"[.:;,\-–—]+$", "", safe_headline).strip()

    return (safe_headline.strip(), bool(is_risky), bool(gossip_only))
