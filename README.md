# Fantasy Baseball SGP Draft Board

A roto fantasy baseball draft preparation system built in R and D3.js. Calculates player value using **Standings Gain Points (SGP)** calibrated to your specific league's historical standings, then adjusts for positional scarcity via **Value Above Replacement (VAR)**.

---

## Why SGP Instead of Z-Scores or Generic Rankings

Most public fantasy rankings are:
- Blended across formats (H2H points, H2H categories, roto)
- Based on generic population averages, not your league's actual standings history
- Unadjusted for positional scarcity

SGP solves this by asking a specific question: *how many units of a stat does a team in your league need to gain one point in the standings?* A player's value is denominated directly in standings points — the same currency your league uses.

---

## How It Works

### 1. SGP Denominators

The foundation of the system. For each scoring category, a linear regression is fit on sorted team standings values to estimate the "cost" of one standings point:

```
SGP Denominator = stat units needed to move up 1 spot in the standings
```

**Multi-year averaging:** Denominators are calculated separately for each historical season and then averaged. This prevents a single unusual season (e.g., a stolen base spike following a rule change) from distorting valuations.

**Example denominators** from a 10-team league:

| Category | SGP Denom | Interpretation |
|----------|-----------|----------------|
| R | 19.4 | Need 19.4 more Runs to gain 1 standings point |
| HR | 8.1 | Need 8.1 more HRs |
| SB | 11.1 | Need 11.1 more SBs |
| K | 76.5 | Need 76.5 more strikeouts |
| ERA | 0.084 | Team ERA must improve by 0.084 |
| WHIP | 0.013 | Team WHIP must improve by 0.013 |

---

### 2. Counting Stats SGP

For volume-based categories (R, HR, RBI, SB, K, QS, SV):

```
Player SGP = Projected Stat / SGP Denominator
```

A player projected for 40 HR in a league where 8.1 HR = 1 point contributes **4.94 SGP** in the HR category.

---

### 3. Rate Stats — Marginal Contribution Method

Rate stats (OBP, ERA, WHIP) cannot be divided directly because they depend on volume. A .320 OBP over 200 PA means something very different than .320 over 600 PA.

The solution is to calculate each player's **marginal effect on a typical team's rate stat** when added to (or removed from) a baseline roster pool.

**OBP:**
```
OBP_with    = (team_OBE + player_OBE) / (team_PA + player_PA)
OBP_without = (team_OBE - player_OBE) / (team_PA - player_PA)
OBPSGP      = (OBP_with - OBP_without) / OBP_denominator
```

Where `team_OBE` and `team_PA` represent the average on-base events and plate appearances for a typical team's hitting pool.

**ERA and WHIP** use the same logic with the pitcher pool:
```
ERA_with    = ((team_ER + player_ER) × 9) / (team_IP + player_IP)
ERA_without = ((team_ER - player_ER) × 9) / (team_IP - player_IP)
ERASGP      = -(ERA_with - ERA_without) / ERA_denominator
```

The sign is negated because lower ERA is better.

---

### 4. Value Above Replacement (VAR)

Raw SGP tells you how much a player contributes. VAR adjusts for **positional scarcity** by measuring value relative to the best freely available player at that position — i.e., the best player who goes undrafted.

```
VAR = Total_SGP − Replacement_Level_SGP (at position)
```

**Replacement level** is defined as the SGP of the `(roster_spots × num_teams + 1)`th ranked player at each position. Roster spots account for starters, bench, and estimated bench allocation:

| Position | Roster Spots | Replacement Rank |
|----------|-------------|-----------------|
| C | 1.5 | 16th catcher |
| 1B/2B/3B/SS | 1.25 each | 13th at each |
| OF | 4.5 | 46th outfielder |
| SP | 10 | 101st starter |
| RP | 4 | 41st reliever |

**Why VAR matters:** An elite catcher (e.g., Cal Raleigh) has similar raw SGP to a mid-tier outfielder, but because catcher replacement level is so much lower, his VAR is dramatically higher. Draft on VAR, not raw SGP.

---

### 5. Tiering

Players are bucketed into tiers using **Jenks natural breaks** — an algorithm that finds natural groupings in the VAR distribution rather than forcing arbitrary cutoffs. Tier 1 = elite, Tier 5+ = depth.

---

## Files

```
ffcheatsheet/
├── ffcheatsheet_sgp.R          # Main R script — runs full pipeline
├── Standings_2024.csv          # League standings (rename W → QS if needed)
├── Standings_2023.csv
├── Standings_2022.csv
├── baseballdatatest_sgp.json   # Output — player rankings (auto-generated)
├── baseballdatatest_sgp.js     # Output — JS-embedded version for draft board
├── draft-board.html            # Draft day UI
└── AllData_SGP_VAR.csv         # Output — full rankings table
```

