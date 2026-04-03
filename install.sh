#!/usr/bin/env bash
# Quick installer for toolboxer
set -euo pipefail

BINDIR="${HOME}/.local/bin"
COMPDIR="${HOME}/.local/share/bash-completion/completions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing toolboxer..."

mkdir -p "$BINDIR"
mkdir -p "$COMPDIR"

install -m 755 "$SCRIPT_DIR/toolboxer" "$BINDIR/toolboxer"
install -m 644 "$SCRIPT_DIR/completions/toolboxer.bash" "$COMPDIR/toolboxer"

echo "Installed toolboxer to $BINDIR/toolboxer"
echo "Installed completions to $COMPDIR/toolboxer"

case ":$PATH:" in
    *:$BINDIR:*) ;;
    *)
        echo ""
        echo "NOTE: $BINDIR is not in your PATH. Add it to your shell profile:"
        echo "  export PATH=\"\$PATH:$BINDIR\""
        ;;
esac

echo ""
echo "Start a new shell or run: source $COMPDIR/toolboxer"
echo "Then run: toolboxer create"
