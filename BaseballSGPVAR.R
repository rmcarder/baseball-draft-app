##############################################################################
# Fantasy Baseball SGP + Value Above Replacement (VAR) System
# Adapted from ffcheatsheet.R
#
# Key improvements over original:
#   1. SGP denominators fit only on middle teams (avoid outlier distortion)
#   2. Rate stats (OBP, ERA, WHIP) use proper marginal contribution method
#   3. Position-specific replacement levels (not a flat top-N cutoff)
#   4. Hitter/pitcher pools kept separate for rate stat pool calculations
#   5. VAR = Total SGP - Position Replacement SGP (the final ranking metric)
##############################################################################

setwd("C:/Users/RichardCarder/Documents/dev/ffcheatsheet")

library(rvest)
library(BAMMtools)
library(dplyr)
library(tidyr)
library(stringr)
library(ggplot2)
library(forcats)
library(gridExtra)
library(grid)
library(viridis)
library(ggrepel)
library(extrafont)
library(jsonlite)
library(readr)

##############################################################################
# SECTION 1: LOAD STANDINGS & CALCULATE SGP DENOMINATORS
##############################################################################

# Load multiple years of standings
standings_list <- list(
  read.csv("Standings2025.csv", header = TRUE) ,
  read.csv("Standings2024.csv", header = TRUE) ,
  read.csv("Standings2023.csv", header = TRUE) 
)

# Calculate denominators for each year separately, then average
yearly_denoms <- lapply(standings_list, function(s) {
  sapply(list(
    R    = calc_sgp_denom(s$R,    positive = TRUE),
    HR   = calc_sgp_denom(s$HR,   positive = TRUE),
    RBI  = calc_sgp_denom(s$RBI,  positive = TRUE),
    SB   = calc_sgp_denom(s$SB,   positive = TRUE),
    OBP  = calc_sgp_denom(s$OBP,  positive = TRUE),
    K    = calc_sgp_denom(s$K,    positive = TRUE),
    QS   = calc_sgp_denom(s$QS,   positive = TRUE),
    SV   = calc_sgp_denom(s$SV,   positive = TRUE),
    ERA  = calc_sgp_denom(s$ERA,  positive = FALSE),
    WHIP = calc_sgp_denom(s$WHIP, positive = FALSE)
  ), function(f) f)
})

# Average across years
denom_matrix <- do.call(rbind, yearly_denoms)
sgp_denom    <- as.list(colMeans(denom_matrix))

cat("SGP Denominators (averaged across years):\n")
print(data.frame(
  Category  = names(sgp_denom),
  SGP_Denom = round(unlist(sgp_denom), 4)
))


##############################################################################
# SECTION 2: SCRAPE PROJECTIONS FROM FANTASYPROS
##############################################################################

xpathpath <- '//*[@id="data"]'

# ---- Hitters ----
hitter_positions <- c("1b", "2b", "3b", "ss", "of", "c")
hitter_limits    <- c(30, 30, 30, 30, 70, 20)

hitter_list <- list()

for (j in seq_along(hitter_positions)) {
  pos <- hitter_positions[j]
  n   <- hitter_limits[j]
  url <- paste0("https://www.fantasypros.com/mlb/projections/", pos, ".php")
  
  raw <- url %>%
    read_html() %>%
    html_nodes(xpath = xpathpath) %>%
    html_table(fill = TRUE)
  
  df <- raw[[1]]
  
  # Fix empty/NA column names before doing anything else
  names(df) <- ifelse(is.na(names(df)) | names(df) == "", 
                      paste0("col_", seq_along(names(df))), 
                      names(df))
  
  df <- df %>%
    head(n) %>%
    # Drop any unnamed/empty columns
    select(-any_of(c("X17", "X18"))) %>%
    select(-starts_with("col_")) %>%
    mutate(
      POS     = toupper(pos),
      POSRANK = row_number()
    )
  
  hitter_list[[pos]] <- df
}

hitters_raw <- bind_rows(hitter_list)

# ---- Starting Pitchers ----
sp_url <- "https://www.fantasypros.com/mlb/projections/sp.php"
sp_raw <- sp_url %>%
  read_html() %>%
  html_nodes(xpath = xpathpath) %>%
  html_table(fill = TRUE)

sp_raw <- sp_raw[[1]]

# Fix empty/NA column names
names(sp_raw) <- ifelse(is.na(names(sp_raw)) | names(sp_raw) == "",
                        paste0("col_", seq_along(names(sp_raw))),
                        names(sp_raw))

