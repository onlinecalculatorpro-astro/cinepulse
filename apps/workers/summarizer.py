# apps/workers/summarizer.py
from __future__ import annotations

import os
import re
from typing import List, Tuple

# ============================= Config ================================
#
# These mirror the env knobs we had in jobs.py so you can tune length
# without touching code. If you want one source of truth, you can import
# these from here in jobs.py.

SUMMARY_TARGET = int(os.getenv("SUMMARY_TARGET_WORDS", "85"))
SUMMARY_MIN    = int(os.getenv("SUMMARY_MIN_WORDS", "60"))
SUMMARY_MAX    = int(os.getenv("SUMMARY_MAX_WORDS", "110"))

PASSTHROUGH_MAX_WORDS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_WORDS", "120"))
PASSTHROUGH_MAX_CHARS = int(os.getenv("SUMMARY_PASSTHROUGH_MAX_CHARS", "900"))

# Sentences with these imperatives are usually promo / CTA, not news.
_PROMO_PREFIX_RE = re.compile(
    r"^(watch|check\s+(this|it)\s+out|don['’]t\s+forget|don['’]t\s+miss|"
    r"follow\s+us|subscribe|hit\s+the\s+bell|like\s+and\s+share)\b",
    re.I,
)

# "Buy tickets now", "book now", "link in bio", etc.
_CTA_NOISE_RE = re.compile(
    r"\b(get\s+tickets?|book\s+now|buy\s+now|pre[- ]?order|"
    r"link\s+in\s+bio|watch\s+now|stream\s+now|order\s+now)\b",
    re.I,
)

# Words that can be safely lowercased if they show up in ALL CAPS.
# We *don't* downcase legit acronyms like IPL, FIFA, OTT, HBO.
_PROTECTED_ACRONYMS = {
    "IPL", "FIFA", "UCL", "UFC", "NBA", "NFL",
    "OTT", "IMAX", "HBO", "UHD", "4K",
    "AI", "VFX", "CGI",
}

# Break text into sentences on ., !, ? boundaries.
_SENT_SPLIT_RE = re.compile(r"(?<=[\.!?])\s+")

# Used to detect "weak tail" that feels unfinished.
_AUX_TAIL_RE = re.compile(
    r"\b(?:has|have|had|is|are|was|were|will|can|could|should|may|might|do|does|did)\b[\.…]*\s*$",
    re.I,
)

# Ending that shouldn't be final word.
_BAD_END_WORD = re.compile(
    r"\b(?:and|but|or|so|because|since|although|though|while|as)\.?$",
    re.I,
)

# Remove trailing ellipsis junk.
_DANGLING_ELLIPSIS_RE = re.compile(r"(?:…|\.{3})\s*$")

# ============================= Helpers ===============================

def _word_list(s: str) -> List[str]:
    return re.findall(r"[A-Za-z0-9]+", s)


def _score_sentence(title_kw: set[str], s: str) -> int:
    """
    Score how "summary-worthy" a sentence is.
    - Overlap with the title's keywords = relevance boost.
    - Presence of 'news verbs' = action boost.
    """
    if not s:
        return -10**9

    # Penalize blatant promo/CTA stuff immediately.
    if _PROMO_PREFIX_RE.search(s) or _CTA_NOISE_RE.search(s):
        return -10**8

    # Overlap with title keywords.
    overlap = len(title_kw.intersection(w.lower() for w in _word_list(s)))

    # Bonus if we see these event-style verbs.
    verb_bonus = 1 if re.search(
        r"\b(announce[ds]?|confirm(?:ed|s)?|revealed?|unveiled?|"
        r"premieres?|releasing?|release[sd]?|launch(?:es|ed)?|"
        r"wins?|beats?|defeats?|edges|stuns?|"
        r"signs?|joins?|cast[s]?|to\s+star|"
        r"injured|ruled\s+out|sidelined|"
        r"streaming\s+on|now\s+streaming|available\s+on)\b",
        s,
        re.I,
    ) else 0

    # Little bonus for having numbers (box office, scorelines).
    number_bonus = 1 if re.search(r"\b\d", s) else 0

    # Penalize extremely short or extremely long sentences.
    wc = len(s.split())
    length_penalty = 0
    if wc < 6:
        length_penalty -= 2
    if wc > 60:
        length_penalty -= 2

    return overlap * 2 + verb_bonus + number_bonus + length_penalty


def _clean_caps(word: str) -> str:
    """
    Downcase SCREAMING CAPS unless it's a protected acronym.
    e.g. "TRAILER" -> "Trailer", but "IPL" stays "IPL".
    """
    if len(word) <= 2:
        return word  # "To", "In", etc.
    if word.upper() == word and word.isalpha():
        if word.upper() in _PROTECTED_ACRONYMS:
            return word.upper()
        # "TRAILER" -> "Trailer"
        return word.capitalize()
    return word


