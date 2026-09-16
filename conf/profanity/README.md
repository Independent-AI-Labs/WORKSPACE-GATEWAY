# Dictionary sources and licenses

| File | Source | License | Fetched |
|------|--------|---------|---------|
| `en.txt` | [coffee-and-fun/google-profanity-words](https://github.com/coffee-and-fun/google-profanity-words) `data/en.txt` (v3.0.7, Apr 2026) | MIT | 2026-09-16 |
| `vader-negative.txt` | [cjhutto/vaderSentiment](https://github.com/cjhutto/vaderSentiment) `vader_lexicon.txt`, valence <= -2.0 single-word subset, profanity overlaps removed | MIT | 2026-09-16 |
| `frustration-phrases.txt` | gateway-owned, hand-curated chat-correction phrases | this repo |: |

Refresh with `make gw-update-dictionaries` (runs `res/scripts/update-dictionaries.sh`).
`frustration-phrases.txt` is never modified by the refresh script.

`vader-negative.txt` format: `word<TAB>valence` (valence in [-4.0, -2.0]).
The valence feeds instance weights: `round(|valence| / 4.0, 2)` per match
(REQ-USEFULNESS-TELEMETRY FR-5.7).