sp_raw <- sp_raw %>%
  head(100) %>%
  select(-any_of(c("X17", "X18"))) %>%
  select(-starts_with("col_")) %>%
  mutate(
    POS     = "SP",
    POSRANK = row_number(),
    SV      = 0
  ) %>%
  rename(Hits = H, Walks = BB) %>%
  select(-any_of("HR"))

# ---- Relief Pitchers ----
rp_url <- "https://www.fantasypros.com/mlb/projections/rp.php"
rp_raw <- rp_url %>%
  read_html() %>%
  html_nodes(xpath = xpathpath) %>%
  html_table(fill = TRUE)

rp_raw <- rp_raw[[1]]

# Fix empty/NA column names
names(rp_raw) <- ifelse(is.na(names(rp_raw)) | names(rp_raw) == "",
                        paste0("col_", seq_along(names(rp_raw))),
                        names(rp_raw))

rp_raw <- rp_raw %>%
  head(40) %>%
  select(-any_of(c("X17", "X18"))) %>%
  select(-starts_with("col_")) %>%
  mutate(
    POS     = "RP",
    POSRANK = row_number(),
    QS      = 0
  ) %>%
  rename(Hits = H, Walks = BB) %>%
  select(-any_of("HR"))

##############################################################################
# SECTION 3: CALCULATE SGP FOR HITTERS
##############################################################################
# For counting stats: SGP = stat / denom
# For OBP: marginal contribution method.
#   We estimate a "typical team's" hitting pool as the average starter pool,
#   then measure how each player shifts the team OBP vs. replacement.
#   league_pool_* = average team's cumulative on-base events / plate appearances
#   (approximated as top N rostered hitters divided by num_teams)


NUM_TEAMS         <- 10
HITTERS_PER_TEAM  <- 9 + 2   # 9 starters + ~3 bench hitters
PITCHERS_PER_TEAM <- 7 + 8   # 7 starters + ~7 bench pitchers

# Replacement level cutoffs by position.
# UTIL and P flex spots deepen the pool for hitters/pitchers respectively,
# which is why we add 1 extra to OF and P beyond the strict starting spots.
roster_spots <- list(
  C    = 1.5,   # 1 starter + 0.5 bench for off days
  `1B` = 1.25,  # 1 starter + 0.25 bench (shared util/bench allocation)
  `2B` = 1.25,
  `3B` = 1.25,
  SS   = 1.25,
  OF   = 4.5,   # 3 starters + UTIL + 0.5 bench
  SP   = 10,    # 3 starters + 7 bench
  RP   = 4      # 2 starters + 2 bench
)
# Build the hitter pool for OBP marginal calc.
# We use the top (NUM_TEAMS * HITTERS_PER_TEAM) hitters by projected AB as the
# full draftable pool, then compute league-average pool per team.
hitters_deduped <- hitters_raw[!duplicated(hitters_raw$Player), ]

pool_size        <- NUM_TEAMS * HITTERS_PER_TEAM
hitter_pool      <- hitters_deduped %>% arrange(desc(AB)) %>% head(pool_size)

pool_OBE_total   <- sum(hitter_pool$H + hitter_pool$BB, na.rm = TRUE)
pool_PA_total    <- sum(hitter_pool$AB + hitter_pool$BB, na.rm = TRUE)
pool_OBE_per_team <- pool_OBE_total / NUM_TEAMS
pool_PA_per_team  <- pool_PA_total  / NUM_TEAMS
league_avg_OBP    <- pool_OBE_total / pool_PA_total

cat(sprintf("\nLeague average OBP (hitter pool): %.4f\n", league_avg_OBP))

hitters_sgp <- hitters_deduped %>%
  mutate(
    player_OBE = H + BB,
    player_PA  = AB + BB,
    
    # Counting stat SGPs
    RSGP   = R   / sgp_denom$R,
    HRSGP  = HR  / sgp_denom$HR,
    RBISGP = RBI / sgp_denom$RBI,
    SBSGP  = SB  / sgp_denom$SB,
    
    # OBP marginal SGP:
    # How much does adding this player change a team's OBP vs. removing them?
    # We compute (team_pool + player) OBP minus (team_pool - player) OBP,
    # then divide by the OBP SGP denominator.
    OBP_with    = (pool_OBE_per_team + player_OBE) / (pool_PA_per_team + player_PA),
    OBP_without = (pool_OBE_per_team - player_OBE) / (pool_PA_per_team - player_PA),
    OBPSGP      = (OBP_with - OBP_without) / sgp_denom$OBP,
    
    # Zero out pitcher categories
    KSGP   = 0, QSSGP = 0, SVSGP = 0, ERASGP = 0, WHIPSGP = 0,
    
    Total_SGP = RSGP + HRSGP + RBISGP + SBSGP + OBPSGP
  )

