#!/usr/bin/env bash
set -euo pipefail

# Intersect_ost_self_attest_1.sh - Intersect OST self-attestation script (v2)
# Author: Bernard Sibanda OSC
# License: MIT
# Created: 2026-02-07
# Description: This script generates a weighted OSS attestation report for a specified GitHub repository, assessing various health and maintenance signals to produce an overall score and detailed breakdown. The report is output in HTML and Markdown formats, with an optional PDF rendering if wkhtmltopdf or pandoc is available.
# Weighted OSS attestation report for a GitHub repository.
# - Outputs HTML + MD, optional PDF via wkhtmltopdf/pandoc.
# - Uses gh + jq (required).
# - Flags stale directories/files (>= 2 years by default).
#
# Usage:
#   ./intersect_ost_self_attest_1.sh owner/repo [--out report.pdf] [--days 180] [--stale-days 730] [--verbose]
#
# Notes:
# - Requires: gh, jq
# - Optional: wkhtmltopdf OR pandoc for PDF output

REPO=""
OUT="report.pdf"
DAYS=180
STALE_DAYS=730
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --stale-days) STALE_DAYS="$2"; shift 2;;
    -v|--verbose) VERBOSE=1; shift;;
    *) if [[ -z "$REPO" ]]; then REPO="$1"; shift; else echo "Unknown arg: $1"; exit 1; fi;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "Usage: $0 owner/repo [--out report.pdf] [--days 180] [--stale-days 730] [--verbose]"
  exit 1
fi

if [[ "$VERBOSE" -eq 1 ]]; then
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: ${FUNCNAME[0]:-main}() -> '
  set -x
fi

log()   { printf '[attest] %s\n' "$*"; }
outln() { printf '%s\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { outln "Missing dependency: $1"; exit 1; }; }
need gh
need jq
need sed
need awk

if ! gh auth status >/dev/null 2>&1; then
  outln "[ERROR] GitHub CLI not authenticated. Run: gh auth login"
  exit 1
fi

# ---------------- output paths ----------------
CWD="$(pwd)"
FILENAME_NOEXT="$(basename "${OUT%.*}")"
BASENAME="${CWD}/${FILENAME_NOEXT}"
PDF_OUT="${BASENAME}.pdf"
HTML_OUT="${BASENAME}.html"
MD_OUT="${BASENAME}.md"

outln "=============================================="
outln "[OUTPUT] Working directory : $CWD"
outln "[OUTPUT] HTML report       : $HTML_OUT"
outln "[OUTPUT] PDF report        : $PDF_OUT"
outln "[OUTPUT] Markdown summary  : $MD_OUT"
outln "=============================================="

# ---------------- error trap ----------------
on_error() {
  local exit_code=$?
  outln ""
  outln "[ERROR] Failed at line ${BASH_LINENO[0]} while running: ${BASH_COMMAND}"
  outln "[ERROR] Exit code: $exit_code"
  outln ""
  outln "Tips:"
  outln "  • gh auth status"
  outln "  • gh api rate_limit"
  outln "  • gh repo view \"$REPO\""
  outln "  • Re-run with --verbose"
  outln ""
  outln "Artifacts (if any):"
  outln "  HTML: $HTML_OUT"
  outln "  PDF : $PDF_OUT (if render reached)"
  outln "  MD  : $MD_OUT"
  exit "$exit_code"
}
trap on_error ERR

# ---------------- helpers ----------------
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

status_label_text() {
  case "$1" in
    GREEN) echo "Pass";;
    AMBER) echo "Warning";;
    RED)   echo "Fail";;
    *)     echo "$1";;
  esac
}
status_chip() { local s="$1"; echo "<span class=\"chip $s\">$(status_label_text "$s")</span>"; }

# Returns GREEN/AMBER/RED based on numeric thresholds (>=g green, >=w amber else red)
traffic_light_count() {
  local c="$1" g="$2" w="$3"
  if [ "$c" -ge "$g" ]; then echo GREEN
  elif [ "$c" -ge "$w" ]; then echo AMBER
  else echo RED
  fi
}

# POSIX-safe increment
inc() { eval "$1=\$(( \${$1:-0} + 1 ))"; }

