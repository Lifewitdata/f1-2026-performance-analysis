# =============================================================================
# F1 Race Performance Statistical Analysis (2026)
# EA Associate Data Science Portfolio Project
# =============================================================================
# Author:  Isfaq
# Dataset: 2026 F1 Season — Qualifying, Sprint Qualifying, Sprint Race Results
# Tool:    R | tidyverse | ggplot2 | tidymodels | broom | pROC
# =============================================================================


# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: SETUP & DATA WRANGLING (Days 1–2)
# ─────────────────────────────────────────────────────────────────────────────

# ── 1.1  Install & load packages ─────────────────────────────────────────────
# Run this block once per fresh environment:
# install.packages(c("tidyverse","lubridate","janitor","tidymodels",
#                    "patchwork","broom","pROC","yardstick","scales"))

library(tidyverse)
library(janitor)
library(tidymodels)
library(patchwork)
library(broom)
library(pROC)
library(scales)

# ── 1.2  Load raw CSVs ───────────────────────────────────────────────────────
# Update these paths to wherever you place the files locally.
raw_sprint     <- read_csv("data/Formula1_2026Season_SprintResults.csv",
                           show_col_types = FALSE)
raw_sprint_q   <- read_csv("data/Formula1_2026Season_SprintQualifyingResults.csv",
                           show_col_types = FALSE)
raw_qual       <- read_csv("data/Formula1_2026Season_QualifyingResults.csv",
                           show_col_types = FALSE)

# ── 1.3  Inspect ─────────────────────────────────────────────────────────────
glimpse(raw_sprint)
glimpse(raw_sprint_q)
glimpse(raw_qual)

summary(raw_sprint)
summary(raw_sprint_q)
summary(raw_qual)

# ── 1.4  Standardise & clean column names (janitor) ──────────────────────────
sprint   <- raw_sprint   |> clean_names()
sprint_q <- raw_sprint_q |> clean_names()
qual     <- raw_qual     |> clean_names()

# ── 1.5  Type coercion & missing-value handling ───────────────────────────────
# Q2 / Q3 NAs in qualifying are structural (knockout format — not missing data).
# We convert the lap-time columns to numeric seconds for modelling.
parse_laptime <- function(x) {
  # Accepts "1:18.518" or NA.  Returns seconds as numeric.
  ifelse(
    is.na(x), NA_real_,
    sapply(x, function(t) {
      if (is.na(t)) return(NA_real_)
      parts <- str_split(t, ":")[[1]]
      as.numeric(parts[1]) * 60 + as.numeric(parts[2])
    })
  )
}

qual <- qual |>
  mutate(
    q1_sec = parse_laptime(q1),
    q2_sec = parse_laptime(q2),
    q3_sec = parse_laptime(q3),
    # Best lap = best available session time
    best_lap_sec = coalesce(q3_sec, q2_sec, q1_sec)
  )

sprint_q <- sprint_q |>
  mutate(
    sq1_sec = parse_laptime(q1),
    sq2_sec = parse_laptime(q2),
    sq3_sec = parse_laptime(q3),
    sq_best_lap_sec = coalesce(sq3_sec, sq2_sec, sq1_sec)
  )

# Clean position columns — convert NC / DQ to NA for numeric analysis
clean_position <- function(x) {
  as.integer(ifelse(x %in% c("NC", "DQ"), NA_character_, x))
}

sprint <- sprint |>
  mutate(
    sprint_position    = clean_position(position),
    sprint_grid        = as.integer(starting_grid),
    sprint_points      = as.numeric(points)
  )

qual <- qual |>
  mutate(qual_position = clean_position(position))

sprint_q <- sprint_q |>
  mutate(sq_position = clean_position(position))

# Remove duplicates (none expected, but good practice)
sprint   <- sprint   |> distinct()
sprint_q <- sprint_q |> distinct()
qual     <- qual     |> distinct()

# ── 1.6  Join into a master dataset ──────────────────────────────────────────
# Keys: driver (name) + track.
# Sprint dataset is the "race result" anchor.
# We join qualifying (Sunday grid) and sprint qualifying to it.
#
# Note: Qualifying covers 7 race weekends; Sprint covers only 3.
# The master frame therefore contains only the 3 sprint weekends
# where all three tables overlap.

