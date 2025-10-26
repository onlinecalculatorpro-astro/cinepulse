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
# keep it tight; avoid trailing fluff
SUMMARY_MAX    = int(os.getenv("SUMMARY_MAX_WORDS", "120"))

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
    r"^(watch|watch\s+now|check\s+(this|it)\s+out|don['']t\s+miss|"
    r"don['']t\s+forget|follow\s+us|subscribe|hit\s+the\s+bell|"
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

# Overhype / gossip / fan-reaction framing that we want to penalize hard.
_HYPE_RE = re.compile(
    r"\b(buzz(?:ing)?|internet\s+is\s+buzzing|fans\s+are\s+going\s+crazy|"
    r"fans\s+can['']t\s+keep\s+calm|internet\s+reacts|"
    r"massive\s+showdown|epic\s+clash|who(?:'|')ll\s+win|who\s+will\s+win|"
    r"promises\s+to\s+deliver|set(?:ting)?\s+the\s+stage\s+for\s+a\s+showdown|"
    r"blockbuster\s+in\s+the\s+making|taking\s+the\s+internet\s+by\s+storm|"
    r"poised\s+to\s+dominate|expected\s+to\s+shatter|"
    r"all\s+set\s+to\s+take\s+over)\b",
    re.I,
)

# Future hype / prediction lines we don't want in final paragraph.
_FUTURE_HYPE_RE = re.compile(
    r"\b(poised\s+to|expected\s+to|set\s+to\s+dominate|"
    r"all\s+set\s+to\s+take\s+over|will\s+set\s+the\s+box\s+office\s+on\s+fire)\b",
    re.I,
)