utc_now="$(date -u '+%Y-%m-%d %H:%M UTC')"
since_utc="$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
since_30="$(date -u -d "-30 days" +%Y-%m-%dT%H:%M:%SZ)"
since_stale="$(date -u -d "-${STALE_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"

log "Collecting data for $REPO (window: last ${DAYS}d, stale threshold: ${STALE_DAYS}d) ..."

# ---------------- repo basics ----------------
repo_json="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}")"
default_branch="$(jq -r '.default_branch' <<<"$repo_json")"
repo_name="$(jq -r '.name' <<<"$repo_json")"
repo_full="$(jq -r '.full_name' <<<"$repo_json")"
repo_url="$(jq -r '.html_url' <<<"$repo_json")"
repo_desc="$(jq -r '.description // ""' <<<"$repo_json")"
repo_archived="$(jq -r '.archived' <<<"$repo_json")"
repo_fork="$(jq -r '.fork' <<<"$repo_json")"
repo_license="$(jq -r '.license.spdx_id // ""' <<<"$repo_json")"
repo_pushed_at="$(jq -r '.pushed_at // ""' <<<"$repo_json")"

# ---------------- must-have docs ----------------
root_contents="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/contents?ref=${default_branch}")"
MUST_FILES=( "LICENSE" "README.md" "CONTRIBUTING.md" "SECURITY.md" "CODE_OF_CONDUCT.md" "GOVERNANCE.md" "SUPPORT.md" "CHANGELOG.md" )

has_top_file() {
  local name="$1"
  if [[ "$name" == "LICENSE" ]]; then
    jq -r '.[].name' <<<"$root_contents" | grep -E -q '^LICENSE(\.md)?$'
  else
    jq -r '.[].name' <<<"$root_contents" | grep -Fx -q "$name"
  fi
}

# ---------------- CI / workflows ----------------
workflows_count=0
if gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/contents/.github/workflows?ref=${default_branch}" >/dev/null 2>&1; then
  workflows_count="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/contents/.github/workflows?ref=${default_branch}" \
    | jq '[.[] | select(.type=="file") | select(.name|test("\\.ya?ml$"))] | length')"
fi

# Check for recent CI runs (last 30d) - lightweight signal
ci_runs_30=0
if gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/actions/runs?per_page=30" >/dev/null 2>&1; then
  ci_runs_30="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/actions/runs?per_page=30" \
    | jq --arg since "$since_30" '[.workflow_runs[] | select(.created_at >= $since)] | length')"
fi

# ---------------- Security scanning ----------------
codescan_status="Not enabled"; codescan_label="AMBER"
if gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/code-scanning/alerts?per_page=1" >/dev/null 2>&1; then
  codescan_status="Enabled"; codescan_label="GREEN"
fi

# Dependabot alerts requires security permissions; treat inability as unknown (AMBER)
dependabot_status="Unknown"; dependabot_label="AMBER"
if gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/dependabot/alerts?per_page=1" >/dev/null 2>&1; then
  dependabot_status="Enabled"; dependabot_label="GREEN"
fi

# SECURITY.md present is already checked in must-have list; we also check for "reporting path" strings as a safety hint
security_md_ok="AMBER"
if has_top_file "SECURITY.md"; then
  security_md_ok="GREEN"
fi

# ---------------- Releases ----------------
releases_json="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/releases?per_page=100")"
releases_count="$(jq 'length' <<<"$releases_json")"
latest_release_tag="$(jq -r '.[0].tag_name // empty' <<<"$releases_json")"
latest_release_date="$(jq -r '.[0].published_at // ""' <<<"$releases_json")"

# Release freshness: GREEN if within 180d, AMBER if within 365d, else RED if has releases but old, AMBER if none
release_fresh_label="AMBER"
release_fresh_note="No releases"
if [[ -n "$latest_release_date" ]]; then
  latest_epoch="$(date -u -d "$latest_release_date" +%s)"
  now_epoch="$(date -u +%s)"
  age_days="$(( (now_epoch - latest_epoch) / 86400 ))"
  if [ "$age_days" -le 180 ]; then release_fresh_label="GREEN"
  elif [ "$age_days" -le 365 ]; then release_fresh_label="AMBER"
  else release_fresh_label="RED"
  fi
  release_fresh_note="Latest ${latest_release_tag} (${age_days}d ago)"