def _polish_sentence(s: str) -> str:
    """
    Make a single sentence sound less like promo copy and more like news copy:
    - Drop 'Watch:' / 'Check this out:' intros.
    - Remove trailing junk like "..." or unfinished 'and/but'.
    - Normalize screaming caps.
    - Collapse whitespace.
    - Ensure it starts with a capital.
    - Ensure it ends with punctuation.
    """
    original = s.strip()

    # Strip leading promo-y command phrases ("Watch:", "Check this out:", etc.).
    s = re.sub(
        r"^(watch|check\s+this\s+out|check\s+it\s+out|don['’]t\s+miss|"
        r"don['’]t\s+forget\s+to\s+subscribe|subscribe\s+now)[:\-–]\s*",
        "",
        original,
        flags=re.I,
    ).strip()

    # Remove dangling marketing CTAs at the end.
    s = re.sub(r"(subscribe\s+for\s+more.*)$", "", s, flags=re.I).strip()
    s = re.sub(r"(follow\s+us.*)$", "", s, flags=re.I).strip()
    s = re.sub(r"(hit\s+the\s+bell.*)$", "", s, flags=re.I).strip()

    # Trim ellipsis / trailing "and"/"but"/"because" endings.
    s = _DANGLING_ELLIPSIS_RE.sub("", s).strip()
    s = _BAD_END_WORD.sub("", s).strip()
    s = _AUX_TAIL_RE.sub("", s).strip()

    # Lower/sanitize shouty ALL CAPS words unless protected.
    fixed_words = [_clean_caps(w) for w in s.split()]
    s = " ".join(fixed_words)

    # Normalize whitespace + stray punctuation spacing.
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"\s+([,.;!?])", r"\1", s)

    # Capitalize first char if not already.
    if s and s[0].islower():
        s = s[0].upper() + s[1:]

    # Add ending punctuation if missing.
    if s and s[-1] not in ".!?":
        s += "."

    return s


def _assemble_paragraph(chosen_sentences: List[str]) -> str:
    """
    Join chosen sentences into one paragraph, re-polishing the tail.
    """
    if not chosen_sentences:
        return ""

    # Polish each sentence individually.
    polished = [_polish_sentence(s) for s in chosen_sentences if s.strip()]
    text = " ".join(polished).strip()

    # Final cleanup: collapse any double spaces created during joins.
    text = re.sub(r"\s+", " ", text).strip()

    # Final punctuation safety.
    if text and text[-1] not in ".!?":
        text += "."

    return text


def _select_sentences(title: str, body_text: str) -> List[str]:
    """
    Core extractive summarization:
    - If body_text is already short enough, just return [body_text].
    - Else:
        - split into sentences
        - score them
        - pick best set in original order to hit SUMMARY_MIN..SUMMARY_TARGET
          and never exceed SUMMARY_MAX.
    """
    body_text = (body_text or "").strip()
    if not body_text:
        return [title.strip()]

    words_all = body_text.split()
    if (
        len(words_all) <= PASSTHROUGH_MAX_WORDS
        and len(body_text) <= PASSTHROUGH_MAX_CHARS
    ):
        # Body already concise enough: just use it raw (will still get polished later)
        return [body_text]

    # Build scored sentences
    sentences = [s.strip() for s in _SENT_SPLIT_RE.split(body_text) if s.strip()]
    if not sentences:
        return [body_text]

    title_kw = set(w.lower() for w in _word_list(title or ""))

    scored: List[Tuple[int, int, str]] = []
    for i, s in enumerate(sentences):
        score = _score_sentence(title_kw, s)
        scored.append((score, i, s))

    # sort highest score first
    scored.sort(key=lambda x: (-x[0], x[1]))

    # pick top ~10 indices as "interesting"
    pool_idx = {i for _, i, _ in scored[:10]}

    chosen: List[Tuple[int, str]] = []
    total_words = 0

    for i, s in enumerate(sentences):
        if i not in pool_idx:
            continue
        wc = len(s.split())
        if wc < 6:
            # tiny fragments often read badly in isolation
            continue

        # include if:
        # - we haven't hit our minimum yet OR
        # - adding it won't break SUMMARY_MAX
        if total_words < SUMMARY_MIN or (total_words + wc) <= SUMMARY_MAX:
            chosen.append((i, s))
            total_words += wc

        # stop early if we've crossed both minimum and target
        if total_words >= SUMMARY_MIN and total_words >= SUMMARY_TARGET:
            break

    if not chosen:
        # fallback: first halfway-decent sentence
        for s in sentences:
            if len(s.split()) >= 6:
                chosen.append((0, s))
                break

    # keep original order
    chosen.sort(key=lambda x: x[0])

    # soft-tail prune: if last sentence is super weak or trailing,
    # drop it to avoid ending with "and ..." or "He will".
    while len(chosen) > 1:
        tail = chosen[-1][1]
        tail_wc = len(tail.split())
        if tail_wc < 8 or _AUX_TAIL_RE.search(tail) or _BAD_END_WORD.search(tail):
            chosen.pop()
            continue
        break

    # enforce SUMMARY_MAX again in case pruning re-exposed long mid-sentence
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
    Main entry point for jobs.py.
    Returns a single polished paragraph summary.
    """
    sentences = _select_sentences(title, body_text)
    paragraph = _assemble_paragraph(sentences)
    return paragraph.strip()
