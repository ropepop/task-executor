#!/usr/bin/env bash
set -euo pipefail

# Workflow-only long-running drain runner with adaptive continuation.
# Can be sourced for smoke tests; when executed directly it runs main().

normalize_bool() {
  local raw="${1:-false}"
  raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]')"
  case "${raw}" in
    true|1|yes|y|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

safe_int() {
  local raw="${1:-0}"
  if [[ "${raw}" =~ ^-?[0-9]+$ ]]; then
    echo "${raw}"
  else
    echo "0"
  fi
}

json_num() {
  local expr="${1}"
  local file="${2}"
  jq -r "${expr} | tonumber? // 0" "${file}" 2>/dev/null || echo 0
}

json_str() {
  local expr="${1}"
  local file="${2}"
  jq -r "${expr} // \"\"" "${file}" 2>/dev/null || echo ""
}

determine_runtime_tier() {
  local depth="$(safe_int "${1:-0}")"
  if [ "${depth}" -ge 8 ]; then
    echo "severe"
  elif [ "${depth}" -ge 3 ]; then
    echo "heavy"
  else
    echo "normal"
  fi
}

# Prints: effective_progress<TAB>rate_limit_only<TAB>decision_code<TAB>should_stop
# decision_code is one of: continue, no_backlog_remaining, max_chain_depth_reached,
# rate_limited_only_no_success, no_progress
evaluate_iteration_outcome() {
  local backlog_before="$(safe_int "${1}")"
  local backlog_after="$(safe_int "${2}")"
  local succeeded_count="$(safe_int "${3}")"
  local rate_limited_count="$(safe_int "${4}")"
  local rate_limit_only_in="$(normalize_bool "${5}")"
  local chain_depth="$(safe_int "${6}")"
  local max_chain_depth="$(safe_int "${7}")"

  local rate_limit_only="${rate_limit_only_in}"
  if [ "${rate_limit_only}" != "true" ] && [ "${succeeded_count}" -eq 0 ] && [ "${rate_limited_count}" -gt 0 ]; then
    rate_limit_only="true"
  fi

  local effective_progress="false"
  if [ "${succeeded_count}" -gt 0 ]; then
    effective_progress="true"
  elif [ "${backlog_after}" -lt "${backlog_before}" ] && [ "${rate_limit_only}" != "true" ]; then
    effective_progress="true"
  fi

  local decision_code="continue"
  local should_stop="false"
  if [ "${backlog_after}" -le 0 ]; then
    decision_code="no_backlog_remaining"
    should_stop="true"
  elif [ "${chain_depth}" -ge "${max_chain_depth}" ]; then
    decision_code="max_chain_depth_reached"
    should_stop="true"
  elif [ "${rate_limit_only}" = "true" ]; then
    decision_code="rate_limited_only_no_success"
    should_stop="true"
  elif [ "${effective_progress}" != "true" ]; then
    decision_code="no_progress"
    should_stop="true"
  fi

  printf "%s\t%s\t%s\t%s\n" "${effective_progress}" "${rate_limit_only}" "${decision_code}" "${should_stop}"
}

emit_summary() {
  local file="${GITHUB_STEP_SUMMARY:-}"
  local content="${1:-}"
  if [ -n "${file}" ]; then
    printf "%s\n" "${content}" >> "${file}"
  fi
}

run_self_test() {
  local out

  # Case: backlog cleared
  out="$(evaluate_iteration_outcome 10 0 2 0 false 1 500)"
  [ "$(echo "${out}" | cut -f3)" = "no_backlog_remaining" ]

  # Case: succeeded > 0 and backlog remains => continue
  out="$(evaluate_iteration_outcome 20 19 1 0 false 1 500)"
  [ "$(echo "${out}" | cut -f1)" = "true" ]
  [ "$(echo "${out}" | cut -f3)" = "continue" ]

  # Case: rate limited only => stop
  out="$(evaluate_iteration_outcome 20 20 0 5 true 1 500)"
  [ "$(echo "${out}" | cut -f3)" = "rate_limited_only_no_success" ]

  # Case: no progress => stop
  out="$(evaluate_iteration_outcome 20 20 0 0 false 1 500)"
  [ "$(echo "${out}" | cut -f3)" = "no_progress" ]

  # Case: depth reached => stop
  out="$(evaluate_iteration_outcome 20 19 1 0 false 500 500)"
  [ "$(echo "${out}" | cut -f3)" = "max_chain_depth_reached" ]

  echo "drain_runner self-test passed"
}