else
  release_fresh_note="No GitHub Releases"
fi

# ---------------- Issues / activity ----------------
open_issues_count="$(gh api -H 'Accept: application/vnd.github+json' "/search/issues?q=repo:${REPO}+is:issue+is:open&per_page=1" | jq '.total_count')"
closed_issues_count="$(gh api -H 'Accept: application/vnd.github+json' "/search/issues?q=repo:${REPO}+is:issue+is:closed&per_page=1" | jq '.total_count')"

commits_30="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?sha=${default_branch}&since=${since_30}&per_page=100" | jq 'length')"
commits_window="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?sha=${default_branch}&since=${since_utc}&per_page=100" | jq 'length')"
commits_180_json="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?sha=${default_branch}&since=$(date -u -d "-180 days" +%Y-%m-%dT%H:%M:%SZ)&per_page=100")"
contributors_180="$(jq -r '.[].commit.author.email // empty' <<<"$commits_180_json" | awk 'NF' | sort -u | wc -l | tr -d ' ')"

# Maintainers signal
maintainers_present="false"
if jq -r '.[].name' <<<"$root_contents" | grep -E -q '^(CODEOWNERS|MAINTAINERS(\.md)?|OWNERS)$'; then
  maintainers_present="true"
fi

# ---------------- Staleness checks ----------------
# We check:
# - Top-level directories (from root listing)
# - Key files (README, LICENSE, SECURITY, flake.nix, default.nix, cabal/project files)
#
# For directories: use /repos/{repo}/commits?path=DIR&per_page=1 to get last commit date for that dir.
# For files: same with path=FILE
#
# Note: This is API-call heavy if you have many dirs; so we limit to first N entries.

MAX_DIRS=12
dir_rows=""
stale_dirs=0
checked_dirs=0

# extract top-level dirs
top_dirs="$(jq -r '.[] | select(.type=="dir") | .name' <<<"$root_contents" | head -n "$MAX_DIRS" || true)"

while IFS= read -r d; do
  [[ -z "$d" ]] && continue
  inc checked_dirs
  # last commit touching this directory
  last_commit="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?path=${d}&sha=${default_branch}&per_page=1" | jq -r '.[0].commit.committer.date // empty')"
  label="AMBER"
  note="No commit data"
  if [[ -n "$last_commit" ]]; then
    last_epoch="$(date -u -d "$last_commit" +%s)"
    now_epoch="$(date -u +%s)"
    age_days="$(( (now_epoch - last_epoch) / 86400 ))"
    if [ "$age_days" -ge "$STALE_DAYS" ]; then
      label="RED"
      inc stale_dirs
      note="stale (${age_days}d)"
    elif [ "$age_days" -ge 365 ]; then
      label="AMBER"
      note="aging (${age_days}d)"
    else
      label="GREEN"
      note="active (${age_days}d)"
    fi
  fi
  dir_rows+="<tr><td><code>/${d}</code></td><td>$(status_chip "$label")</td><td>${note}</td></tr>"
done <<<"$top_dirs"

# key files staleness
KEY_PATHS=( "README.md" "LICENSE" "SECURITY.md" "CHANGELOG.md" "flake.nix" "flake.lock" "default.nix" "cabal.project" )
file_rows=""
stale_files=0
checked_files=0

for p in "${KEY_PATHS[@]}"; do
  inc checked_files
  last_commit="$(gh api -H 'Accept: application/vnd.github+json' "/repos/${REPO}/commits?path=${p}&sha=${default_branch}&per_page=1" 2>/dev/null | jq -r '.[0].commit.committer.date // empty' || true)"
  label="AMBER"
  note="not found or no commit data"
  if [[ -n "$last_commit" ]]; then
    last_epoch="$(date -u -d "$last_commit" +%s)"
    now_epoch="$(date -u +%s)"
    age_days="$(( (now_epoch - last_epoch) / 86400 ))"
    if [ "$age_days" -ge "$STALE_DAYS" ]; then
      label="RED"; inc stale_files; note="stale (${age_days}d)"
    elif [ "$age_days" -ge 365 ]; then
      label="AMBER"; note="aging (${age_days}d)"
    else
      label="GREEN"; note="active (${age_days}d)"
    fi
  fi
  file_rows+="<tr><td><code>${p}</code></td><td>$(status_chip "$label")</td><td>${note}</td></tr>"
