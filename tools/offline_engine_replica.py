#!/usr/bin/env python3
"""Faithful Python replica of SongFinisher's offline lyric pipeline.

Ports LexiconStore (SFLX v1), SeededRandom (SplitMix64), StressPatternIndex,
TemplateBank, PhraseAssembler, SuggestionRanker, and OfflineLyricProvider's
candidate flow, so generation behavior can be exercised and *tuned* on a
machine with no Swift toolchain (e.g. a Linux cloud session). The `fixed`
flag flips between the pre- and post-cleanup behavior so before/after output
can be compared side by side; an optional third mode approximates the
build_lexicon.py proper-noun fix using the system word list.

NOT the source of truth: PhraseAssembler.swift is. If the Swift scoring or
guards change, mirror the change here or the comparison lies. Output is
representative rather than bit-identical to the app (Swift's unstable sort
and shuffle break ties differently), but logic, scoring, and guards are
line-for-line the same.

Run:  python3 tools/offline_engine_replica.py \
          Packages/LyricEngine/Sources/LyricEngine/Resources/lexicon.bin
"""

import struct
import sys

MASK64 = (1 << 64) - 1

# ── SeededRandom (SplitMix64) ────────────────────────────────────────────────

class SeededRandom:
    def __init__(self, seed):
        self.state = seed & MASK64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return (z ^ (z >> 31)) & MASK64

    # Swift's RandomNumberGenerator.next(upperBound:) — Lemire with rejection.
    def next_upper(self, upper):
        random = self.next()
        m = random * upper
        low = m & MASK64
        if low < upper:
            t = ((1 << 64) - upper) % upper
            while low < t:
                random = self.next()
                m = random * upper
                low = m & MASK64
        return m >> 64


def swift_shuffle(arr, rng):
    """Swift's Collection.shuffle(using:) — forward Fisher–Yates."""
    amount = len(arr)
    current = 0
    while amount > 1:
        r = rng.next_upper(amount)
        amount -= 1
        arr[current], arr[current + r] = arr[current + r], arr[current]
        current += 1


def fnv(text):
    h = 0xCBF29CE484222325
    for b in text.encode():
        h = ((h ^ b) * 0x100000001B3) & MASK64
    return h

# ── POS bits ─────────────────────────────────────────────────────────────────

NOUN, PLURAL, VERB, ADJ, ADV = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4
CONJ, PREP, INTERJ, PRON, ARTICLE, NP = 1 << 5, 1 << 6, 1 << 7, 1 << 8, 1 << 9, 1 << 10
CONTENT = NOUN | PLURAL | VERB | ADJ | ADV | INTERJ

# ── LexiconStore ─────────────────────────────────────────────────────────────

class Entry:
    __slots__ = ("index", "text", "syllables", "stress", "openb", "pos",
                 "zipf", "valence", "cluster", "rhyme")

    def __init__(self, index, text, syllables, stress, openb, pos, zipf, valence, cluster, rhyme):
        self.index, self.text, self.syllables = index, text, syllables
        self.stress, self.openb, self.pos = stress, openb, pos
        self.zipf, self.valence, self.cluster, self.rhyme = zipf, valence, cluster, rhyme

    def is_stressed(self, i):
        return bool(self.stress & (1 << i))


class LexiconStore:
    def __init__(self, path):
        data = open(path, "rb").read()
        magic, version, n, strings_off, strings_len = struct.unpack_from("<4sIIII", data, 0)
        assert magic == b"SFLX" and version == 1
        cur = 32
        offsets = struct.unpack_from(f"<{n + 1}I", data, cur); cur += (n + 1) * 4
        syl = struct.unpack_from(f"<{n}B", data, cur); cur += n
        stress = struct.unpack_from(f"<{n}H", data, cur); cur += n * 2
        openb = struct.unpack_from(f"<{n}H", data, cur); cur += n * 2
        pos = struct.unpack_from(f"<{n}H", data, cur); cur += n * 2
        zipf = struct.unpack_from(f"<{n}B", data, cur); cur += n
        val = struct.unpack_from(f"<{n}b", data, cur); cur += n
        cluster = struct.unpack_from(f"<{n}B", data, cur); cur += n
        rhyme = struct.unpack_from(f"<{n}I", data, cur); cur += n * 4
        assert cur == strings_off, (cur, strings_off)
        blob = data[strings_off:strings_off + strings_len]
        self.entries = []
        self.by_text = {}
        for i in range(n):
            text = blob[offsets[i]:offsets[i + 1]].decode()
            e = Entry(i, text, syl[i], stress[i], openb[i], pos[i],
                      zipf[i] / 20.0, val[i] / 25.0, cluster[i], rhyme[i])
            self.entries.append(e)
            self.by_text[text] = e
        self.count = n

    def lookup(self, word):
        return self.by_text.get(word.lower())