##############################################################################
# SECTION 4: CALCULATE SGP FOR PITCHERS
##############################################################################
# ERA and WHIP use the same marginal logic as OBP:
#   Add this pitcher to a baseline rotation; how does ERA/WHIP change?
#   Negative because lower ERA/WHIP = better.

pitchers_raw <- bind_rows(sp_raw, rp_raw)
pitchers_deduped <- pitchers_raw[!duplicated(pitchers_raw$Player), ]

pitcher_pool_size    <- NUM_TEAMS * PITCHERS_PER_TEAM
pitcher_pool         <- pitchers_deduped %>% arrange(desc(IP)) %>% head(pitcher_pool_size)

pool_IP_total        <- sum(pitcher_pool$IP,     na.rm = TRUE)
pool_ER_total        <- sum(pitcher_pool$ER,     na.rm = TRUE)
pool_Hits_total      <- sum(pitcher_pool$Hits,   na.rm = TRUE)
pool_Walks_total     <- sum(pitcher_pool$Walks,  na.rm = TRUE)

pool_IP_per_team     <- pool_IP_total    / NUM_TEAMS
pool_ER_per_team     <- pool_ER_total    / NUM_TEAMS
pool_Hits_per_team   <- pool_Hits_total  / NUM_TEAMS
pool_Walks_per_team  <- pool_Walks_total / NUM_TEAMS

league_avg_ERA  <- (pool_ER_total    * 9) / pool_IP_total
league_avg_WHIP <- (pool_Hits_total + pool_Walks_total) / pool_IP_total

cat(sprintf("League average ERA  (pitcher pool): %.3f\n", league_avg_ERA))
cat(sprintf("League average WHIP (pitcher pool): %.3f\n\n", league_avg_WHIP))

pitchers_sgp <- pitchers_deduped %>%
  mutate(
    # Counting stat SGPs
    KSGP   = coalesce(K,  0) / sgp_denom$K,
    QSSGP  = coalesce(QS, 0) / sgp_denom$QS,
    SVSGP  = coalesce(SV, 0) / sgp_denom$SV,
    
    # ERA marginal SGP:
    # (pool - this pitcher) ERA minus (pool + this pitcher) ERA, divided by denom.
    # Positive = good (pitcher improves team ERA vs. replacement).
    ERA_with    = ((pool_ER_per_team + ER) * 9) / (pool_IP_per_team + IP),
    ERA_without = ((pool_ER_per_team - ER) * 9) / (pool_IP_per_team - IP),
    ERASGP      = -(ERA_with - ERA_without) / sgp_denom$ERA,
    
    # WHIP marginal SGP
    WHIP_with    = (pool_Hits_per_team + pool_Walks_per_team + Hits + Walks) /
      (pool_IP_per_team + IP),
    WHIP_without = (pool_Hits_per_team + pool_Walks_per_team - Hits - Walks) /
      (pool_IP_per_team - IP),
    WHIPSGP      = -(WHIP_with - WHIP_without) / sgp_denom$WHIP,
    
    # Zero out hitter categories
    RSGP = 0, HRSGP = 0, RBISGP = 0, SBSGP = 0, OBPSGP = 0,
    
    Total_SGP = KSGP + QSSGP + SVSGP + ERASGP + WHIPSGP
  )

##############################################################################
# SECTION 5: COMBINE & CALCULATE VALUE ABOVE REPLACEMENT (VAR)
##############################################################################
# Replacement level = SGP of the (NUM_TEAMS * roster_spots + 1)th player
# at each position. This is the freely available baseline.

# Add a utility/CI/MI slot if your league has them:
# roster_spots[["UTIL"]] <- 1

all_players <- bind_rows(
  hitters_sgp %>% select(Player, POS, POSRANK, Total_SGP,
                         RSGP, HRSGP, RBISGP, SBSGP, OBPSGP,
                         KSGP, QSSGP, SVSGP, ERASGP, WHIPSGP),
  pitchers_sgp %>% select(Player, POS, POSRANK, Total_SGP,
                          RSGP, HRSGP, RBISGP, SBSGP, OBPSGP,
                          KSGP, QSSGP, SVSGP, ERASGP, WHIPSGP)
)