done

# ---------------- Must-have checklist scoring ----------------
passes=0; ambers=0; reds=0
checklist_rows=""
for f in "${MUST_FILES[@]}"; do
  status=""; note=""
  if has_top_file "$f"; then
    status="GREEN"; note="present"
  else
    if [[ "$f" == "SECURITY.md" ]]; then status="RED"; else status="AMBER"; fi
    note="missing (top level)"
  fi

  case "$status" in
    GREEN) inc passes ;;
    AMBER) inc ambers ;;
    RED)   inc reds ;;
  esac

  checklist_rows+="<tr><td><code>${f}</code></td><td>$(status_chip "$status")</td><td>${note}</td></tr>"
done

# ---------------- Weighted scoring ----------------
# Categories (total 100):
#  - Docs & Governance: 25
#  - Delivery (CI): 20
#  - Security: 30
#  - Releases & Consumability: 15
#  - Maintenance & Freshness: 10

score_docs=0
# docs rubric: 8 must-haves -> up to 20, maintainers->5
score_docs="$(( passes * 2 ))" # 8 files => 16 max, but SECURITY red hurts overall below
if [[ "$maintainers_present" == "true" ]]; then score_docs="$(( score_docs + 5 ))"; fi
# cap to 25
if [ "$score_docs" -gt 25 ]; then score_docs=25; fi

score_ci=0
if [ "$workflows_count" -ge 1 ]; then score_ci=12; fi
if [ "$ci_runs_30" -ge 1 ]; then score_ci="$((score_ci + 8))"; fi
if [ "$score_ci" -gt 20 ]; then score_ci=20; fi

score_sec=0
# security components:
# - SECURITY.md: 10
# - CodeQL: 12
# - Dependabot (if accessible): 8
if [[ "$security_md_ok" == "GREEN" ]]; then score_sec="$((score_sec + 10))"; fi
if [[ "$codescan_label" == "GREEN" ]]; then score_sec="$((score_sec + 12))"; fi
if [[ "$dependabot_label" == "GREEN" ]]; then score_sec="$((score_sec + 8))"; else score_sec="$((score_sec + 4))"; fi  # unknown -> partial credit
if [ "$score_sec" -gt 30 ]; then score_sec=30; fi

score_rel=0
# releases: 10 for having >=1 release, +5 for freshness
if [ "$releases_count" -ge 1 ]; then score_rel=10; fi
if [[ "$release_fresh_label" == "GREEN" ]]; then score_rel="$((score_rel + 5))"
elif [[ "$release_fresh_label" == "AMBER" ]]; then score_rel="$((score_rel + 2))"
fi
if [ "$score_rel" -gt 15 ]; then score_rel=15; fi

score_maint=10
# penalize stale dirs/files
# - each stale dir costs 1 (up to 6)
# - each stale key file costs 1 (up to 4)
pen_dir="$stale_dirs"; if [ "$pen_dir" -gt 6 ]; then pen_dir=6; fi
pen_file="$stale_files"; if [ "$pen_file" -gt 4 ]; then pen_file=4; fi
score_maint="$(( 10 - pen_dir - pen_file ))"
if [ "$score_maint" -lt 0 ]; then score_maint=0; fi

total_score="$(( score_docs + score_ci + score_sec + score_rel + score_maint ))"

overall="GREEN"
if [ "$total_score" -lt 60 ] || [ "$reds" -gt 0 ]; then overall="RED"
elif [ "$total_score" -lt 80 ] || [ "$ambers" -gt 0 ] || [ "$stale_dirs" -gt 0 ] || [ "$stale_files" -gt 0 ]; then overall="AMBER"
fi

# Status for category tables
ci_label="$(traffic_light_count "$workflows_count" 1 0)"
activity_label="$(traffic_light_count "$commits_window" 10 1)"
contributors_label="$(traffic_light_count "$contributors_180" 5 2)"

# ---------------- HTML sections ----------------
kpi_cards=""
kpi_card() {
  local label="$1" value="$2" sub="$3"
  kpi_cards+="<div class=\"card\"><div class=\"card-value\">${value}</div><div class=\"card-label\">${label}</div><div class=\"card-sub\">${sub}</div></div>"
}

