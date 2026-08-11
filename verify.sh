#!/usr/bin/env bash
#
# PF2P_PROVENANCE — Phase 1 verification script (v3)
#
# Run this ON THE NAS, in the same directory as docker-compose.yml and .env,
# AFTER `docker compose up -d` has already been run manually by a human.
# This script does not start, stop, or modify the compose stack itself.
#
# v3 fixes vs v2:
#   - Corrected a typo ("$VERIFY RESPONSE" -> "$VERIFY_RESPONSE") that broke
#     Check 8b under `set -u`.
#   - Switched all reachability checks from https:// to http://, matching
#     the actual current deployment: the API and gateway containers serve
#     plain HTTP (uvicorn, no TLS configured). Transport is still encrypted
#     end-to-end by Tailscale's own WireGuard layer, but there is currently
#    NO application-layer TLS on top of that. This is a known, tracked gap
#    versus the original "HTTPS only, even over the private tunnel" design
#    goal -- deferred intentionally for Phase 1 (test-only, no real asset
#    data), to be added before Phase 2 real-asset registration work.
#
# Scope note: Tailscale reachability checks run FRoM THE NAS ITSELF are a
# self-check only — they prove the gateway is bound and answering on its
# Tailscale address, NOT that the iPad can reach it end-to-end. A separate
# manual step (Check 3 below) is required to actually prove iPad access.
#
# Safety design:
#   - RAW-safety checks operate exclusively against a disposable, unique,
#     per-run fixture directory created by THIS script using normal host
#     permissions. It NEVER touches or references an existing photograph.
#   - The script aborts before doing anything else if that fixture
#     directory unexpectedly already exists (should not happen given the
#     per-run unique name, but treated as a hard stop, not overwritten).
#   - The only persistent write this script performs anywhere is a single
#     SYSTEM_VERIFICATION provenance event, created via a real API call
#     (not a direct file poke) and INTENTIONALLY RETAINED afterward — it is
#     not deleted, per the append-only provenance model.
#   - No write/rename/delete is ever attempted through the API against
#     anything except the disposable RAW fixture — and that attempt is
#     EXPECTED to fail, which is what proves the boundary.

set -uo pipefail

# ---- Configuration -----------------------------------------------------
RAW_HOST_DIR="/volume1/Personal/Photos/RAW FILES"
RUN_ID="$(date +%Y%m%dT%H%M%S)_$$"
FIXTURE_SUBDIR="_pf2p_test_fixture_${RUN_ID}"     # unique per run
FIXTURE_NAME="pf2p_disposable_test.txt"
FIXTURE_HOST_PATH="${RAW_HOST_DIR}/${FIXTURE_SUBDIR}/${FIXTURE_NAME}"
FIXTURE_CONTAINER_PATH="/archive_readonly/RAW_FILES/${FIXTURE_SUBDIR}/${FIXTURE_NAME}"

API_SERVICE="pf2p-provenance-api"
GATEWAY_SERVICE="pf2p-gateway"

: "${TAILSCALE_IP:?TAILSCALE_IP must be set — source your .env first (
set -a; source .env; set +a)}"

LAN_IP="${PF2P_TEST_LAN_IP:-}"   # optional: run FROM ANOTHER LAN CLIENT with this set for Check 4 to be meaningful

RESULTS=()
PASS_COUNT=0
TOTAL=0

record() {
  local label="$1" ok="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$ok" = "0" ]; then
    RESULTS+=("[PASS] ${label}")
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    RESULTS+=("[FAIL] ${label}")
  fi
}

skip() {
  local label="$1"
  RESULTS+=("[SKIP] ${label}")
}

cleanup() {
  if [ -f "$FIXTURE_HOST_PATH" ]; then
    rm -f -- "$FIXTURE_HOST_PATH" 2>/dev/null
  fi
  if [ -d "${RAW_HOST_DIR}/${FIXTURE_SUBDIR}" ]; then
    rmdir "${RAW_HOST_DIR}/${FIXTURE_SUBDIR}" 2>/dev/null
  fi
}
trap cleanup EXIT