master <- sprint |>
  left_join(
    sprint_q |>
      select(track, driver, sq_position, sq_best_lap_sec),
    by = c("track", "driver")
  ) |>
  left_join(
    qual |>
      select(track, driver, qual_position, best_lap_sec, q1_sec, q2_sec, q3_sec),
    by = c("track", "driver")
  ) |>
  # Rename for clarity
  rename(
    race_weekend     = track,
    race_position    = sprint_position,
    grid_position    = sprint_grid
  ) |>
  # ── 1.7  Feature Engineering ─────────────────────────────────────────────
  mutate(
    # grid_diff: how many places gained (+) or lost (-) relative to grid
    grid_diff = grid_position - race_position,

    # sprint_to_race_delta: sprint qualifying pos vs sprint race pos
    # positive = improved from sprint qualifying to sprint race
    sprint_to_race_delta = sq_position - race_position,

    # Binary target: 1 = podium finish (top 3), 0 = otherwise
    podium_finish = as.factor(if_else(race_position <= 3, 1L, 0L))
  )

glimpse(master)
cat("\nMaster dataset rows:", nrow(master), "| columns:", ncol(master), "\n")
cat("Sprint weekends covered:", paste(unique(master$race_weekend), collapse = ", "), "\n")
cat("NA summary:\n")
print(colSums(is.na(master)))

# ── 1.8  Save clean master dataset ───────────────────────────────────────────
dir.create("data/clean", showWarnings = FALSE)
saveRDS(master, "data/clean/f1_master_2026.rds")
cat("\n✅ Master dataset saved to data/clean/f1_master_2026.rds\n")


# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: EDA & HYPOTHESIS TESTING (Days 3–4)
# ─────────────────────────────────────────────────────────────────────────────

# ── 2.1  Descriptive statistics ──────────────────────────────────────────────
cat("\n──── Descriptive stats by driver ────\n")
driver_stats <- master |>
  filter(!is.na(race_position)) |>
  group_by(driver) |>
  summarise(
    races          = n(),
    mean_race_pos  = round(mean(race_position, na.rm = TRUE), 2),
    median_race_pos= median(race_position, na.rm = TRUE),
    podiums        = sum(race_position <= 3, na.rm = TRUE),
    total_points   = sum(sprint_points, na.rm = TRUE),
    mean_grid_pos  = round(mean(grid_position, na.rm = TRUE), 2),
    mean_grid_diff = round(mean(grid_diff, na.rm = TRUE), 2),
    .groups = "drop"
  ) |>
  arrange(mean_race_pos)

print(driver_stats)

cat("\n──── Descriptive stats by team ────\n")
team_stats <- master |>
  filter(!is.na(race_position)) |>
  group_by(team) |>
  summarise(
    entries        = n(),
    mean_race_pos  = round(mean(race_position, na.rm = TRUE), 2),
    podiums        = sum(race_position <= 3, na.rm = TRUE),
    total_points   = sum(sprint_points, na.rm = TRUE),
    .groups = "drop"
  ) |>
  arrange(mean_race_pos)

print(team_stats)

# ── 2.2  Hypothesis Test 1: Spearman correlation ─────────────────────────────
# H0: No monotonic relationship between qualifying grid position
#     and sprint race finishing position.
cat("\n──── H1: Spearman Correlation — Qualifying Grid vs Sprint Race Position ────\n")
complete_for_cor <- master |>
  filter(!is.na(qual_position), !is.na(race_position))

spearman_test <- cor.test(
  complete_for_cor$qual_position,
  complete_for_cor$race_position,
  method = "spearman",
  exact  = FALSE
)
cat("Spearman rho:", round(spearman_test$estimate, 4), "\n")
cat("p-value     :", format.pval(spearman_test$p.value, digits = 4), "\n")
cat("Interpretation: A rho close to 1 means drivers who qualify higher also\n")
cat("finish higher in the sprint race. p < 0.05 rejects H0.\n")