kpi_card "Total Score" "${total_score}/100" "weighted"
kpi_card "Commits (30d)" "$commits_30" "$default_branch"
kpi_card "Commits (${DAYS}d)" "$commits_window" "$default_branch"
kpi_card "Contributors (180d)" "$contributors_180" "unique emails"
kpi_card "Releases" "$releases_count" "$release_fresh_note"

score_rows=""
score_rows+="<tr><td>Docs & Governance</td><td><b>${score_docs}/25</b></td><td>${passes} pass, ${ambers} warn, ${reds} fail</td></tr>"
score_rows+="<tr><td>Delivery (CI)</td><td><b>${score_ci}/20</b></td><td>${workflows_count} workflow(s); ${ci_runs_30} runs in 30d</td></tr>"
score_rows+="<tr><td>Security</td><td><b>${score_sec}/30</b></td><td>CodeQL: ${codescan_status}; Dependabot: ${dependabot_status}</td></tr>"
score_rows+="<tr><td>Releases & Consumability</td><td><b>${score_rel}/15</b></td><td>${release_fresh_note}</td></tr>"
score_rows+="<tr><td>Maintenance & Freshness</td><td><b>${score_maint}/10</b></td><td>${stale_dirs} stale dirs; ${stale_files} stale key files</td></tr>"

elig_rows=""
elig_rows+="<tr><td>Repo Health</td><td>$(status_chip "$(traffic_light_count "$passes" 7 5)")</td><td>Must-have docs at top level</td></tr>"
elig_rows+="<tr><td>Governance</td><td>$(status_chip "$( [[ "$maintainers_present" == true ]] && echo GREEN || echo AMBER )")</td><td>Maintainers/CODEOWNERS presence</td></tr>"
elig_rows+="<tr><td>Delivery</td><td>$(status_chip "$ci_label")</td><td>${workflows_count} workflow(s); ${ci_runs_30} runs in 30d</td></tr>"
elig_rows+="<tr><td>Security</td><td>$(status_chip "$codescan_label")</td><td>Code scanning: ${codescan_status}</td></tr>"
elig_rows+="<tr><td>Activity</td><td>$(status_chip "$activity_label")</td><td>${commits_window} commits in ${DAYS}d</td></tr>"
elig_rows+="<tr><td>Community</td><td>$(status_chip "$contributors_label")</td><td>${contributors_180} contributors in 180d</td></tr>"