echo "PF2P PHASE 1 VERIFICATION"
echo

# ---- Preflight: fixture directory must not already exist ----
if [ -e "${RAW_HOST_DIR}/${FIXTURE_SUBDIR}" ]; then
  echo "ABORT: fixture directory ${FIXTURE_SUBDIR} already exists. Refusing to proceed."
  exit 2
fi
mkdir -- "${RAW_HOST_DIR}/${FIXTURE_SUBDIR}" || {
  echo "ABORT: could not create isolated per-run test subfolder under RAW FILES. No further checks run."
  exit 2
}
echo "disposable pf2p test fixture (run ${RUN_ID}) — safe to delete, not a real photograph" > "$FIXTURE_HOST_PATH" || {
  echo "ABORT: could not create disposable fixture file. No further checks run."
  exit 2
fi

# ---- Check 1: Compose services healthy ----
API_HEALTH=$(docker compose ps --format json "$API_SERVICE" 2>/dev/null | grep -o '"Health":"[a-z]*"' | head -1 | cut -d'"' -f4)
GW_HEALTH=$(docker compose ps --format json "$GATEWAY_SERVICE" 2>/dev/null | grep -o '"Health":"[a-z]*"' | head -1 | cut -d'"' -f4)
if [ "$API_HEALTH" = "healthy" ] && [ "$GW_HEALTH" = "healthy" ]; then
  record "Compose services healthy (api=${API_HEALTH}, gateway=${GW_HEALTH})" 0
else
  record "Compose services healthy (api=${API_HEALTH:-unknown}, gateway=${GW_HEALTH:-unknown})" 1
fi

# ---- Check 2: NAS self-check — gateway reachable via its Tailscale binding ----
# This proves the gateway is bound/listening on TAILSCALE_IP:8421 from the
# NAS's own vantage point. It is NOT proof of end-to-end iPad reachability
# (see Check 3, manual). Uses plain HTTP — see v3 header note re: TLS.
if curl -s --max-time 5 "http://${TAILSCALE_IP}:8421/v1/status" >/dev/null; then
  record "Gateway reachable via Tailscale binding (NAS self-check only)" 0
else
  record "Gateway reachable via Tailscale binding (NAS self-check only)" 1
fi

# ---- Check 3: iPad reachability — MANUAL, not scriptable from the NAS ----
echo
echo "[MANUAL STEP REQUIRED] Check 3 — iPad / Tailscale end-to-end reachability:"
echo "  On the iPad itself (connected to Tailscale), open or curl:"
echo "    http://${TAILSCALE_IP}:8421/v1/status"
echo "  Confirm a response is received. This cannot be verified by this script"
echo "  running on the NAS — it must be confirmed from the iPad."
skip "iPad reachable over Tailscale (confirm manually per instructions above)"
echo

# ---- Check 4: Gateway blocked over LAN IP (remote-client confirmation preferred) ----
if [ -n "$LAN_IP" ]; then
  if curl -s --max-time 5 "http://${LAN_IP}:8421/v1/status" >/dev/null 2>&1; then
    record "Gateway blocked over LAN IP" 1   # reachable = FAIL, boundary violated
  else
    record "Gateway blocked over LAN IP" 0
  fi
else
  echo "NOTE: PF2P_TEST_LAN_IP not set. This check is most meaningful when run"
  echo "FROM ANOTHER DEVICE on the LAN (not the NAS itself) against the NAS's"
  echo "ordinary LAN address. Skipping automated result; confirm manually if"
  echo "no remote LAN client is available for this run."
  skip "Gateway blocked over LAN IP (run from a remote LAN client)"
fi

# ---- Check 5: API not directly reachable (LAN or Tailscale) ----
API_TS_REACHABLE=1
API_LAN_REACHABLE=1
curl -s --max-time 5 "http://${TAILSCALE_IP}:8420/v1/status" >/dev/null 2>&1 && API_TS_REACHABLE=0
if [ -n "$LAN_IP" ]; then
  curl -s --max-time 5 "http://${LAN_IP}:8420/v1/status" >/dev/null 2>&1 && API_LAN_REACHABLE=0
fi
if [ "$API_TS_REACHABLE" = "0" ] || [ "$API_LAN_REACHABLE" = "0" ]; then
  record "API not directly reachable (LAN or Tailscale)" 1
else
  record "API not directly reachable (LAN or Tailscale)" 0
fi

# ---- Check 6: Gateway reaches API internally ----
if docker compose exec -T "$GATEWAY_SERVICE" curl -s --max-time 5 "http://${API_SERVICE}:8420/v1/status" >/dev/null; then
  record "Gateway reaches API internally" 0
else
  record "Gateway reaches API internally" 1
fi

# ---- Check 7: RAW fixture readable, write/rename/delete blocked ----
READ_OK=1
docker compose exec -T "$API_SERVICE" cat "$FIXTURE_CONTAINER_PATH" >/dev/null 2>&1 && READ_OK=0

WRITE_BLOCKED=0
RENAME_BLOCKED=0
DELETE_BLOCKED=0
docker compose exec -T "$API_SERVICE" sh -c "echo tamper >> '$FIXTURE_CONTAINER_PATH'" >/dev/null 2>&1 && WRITE_BLOCKED=1
docker compose exec -T "$API_SERVICE" sh -c "mv '$FIXTURE_CONTAINER_PATH' '${FIXTURE_CONTAINER_PATH}.renamed'" >/dev/null 2>&1 && RENAME_BLOCKED=1
docker compose exec -T "$API_SERVICE" sh -c "rm '$FIXTURE_CONTAINER_PATH'" >/dev/null 2>&1 && DELETE_BLOCKED=1

if [ "$READ_OK" = "0" ] && [ "$WRITE_BLOCKED" = "0" ] && [ "$RENAME_BLOCKED" = "0" ] && [ "$DELETE_BLOCKED" = "0" ]; then
  record "RAW fixture readable, write/rename/delete blocked" 0
else
  record "RAW fixture readable, write/rename/delete blocked" 1
fi

# ---- Check 8a: Provenance storage is writable (low-level) ----
STORAGE_MARKER="/data/db/.pf2p_storage_check_${RUN_ID}"
if docker compose exec -T "$API_SERVICE" sh -c "echo 'pf2p storage check $(date -u)' > '$STORAGE_MARKER' && cat '$STORAGE_MARKER'" >/dev/null 2>&1; then
  docker compose exec -T "$API_SERVICE" sh -c "rm -f '$STORAGE_MARKER'" >/dev/null 2>&1
  record "Provenance storage writable" 0
else
  record "Provenance storage writable" 1
fi

# ---- Check 8b: API records a real SYSTEM_VERIFICATION transaction (retained) ----
# Calls the dedicated verification endpoint over plain HTTP (
see v3 header
# note re: TLS). This event is NOT deleted afterward — it is a permanent,
# append-only provenance record proving a successful verification run.
VERIFY_RESPONSE=$(curl -s --max-time 5 -X POST \
  "http://${TAILSCALE_IP}:8421/v1/system/verify" \
  -H "Content-Type: application/json" \
  -d "{\"run_id\":\"${RUN_ID}\",\"source_client\":\"verify-script\"}")
VERIFY_EVENT_ID=$(printf '%s' "$VERIFY_RESPONSE" | grep -o '"event_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
if [ -n "$VERIFY_EVENT_ID" ]; then
  record "API recorded SYSTEM_VERIFICATION event (event_id=${VERIFY_EVENT_ID}, retained)" 0
else
  record "API recorded SYSTEM_VERIFICATION event" 1
fi

# ---- Report ----
echo
for line in "${RESULTS[@]}"; do
  echo "$line"
done
echo
echo "RESULT: ${PASS_COUNT}/${TOTAL} AUTOMATED CHECKS PASSED"
echo "(Check 3, iPad reachability, requires separate manual confirmation — see instructions above.)"
echo
if [ "$PASS_COUNT" -lt "$TOTAL" ]; then
  echo "One or more automated checks did not pass as expected. Do not proceed"
  echo "beyond this verification step — review failures above before any"
  echo "further action."
  exit 1
fi

exit 0
