#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# SL-SRE Learning Hub — GitLab.cee Repo Setup Script
# Target namespace : hcm-service-lifecycle
# Pages URL        : https://hcm-service-lifecycle.pages.redhat.com/sl-sre-learning-hub
#
# What this script does:
#   1. Validates prerequisites (git, curl, GitLab PAT)
#   2. Creates the GitLab project via API (skips if already exists)
#   3. Initialises a local git repo and pushes the site files
#   4. Prints the Pages URL once the first CI pipeline completes
#
# Usage:
#   export GITLAB_TOKEN=<your-personal-access-token>
#   bash setup.sh
#
# The PAT needs at minimum: api, read_repository, write_repository scopes.
# Create one at: https://gitlab.cee.redhat.com/-/user_settings/personal_access_tokens
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GITLAB_HOST="https://gitlab.cee.redhat.com"
NAMESPACE="hcm-service-lifecycle"
PROJECT_NAME="sl-sre-learning-hub"
PROJECT_DESCRIPTION="SL-SRE Learning Hub — SOPs, certs, AI learning. Hosted on GitLab Pages."
DEFAULT_BRANCH="main"

PAGES_URL="https://${NAMESPACE}.pages.redhat.com/${PROJECT_NAME}"
REPO_URL="${GITLAB_HOST}/${NAMESPACE}/${PROJECT_NAME}.git"
API_URL="${GITLAB_HOST}/api/v4"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       SL-SRE Learning Hub — GitLab Pages Setup              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Namespace : ${CYAN}${NAMESPACE}${RESET}"
echo -e "  Project   : ${CYAN}${PROJECT_NAME}${RESET}"
echo -e "  Pages URL : ${CYAN}${PAGES_URL}${RESET}"
echo ""

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."

command -v git  >/dev/null 2>&1 || die "'git' not found. Please install git."
command -v curl >/dev/null 2>&1 || die "'curl' not found. Please install curl."

if [[ -z "${GITLAB_TOKEN:-}" ]]; then
  echo ""
  warn "GITLAB_TOKEN is not set."
  echo "  Create a Personal Access Token at:"
  echo "  ${GITLAB_HOST}/-/user_settings/personal_access_tokens"
  echo "  Required scopes: api, read_repository, write_repository"
  echo ""
  read -rsp "  Paste your GitLab PAT: " GITLAB_TOKEN
  echo ""
fi

[[ -n "$GITLAB_TOKEN" ]] || die "No GitLab token provided."
success "Prerequisites OK"

# ── 2. Verify token works ─────────────────────────────────────────────────────
info "Verifying GitLab token..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${API_URL}/user")

if [[ "$HTTP_STATUS" != "200" ]]; then
  die "Token verification failed (HTTP ${HTTP_STATUS}). Check your PAT and VPN/RH SSO."