# ── StressPatternIndex ───────────────────────────────────────────────────────

class StressPatternIndex:
    def __init__(self, store):
        self.store = store
        buckets = {}
        for e in store.entries:
            if e.syllables > 8:
                continue
            bits = e.pos
            while bits:
                bit = bits & (-bits)
                bits &= bits - 1
                buckets.setdefault((e.syllables, bit), []).append(e.index)
        for key, idxs in buckets.items():
            idxs.sort(key=lambda i: -store.entries[i].zipf)
        self.buckets = buckets

    def top_candidates(self, syllables, pos, limit, extra_random, rng):
        out = []
        bits = pos
        while bits:
            bit = bits & (-bits)
            bits &= bits - 1
            bucket = self.buckets.get((syllables, bit))
            if not bucket:
                continue
            head = min(limit, len(bucket))
            out.extend(bucket[:head])
            if len(bucket) > head and extra_random > 0:
                for _ in range(extra_random):
                    pick = rng.next() % (len(bucket) - head) + head
                    out.append(bucket[pick])
        return out

# ── TemplateBank ─────────────────────────────────────────────────────────────

SUBJECTS_OLD = ["I", "you", "we", "they", "she", "he"]
SUBJECTS_NEW = ["I", "you", "we", "they"]
SUBJECTS = SUBJECTS_NEW  # rebound per assembler mode in make_templates()
ARTICLES = ["the", "a", "this", "that", "my", "your", "our", "her", "his"]
ENDERS = ["again", "tonight", "away", "alone", "somehow", "for now", "at last", "inside"]

def P(cat): return ("pos", cat)
def O(words): return ("oneOf", words)

def make_raw_templates(new):
    S = SUBJECTS_NEW if new else SUBJECTS_OLD
    t = [
        [O(S), P(VERB), O(ARTICLES), P(NOUN)],
        [O(S), P(VERB), P(PREP), O(ARTICLES), P(NOUN)],
        [O(S), P(VERB), O(ARTICLES), P(ADJ), P(NOUN)],
        [O(S), P(ADV), P(VERB), O(ARTICLES), P(NOUN)],
        [O(S), P(VERB), O(ENDERS)],
        [O(S), P(VERB), P(PLURAL)],
        [O(["I'm", "you're", "we're"]), P(ADJ), O(ENDERS)],
        [O(["I'll", "you'll", "we'll"]), P(VERB), O(ARTICLES), P(NOUN)],
        [O(["don't", "can't", "won't"]), P(VERB), O(ARTICLES), P(NOUN)],
        ([O(["the", "my", "your", "our", "her", "his", "these", "those"]), P(PLURAL), P(VERB), O(ENDERS)]
         if new else [O(ARTICLES), P(NOUN), P(VERB), O(ENDERS)]),
        [O(ARTICLES), P(NOUN), P(PREP), O(ARTICLES), P(NOUN)],
        [P(ADJ), P(NOUN), P(PREP), O(ARTICLES), P(NOUN)],
        [O(ARTICLES), P(ADJ), P(NOUN)],
        [P(PLURAL), P(PREP), O(ARTICLES), P(NOUN)],
        [P(NOUN), O(["and"]), P(NOUN), O(ENDERS)],
        [O(["all", "half"]), P(PREP), O(ARTICLES), P(PLURAL)],
        [P(VERB), O(["me", "us", "it"]), O(ENDERS)],
        [P(VERB), O(ARTICLES), P(NOUN), O(ENDERS)],
        [P(VERB), P(PREP), O(ARTICLES), P(NOUN)],
        [O(["oh", "so", "still", "now"]), O(S), P(VERB), O(ARTICLES), P(NOUN)],
        [P(PREP), O(ARTICLES), P(NOUN), O(S), P(VERB)],
        [P(PREP), O(ARTICLES), P(ADJ), P(NOUN)],
        [P(PREP), P(PLURAL), O(["and"]), P(PLURAL)],
        [O(ARTICLES), P(NOUN), O(["is", "was"]), P(ADJ)],
    ]
    if new:
        t.append([O(["I"]), O(["am", "was"]), P(ADV), P(ADJ)])
        t.append([O(["you", "we", "they"]), O(["are", "were"]), P(ADV), P(ADJ)])
        t.append([O(["she", "he"]), O(["is", "was"]), P(ADV), P(ADJ)])
    else:
        t.append([O(SUBJECTS_OLD), O(["was", "were", "am", "are"]), P(ADV), P(ADJ)])
    t.append([O(["it's", "there's"]), O(ARTICLES), P(ADJ), P(NOUN)])
    return t