# Calculate replacement level SGP for each position
calc_replacement_sgp <- function(data, pos_code, spots_per_team, n_teams) {
  pos_players <- data %>%
    filter(POS == pos_code) %>%
    arrange(desc(Total_SGP))
  
  cutoff_rank <- spots_per_team * n_teams + 1
  
  if (nrow(pos_players) >= cutoff_rank) {
    pos_players$Total_SGP[cutoff_rank]
  } else {
    # Not enough projected players; use the worst available
    min(pos_players$Total_SGP, na.rm = TRUE)
  }
}

replacement_levels <- tibble(
  POS         = names(roster_spots),
  Repl_SGP    = sapply(names(roster_spots), function(p) {
    calc_replacement_sgp(all_players, p, roster_spots[[p]], NUM_TEAMS)
  })
)

cat("Replacement Level SGP by Position:\n")
print(replacement_levels)

# Join replacement levels and compute VAR
all_players <- all_players %>%
  left_join(replacement_levels, by = "POS") %>%
  mutate(
    VAR = Total_SGP - Repl_SGP
  ) %>%
  arrange(desc(VAR)) %>%
  mutate(
    OverallRank = row_number(),
    label = paste0(Player, " (", POS, ") SGP: ", round(Total_SGP, 2),
                   " | VAR: ", round(VAR, 2))
  )

##############################################################################
# SECTION 6: TIER ASSIGNMENTS (JENKS NATURAL BREAKS ON VAR)
##############################################################################

breaks <- getJenksBreaks(all_players$VAR, 11)
all_players$Jenks <- cut(all_players$VAR, breaks = breaks, labels = as.character(1:10))
all_players$Tier  <- 11 - as.integer(all_players$Jenks)   # invert so Tier 1 = best

##############################################################################
# SECTION 7: EXPORT
##############################################################################

write.csv(all_players, "AllData_SGP_VAR.csv", row.names = FALSE)

all_players %>%
  toJSON() %>%
  write_lines("baseballdatatest_sgp.json")

cat(sprintf("\nTop 20 players by VAR:\n"))
all_players %>%
  select(OverallRank, Player, POS, Total_SGP, VAR, Tier) %>%
  head(20) %>%
  print()

##############################################################################
# SECTION 8: HEATMAP — SGP COMPONENT BREAKDOWN
##############################################################################

heattheme <- theme(
  axis.title      = element_text(color = "#000000", family = "Montserrat Light", size = 7),
  text            = element_text(color = "#000000", family = "Montserrat Light", size = 5),
  legend.position = "none",
  axis.text.x     = element_text(angle = 35, color = "#000000", family = "Montserrat Light",
                                 hjust = 1, size = 7),
  axis.text.y     = element_text(color = "#000000", family = "Montserrat Light", size = 7),
  axis.title.x    = element_blank(),
  axis.title.y    = element_blank(),
  panel.background = element_blank(),
  plot.margin      = margin(10, 10, 10, 40),
  panel.border     = element_blank(),
  panel.grid.major = element_blank(),
  panel.grid.minor = element_blank()
)

sgp_cols <- c("RSGP", "HRSGP", "RBISGP", "SBSGP", "OBPSGP",
              "KSGP", "QSSGP", "SVSGP", "ERASGP", "WHIPSGP")

heat_data <- all_players %>%
  filter(!is.na(Tier), Tier <= 5) %>%          # top tiers only for readability
  mutate(label = fct_reorder(factor(label), VAR)) %>%
  pivot_longer(cols = all_of(sgp_cols), names_to = "Stat", values_to = "SGP_value")

heat_plot <- ggplot(heat_data, aes(y = label, x = Stat, fill = SGP_value)) +
  geom_tile() +
  geom_text(aes(label = round(SGP_value, 2)),
            color = "#000000", family = "Montserrat Light", size = 2.5) +
  scale_fill_distiller(palette = "RdYlGn", limits = c(-3, 3), direction = 1) +
  heattheme

ggsave("HeatSGP_VAR.pdf", plot = heat_plot, width = 10, height = 14)
embed_fonts("HeatSGP_VAR.pdf", outfile = "HeatSGP_VAR.pdf")

cat("\nDone. Output files: AllData_SGP_VAR.csv, baseballdatatest_sgp.json, HeatSGP_VAR.pdf\n")