main() {
  if [ "${DRAIN_RUNNER_SELF_TEST:-0}" = "1" ]; then
    run_self_test
    return 0
  fi

  : "${STALLED_RUNNER_BASE_URL:?Missing STALLED_RUNNER_BASE_URL}"
  : "${CRON_SECRET:?Missing CRON_SECRET}"
  : "${GITHUB_TOKEN:?Missing GITHUB_TOKEN}"
  : "${GITHUB_REPOSITORY:?Missing GITHUB_REPOSITORY}"
  : "${GITHUB_REF_NAME:?Missing GITHUB_REF_NAME}"
  : "${GITHUB_RUN_ID:?Missing GITHUB_RUN_ID}"
  : "${GITHUB_EVENT_NAME:?Missing GITHUB_EVENT_NAME}"

  local chain_depth="$(safe_int "${CHAIN_DEPTH_INPUT:-0}")"
  local chain_origin="${CHAIN_ORIGIN_INPUT:-manual}"
  local run_budget_minutes="$(safe_int "${RUN_BUDGET_MINUTES_INPUT:-100}")"
  local max_request_timeout_sec="$(safe_int "${MAX_REQUEST_TIMEOUT_SEC_INPUT:-1800}")"
  local max_iterations="$(safe_int "${MAX_ITERATIONS_INPUT:-60}")"
  local min_iterations_before_chain="$(safe_int "${MIN_ITERATIONS_BEFORE_CHAIN_INPUT:-2}")"

  local run_budget_sec=$((run_budget_minutes * 60))
  local min_request_timeout_sec=120
  local target_request_timeout_sec=900
  local dispatch_buffer_sec=90
  local max_chain_depth=500
  local rate_limit_same_run_cooldown_sec=300
  local high_backlog_chain_threshold=300

  if [ "${run_budget_sec}" -lt 600 ]; then
    run_budget_sec=600
  fi
  if [ "${max_request_timeout_sec}" -lt "${min_request_timeout_sec}" ]; then
    max_request_timeout_sec="${min_request_timeout_sec}"
  fi
  if [ "${max_iterations}" -lt 1 ]; then
    max_iterations=1
  fi
  if [ "${min_iterations_before_chain}" -lt 1 ]; then
    min_iterations_before_chain=1
  fi

  local run_start_epoch
  run_start_epoch="$(date +%s)"

  local drain_url="${STALLED_RUNNER_BASE_URL%/}/api/internal/pipeline/operations/actions/drain"
  local decision_code=""
  local decision_reason=""
  local chain_action="none"
  local should_dispatch="false"
  local iteration_count=0

  local final_before_backlog=0
  local final_after_backlog=0
  local final_before_pending=0
  local final_before_dispatched=0
  local final_after_pending=0
  local final_after_dispatched=0
  local final_attempted_count=0
  local final_succeeded_count=0
  local final_failed_count=0
  local final_rate_limited_count=0
  local final_progress_hint=""
  local final_rate_limit_only=""
  local final_retry_after_sec=""
  local total_attempted_count=0
  local total_succeeded_count=0
  local total_failed_count=0
  local total_rate_limited_count=0
  local productive_iterations=0

  while [ "${iteration_count}" -lt "${max_iterations}" ]; do
    iteration_count=$((iteration_count + 1))

    local now_epoch elapsed_sec remaining_budget_sec available_for_request_sec
    now_epoch="$(date +%s)"
    elapsed_sec=$((now_epoch - run_start_epoch))
    remaining_budget_sec=$((run_budget_sec - elapsed_sec))
    available_for_request_sec=$((remaining_budget_sec - dispatch_buffer_sec))

    if [ "${available_for_request_sec}" -lt 30 ]; then
      decision_code="run_budget_exhausted"
      decision_reason="Run budget exhausted before next safe iteration"
      break
    fi

    local request_timeout_sec="${target_request_timeout_sec}"
    if [ "${request_timeout_sec}" -gt "${max_request_timeout_sec}" ]; then
      request_timeout_sec="${max_request_timeout_sec}"
    fi
    if [ "${request_timeout_sec}" -gt "${available_for_request_sec}" ]; then
      request_timeout_sec="${available_for_request_sec}"
    fi
    if [ "${request_timeout_sec}" -lt "${min_request_timeout_sec}" ]; then
      request_timeout_sec="${available_for_request_sec}"
    fi
    if [ "${request_timeout_sec}" -lt 30 ]; then
      decision_code="run_budget_exhausted"
      decision_reason="Not enough budget for a useful request window"
      break
    fi

    local runtime_tier
    runtime_tier="$(determine_runtime_tier "${chain_depth}")"

    local response_file status_code
    response_file="$(mktemp)"
    status_code="$(
      curl \
        --silent \
        --show-error \
        --connect-timeout 10 \
        --max-time "${request_timeout_sec}" \
        --output "${response_file}" \
        --write-out '%{http_code}' \
        --request POST \
        --header "Authorization: Bearer ${CRON_SECRET}" \
        --header "Content-Type: application/json" \
        --header "X-Cron-Source: task-executor" \
        --header "X-Cron-Run-Id: ${GITHUB_RUN_ID}" \
        --header "X-Cron-Event: ${GITHUB_EVENT_NAME}" \
        --header "X-Cron-Chain-Depth: ${chain_depth}" \
        --header "X-Cron-Runtime-Tier: ${runtime_tier}" \
        --header "X-Cron-Target-Runtime-Sec: ${request_timeout_sec}" \
        "${drain_url}"
    )"

    echo "Iteration ${iteration_count} status=${status_code} requestTimeoutSec=${request_timeout_sec} runtimeTier=${runtime_tier}"
    cat "${response_file}"

    if [ "${status_code}" -lt 200 ] || [ "${status_code}" -ge 300 ]; then
      echo "Operation queue drain failed"
      exit 1
    fi

    local before_pending before_dispatched after_pending after_dispatched
    local attempted_count succeeded_count failed_count rate_limited_count
    local progress_hint rate_limit_only retry_after_sec

    before_pending="$(json_num '(.data.before.pendingCount // .before.pendingCount // 0)' "${response_file}")"
    before_dispatched="$(json_num '(.data.before.dispatchedCount // .before.dispatchedCount // 0)' "${response_file}")"
    after_pending="$(json_num '(.data.after.pendingCount // .after.pendingCount // 0)' "${response_file}")"
    after_dispatched="$(json_num '(.data.after.dispatchedCount // .after.dispatchedCount // 0)' "${response_file}")"
    attempted_count="$(json_num '(.data.attemptedCount // .attemptedCount // 0)' "${response_file}")"
    succeeded_count="$(json_num '(.data.succeededCount // .succeededCount // 0)' "${response_file}")"
    failed_count="$(json_num '(.data.failedCount // .failedCount // 0)' "${response_file}")"
    rate_limited_count="$(json_num '(.data.rateLimitedCount // .rateLimitedCount // 0)' "${response_file}")"

    progress_hint="$(json_str '(if ((.data|type)=="object" and (.data|has("progressHint"))) then (if .data.progressHint==true then "true" elif .data.progressHint==false then "false" else "unset" end) elif has("progressHint") then (if .progressHint==true then "true" elif .progressHint==false then "false" else "unset" end) else "unset" end)' "${response_file}")"
    rate_limit_only="$(json_str '(if ((.data|type)=="object" and (.data|has("rateLimitOnly"))) then (if .data.rateLimitOnly==true then "true" elif .data.rateLimitOnly==false then "false" else "unset" end) elif has("rateLimitOnly") then (if .rateLimitOnly==true then "true" elif .rateLimitOnly==false then "false" else "unset" end) else "unset" end)' "${response_file}")"
    retry_after_sec="$(json_str '(.data.retryAfterSec // .retryAfterSec // "")' "${response_file}")"

    if [ "${rate_limit_only}" = "unset" ] || [ -z "${rate_limit_only}" ]; then
      rate_limit_only="false"
    fi

    local backlog_before backlog_after outcome effective_progress should_stop
    backlog_before=$((before_pending + before_dispatched))
    backlog_after=$((after_pending + after_dispatched))
    outcome="$(evaluate_iteration_outcome "${backlog_before}" "${backlog_after}" "${succeeded_count}" "${rate_limited_count}" "${rate_limit_only}" "${chain_depth}" "${max_chain_depth}")"
    effective_progress="$(echo "${outcome}" | cut -f1)"
    rate_limit_only="$(echo "${outcome}" | cut -f2)"
    decision_code="$(echo "${outcome}" | cut -f3)"
    should_stop="$(echo "${outcome}" | cut -f4)"

    final_before_pending="${before_pending}"
    final_before_dispatched="${before_dispatched}"
    final_after_pending="${after_pending}"
    final_after_dispatched="${after_dispatched}"
    final_before_backlog="${backlog_before}"
    final_after_backlog="${backlog_after}"
    final_attempted_count="${attempted_count}"
    final_succeeded_count="${succeeded_count}"
    final_failed_count="${failed_count}"
    final_rate_limited_count="${rate_limited_count}"
    final_progress_hint="${progress_hint}"
    final_rate_limit_only="${rate_limit_only}"
    final_retry_after_sec="${retry_after_sec}"
    total_attempted_count=$((total_attempted_count + attempted_count))
    total_succeeded_count=$((total_succeeded_count + succeeded_count))
    total_failed_count=$((total_failed_count + failed_count))
    total_rate_limited_count=$((total_rate_limited_count + rate_limited_count))
    if [ "${effective_progress}" = "true" ]; then
      productive_iterations=$((productive_iterations + 1))
    fi

    echo "Iteration ${iteration_count} backlogBefore=${backlog_before} backlogAfter=${backlog_after} succeeded=${succeeded_count} rateLimited=${rate_limited_count} progressHint=${progress_hint} rateLimitOnly=${rate_limit_only}"

    if [ "${should_stop}" = "true" ]; then
      case "${decision_code}" in
        no_backlog_remaining)
          decision_reason="No backlog remains after drain"
          ;;
        max_chain_depth_reached)
          decision_reason="Maximum chain depth reached (${chain_depth}/${max_chain_depth})"
          ;;
        rate_limited_only_no_success)
          local retry_sec
          retry_sec="$(safe_int "${retry_after_sec}")"
          local now2 remaining2
          now2="$(date +%s)"
          remaining2=$((run_budget_sec - (now2 - run_start_epoch)))
          if [ "${retry_sec}" -gt 0 ] && [ "${retry_sec}" -le "${rate_limit_same_run_cooldown_sec}" ] && [ "${remaining2}" -gt $((retry_sec + dispatch_buffer_sec + 30)) ] && [ "${iteration_count}" -lt "${max_iterations}" ]; then
            echo "Rate-limited-only iteration; retryAfterSec=${retry_sec}, sleeping and retrying in same run"
            sleep "${retry_sec}"
            continue
          fi
          decision_reason="Rate-limited-only without safe same-run retry window"
          ;;
        no_progress)
          decision_reason="No effective progress signal"
          ;;
        *)
          decision_reason="Stopped by safety condition"
          ;;
      esac
      break
    fi

    # Productive iteration; decide whether to continue same run or hand off to next run.
    local now3 remaining3
    now3="$(date +%s)"
    remaining3=$((run_budget_sec - (now3 - run_start_epoch)))
    if [ "${remaining3}" -le $((dispatch_buffer_sec + min_request_timeout_sec)) ]; then
      should_dispatch="true"
      chain_action="self_dispatch"
      decision_code="run_budget_exhausted_with_progress"
      decision_reason="Productive run reached budget boundary"
      break
    fi

    decision_code="continue_same_run"
    decision_reason="Productive iteration with remaining budget"
  done

  if [ -z "${decision_reason}" ]; then
    if [ "${decision_code}" = "run_budget_exhausted" ] && [ "${final_after_backlog}" -gt 0 ] && [ "${final_succeeded_count}" -gt 0 ]; then
      should_dispatch="true"
      chain_action="self_dispatch"
      decision_code="run_budget_exhausted_with_progress"
      decision_reason="Budget exhausted after productive work"
    else
      decision_reason="Stopped after reaching iteration or budget guard"
      chain_action="none"
    fi
  fi

  if [ "${final_after_backlog}" -le 0 ]; then
    should_dispatch="false"
    chain_action="none"
  fi
  if [ "${chain_depth}" -ge "${max_chain_depth}" ]; then
    should_dispatch="false"
    chain_action="none"
  fi
  if [ "${decision_code}" = "rate_limited_only_no_success" ] || [ "${decision_code}" = "no_progress" ]; then
    should_dispatch="false"
    chain_action="none"
  fi
  if [ "${should_dispatch}" = "true" ] && [ "${productive_iterations}" -lt 1 ]; then
    should_dispatch="false"
    chain_action="none"
    decision_code="no_productive_iterations_no_chain"
    decision_reason="Backlog remains but no productive iterations were observed"
  fi
  if [ "${should_dispatch}" = "true" ] && [ "${iteration_count}" -lt "${min_iterations_before_chain}" ] && [ "${final_after_backlog}" -lt "${high_backlog_chain_threshold}" ]; then
    should_dispatch="false"
    chain_action="none"
    decision_code="chain_guard_min_iterations_not_met"
    decision_reason="Chain guard blocked dispatch (iterations=${iteration_count} < min=${min_iterations_before_chain}, backlog=${final_after_backlog} < high=${high_backlog_chain_threshold})"
  fi

  local run_end_epoch elapsed_total_sec remaining_budget_sec
  run_end_epoch="$(date +%s)"
  elapsed_total_sec=$((run_end_epoch - run_start_epoch))
  remaining_budget_sec=$((run_budget_sec - elapsed_total_sec))
  if [ "${remaining_budget_sec}" -lt 0 ]; then
    remaining_budget_sec=0
  fi

  echo "Backlog before: ${final_before_backlog} (pending=${final_before_pending}, dispatched=${final_before_dispatched})"
  echo "Backlog after: ${final_after_backlog} (pending=${final_after_pending}, dispatched=${final_after_dispatched})"
  echo "Remaining backlog: ${final_after_backlog}"
  echo "Iterations executed: ${iteration_count}"
  echo "Productive iterations: ${productive_iterations}"
  echo "Attempted count: ${final_attempted_count}"
  echo "Succeeded count: ${final_succeeded_count}"
  echo "Failed count: ${final_failed_count}"
  echo "Rate-limited count: ${final_rate_limited_count}"
  echo "Total attempted count: ${total_attempted_count}"
  echo "Total succeeded count: ${total_succeeded_count}"
  echo "Total failed count: ${total_failed_count}"
  echo "Total rate-limited count: ${total_rate_limited_count}"
  echo "Progress hint: ${final_progress_hint}"
  echo "Rate-limit-only: ${final_rate_limit_only}"
  echo "Retry-after seconds: ${final_retry_after_sec}"
  echo "Chain context: depth=${chain_depth}, origin=${chain_origin}"
  echo "Chain guard: minIterationsBeforeChain=${min_iterations_before_chain}, highBacklogThreshold=${high_backlog_chain_threshold}"
  echo "Decision code: ${decision_code}"
  echo "Decision reason: ${decision_reason}"
  echo "Iteration count: ${iteration_count}/${max_iterations}"
  echo "Run budget sec: ${run_budget_sec}"
  echo "Remaining budget sec: ${remaining_budget_sec}"
  echo "Chain action: ${chain_action}"

  emit_summary "### Operation Queue Drain Summary"
  emit_summary ""
  emit_summary "- Backlog before: \`${final_before_backlog}\` (pending=\`${final_before_pending}\`, dispatched=\`${final_before_dispatched}\`)"
  emit_summary "- Backlog after: \`${final_after_backlog}\` (pending=\`${final_after_pending}\`, dispatched=\`${final_after_dispatched}\`)"
  emit_summary "- Remaining backlog: \`${final_after_backlog}\`"
  emit_summary "- Iterations executed: \`${iteration_count}\`"
  emit_summary "- Productive iterations: \`${productive_iterations}\`"
  emit_summary "- Attempted count: \`${final_attempted_count}\`"
  emit_summary "- Succeeded count: \`${final_succeeded_count}\`"
  emit_summary "- Failed count: \`${final_failed_count}\`"
  emit_summary "- Rate-limited count: \`${final_rate_limited_count}\`"
  emit_summary "- Total attempted count: \`${total_attempted_count}\`"
  emit_summary "- Total succeeded count: \`${total_succeeded_count}\`"
  emit_summary "- Total failed count: \`${total_failed_count}\`"
  emit_summary "- Total rate-limited count: \`${total_rate_limited_count}\`"
  emit_summary "- Progress hint: \`${final_progress_hint}\`"
  emit_summary "- Rate-limit-only: \`${final_rate_limit_only}\`"
  emit_summary "- Retry-after seconds: \`${final_retry_after_sec}\`"
  emit_summary "- Chain depth: \`${chain_depth}\` (max \`${max_chain_depth}\`)"
  emit_summary "- Chain origin: \`${chain_origin}\`"
  emit_summary "- Chain guard min iterations: \`${min_iterations_before_chain}\`"
  emit_summary "- Chain guard high backlog threshold: \`${high_backlog_chain_threshold}\`"
  emit_summary "- Decision code: \`${decision_code}\`"
  emit_summary "- Decision reason: ${decision_reason}"
  emit_summary "- Iteration count: \`${iteration_count}\` / \`${max_iterations}\`"
  emit_summary "- Run budget sec: \`${run_budget_sec}\`"
  emit_summary "- Remaining budget sec: \`${remaining_budget_sec}\`"
  emit_summary "- Chain action: \`${chain_action}\`"

  if [ "${should_dispatch}" != "true" ]; then
    return 0
  fi

  local next_chain_depth
  next_chain_depth=$((chain_depth + 1))

  local dispatch_url dispatch_response_file dispatch_payload dispatch_status
  dispatch_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/stalled-runner-cron.yml/dispatches"
  dispatch_response_file="$(mktemp)"
  dispatch_payload="$(
    jq -n \
      --arg ref "${GITHUB_REF_NAME}" \
      --arg chain_depth "${next_chain_depth}" \
      --arg chain_origin "auto-backlog" \
      --arg run_budget_minutes "${run_budget_minutes}" \
      --arg max_request_timeout_sec "${max_request_timeout_sec}" \
      --arg max_iterations "${max_iterations}" \
      --arg min_iterations_before_chain "${min_iterations_before_chain}" \
      '{
        ref:$ref,
        inputs:{
          chain_depth:$chain_depth,
          chain_origin:$chain_origin,
          run_budget_minutes:$run_budget_minutes,
          max_request_timeout_sec:$max_request_timeout_sec,
          max_iterations:$max_iterations,
          min_iterations_before_chain:$min_iterations_before_chain
        }
      }'
  )"

  dispatch_status="$(
    curl \
      --silent \
      --show-error \
      --connect-timeout 10 \
      --max-time 60 \
      --output "${dispatch_response_file}" \
      --write-out '%{http_code}' \
      --request POST \
      --header "Accept: application/vnd.github+json" \
      --header "Authorization: Bearer ${GITHUB_TOKEN}" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      --header "Content-Type: application/json" \
      --data "${dispatch_payload}" \
      "${dispatch_url}"
  )"

  echo "Self-dispatch status: ${dispatch_status}"
  if [ -s "${dispatch_response_file}" ]; then
    cat "${dispatch_response_file}"
  fi

  if [ "${dispatch_status}" -lt 200 ] || [ "${dispatch_status}" -ge 300 ]; then
    emit_summary "- Self-dispatch status: \`${dispatch_status}\`"
    emit_summary "- Self-dispatch result: failed"
    echo "Self-dispatch failed"
    exit 1
  fi

  emit_summary "- Self-dispatch status: \`${dispatch_status}\`"
  emit_summary "- Self-dispatch result: queued next worker with \`chain_depth=${next_chain_depth}\`"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