def template_bounds(slots):
    mn = mx = 0
    for kind, val in slots:
        if kind == "pos":
            mn += 1; mx += 4
        else:
            mn += 1
            mx += 3 if any(" " in w for w in val) else 2
    return mn, mx

def make_templates(new):
    return [(slots, *template_bounds(slots)) for slots in make_raw_templates(new)]

# ── PhraseAssembler ──────────────────────────────────────────────────────────

BEAM_WIDTH = 12
CANDIDATES_PER_SLOT = 24
EXTRA_REACH = 12
EVOCATIVE_PEAK = 3.8
FAST_NOTE_MS = 180

STOP_WORDS = {
    "a", "a's", "an", "the", "and", "or", "but", "nor", "so", "yet",
    "of", "to", "in", "on", "at", "by", "for", "with", "as", "than", "then",
    "is", "was", "are", "were", "am", "be", "been", "being",
    "do", "does", "did", "done", "has", "have", "had", "having",
    "will", "would", "shall", "should", "can", "could", "may", "might", "must",
    "i", "you", "he", "she", "we", "they", "it", "me", "him", "us", "them",
    "my", "your", "his", "her", "its", "our", "their",
    "mine", "yours", "ours", "theirs", "hers", "myself", "yourself",
    "this", "that", "these", "those", "who", "whom", "whose", "which", "what",
    "not", "no", "if", "there", "here", "such", "very", "too",
}

EXCLUDED = {
    "piss", "pissed", "shit", "shitty", "fuck", "fucked", "fucking",
    "cum", "cock", "dick", "tits", "whore", "slut", "bitch", "bitches",
    "bastard", "asshole", "ass", "asses",
}


TRIGGER_STATES = {
    "joyful_release": {
        "breathe","open","light","air","sky","wide","clear","free","loose","expand",
        "finally","away","rise","fly","lift","home","safe","found","whole","settled",
        "arrived","won","standing","alive","survived","soft","warm","held","quiet","resting",
    },
    "heartbreak_hold": {
        "quiet","still","empty","hollow","cold","frozen","flat","dim",
        "gone","missing","space","lost","hold","wait","alone","inside",
        "heavy","ache","numb","slow","tight","sinking","stone","low","pressed",
        "black","dead","stripped",
    },
    "tension_spiral": {
        "faster","louder","higher","harder","rising","building","climbing",
        "tighter","closer","pushing","pulling","breaking","cracking","walls","weight",
        "again","quick","burn","crash","snap","shatter","fall","splinter","collapse",
        "watch","creep","dark","breathe","stop","help","please",
    },
    "hope_return": {
        "maybe","almost","barely","softer","brighter","lighter","warmer","dawn",
        "crack","edge","find","start","turning","waking","beginning",
        "small","slow","careful","first","new","gentle","emerging","faint","thread","learning",
    },
    "final_resolve": {
        "finished","complete","whole","end","final","closed","know","true","real",
        "clear","certain","sure","honest","rest","peace","still","calm","home",
        "settled","quiet","forever","earned","claimed","released","survived","standing","won",
    },
}
EMOTION_STATE = {
    "joy": "joyful_release", "release": "joyful_release",
    "melancholy": "heartbreak_hold", "longing": "heartbreak_hold", "nostalgia": "heartbreak_hold",
    "tension": "tension_spiral", "hope": "hope_return", "reflection": "final_resolve",
}
def trigger_words(emotion):
    return TRIGGER_STATES[EMOTION_STATE[emotion]]

EMOTION_VALENCE = {
    "joy": 3.0, "hope": 2.5, "release": 1.5, "nostalgia": -0.5,
    "reflection": -0.25, "longing": -1.0, "tension": -1.5, "melancholy": -2.5,
}


class Line:
    __slots__ = ("text", "syllables", "stress", "prosody", "fluency", "emotion", "content")

    def __init__(self, text, syllables, stress, prosody, fluency, emotion, content):
        self.text, self.syllables, self.stress = text, syllables, stress
        self.prosody, self.fluency, self.emotion, self.content = prosody, fluency, emotion, content