# Noise chunks / scrape artefacts we want to strip before sentence split.
_NOISE_CHUNK_RE_LIST = [
    # Photo credit junk
    re.compile(r"\(\s*photo\s+credit[^)]*\)", re.I),
    re.compile(r"\(\s*image(?:s)?\s+credit[^)]*\)", re.I),
    re.compile(r"\(\s*pic\s+credit[^)]*\)", re.I),
    # "Sunday Morning Report!" / "Morning Report!"
    re.compile(r"\b(morning\s+report!?)\b", re.I),
    re.compile(r"\b(sunday\s+morning\s+report!?)\b", re.I),
    # "Read Also:" / "Read More:" segments inside text
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

# Words that we allow to stay uppercase (acronyms/platforms).
_PROTECTED_ACRONYMS = {
    "IPL", "FIFA", "UCL", "UFC", "NBA", "NFL",
    "OTT", "IMAX", "HBO", "UHD", "4K",
    "AI", "VFX", "CGI",
    "PVR", "INOX",
    "SRK",
    "JIO", "JIOCINEMA", "JIOCINEMAA", "HOTSTAR", "NETFLIX",
}

# We like factual / numeric / distributional info.
# If a sentence has these, boost score.
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

# junk / tail clauses we don't want in card titles:
# e.g. "— How It Stacks Up Against...", "— Detailed Report Inside", etc.
_HEADLINE_TAIL_RE = re.compile(
    r"\s*(--|—|–|:|\||\?)\s*(how\s+it\s+stacks\s+up.*|"
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

# hype / clickbait adjectives we don't want IN the title at all
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

# generic split chars for multi-clause SEO headlines
_HEADLINE_SPLIT_RE = re.compile(r"\s+(--|—|–|-{2,}|\||:)\s+")

# strip filler words in titles too (same filler list as summary)
_HEADLINE_FILLER_RE = _FILLER_WORDS_RE

# =====================================================================
# LEGAL / DEFAMATION / GOSSIP RISK REGEX
# =====================================================================

# Anything that sounds like crime / raid / lawsuit / scandal / morality play.
_RISKY_RE = re.compile(
    r"\b("
    r"accused|allegations?|allegedly|arrested|detained|custody|in\s+custody|"
    r"police\s+custody|f\.?\s*i\.?\s*r\.?|FIR|police\s+complaint|police\s+case|"
    r"raid(?:ed)?|income\s+tax\s+raid|it\s+raid|ed\s+raid|ncb\s+raid|"
    r"drug\s+case|drugs?\s+case|narcotics|money\s+laundering|scam|fraud|"
    r"cheating\s+case|cheated|extortion|tax\s+evasion|"
    r"harass(?:ment|ed)?|abuse|misconduct|assault|violence|molestation|"
    r"backlash|boycott|trolled|slammed|controversy|controversial|leaked\s+chat|"
    r"leaked\s+video|leaked\s+audio|private\s+video|affair"
    r")\b",
    re.I,
)

# Pure gossip / personal-life / outrage bait
_GOSSIP_RE = re.compile(
    r"\b("
    r"affair|relationship|dating|spotted\s+together|"
    r"cheated\s+on|cheating\s+rumors?|split|break\s*up|divorce|"
    r"leaked\s+chat|leaked\s+video|private\s+video|"
    r"boycott|backlash|trolled|slammed|controversy|controversial"
    r")\b",
    re.I,
)

# Signals that this story is about work / release / business,
# which lets us keep it even if there is some "backlash" language.
_WORK_INFO_RE = re.compile(
    r"(box\s*office|collection[s]?\b|opening\s+weekend|₹\s?\d|"
    r"\b\d+(\.\d+)?\s*(crore|cr)\b|day\s+\d+\b|"
    r"release(?:d|s|ing)?\s+on|now\s+streaming|"
    r"\bon\s+(Netflix|Prime\s+Video|Jio\s*Cinema|Hotstar|Sony\s*LIV|Apple\s+TV\+|Max)\b|"
    r"\btrailer\b|\bteaser\b|\bcast\b|\bdirector\b|\bbox\s+office\b|"
    r"\bruntime\b|\bbudget\b|\bscreens\b|\bshowtimes?\b|\boccupancy\b)",
    re.I,
)

# =====================================================================
# Small helpers
# =====================================================================

def _word_list(s: str) -> List[str]:
    # Extract bare words/numbers for keyword overlap scoring.
    return re.findall(r"[A-Za-z0-9]+", s)


def _preclean_body_text(raw: str) -> str:
    """
    Remove scrape noise, credits, social plugs,
    and reader-bait questions like:
      "How much did it earn in 5 days?"
      "Will it cross 100 crore?"
      "What does this mean for X?"
    Collapse whitespace.
    """
    if not raw:
        return ""

    text = raw

    # Kill common junk chunks.
    for _pat in _NOISE_CHUNK_RE_LIST:
        text = _pat.sub(" ", text)

    # Drop clickbait / Q-style bait at the end.
    text = re.sub(
        r"(how\s+much\s+did\s+[^?]+\?\s*)$",
        " ",
        text,
        flags=re.I | re.M,
    )
    text = re.sub(
        r"(will\s+it\s+[^?]+\?\s*)$",
        " ",
        text,
        flags=re.I | re.M,
    )
    text = re.sub(
        r"(what\s+does\s+this\s+mean[^?]*\?\s*)$",
        " ",
        text,
        flags=re.I | re.M,
    )

    # Remove social handle fluff like "(Photo Credit – Instagram)".
    text = re.sub(r"\(\s*(photo|image|pic)[^)]+\)", " ", text, flags=re.I)

    # Remove obvious social plugs mid-body.
    text = re.sub(
        r"(follow\s+us\s+on\s+instagram[^\.!?]*[\.!?])",
        " ",
        text,
        flags=re.I,
    )

    # Remove vague time references that add no value
    text = re.sub(
        r"\b(recently|in\s+recent\s+times|lately)\b",
        "",
        text,
        flags=re.I,
    )

    # Collapse multiple spaces/newlines.
    text = re.sub(r"[\r\n\t]+", " ", text)
    text = re.sub(r"\s{2,}", " ", text).strip()

    return text


def _clean_caps(word: str) -> str:
    """
    Downcase scream-cased words unless they are in _PROTECTED_ACRONYMS.
    "TRAILER" -> "Trailer", but "OTT" stays "OTT".
    """
    if len(word) <= 2:
        return word  # "To", "In", etc.
    if word.upper() == word and word.isalpha():
        if word.upper() in _PROTECTED_ACRONYMS:
            return word.upper()
        return word.capitalize()
    return word


def _polish_sentence(s: str) -> str:
    """
    Clean up 1 sentence:
    - drop promo intros ("Watch:", "Check this out:")
    - kill CTA tails
    - trim dangling "and..." endings etc.
    - normalize CAPS -> Title except whitelisted acronyms
    - enforce starting capital & ending punctuation
    - remove filler words
    - normalize awkward phrasings
    """
    original = s.strip()

    # Strip leading promo-y prefixes.
    s = re.sub(
        r"^(watch|watch\s+now|check\s+this\s+out|check\s+it\s+out|"
        r"don['']t\s+miss|don['']t\s+forget\s+to\s+subscribe|"
        r"subscribe\s+now|exclusive\s*:)\s*",
        "",
        original,
        flags=re.I,
    ).strip()

    # Remove trailing CTA/subscribe lines.
    s = re.sub(r"(subscribe\s+for\s+more.*)$", "", s, flags=re.I).strip()
    s = re.sub(r"(follow\s+us.*)$", "", s, flags=re.I).strip()
    s = re.sub(r"(hit\s+the\s+bell.*)$", "", s, flags=re.I).strip()

    # Normalize awkward phrasings
    s = re.sub(r"\b(\d+)-day\s+([A-Z][a-z]+)\s+schedule\b", r"\1-day schedule in \2", s, re.I)
    s = re.sub(r"\btoo\s+slow\s+and\s+logistically\s+complex\b", "too complex to execute", s, re.I)
    s = re.sub(r"\brecently\s+completed\b", "completed", s, re.I)
    s = re.sub(r"\bcurrently\s+targeted[;,]?\s*the\s+date\s+is\s+not\s+yet\s+officially\s+confirmed\b", "targeted", s, re.I)
    s = re.sub(r"\bcurrently\s+targeted\b", "targeted", s, re.I)

    # Trim annoying tails like "and..." "but..." etc.
    s = _DANGLING_ELLIPSIS_RE.sub("", s).strip()
    s = _BAD_END_WORD.sub("", s).strip()
    s = _AUX_TAIL_RE.sub("", s).strip()

    # Remove filler words
    s = _FILLER_WORDS_RE.sub("", s)
    # Collapse multiple spaces after filler removal
    s = re.sub(r"\s+", " ", s).strip()

    # Normalize all-caps words.
    fixed_words = [_clean_caps(w) for w in s.split()]
    s = " ".join(fixed_words)

    # Whitespace & punctuation spacing.
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"\s+([,.;!?])", r"\1", s)

    # Start with capital.
    if s and s[0].islower():
        s = s[0].upper() + s[1:]

    # End with punctuation.
    if s and s[-1] not in ".!?":
        s += "."

    return s


def _similar_enough(a: str, b: str) -> bool:
    """
    Cheap de-dup. If two sentences are basically the same info,
    don't include both.
    We'll compare Jaccard overlap of word sets.
    """
    aw = set(w.lower() for w in _word_list(a))
    bw = set(w.lower() for w in _word_list(b))
    if not aw or not bw:
        return False
    inter = len(aw & bw)
    union = len(aw | bw)
    if union == 0:
        return False
    jacc = inter / union
    return jacc >= 0.7  # high overlap => basically duplicate


def _score_sentence(title_kw: set[str], s: str) -> int:
    """
    Score summary-worthiness:
    + overlap with title keywords
    + factual bonus (numbers, %, Day 5, release dates, platforms)
    + box office / performance verbs
    + clarity bonus for specific transitions
    - hype / gossip / CTA / promo / fluff
    - extreme length / extreme short
    - redundancy penalty
    """

    if not s:
        return -10**9

    # Hard penalties: promo / CTA / hype / fluff.
    if _PROMO_PREFIX_RE.search(s):
        return -10**8
    if _CTA_NOISE_RE.search(s):
        return -10**8
    if _HYPE_RE.search(s):
        return -10**7
    if _SOFT_FLUFF_RE.search(s):
        return -10**7

    # Title keyword overlap.
    overlap = len(title_kw.intersection(w.lower() for w in _word_list(s)))

    # Box-office / result / timing verbs etc.
    verb_bonus = 1 if re.search(
        r"\b(announce[ds]?|confirm(?:ed|s)?|revealed?|unveiled?|"
        r"premieres?|releasing?|release[sd]?|launch(?:es|ed)?|"
        r"earns?|earned|gross(?:ed|es)?|collect(?:ed|s)?|"
        r"beats?|surpass(?:ed|es)?|leads?|leads?\s+with|"
        r"occupancy|stream(?:s|ing)?\s+on|arrives?\s+on|"
        r"opens?\s+on|opens?\s+to|available\s+on)\b",
        s,
        re.I,
    ) else 0

    # Factual numeric bonus (money, %, day numbers, platforms, release dates).
    factual_bonus = 2 if _FACTUAL_BONUS_RE.search(s) else 0

    # Bonus for clear, specific phrasing
    clarity_bonus = 0
    if re.search(r"\b(instead|after|rather\s+than|in\s+place\s+of)\b", s, re.I):
        clarity_bonus += 1
    if re.search(r"\b(has\s+(built|filmed|completed|cancelled|dropped))\b", s, re.I):
        clarity_bonus += 1

    # Penalize leftover hype adjectives if somehow here.
    fluff_penalty = -1 if re.search(
        r"\b(huge|massive|epic|intense\s+clash|explosive\s+showdown)\b",
        s,
        re.I,
    ) else 0

    # Penalize redundant phrasing
    redundancy_penalty = 0
    if re.search(r"\b(currently\s+targeted|not\s+yet\s+officially\s+confirmed)\b", s, re.I):
        redundancy_penalty -= 2
    if re.search(r"\b(too\s+slow\s+and\s+logistically|too\s+slow\s+and)\b", s, re.I):
        redundancy_penalty -= 1

    wc = len(s.split())
    length_penalty = 0
    if wc < 6:
        length_penalty -= 2
    if wc > 60:
        length_penalty -= 2

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
    """
    Join chosen sentences into one paragraph and re-polish.
    - Drop future-hype ("poised to dominate", etc.)
    - Polish each sentence (caps, punctuation, trim fluff)
    - De-dupe again post-polish
    - Join into one paragraph
    """
    if not chosen_sentences:
        return ""

    interim: List[str] = []
    for s in chosen_sentences:
        s = s.strip()
        if not s:
            continue
        # drop predictive hype like "is poised to dominate"
        if _FUTURE_HYPE_RE.search(s):
            continue
        ps = _polish_sentence(s)
        if ps:
            interim.append(ps)

    # Deduplicate again after polish (polish can normalize two lines
    # into near-identical wording).
    final_sents: List[str] = []
    for s in interim:
        if not any(_similar_enough(s, prev) for prev in final_sents):
            final_sents.append(s)

    text = " ".join(final_sents).strip()
    text = re.sub(r"\s+", " ", text).strip()

    # Ensure final punctuation.
    if text and text[-1] not in ".!?":
        text += "."

    return text


def _select_sentences(title: str, body_text: str) -> List[str]:
    """
    Extractive summary:
    1. Pre-clean body text (remove junk / CTA / fan fluff).
    2. If body is extremely short, reuse it (polished later).
    3. Else:
        - split into sentences
        - score sentences for factual signal
        - pick best in ORIGINAL ARTICLE ORDER
        - ensure first sentence actually names the subject
        - cap around ~80-100 words
    """
    body_text = _preclean_body_text(body_text or "")
    if not body_text:
        # No body, fallback to title.
        t = (title or "").strip()
        return [t] if t else []

    # If already tweet-sized, just pass it through. We'll still polish later.
    words_all = body_text.split()
    if (
        len(words_all) <= PASSTHROUGH_MAX_WORDS
        and len(body_text) <= PASSTHROUGH_MAX_CHARS
    ):
        return [body_text]

    # Sentence split.
    sentences = [s.strip() for s in _SENT_SPLIT_RE.split(body_text) if s.strip()]
    if not sentences:
        return [body_text]

    title_kw = set(w.lower() for w in _word_list(title or ""))

    # Score each sentence.
    scored: List[Tuple[int, int, str]] = []
    for i, s in enumerate(sentences):
        score = _score_sentence(title_kw, s)
        scored.append((score, i, s))

    # Higher score first.
    scored.sort(key=lambda x: (-x[0], x[1]))

    # We'll take the top ~12 by score as our "interesting pool".
    candidate_idx = {i for _, i, _ in scored[:12]}

    # Walk original order, pick useful, stop near targets.
    chosen: List[Tuple[int, str]] = []
    total_words = 0

    for i, s in enumerate(sentences):
        if i not in candidate_idx:
            continue

        wc = len(s.split())
        if wc < 6:
            # Fragment, skip.
            continue

        # Don't add near-duplicates.
        duplicate = False
        for _, prev_s in chosen:
            if _similar_enough(prev_s, s):
                duplicate = True
                break
        if duplicate:
            continue

        # Skip if still mostly hype.
        if _HYPE_RE.search(s) or _CTA_NOISE_RE.search(s) or _SOFT_FLUFF_RE.search(s):
            continue

        # Add it if:
        #   - we haven't hit SUMMARY_MIN yet
        #   OR adding it doesn't blow SUMMARY_MAX
        if total_words < SUMMARY_MIN or (total_words + wc) <= SUMMARY_MAX:
            chosen.append((i, s))
            total_words += wc

        # Stop if we've reached both MIN and TARGET.
        if total_words >= SUMMARY_MIN and total_words >= SUMMARY_TARGET:
            break

    # Fallback: if somehow nothing got chosen, grab first decent sentence.
    if not chosen:
        for s in sentences:
            if len(s.split()) >= 6:
                chosen.append((0, s))
                break

    # Sort back to original article order.
    chosen.sort(key=lambda x: x[0])

    # Ensure the first sentence actually references the subject/title.
    if chosen:
        first_idx, first_sent = chosen[0]
        first_kw = set(w.lower() for w in _word_list(first_sent))
        if len(title_kw & first_kw) < 1:
            # try to swap with a later sentence that DOES include a title keyword
            for j in range(1, len(chosen)):
                _, cand_sent = chosen[j]
                cand_kw = set(w.lower() for w in _word_list(cand_sent))
                if len(title_kw & cand_kw) >= 1:
                    chosen[0], chosen[j] = chosen[j], chosen[0]
                    break

    # Tail prune:
    # Drop weak last sentence if it's super short, trails off,
    # or ends with redundant info.
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

    # Hard enforce SUMMARY_MAX by trimming from the end.
    while True:
        words_now = sum(len(s.split()) for _, s in chosen)
        if words_now <= SUMMARY_MAX:
            break
        if len(chosen) <= 1:
            break
        chosen.pop()

    return [s for _, s in chosen]


def summarize_story(title: str, body_text: str) -> str:
    """
    Public entry point.
    Returns a single polished paragraph ~80-100 words,
    neutral, trade-style, no hype.
    """
    sentences = _select_sentences(title, body_text)
    paragraph = _assemble_paragraph(sentences).strip()
    return paragraph


# =====================================================================
# HEADLINE GENERATION
# =====================================================================

def _shorten_title_chars(t: str, max_chars: int) -> str:
    """
    Trim headline to max_chars gracefully.
    We prefer cutting at the last space and adding "…".
    """
    t = t.strip()
    if len(t) <= max_chars:
        return t
    # leave a little room for the ellipsis
    cut_limit = max_chars - 1
    if cut_limit < 1:
        return t[:max_chars]
    cut_at = t.rfind(" ", 0, cut_limit)
    if cut_at == -1:
        cut_at = cut_limit
    return t[:cut_at].rstrip(" ,;:-") + "…"


def _clean_source_title(raw_title: str) -> str:
    """
    Take the scraped headline and strip clickbait tails, hype words,
    filler, and SEO junk. Keep it factual. Keep money / day counts etc.
    """
    if not raw_title:
        return ""

    t = raw_title.strip()

    # If it's an SEO Frankenstein like "Movie Title | Box Office Update",
    # split on separators and keep first factual clause.
    parts = _HEADLINE_SPLIT_RE.split(t)
    if parts:
        # parts is like ["Movie Title", "|", "Box Office Update"]
        # we want the first textual chunk
        t = parts[0].strip()

    # Drop trailing "— How It Stacks Up..." / "— Full Report Inside" etc.
    t = _HEADLINE_TAIL_RE.sub("", t).strip()

    # Remove hype-y adjectives ("goes viral", "insane", etc.)
    t = _HEADLINE_HYPE_RE.sub("", t)

    # Remove filler words ("really", "very", "just", etc.)
    t = _HEADLINE_FILLER_RE.sub("", t)

    # Collapse extra whitespace after removals
    t = re.sub(r"\s{2,}", " ", t).strip()

    # Remove trailing punctuation like ":" "|" "-" "?" etc.
    t = re.sub(r"[\s\-\|:]+$", "", t).strip()

    # Normalize case for SHOUTY words but keep acronyms
    fixed_words = [_clean_caps(w) for w in t.split()]
    t = " ".join(fixed_words).strip()

    # Ensure first char uppercase
    if t and t[0].islower():
        t = t[0].upper() + t[1:]

    # Drop ending "?" if it's just clickbait ("Will X Beat Y?")
    # Replace with neutral factual framing if it's purely speculative.
    if t.endswith("?"):
        t = t[:-1].strip()

    return t


def _best_fact_sentence(title: str, body_text: str) -> str:
    """
    As a fallback for headlines: grab the single highest-scoring,
    most factual sentence from the article body.
    We'll polish it, then strip final period for headline style.
    """
    clean_body = _preclean_body_text(body_text or "")
    if not clean_body:
        return ""

    sentences = [s.strip() for s in _SENT_SPLIT_RE.split(clean_body) if s.strip()]
    if not sentences:
        return ""

    title_kw = set(w.lower() for w in _word_list(title or ""))

    scored: List[Tuple[int, str]] = []
    for s in sentences:
        sc = _score_sentence(title_kw, s)
        scored.append((sc, s))

    # sort best-first
    scored.sort(key=lambda x: -x[0])

    for score, sent in scored:
        if score < 0:
            # it's all garbage/hype? bail
            continue
        wc = len(sent.split())
        if wc < 4:
            continue
        # polish it into professional tone
        polished = _polish_sentence(sent).strip()
        if polished.endswith("."):
            polished = polished[:-1].strip()
        if polished:
            return polished

    return ""


def generate_clean_title(raw_title: str, body_text: str) -> str:
    """
    Public entry point for card headline.
    Rules:
    - Aim for clean, professional, factual.
    - Keep numbers, performance metrics, platform, release/box office info.
    - Remove hype, fan reaction, questions/teasers.
    - <= HEADLINE_MAX_CHARS.
    - If source title is useless after cleaning, fall back to factual
      best sentence from body.
    """
    base = _clean_source_title(raw_title or "")

    # If base is empty or too generic, try fallback from article body
    too_short = len(base.split()) < 4  # e.g. "Big Update From X"
    if not base or too_short:
        fallback = _best_fact_sentence(raw_title, body_text)
        if fallback:
            base = fallback

    # Safety: if it's STILL empty, use raw_title minimal
    if not base:
        base = (raw_title or "").strip()

    # Final whitespace cleanup
    base = re.sub(r"\s{2,}", " ", base).strip()

    # Final length cap
    base = _shorten_title_chars(base, HEADLINE_MAX_CHARS)

    # Avoid trailing punctuation that looks sloppy in cards
    base = re.sub(r"[.:;,\-–—]+$", "", base).strip()

    # Capitalize first char if needed
    if base and base[0].islower():
        base = base[0].upper() + base[1:]

    return base


# =====================================================================
# LEGAL / SAFETY WRAPPERS
# =====================================================================

def _detect_risk_flags(title: str, body_text: str) -> Tuple[bool, bool]:
    """
    Detect if the story has legal/PR heat and whether it's basically just gossip.

    Returns:
        (is_risky, gossip_only)

        is_risky:
            True if mentions arrests, raids, FIR, leaked chats, boycott, etc.
            Any stuff that can get us in trouble if we assert it as fact.

        gossip_only:
            True if it's basically relationship/backlash/leaked-chat drama
            AND there's no work/box-office/release/platform info to ground it
            in professional reporting.
    """
    hay = f"{title or ''}\n{body_text or ''}"

    is_risky = bool(_RISKY_RE.search(hay))

    gossip_hit = bool(_GOSSIP_RE.search(hay))
    has_work_info = bool(_WORK_INFO_RE.search(hay))

    gossip_only = gossip_hit and not has_work_info

    return (is_risky, gossip_only)


def _soften_phrases(text: str) -> str:
    """
    Tone down language to avoid sounding like we're asserting guilt,
    huge moral outrage, etc. We lean on 'reportedly', 'online reaction',
    'dispute', 'criticized', etc.
    """
    if not text:
        return text or ""

    repls: List[Tuple[re.Pattern, str]] = [
        (re.compile(r"\bwas\s+arrested\b", re.I), "was reportedly arrested"),
        (re.compile(r"\bwere\s+arrested\b", re.I), "were reportedly arrested"),
        (re.compile(r"\bwas\s+detained\b", re.I), "was reportedly detained"),
        (re.compile(r"\bwere\s+detained\b", re.I), "were reportedly detained"),
        (re.compile(r"\bin\s+custody\b", re.I), "in custody, according to reports"),
        (re.compile(r"\bfacing\s+massive\s+backlash\b", re.I), "drew online reaction"),
        (re.compile(r"\bfaces\s+massive\s+backlash\b", re.I), "drew online reaction"),
        (re.compile(r"\bfaces\s+backlash\b", re.I), "drew online reaction"),
        (re.compile(r"\bmassive\s+backlash\b", re.I), "online reaction"),
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

    # Collapse doubled spaces from replacements
    out = re.sub(r"\s{2,}", " ", out).strip()
    return out


def _summary_attribution_prefix(source_domain: Optional[str], source_type: Optional[str]) -> str:
    """
    Build a short prefix for risky stories so we attribute, not assert.
    """
    st = (source_type or "").lower()
    dom = (source_domain or "").strip()

    if st.startswith("youtube"):
        return "A YouTube video claims:"
    if dom:
        return f"According to {dom}:"
    return "According to the report:"


def _headline_attribution_prefix(source_domain: Optional[str], source_type: Optional[str]) -> str:
    """
    Build an even shorter prefix for headlines (char budget matters).
    We still try to indicate attribution instead of asserting.
    """
    st = (source_type or "").lower()
    dom = (source_domain or "").strip()

    if st.startswith("youtube"):
        return "YouTube video claims:"
    if dom:
        # `example.com:` is short and clearly attributional
        return f"{dom}:"
    return "Report:"


def summarize_story_safe(
    title: str,
    body_text: str,
    source_domain: Optional[str] = None,
    source_type: Optional[str] = None,
) -> Tuple[str, bool, bool]:
    """
    Safer wrapper around summarize_story().

    Steps:
    - Build normal factual ~100-word paragraph.
    - Detect 'is_risky' and 'gossip_only'.
    - If is_risky, soften phrasing + prepend attribution
      ("According to <domain>: ...", "A YouTube video claims: ...").

    Returns:
        (safe_summary, is_risky, gossip_only)
    """
    base_summary = summarize_story(title, body_text)
    is_risky, gossip_only = _detect_risk_flags(title, body_text)

    safe_summary = base_summary

    if is_risky:
        safe_summary = _soften_phrases(safe_summary)

        prefix = _summary_attribution_prefix(source_domain, source_type)
        # If base_summary already begins with "According to" etc.
        # don't double-prefix. We'll detect a leading "According to".
        if not re.match(r"^(According to|A YouTube video claims:)", safe_summary, re.I):
            safe_summary = f"{prefix} {safe_summary}"

    # Final whitespace cleanup
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

    Steps:
    - Build normal cleaned, professional headline.
    - Detect 'is_risky' and 'gossip_only'.
    - If is_risky, prefix attribution ("YouTube video claims:", "<domain>:")
      so we don't assert the claim as our own.
    - Enforce HEADLINE_MAX_CHARS after adding prefix.

    Returns:
        (safe_headline, is_risky, gossip_only)
    """
    base_headline = generate_clean_title(raw_title, body_text)

    is_risky, gossip_only = _detect_risk_flags(raw_title, body_text)

    safe_headline = base_headline

    if is_risky:
        prefix = _headline_attribution_prefix(source_domain, source_type)

        # avoid double-prefix if the cleaned title already starts with that domain or "YouTube"
        already_attr = False
        if prefix.endswith(":"):
            core_prefix = prefix[:-1].strip().lower()
        else:
            core_prefix = prefix.strip().lower()

        first_words = " ".join(base_headline.lower().split()[:3])
        if core_prefix and core_prefix in first_words:
            already_attr = True
        if base_headline.lower().startswith("according to"):
            already_attr = True
        if base_headline.lower().startswith("a youtube video claims"):
            already_attr = True

        if not already_attr:
            safe_headline = f"{prefix} {base_headline}"

        # length cap again after prefix
        safe_headline = _shorten_title_chars(safe_headline, HEADLINE_MAX_CHARS)

        # clean sloppy trailing punctuation again
        safe_headline = re.sub(r"[.:;,\-–—]+$", "", safe_headline).strip()

    return (safe_headline.strip(), bool(is_risky), bool(gossip_only))