# ── 2.3  Hypothesis Test 2: t-test — sprint qualifying position ──────────────
# H0: Sprint qualifying position does not differ significantly between
#     drivers who finish on the podium vs those who do not.
cat("\n──── H2: t-test — Sprint Qualifying Position: Podium vs Non-Podium ────\n")
podium_sq     <- master |> filter(podium_finish == 1, !is.na(sq_position)) |> pull(sq_position)
non_podium_sq <- master |> filter(podium_finish == 0, !is.na(sq_position)) |> pull(sq_position)

ttest_result <- t.test(podium_sq, non_podium_sq, alternative = "less")
cat("Mean sq position (podium)    :", round(mean(podium_sq), 2), "\n")
cat("Mean sq position (non-podium):", round(mean(non_podium_sq), 2), "\n")
cat("t-statistic:", round(ttest_result$statistic, 4), "\n")
cat("p-value    :", format.pval(ttest_result$p.value, digits = 4), "\n")
cat("95% CI     :", round(ttest_result$conf.int, 4), "\n")
cat("Interpretation: Tests whether podium finishers had a better (lower-numbered)\n")
cat("sprint qualifying position on average. p < 0.05 rejects H0.\n")

# ── 2.4  Hypothesis Test 3: ANOVA — sprint qualifying position across finish groups ─
# H0: Mean sprint qualifying position does not differ across finish quintiles.
cat("\n──── H3: One-Way ANOVA — Sprint Qualifying by Finish Position Group ────\n")
master_anova <- master |>
  filter(!is.na(race_position), !is.na(sq_position)) |>
  mutate(
    finish_group = case_when(
      race_position <= 3  ~ "Podium (1–3)",
      race_position <= 8  ~ "Points (4–8)",
      race_position <= 15 ~ "Midfield (9–15)",
      TRUE                ~ "Tail (16+)"
    ) |> factor(levels = c("Podium (1–3)", "Points (4–8)", "Midfield (9–15)", "Tail (16+)"))
  )

anova_model  <- aov(sq_position ~ finish_group, data = master_anova)
anova_tidy   <- tidy(anova_model)
cat("ANOVA summary:\n")
print(anova_tidy)
cat("Interpretation: A significant F (p < 0.05) means sprint qualifying position\n")
cat("explains variation in sprint race finishing group.\n")

tukey_result <- TukeyHSD(anova_model)
cat("\nTukey HSD post-hoc pairwise comparisons:\n")
print(tukey_result)


# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: VISUALISATIONS (5 ggplot2 charts)
# ─────────────────────────────────────────────────────────────────────────────

# ── Custom F1 theme ──────────────────────────────────────────────────────────
theme_f1 <- function(base_size = 13) {
  theme_minimal(base_size = base_size) +
    theme(
      plot.background    = element_rect(fill = "#0F0F0F", color = NA),
      panel.background   = element_rect(fill = "#1A1A1A", color = NA),
      panel.grid.major   = element_line(color = "#2E2E2E"),
      panel.grid.minor   = element_blank(),
      text               = element_text(color = "#E8E8E8", family = "sans"),
      plot.title         = element_text(color = "#E10600", face = "bold", size = base_size + 3),
      plot.subtitle      = element_text(color = "#AAAAAA", size = base_size - 1),
      plot.caption       = element_text(color = "#666666", size = 9, hjust = 1),
      axis.text          = element_text(color = "#CCCCCC"),
      axis.title         = element_text(color = "#CCCCCC", face = "bold"),
      legend.background  = element_rect(fill = "#1A1A1A", color = NA),
      legend.text        = element_text(color = "#CCCCCC"),
      legend.title       = element_text(color = "#E8E8E8", face = "bold"),
      strip.text         = element_text(color = "#E10600", face = "bold"),
      strip.background   = element_rect(fill = "#1A1A1A"),
      plot.margin        = margin(15, 15, 15, 15)
    )
}

f1_red    <- "#E10600"
f1_silver <- "#C0C0C0"
f1_gold   <- "#FFD700"
f1_white  <- "#F5F5F5"