class Assembler:
    def __init__(self, store, index, fixed=True):
        self.store = store
        self.index = index
        self.fixed = fixed   # False = behavior before PR #2's guards + slot fixes
        self.templates = make_templates(new=fixed)

    def is_acceptable(self, line):
        if not line.content:
            return False
        words = [w.lower() for w in line.text.split(" ")]
        if not words:
            return False
        if words[-1] in STOP_WORDS:
            return False
        if self.fixed:
            if len(set(words)) != len(words):
                return False
            for w, nxt in zip(words, words[1:]):
                if w == "a" and nxt[:1] in "aeiou":
                    return False
                if w in ("a", "an", "this", "that") and nxt.endswith("s"):
                    e = self.store.lookup(nxt)
                    if e is not None and (e.pos & PLURAL):
                        return False
        return True

    def assemble(self, spec, target, seed, pool_target):
        pattern = pad(spec["pattern"], target)
        long_slots = set(spec.get("long_slots", ()))
        durations = spec.get("durations", [400] * target)
        emo = spec.get("override") or spec["emotion"]
        tv = EMOTION_VALENCE[emo]
        trig = trigger_words(emo) if self.fixed else frozenset()
        rng = SeededRandom(seed)
        templates = [t for t in self.templates if t[1] <= target <= t[2]]
        swift_shuffle(templates, rng)
        pool, seen = [], set()
        for slots, _, _ in templates:
            if len(pool) >= pool_target:
                break
            for line in self.fill(slots, pattern, long_slots, durations, tv, trig, rng):
                if self.is_acceptable(line) and line.text not in seen:
                    seen.add(line.text)
                    pool.append(line)
        return pool

    def expansions(self, slot, rng):
        kind, val = slot
        if kind == "oneOf":
            out = [self.resolve_literal(w) for w in val]
            return [e for e in out if e is not None]
        is_content = bool(val & CONTENT)
        reach = EXTRA_REACH if (is_content or not self.fixed) else 0
        out = []
        for syll in range(1, 5):
            for i in self.index.top_candidates(syll, val, CANDIDATES_PER_SLOT, reach, rng):
                e = self.store.entries[i]
                if is_content and e.text in STOP_WORDS:
                    continue
                if self.fixed and is_content and (len(e.text) == 1 or e.text in EXCLUDED):
                    continue
                if self.fixed and not (val & ARTICLE) and (e.pos & ARTICLE):
                    continue
                if self.fixed and (val & VERB) and e.syllables >= 2 and \
                        (e.text.endswith("ing") or e.text.endswith("ed")):
                    continue
                out.append(e)
        return out

    def resolve_literal(self, literal):
        words = literal.lower().split(" ")
        if len(words) == 1:
            return self.store.lookup(words[0])
        stress = openb = syllables = cluster = 0
        valence = 0.0
        zipf = float("inf")
        for w in words:
            e = self.store.lookup(w)
            if e is None:
                return None
            stress |= (e.stress << syllables) & 0xFFFF
            openb |= (e.openb << syllables) & 0xFFFF
            syllables += e.syllables
            valence += e.valence
            zipf = min(zipf, e.zipf)
            cluster = max(cluster, e.cluster)
        last = self.store.lookup(words[-1])
        return Entry(-1, literal.lower(), syllables, stress, openb, 0,
                     zipf, valence / len(words), cluster, last.rhyme)

    def position_score(self, e, p, pattern, long_slots, durations, trig, rng):
        score = 0.0
        for j in range(e.syllables):
            slot = p + j
            if slot >= len(pattern):
                break
            stressed = e.is_stressed(j)
            strong = pattern[slot] == "S"
            if stressed and strong: score += 1.0
            elif not stressed and not strong: score += 0.4
            elif stressed and not strong: score -= 0.6
            else: score -= 0.3
            if slot in long_slots:
                score += 0.6 if (e.openb >> j) & 1 else -0.4
            if slot < len(durations) and durations[slot] < FAST_NOTE_MS and e.cluster >= 3:
                score -= 0.4
        score += max(0.0, 0.3 - abs(e.zipf - EVOCATIVE_PEAK) * 0.15)
        if self.fixed and (e.pos & CONTENT):
            score += min(0.25, abs(e.valence) * 0.15)
        if e.text in trig and (e.pos & CONTENT) and e.text not in STOP_WORDS:
            score += 0.25
        score += (rng.next() % 100) / 2000.0
        return score

    def fill(self, slots, pattern, long_slots, durations, tv, trig, rng):
        n = len(pattern)
        beam = [(0, 0, (), 0.0)]   # slotIndex, syllablePosition, entries, score
        completed = []
        while beam:
            nxt = []
            for si, sp, entries, sc in beam:
                if si >= len(slots):
                    if sp == n:
                        completed.append((entries, sc))
                    continue
                rem_slots = len(slots) - si
                rem_syll = n - sp
                if rem_syll < rem_slots:
                    continue
                for e in self.expansions(slots[si], rng):
                    if e.syllables > rem_syll - (rem_slots - 1):
                        continue
                    s = self.position_score(e, sp, pattern, long_slots, durations, trig, rng)
                    nxt.append((si + 1, sp + e.syllables, entries + (e,), sc + s))
            nxt.sort(key=lambda t: -t[3])
            del nxt[BEAM_WIDTH * 4:]
            grouped = {}
            beam = []
            for st in nxt:
                key = st[0] << 8 | st[1]
                c = grouped.get(key, 0)
                grouped[key] = c + 1
                if c < BEAM_WIDTH:
                    beam.append(st)
        return [self.finalize(entries, sc, tv) for entries, sc in completed]

    def finalize(self, entries, positional, tv):
        text = " ".join(e.text for e in entries)
        stress, content = [], set()
        valence = zipf_sum = 0.0
        for e in entries:
            is_content = bool(e.pos & CONTENT)
            if self.fixed:
                is_content = is_content and e.text not in STOP_WORDS
            for j in range(e.syllables):
                stress.append("S" if e.is_stressed(j) else "w")
            if is_content:
                content.add(e.text)
            valence += e.valence
            zipf_sum += e.zipf
        syllables = len(stress)
        mean_val = valence / max(1, len(entries))
        prosody = min(1.0, max(0.0, positional / max(1, syllables) * 0.7 + 0.3))
        fluency = min(1.0, max(0.0, (zipf_sum / max(1, len(entries)) - 2.5) / 3.0))
        emotion = min(1.0, max(0.0, 1.0 - abs(mean_val - tv) / 8.0))
        return Line(text, syllables, "".join(stress), prosody, fluency, emotion, content)