fi
GITLAB_USERNAME=$(curl -s \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${API_URL}/user" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
success "Authenticated as: ${GITLAB_USERNAME}"

# ── 3. Resolve namespace ID ───────────────────────────────────────────────────
info "Resolving namespace '${NAMESPACE}'..."
NS_RESPONSE=$(curl -s \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${API_URL}/namespaces?search=${NAMESPACE}")
NAMESPACE_ID=$(echo "$NS_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for ns in data:
    if ns.get('path') == '${NAMESPACE}':
        print(ns['id'])
        break
" 2>/dev/null || true)

if [[ -z "$NAMESPACE_ID" ]]; then
  die "Namespace '${NAMESPACE}' not found. Make sure you have access to that group."
fi
success "Namespace ID: ${NAMESPACE_ID}"

# ── 4. Create project (idempotent) ────────────────────────────────────────────
info "Checking if project '${PROJECT_NAME}' already exists..."
EXISTING=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${API_URL}/projects/${NAMESPACE}%2F${PROJECT_NAME}")

if [[ "$EXISTING" == "200" ]]; then
  warn "Project already exists — skipping creation."
  PROJECT_ID=$(curl -s \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${API_URL}/projects/${NAMESPACE}%2F${PROJECT_NAME}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
else
  info "Creating project '${PROJECT_NAME}' under '${NAMESPACE}'..."
  CREATE_RESPONSE=$(curl -s \
    -X POST "${API_URL}/projects" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${PROJECT_NAME}\",
      \"path\": \"${PROJECT_NAME}\",
      \"namespace_id\": ${NAMESPACE_ID},
      \"description\": \"${PROJECT_DESCRIPTION}\",
      \"visibility\": \"internal\",
      \"initialize_with_readme\": false,
      \"default_branch\": \"${DEFAULT_BRANCH}\",
      \"pages_access_level\": \"public\"
    }")

  PROJECT_ID=$(echo "$CREATE_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
  if [[ -z "$PROJECT_ID" ]]; then
    error "Project creation failed. API response:"
    echo "$CREATE_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$CREATE_RESPONSE"
    die "Aborting."
  fi
  success "Project created (ID: ${PROJECT_ID})"
fi

# ── 5. Enable GitLab Pages ────────────────────────────────────────────────────
info "Ensuring Pages is enabled for project..."
curl -s -o /dev/null \
  -X PUT "${API_URL}/projects/${PROJECT_ID}" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"pages_access_level":"public"}' || warn "Could not update pages_access_level (may already be set)"
success "Pages access: public"

# ── 6. Initialise and push ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/index.html" ]]; then
  die "index.html not found in ${SCRIPT_DIR}. Run this script from the site root directory."
fi

info "Initialising git repository..."

# Embed token in URL for push (removed from git config afterwards)
PUSH_URL="https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST#https://}/${NAMESPACE}/${PROJECT_NAME}.git"

cd "$SCRIPT_DIR"

if [[ -d ".git" ]]; then
  warn ".git directory already exists — using existing repo."
  git remote set-url origin "$PUSH_URL" 2>/dev/null || git remote add origin "$PUSH_URL"
else
  git init -b "$DEFAULT_BRANCH"
  git remote add origin "$PUSH_URL"
fi

# Configure git identity if not set
git config user.email 2>/dev/null || git config user.email "${GITLAB_USERNAME}@redhat.com"
git config user.name  2>/dev/null || git config user.name  "${GITLAB_USERNAME}"

# Create .gitignore if absent
if [[ ! -f ".gitignore" ]]; then
  cat > .gitignore << 'GITIGNORE'
node_modules/
.DS_Store
*.swp
dist/
public/
GITIGNORE
  success "Created .gitignore"
fi

# Stage everything
git add -A

# Commit (skip if nothing to commit)
if git diff --cached --quiet; then
  warn "Nothing to commit — working tree clean."
else
  git commit -m "chore: initial SL-SRE Learning Hub deployment

- index.html: SRE Operations, Certifications, AI Learning, Resources tabs
- .gitlab-ci.yml: GitLab Pages pipeline
- Hosted at: ${PAGES_URL}
"
  success "Committed site files"
fi

# Push
info "Pushing to GitLab (${REPO_URL})..."
if git push -u origin "$DEFAULT_BRANCH" --force-with-lease 2>/dev/null || \
   git push -u origin "$DEFAULT_BRANCH" --force 2>/dev/null; then
  success "Push complete"
else
  die "Push failed. Check your PAT has write_repository scope and you have Developer+ access to the group."
fi

# Clear token from remote URL
git remote set-url origin "${GITLAB_HOST}/${NAMESPACE}/${PROJECT_NAME}.git"

# ── 7. Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                     ✅  Setup Complete                       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Repository : ${CYAN}${GITLAB_HOST}/${NAMESPACE}/${PROJECT_NAME}${RESET}"
echo -e "  Pipeline   : ${CYAN}${GITLAB_HOST}/${NAMESPACE}/${PROJECT_NAME}/-/pipelines${RESET}"
echo -e "  Pages URL  : ${GREEN}${PAGES_URL}${RESET}  ← live after pipeline passes"
echo ""
echo -e "  ${YELLOW}Note:${RESET} GitLab Pages may take 1-2 minutes to go live after"
echo -e "        the 'pages' job completes in the CI pipeline."
echo ""
echo -e "  If the original learning-hub course files exist locally, copy"
echo -e "  the 'courses/', 'assets/', and 'lib/' directories into this"
echo -e "  directory and re-run: ${CYAN}git add -A && git push${RESET}"
echo ""
