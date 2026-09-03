#!/bin/bash
# Extracts the model-scoped weekly quota (e.g. "Weekly · Fable") that Claude Code shows in /usage.
#
# Source: ~/.claude.json -> .cachedUsageUtilization.utilization.limits[]
# Claude Code caches the /api/oauth/usage response there itself, so this needs no credentials and
# makes no network call. The key appears after a successful usage fetch (run /usage once) and is
# cleared on logout.
#
# This is NOT .rate_limits.seven_day, which is the all-models weekly quota. The model-scoped window
# has its own denominator and can sit far above or below the all-models figure.
#
# Selection mirrors Claude Code's own filter: kind == "weekly_scoped", and a case-insensitive match
# of scope.model.display_name against the overage-included-models allowlist.
#
# Prints the object below, or the bare value null when no such quota can be found. Never guesses.
#   {"fable_weekly_used_percentage":44,"fable_weekly_resets_at":"...","model":"Fable","observed_at":"..."}
#
# Only .cachedUsageUtilization and the allowlist are read; no credential or unrelated config is
# touched. Exit status is 0 whether or not a quota was found; non-zero means jq is missing.

set -u

CONFIG="${CLAUDE_CONFIG:-$HOME/.claude.json}"
MODEL="${1:-}"   # empty = any model on the overage-included allowlist

if ! command -v jq >/dev/null 2>&1; then
  echo "kannu-fable-usage: jq is required" >&2
  exit 2
fi

[ -r "$CONFIG" ] || { echo null; exit 0; }

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -c --arg model "$MODEL" --arg now "$NOW" '
  ( .cachedGrowthBookFeatures.tengu_usage_overage_included_models // [$model] )
    | map(ascii_downcase)
' "$CONFIG" >/dev/null 2>&1 || { echo null; exit 0; }

jq -c --arg model "$MODEL" --arg now "$NOW" '
  # The allowlist Claude Code filters per-model windows by; fall back to the requested model alone.
  # With no model argument, accept any model on the overage-included allowlist (that is what
  # Claude Code itself renders). With an explicit argument, that name alone is the filter.
  ( (.cachedGrowthBookFeatures.tengu_usage_overage_included_models // ["Fable","Fable 5"])
    | map(ascii_downcase) ) as $allow
  | ( $model | ascii_downcase ) as $wanted
  | ( .cachedUsageUtilization.utilization.limits // [] )
  | map(select(
        .kind == "weekly_scoped"
        and ((.scope.model.display_name? // "") != "")
        and ( (.scope.model.display_name | ascii_downcase) as $n
              | if $wanted == "" then ($allow | index($n)) != null else $n == $wanted end )
        and ((.percent | type) == "number")
    ))
  | if length == 0 then null
    else ( .[0]
           | { fable_weekly_used_percentage: .percent,
               fable_weekly_resets_at: .resets_at,
               model: .scope.model.display_name,
               observed_at: $now } )
    end
' "$CONFIG" 2>/dev/null || echo null