def pad(pattern, count):
    if len(pattern) >= count:
        return pattern[:count]
    return pattern + "w" * (count - len(pattern))

# ── SuggestionRanker + provider flow ─────────────────────────────────────────

def quality(line):
    return 0.45 * line.prosody + 0.25 * line.fluency + 0.20 * line.emotion


def mmr_select(pool, count):
    remaining = list(pool)
    picked = []
    while len(picked) < count and remaining:
        best_i, best_s = 0, float("-inf")
        for i, c in enumerate(remaining):
            overlap = max((jaccard(c, p) for p in picked), default=0.0)
            s = quality(c) - 0.10 * overlap
            if s > best_s:
                best_s, best_i = s, i
        picked.append(remaining.pop(best_i))
    return picked


def jaccard(a, b):
    if not a.content or not b.content:
        return 0.0
    inter = len(a.content & b.content)
    union = len(a.content | b.content)
    return inter / union if union else 0.0


def search_order(tolerance):
    order = [0]
    for d in range(1, tolerance + 1):
        order += [d, -d]
    return order


def provider_candidates(assembler, spec, phrase_uuid, attempt):
    seed = fnv(phrase_uuid) ^ fnv(f"attempt:{attempt}")
    if spec.get("override"):
        seed ^= fnv(f"emotion:{spec['override']}")
    target = max(1, spec["target"])
    pool, tried = [], set()
    for delta in search_order(spec.get("tolerance", 1)):
        n = target + delta
        if n < 1:
            continue
        tried.add(n)
        pool += assembler.assemble(spec, n, (seed + delta) & MASK64, 60)
        if len(pool) >= 60:
            break
    if not pool:
        for n in range(1, 13):
            if n in tried:
                continue
            pool += assembler.assemble(spec, n, (seed + n - target) & MASK64, 60)
            if pool:
                break
    return mmr_select(pool, 5)

# ── Demo ─────────────────────────────────────────────────────────────────────

def load_dict_words(path="/usr/share/dict/american-english"):
    lower, capped = set(), set()
    for w in open(path, encoding="utf-8"):
        w = w.strip()
        if not w:
            continue
        (capped if w[0].isupper() else lower).add(w.lower())
    return lower, capped