dir.create("outputs/charts", recursive = TRUE, showWarnings = FALSE)

# ── Chart 1: Qualifying Grid vs Sprint Race Position (scatter) ───────────────
p1 <- master |>
  filter(!is.na(qual_position), !is.na(race_position)) |>
  ggplot(aes(x = qual_position, y = race_position, color = race_weekend)) +
  geom_jitter(width = 0.25, height = 0.25, size = 2.5, alpha = 0.8) +
  geom_smooth(method = "lm", formula = y ~ x, se = TRUE,
              color = f1_silver, linewidth = 1, alpha = 0.2) +
  scale_color_manual(
    values = c("China" = f1_red, "Miami" = "#00C8FF", "Canada" = f1_gold),
    name   = "Race Weekend"
  ) +
  scale_x_continuous(breaks = seq(1, 22, 2)) +
  scale_y_continuous(breaks = seq(1, 22, 2)) +
  labs(
    title    = "Does Sunday Qualifying Predict Sprint Race Finish?",
    subtitle = paste0("Spearman ρ = ", round(spearman_test$estimate, 3),
                      " | p ", ifelse(spearman_test$p.value < 0.001, "< 0.001",
                                      paste0("= ", round(spearman_test$p.value, 3)))),
    x        = "Qualifying Grid Position",
    y        = "Sprint Race Finishing Position",
    caption  = "F1 2026 Season · Sprint Weekends only"
  ) +
  theme_f1() +
  theme(legend.position = "right")

ggsave("outputs/charts/01_qual_vs_sprint_scatter.png", p1,
       width = 10, height = 7, dpi = 300, bg = "#0F0F0F")
cat("✅ Chart 1 saved\n")

# ── Chart 2: Grid positions gained/lost per driver (bar chart) ───────────────
p2 <- driver_stats |>
  mutate(driver = fct_reorder(driver, mean_grid_diff)) |>
  ggplot(aes(x = mean_grid_diff, y = driver,
             fill = mean_grid_diff > 0)) +
  geom_col(width = 0.7) +
  geom_vline(xintercept = 0, color = f1_white, linewidth = 0.5, linetype = "dashed") +
  scale_fill_manual(values = c("TRUE" = f1_red, "FALSE" = "#5A5A5A"),
                    labels = c("TRUE" = "Gained places", "FALSE" = "Lost places"),
                    name   = NULL) +
  scale_x_continuous(labels = function(x) ifelse(x > 0, paste0("+", x), x)) +
  labs(
    title    = "Average Positions Gained / Lost vs Sprint Grid",
    subtitle = "Positive = finished ahead of starting grid | Negative = dropped back",
    x        = "Mean Positions Gained (+) / Lost (−)",
    y        = NULL,
    caption  = "F1 2026 Season · Sprint Weekends only"
  ) +
  theme_f1() +
  theme(legend.position = "top")

ggsave("outputs/charts/02_grid_diff_by_driver.png", p2,
       width = 10, height = 8, dpi = 300, bg = "#0F0F0F")
cat("✅ Chart 2 saved\n")

# ── Chart 3: Sprint qualifying position by finish group (box plot) ────────────
p3 <- master_anova |>
  ggplot(aes(x = finish_group, y = sq_position, fill = finish_group)) +
  geom_boxplot(outlier.color = f1_red, outlier.size = 2, alpha = 0.8) +
  geom_jitter(width = 0.15, alpha = 0.4, color = f1_white, size = 1.5) +
  scale_fill_manual(values = c(
    "Podium (1–3)"   = f1_red,
    "Points (4–8)"   = "#FF6B35",
    "Midfield (9–15)"= "#4A90D9",
    "Tail (16+)"     = "#555555"
  )) +
  scale_y_reverse(breaks = seq(1, 22, 2)) +
  labs(
    title    = "Sprint Qualifying Position by Race Finishing Group",
    subtitle = "ANOVA tests whether these groups differ significantly",
    x        = "Finish Group",
    y        = "Sprint Qualifying Position (lower = better)",
    caption  = "F1 2026 Season · Sprint Weekends only"
  ) +
  theme_f1() +
  theme(legend.position = "none")

