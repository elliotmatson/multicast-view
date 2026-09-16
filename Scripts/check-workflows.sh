#!/bin/bash
# Validates the GitHub Actions workflow files.
#
# An unparseable workflow does not fail loudly: GitHub creates a run with zero
# jobs, marks it failed, and there is no log to read. Catching it here is much
# cheaper than working that out from an empty run.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
for file in .github/workflows/*.yml; do
    if ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$file" 2>/tmp/wf-err; then
        echo "ok   $file"
    else
        echo "BAD  $file"
        sed 's/^/     /' /tmp/wf-err
        status=1
    fi
done
rm -f /tmp/wf-err
exit $status