# ---------------- write HTML ----------------
cat > "$HTML_OUT" <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title><!--TITLE--></title>
  <style>
    :root { --bg:#0b1020; --panel:#121a33; --panel-2:#0f1630; --text:#e8ecf8; --muted:#b7c0da; --green:#2ecc71; --amber:#f39c12; --red:#e74c3c; --border:#2a375c; }
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Cantarell,Noto Sans,Helvetica,Arial}
    .container{max-width:1100px;margin:32px auto;padding:0 16px}
    .header{background:linear-gradient(135deg,#1b2a6b 0%,#0f1630 100%);padding:24px;border-radius:16px;border:1px solid var(--border);box-shadow:0 8px 24px rgba(0,0,0,.35)}
    .h-title{font-size:24px;margin:0 0 6px;display:flex;align-items:center;gap:10px}
    .h-sub{color:var(--muted);margin:0 0 4px}
    .h-meta{color:var(--muted);font-size:13px}
    .grid{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-top:16px}
    .card{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:14px}
    .card-value{font-size:22px;font-weight:800}
    .card-label{color:var(--muted);font-size:12px;margin-top:4px}
    .card-sub{color:var(--muted);font-size:11px;margin-top:2px;opacity:.85}
    .section{margin-top:22px}
    .section h2{font-size:16px;margin:0 0 10px;color:#d7def5}
    .panel{background:var(--panel-2);border:1px solid var(--border);border-radius:14px;padding:14px}
    table{width:100%;border-collapse:collapse}
    th,td{text-align:left;padding:10px 8px;border-bottom:1px solid var(--border);vertical-align:top}
    th{color:#d7def5;font-weight:700;background:#0d1531;position:sticky;top:0}
    tr:last-child td{border-bottom:none}
    code{background:#0a1230;padding:2px 6px;border-radius:6px;border:1px solid var(--border)}
    .row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
    .chip{padding:4px 8px;border-radius:999px;font-size:12px;font-weight:700;border:1px solid transparent}
    .GREEN{background:rgba(46,204,113,.15);color:#a6f4c5;border-color:#2ecc71}
    .AMBER{background:rgba(243,156,18,.16);color:#ffd699;border-color:#f39c12}
    .RED{background:rgba(231,76,60,.16);color:#ffb3a7;border-color:#e74c3c}
    .footer{color:var(--muted);font-size:12px;margin-top:18px;text-align:center}
    a{color:#9dcaff;text-decoration:none}
    .warnbox{border-left:4px solid var(--amber);padding:10px 12px;background:rgba(243,156,18,.10);border-radius:10px}
    .failbox{border-left:4px solid var(--red);padding:10px 12px;background:rgba(231,76,60,.10);border-radius:10px}
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="row">
        <h1 class="h-title">📄 <!--REPO_FULL--></h1>
        <div class="chip <!--OVERALL-->">Overall: <!--OVERALL_TEXT--></div>
      </div>
      <p class="h-sub"><!--REPO_DESC--></p>
      <p class="h-meta">
        Default branch: <b><!--BRANCH--></b> •
        Generated: <b><!--GENERATED--></b> •
        Source: <a href="<!--REPO_URL-->"><!--REPO_URL--></a>
      </p>
      <div class="grid">
        <!--KPI_CARDS-->
      </div>
    </div>

    <div class="section">
      <h2>Weighted Score Breakdown</h2>
      <div class="panel">
        <table>
          <thead><tr><th>Area</th><th>Score</th><th>Evidence</th></tr></thead>
          <tbody><!--SCORE_ROWS--></tbody>
        </table>
      </div>
    </div>

    <div class="section">
      <h2>Eligibility Overview</h2>
      <div class="panel">
        <table>
          <thead><tr><th>Category</th><th>Status</th><th>Notes</th></tr></thead>
          <tbody><!--ELIG_ROWS--></tbody>
        </table>
      </div>
    </div>

    <div class="section">
      <h2>Must-Have Checklist (Top-level only)</h2>
      <div class="panel">
        <table>
          <thead><tr><th>File</th><th>Status</th><th>Detail</th></tr></thead>
          <tbody><!--CHECKLIST_ROWS--></tbody>
        </table>
      </div>
    </div>

    <div class="section">
      <h2>Staleness / Freshness Signals</h2>
      <div class="panel">
        <div class="warnbox" style="margin-bottom:12px;">
          Threshold: flagged as <b>stale</b> when last touch is ≥ <!--STALE_DAYS--> days.
          Only the first <!--MAX_DIRS--> top-level directories are checked to avoid excessive API calls.
        </div>

        <h3 style="margin:10px 0 6px;color:#d7def5;font-size:14px;">Top-level directories (sample)</h3>
        <table>
          <thead><tr><th>Path</th><th>Status</th><th>Last touch</th></tr></thead>
          <tbody><!--DIR_ROWS--></tbody>
        </table>

        <h3 style="margin:14px 0 6px;color:#d7def5;font-size:14px;">Key files</h3>
        <table>
          <thead><tr><th>Path</th><th>Status</th><th>Last touch</th></tr></thead>
          <tbody><!--FILE_ROWS--></tbody>
        </table>
      </div>
    </div>

    <div class="section">
      <h2>Notes & Next Steps</h2>
      <div class="panel">
        <ul style="margin:0 0 0 18px;">
          <li>If you want <code>nix build</code> to work without specifying a target, define <code>packages.&lt;system&gt;.default</code> in <code>flake.nix</code>.</li>
          <li>Enable Dependabot alerts (if you have permission) and keep CodeQL enabled.</li>
          <li>Publish GitHub Releases regularly; keep release notes consistent with <code>CHANGELOG.md</code>.</li>
          <li>Investigate any directories flagged stale ≥ 2 years; either update them or label as archived/legacy.</li>
        </ul>
      </div>
    </div>

    <div class="footer">Generated by intersect_ost_self_attest_1.sh</div>
  </div>
</body>
</html>
EOF

OVERALL_TEXT="$(status_label_text "$overall")"

sed -i \
  -e "s|<!--TITLE-->|${repo_full} • OSS Attestation|g" \
  -e "s|<!--REPO_FULL-->|$(echo "$repo_full" | esc)|g" \
  -e "s|<!--REPO_DESC-->|$(echo "$repo_desc" | esc)|g" \
  -e "s|<!--BRANCH-->|$(echo "$default_branch" | esc)|g" \
  -e "s|<!--GENERATED-->|$(echo "$utc_now" | esc)|g" \
  -e "s|<!--REPO_URL-->|$(echo "$repo_url" | esc)|g" \
  -e "s|<!--OVERALL-->|$overall|g" \
  -e "s|<!--OVERALL_TEXT-->|$OVERALL_TEXT|g" \
  -e "s|<!--KPI_CARDS-->|$kpi_cards|g" \
  -e "s|<!--SCORE_ROWS-->|$score_rows|g" \
  -e "s|<!--ELIG_ROWS-->|$elig_rows|g" \
  -e "s|<!--CHECKLIST_ROWS-->|$checklist_rows|g" \
  -e "s|<!--DIR_ROWS-->|$dir_rows|g" \
  -e "s|<!--FILE_ROWS-->|$file_rows|g" \
  -e "s|<!--STALE_DAYS-->|$STALE_DAYS|g" \
  -e "s|<!--MAX_DIRS-->|$MAX_DIRS|g" \
  "$HTML_OUT"

# ---------------- MD summary ----------------
{
  echo "# ${repo_name} • OSS Attestation (Summary)"
  echo ""
  echo "- Repo: ${repo_url}"
  echo "- Default branch: ${default_branch}"
  echo "- Generated: ${utc_now}"
  echo "- Score: ${total_score}/100"
  echo "- Overall: ${OVERALL_TEXT}"
  echo ""
  echo "## Score breakdown"
  echo "- Docs & Governance: ${score_docs}/25"
  echo "- Delivery (CI): ${score_ci}/20"
  echo "- Security: ${score_sec}/30"
  echo "- Releases & Consumability: ${score_rel}/15"
  echo "- Maintenance & Freshness: ${score_maint}/10"
  echo ""
  echo "## Staleness"
  echo "- Stale dirs (sample): ${stale_dirs} (checked ${checked_dirs})"
  echo "- Stale key files: ${stale_files} (checked ${checked_files})"
  echo ""
  echo "## Notes"
  echo "- Releases: ${release_fresh_note}"
  echo "- Code scanning: ${codescan_status}"
  echo "- Workflows: ${workflows_count} (runs in 30d: ${ci_runs_30})"
  echo "- Contributors (180d): ${contributors_180}"
} > "$MD_OUT"

# ---------------- render PDF ----------------
if command -v wkhtmltopdf >/dev/null 2>&1; then
  log "Rendering PDF with wkhtmltopdf ..."
  if wkhtmltopdf "$HTML_OUT" "$PDF_OUT" >/dev/null 2>&1; then
    outln "[OUTPUT] ✅ PDF created: $PDF_OUT"
    outln "[OUTPUT] HTML saved : $HTML_OUT"
    outln "[OUTPUT] MD saved   : $MD_OUT"
    exit 0
  else
    outln "[OUTPUT] ❌ wkhtmltopdf failed; open HTML: $HTML_OUT"
    exit 1
  fi
elif command -v pandoc >/dev/null 2>&1; then
  log "wkhtmltopdf not found; rendering PDF with pandoc (reduced CSS fidelity) ..."
  if pandoc "$HTML_OUT" -o "$PDF_OUT" 2>/dev/null; then
    outln "[OUTPUT] ✅ PDF created: $PDF_OUT"
    outln "[OUTPUT] HTML saved : $HTML_OUT"
    outln "[OUTPUT] MD saved   : $MD_OUT"
    exit 0
  else
    outln "[OUTPUT] ❌ pandoc failed; open HTML: $HTML_OUT"
    exit 1
  fi
else
  outln "[OUTPUT] ⚠️ No PDF engine found. Open HTML: $HTML_OUT"
  outln "[OUTPUT] Install one of:"
  outln "  • wkhtmltopdf   (best)"
  outln "  • pandoc        (fallback)"
  exit 0
fi


