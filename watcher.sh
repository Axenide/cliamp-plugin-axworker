#!/usr/bin/env bash
set -u

STATE_FILE="${AXWORKER_STATE_FILE:-$HOME/.local/share/cliamp/axworker-state.json}"
URL="${AXWORKER_URL:-http://localhost:8787}"
SECRET="${AXWORKER_SECRET:-devsecret}"
POLL="${AXWORKER_POLL:-2}"

echo "axworker watcher: $STATE_FILE -> $URL/update (poll ${POLL}s)"

last=""
while true; do
	if [[ -f $STATE_FILE ]]; then
		content="$(cat "$STATE_FILE" 2>/dev/null || true)"
		if [[ -n $content && $content != "$last" ]]; then
			if curl -fsS -X POST "$URL/update" \
				-H "authorization: Bearer $SECRET" \
				-H "content-type: application/json" \
				--data "$content" >/dev/null 2>&1; then
				last="$content"
			else
				echo "watcher: POST failed, will retry" >&2
			fi
		fi
	fi
	sleep "$POLL"
done