---

## Setup & Usage

### Requirements

```r
install.packages(c(
  "rvest", "BAMMtools", "dplyr", "tidyr", "stringr",
  "ggplot2", "forcats", "viridis", "ggrepel",
  "extrafont", "jsonlite", "readr"
))
```

### Standings CSV Format

Your standings files should have these columns (one row per team):

```
R, HR, RBI, SB, OBP, K, W, SV, ERA, WHIP
```

> **Note:** If your league scores Quality Starts (QS) but your CSV has the column named `W`, the script automatically renames it. If your league actually scores Wins, remove the `rename(QS = W)` line and adjust the pitcher SGP section accordingly.

### Configuration

At the top of `ffcheatsheet_sgp.R`, adjust these constants to match your league:

```r
NUM_TEAMS         <- 10    # Number of teams in your league
HITTERS_PER_TEAM  <- 11    # Starting hitters + estimated bench hitters
PITCHERS_PER_TEAM <- 15    # Starting pitchers + estimated bench pitchers

roster_spots <- list(
  C    = 1.5,   # 1 starter + 0.5 bench
  `1B` = 1.25,
  `2B` = 1.25,
  `3B` = 1.25,
  SS   = 1.25,
  OF   = 4.5,   # 3 starters + UTIL + 0.5 bench
  SP   = 10,    # 3 starters + 7 bench
  RP   = 4      # 2 starters + 2 bench
)
```

Fractional roster spots are supported and are rounded when calculating the replacement level cutoff.

### Running the Pipeline

```r
source("ffcheatsheet_sgp.R")
```

This will:
1. Load and average standings across all provided years
2. Calculate SGP denominators
3. Scrape current projections from FantasyPros
4. Calculate SGP and VAR for all players
5. Assign tiers via Jenks breaks
6. Export `AllData_SGP_VAR.csv`, `baseballdatatest_sgp.json`, and `baseballdatatest_sgp.js`

---

## Draft Board UI

The draft board is a single HTML file (`draft-board.html`) powered by D3.js — no build step, no server required.

### Loading Your Data

Place `baseballdatatest_sgp.js` (generated by the R script) in the same folder as `draft-board.html`, then open the HTML file in any browser.

> The `.js` embed approach avoids CORS issues that occur when fetching JSON from `file://` URLs. The R script writes the data as `window.DRAFT_DATA = [...]` which the HTML loads as a script tag.

### Features

| Feature | How to use |
|---------|-----------|
| Sort by any stat | Click any column header |
| Filter by position | Click position pills (ALL / C / 1B / ...) |
| Mark player as drafted | Click **Draft** button in the row |
| Undo a draft pick | Click **Undraft** |
| Show/hide drafted players | Toggle "Show drafted" checkbox |
| Cross-highlight table ↔ scatter | Hover any table row or scatter dot |
| Scatter tooltip | Hover any dot for SGP, VAR, Tier, Rank |

The header bar tracks total drafted, available players, and current draft round in real time.

---

## Interpreting the Output

- **Total_SGP** — raw projected standings points contributed across all categories
- **VAR** — value above the best available replacement at that position; the primary ranking metric
- **Tier** — natural break grouping; target players in Tier 1-2 early, use Tier 3-4 for mid-round value
- **Category SGP columns** (RSGP, HRSGP, etc.) — per-category breakdown; useful for identifying what a player does and doesn't contribute

A player with high Total_SGP but low VAR (e.g., a productive outfielder) is valuable but replaceable. A player with high VAR relative to SGP (e.g., an elite catcher or closer) is scarce and should be drafted earlier than public rankings suggest.

---

## Data Source

Player projections are scraped from [FantasyPros](https://www.fantasypros.com/mlb/projections/) consensus projections at runtime. Re-run the script periodically through spring to pick up updated projections as the season approaches.

---

## Limitations

- **Role risk for relievers:** The system values closers highly based on projected saves. Closer roles are volatile; apply a mental discount to RPs ranked in the top 20.
- **Injury risk:** Projections assume health. High-VAR players with injury history (e.g., Ronald Acuña Jr.) carry unmodeled downside.
- **Single-position assignment:** Players with positional flexibility (e.g., a 1B/OF) are assigned their primary position. This understates their draft value slightly since they offer roster flexibility.
- **League drift:** If your league's composition or scoring changes significantly year-over-year, older standings years in the denominator average may be less representative. Consider weighting recent years more heavily.