ggsave("outputs/charts/03_boxplot_sq_by_finish_group.png", p3,
       width = 10, height = 7, dpi = 300, bg = "#0F0F0F")
cat("✅ Chart 3 saved\n")

# ── Chart 4: Total sprint points by team (bar) ───────────────────────────────
p4 <- team_stats |>
  mutate(team = fct_reorder(team, total_points)) |>
  ggplot(aes(x = total_points, y = team, fill = total_points)) +
  geom_col(width = 0.7) +
  geom_text(aes(label = total_points), hjust = -0.2,
            color = f1_white, size = 3.5, fontface = "bold") +
  scale_fill_gradient(low = "#333333", high = f1_red) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.12))) +
  labs(
    title    = "Sprint Season Points by Constructor",
    subtitle = "Cumulative points across all 3 sprint race weekends (2026)",
    x        = "Total Sprint Points",
    y        = NULL,
    caption  = "F1 2026 Season · Sprint Weekends only"
  ) +
  theme_f1() +
  theme(legend.position = "none")

ggsave("outputs/charts/04_team_sprint_points.png", p4,
       width = 10, height = 7, dpi = 300, bg = "#0F0F0F")
cat("✅ Chart 4 saved\n")

# ── Chart 5: Sprint qualifying to race delta — faceted by weekend ─────────────
p5 <- master |>
  filter(!is.na(sprint_to_race_delta)) |>
  mutate(driver = str_split_fixed(driver, " ", 2)[, 2]) |>   # last name only
  ggplot(aes(x = sprint_to_race_delta,
             y = reorder(driver, sprint_to_race_delta),
             fill = sprint_to_race_delta > 0)) +
  geom_col(width = 0.7) +
  geom_vline(xintercept = 0, color = f1_white, linewidth = 0.4, linetype = "dashed") +
  scale_fill_manual(values = c("TRUE" = f1_red, "FALSE" = "#3A3A3A")) +
  facet_wrap(~race_weekend, scales = "free_y", ncol = 3) +
  labs(
    title    = "Sprint Qualifying → Sprint Race Position Delta",
    subtitle = "Positive = improved from sprint quali to sprint race finish",
    x        = "Positions Gained (+) / Lost (−)",
    y        = NULL,
    caption  = "F1 2026 Season · Sprint Weekends only"
  ) +
  theme_f1() +
  theme(
    legend.position = "none",
    axis.text.y     = element_text(size = 8)
  )

ggsave("outputs/charts/05_sprint_delta_facet.png", p5,
       width = 14, height = 8, dpi = 300, bg = "#0F0F0F")
cat("✅ Chart 5 saved\n")


# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: FEATURE ENGINEERING & LOGISTIC REGRESSION MODEL (Days 5–7)
# ─────────────────────────────────────────────────────────────────────────────

# ── 3.1  Prepare modelling dataset ───────────────────────────────────────────
model_data <- master |>
  filter(!is.na(race_position),
         !is.na(qual_position),
         !is.na(sq_position),
         !is.na(grid_position)) |>
  select(podium_finish, qual_position, sq_position,
         grid_position, grid_diff, sprint_to_race_delta, race_weekend) |>
  mutate(race_weekend = as.factor(race_weekend))

cat("\nModelling dataset rows:", nrow(model_data), "\n")
cat("Podium class balance:\n")
print(table(model_data$podium_finish))
cat("(Note: severe imbalance expected — only 9 podium slots across 3 weekends)\n")

# ── 3.2  Train / test split (80/20, stratified) ──────────────────────────────
set.seed(2026)
split <- initial_split(model_data, prop = 0.80, strata = podium_finish)
train <- training(split)
test  <- testing(split)

cat("\nTrain rows:", nrow(train), "| Test rows:", nrow(test), "\n")

# ── 3.3  Recipe: preprocessing ───────────────────────────────────────────────
rec <- recipe(podium_finish ~ qual_position + sq_position +
                grid_position + grid_diff + sprint_to_race_delta + race_weekend,
              data = train) |>
  step_dummy(race_weekend) |>     # one-hot encode weekend
  step_normalize(all_numeric_predictors())  # centre & scale

