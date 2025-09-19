{pkgs}:
pkgs.writeShellScriptBin "cargo-errors" ''
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

  echo "Collecting Cargo compilation errors..."

  cargo check --message-format=json --color=never "$@" \
    | ${pkgs.jq}/bin/jq -c --arg file_filter "$FILE_FILTER" '
        select(.reason == "compiler-message")
        | .message
        | select(.level == "error")
        | {
            tool: "cargo",
            type: "compilation",
            level: .level,
            code: (.code?.code // "NO_CODE"),
            rule: (.code?.code // "NO_RULE"),
            file: (.spans[0].file_name // "unknown"),
            line: (.spans[0].line_start // null),
            column: (.spans[0].column_start // null),
            message: (.message // .rendered),
            rendered: .rendered,
            suggestion: (.spans[0].suggested_replacement // null),
            raw_spans: (.spans // [])
          }
        | select($file_filter == "" or (.file | test($file_filter)))
    ' \
    | ${pkgs.jq}/bin/jq -s 'unique_by(.message) | sort_by(.file, .line)' \
    > cargo-errors.json

  error_count=$(${pkgs.jq}/bin/jq 'length' cargo-errors.json)
  echo "Found $error_count compilation errors"
  echo "Saved errors to cargo-errors.json"

  if [ "$error_count" -gt 0 ]; then
    echo ""
    echo "Summary of errors:"
    ${pkgs.jq}/bin/jq -r '.[] | "  \(.code): \(.file):\(.line // "?")"' cargo-errors.json | head -10
    if [ "$error_count" -gt 10 ]; then
      echo "  ... and $((error_count - 10)) more"
    fi
  fi
''
