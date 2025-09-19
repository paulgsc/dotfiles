{pkgs}:
pkgs.writeShellScriptBin "clippy-issues" ''
  set -euo pipefail

  FILE_FILTER=""

  # parse optional --file argument
  while [ $# -gt 0 ]; do
    case "$1" in
      --file)
        FILE_FILTER="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  echo "Collecting Clippy warnings and errors..."

  cargo clippy --message-format=json --color=never "$@" \
    | ${pkgs.jq}/bin/jq -c --arg file_filter "$FILE_FILTER" '
        select(.reason == "compiler-message")
        | .message
        | select(.level == "warning" or .level == "error")
        | {
            tool: "clippy",
            type: "lint",
            level: .level,
            code: (.code?.code // "NO_CODE"),
            rule: (.code?.code // "NO_RULE"),
            file: (.spans[0].file_name // "unknown"),
            line: (.spans[0].line_start // null),
            column: (.spans[0].column_start // null),
            message: (.message // .rendered),
            suggestion: (.spans[0].suggested_replacement // null)
          }
        | select($file_filter == "" or (.file | test($file_filter)))
    ' \
    | ${pkgs.jq}/bin/jq -s 'unique_by(.message) | sort_by(.file, .line)' \
    > clippy-issues.json

  issue_count=$(${pkgs.jq}/bin/jq 'length' clippy-issues.json)
  warning_count=$(${pkgs.jq}/bin/jq '[.[] | select(.level == "warning")] | length' clippy-issues.json)
  error_count=$(${pkgs.jq}/bin/jq '[.[] | select(.level == "error")] | length' clippy-issues.json)

  echo "Found $issue_count total issues ($error_count errors, $warning_count warnings)"
  echo "Saved Clippy issues to clippy-issues.json"

  if [ "$issue_count" -gt 0 ]; then
    echo ""
    echo "Top issues by file:"
    ${pkgs.jq}/bin/jq -r 'group_by(.file) | .[] | "\(.length) issues in \(.[0].file)"' clippy-issues.json | head -10
  fi
''