# ── 3.4  Model spec: logistic regression ─────────────────────────────────────
log_spec <- logistic_reg(mode = "classification") |>
  set_engine("glm")

# ── 3.5  Workflow & fit ───────────────────────────────────────────────────────
wf <- workflow() |>
  add_recipe(rec) |>
  add_model(log_spec)

fit <- wf |> fit(data = train)

# ── 3.6  Evaluate on test set ────────────────────────────────────────────────
preds <- augment(fit, new_data = test)

# Confusion matrix
cat("\n──── Confusion Matrix ────\n")
cm <- conf_mat(preds, truth = podium_finish, estimate = .pred_class)
print(cm)

# Classification metrics
metrics_result <- metric_set(accuracy, precision, recall, f_meas)(
  preds, truth = podium_finish, estimate = .pred_class, event_level = "second"
)
cat("\n──── Classification Metrics (positive class = 1 = Podium) ────\n")
print(metrics_result)

# AUC-ROC
roc_data    <- roc(response  = as.numeric(as.character(test$podium_finish)),
                   predictor = preds$.pred_1)
auc_value   <- auc(roc_data)
cat("\nAUC-ROC:", round(auc_value, 4), "\n")

# Coefficient table
coef_tbl <- tidy(extract_fit_parsnip(fit)$fit) |>
  arrange(p.value)
cat("\n──── Logistic Regression Coefficients (sorted by p-value) ────\n")
print(coef_tbl)

# ── 3.7  AUC-ROC plot ────────────────────────────────────────────────────────
roc_df <- data.frame(
  specificity = roc_data$specificities,
  sensitivity = roc_data$sensitivities
)

p_roc <- ggplot(roc_df, aes(x = 1 - specificity, y = sensitivity)) +
  geom_area(fill = f1_red, alpha = 0.2) +
  geom_line(color = f1_red, linewidth = 1.5) +
  geom_abline(slope = 1, intercept = 0, color = "#666666",
              linewidth = 0.8, linetype = "dashed") +
  annotate("text", x = 0.65, y = 0.25,
           label = paste0("AUC = ", round(auc_value, 3)),
           color = f1_gold, size = 6, fontface = "bold") +
  labs(
    title    = "AUC-ROC: Predicting Sprint Race Podium Finishes",
    subtitle = "Logistic regression using qualifying position, sprint quali, and grid features",
    x        = "False Positive Rate (1 − Specificity)",
    y        = "True Positive Rate (Sensitivity)",
    caption  = "F1 2026 Season · Sprint Weekends only"
  ) +
  theme_f1()

ggsave("outputs/charts/06_auc_roc_curve.png", p_roc,
       width = 8, height = 7, dpi = 300, bg = "#0F0F0F")
cat("✅ AUC-ROC chart saved\n")


# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4a: DASHBOARD PANEL (patchwork) — ready for report
# ─────────────────────────────────────────────────────────────────────────────
dashboard <- (p1 | p2) / (p3 | p4) +
  plot_annotation(
    title    = "F1 2026 Sprint Season — Performance Dashboard",
    subtitle = "Qualifying, Sprint Qualifying & Sprint Race Analysis",
    caption  = "EA Portfolio Project · Isfaq · F1 2026 Season",
    theme    = theme(
      plot.background = element_rect(fill = "#0F0F0F", color = NA),
      plot.title      = element_text(color = f1_red, face = "bold", size = 16),
      plot.subtitle   = element_text(color = "#AAAAAA", size = 12),
      plot.caption    = element_text(color = "#666666", size = 9)
    )
  )

ggsave("outputs/charts/00_dashboard_panel.png", dashboard,
       width = 20, height = 14, dpi = 300, bg = "#0F0F0F")
cat("✅ Dashboard panel saved\n")


# ─────────────────────────────────────────────────────────────────────────────
# SESSION INFO (reproducibility)
# ─────────────────────────────────────────────────────────────────────────────
cat("\n──── Session Info ────\n")
sessionInfo()