def main():
    store = LexiconStore(sys.argv[1])
    print(f"lexicon: {store.count} words")
    # Sanity checks mirroring build_lexicon.py's self-checks.
    b = store.lookup("beautiful")
    assert b.syllables == 3 and b.stress == 0b001 and b.openb == 0b110
    assert store.lookup("light").rhyme == store.lookup("night").rhyme
    assert store.lookup("light").rhyme != store.lookup("love").rhyme
    print("lexicon self-checks passed\n")

    index = StressPatternIndex(store)
    old = Assembler(store, index, fixed=False)
    new = Assembler(store, index, fixed=True)

    # Simulated lexicon rebuild (the build_lexicon.py proper-noun fix): strip
    # POS tags from words the system dictionary knows only capitalized — an
    # approximation of "tags only from lowercase Moby headwords". Skipped when
    # no system word list is installed (apt install wamerican).
    rebuilt = None
    try:
        lower_dict, _ = load_dict_words()
    except OSError:
        print("no /usr/share/dict word list; skipping the rebuild simulation\n")
    else:
        store2 = LexiconStore(sys.argv[1])
        stripped = 0
        for e in store2.entries:
            if e.pos and e.text not in lower_dict:
                e.pos = 0
                stripped += 1
        index2 = StressPatternIndex(store2)
        rebuilt = Assembler(store2, index2, fixed=True)
        print(f"simulated rebuild: stripped POS tags from {stripped} proper-noun/junk words\n")

    uuid = "7A9E4C21-3F0B-4D2E-9C61-8B5A2E7D4F10"
    specs = [
        ("screenshot-ish: 5 syllables, Joy", {"target": 5, "pattern": "SwSwS", "emotion": "joy", "tolerance": 1}),
        ("7 syllables, Longing", {"target": 7, "pattern": "SwSwwSw", "emotion": "longing", "tolerance": 1}),
        ("6 syllables, Melancholy", {"target": 6, "pattern": "SwSwwS", "emotion": "melancholy", "tolerance": 1}),
        ("4 syllables, Hope", {"target": 4, "pattern": "SwSw", "emotion": "hope", "tolerance": 1}),
    ]

    modes = [("old code  ", old), ("current   ", new)]
    if rebuilt is not None:
        modes.append(("+ rebuild ", rebuilt))

    for label, spec in specs:
        print(f"═══ {label} ═══")
        for tag, asm in modes:
            picks = provider_candidates(asm, spec, uuid, 0)
            print(f"  [{tag}] " + " | ".join(f"“{l.text}”" for l in picks[:3]))
        print()

    walker = rebuilt if rebuilt is not None else new
    print("═══ regenerate walk (5-syllable Joy) ═══")
    for attempt in range(4):
        picks = provider_candidates(walker, specs[0][1], uuid, attempt)
        print(f"  attempt {attempt}: " + " | ".join(f"“{l.text}”" for l in picks[:3]))
    print()

    print("═══ duplicate-word lines the OLD code offered (now filtered) ═══")
    total_old = dup_old = 0
    examples = []
    for label, spec in specs:
        for attempt in range(3):
            seed = fnv(uuid) ^ fnv(f"attempt:{attempt}")
            for delta in search_order(spec.get("tolerance", 1)):
                n = spec["target"] + delta
                if n < 1:
                    continue
                pool = old.assemble(spec, n, (seed + delta) & MASK64, 60)
                for line in pool:
                    total_old += 1
                    words = line.text.split(" ")
                    if len(set(words)) != len(words):
                        dup_old += 1
                        if len(examples) < 6:
                            examples.append(line.text)
    print(f"  old guard: {dup_old} of {total_old} offered lines repeat a word")
    for ex in examples:
        print(f"    “{ex}”")
    print()

    print("═══ invariant sweep (4 specs × 8 attempts) ═══")
    bad = n_lines = 0
    for _, asm in modes[1:]:
        for label, spec in specs:
            for attempt in range(8):
                for line in provider_candidates(asm, spec, uuid, attempt):
                    n_lines += 1
                    words = [w.lower() for w in line.text.split(" ")]
                    ok = (line.content
                          and words[-1] not in STOP_WORDS
                          and len(set(words)) == len(words)
                          and not (line.content & STOP_WORDS))
                    if not ok:
                        bad += 1
                        print(f"  VIOLATION: “{line.text}”")
    print(f"  {n_lines} candidate lines checked, {bad} violations")


if __name__ == "__main__":
    main()
