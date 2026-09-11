#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resolver="$repo_root/scripts/prepare-docker-publish.sh"
workflow="$repo_root/.github/workflows/docker-publish.yml"
test_dir="$repo_root/.test-prepare-docker-publish.$$"
fake_bin="$test_dir/bin"
output_file="$test_dir/github-output"
all_assets=$'pg-durable-postgresql-17_0.2.8_amd64.deb\npg-durable-postgresql-18_0.2.8_amd64.deb'

cleanup() {
    rm -rf "$test_dir"
}
trap cleanup EXIT

mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    *"--json isDraft"*)
        printf '%s\n' "${GH_TEST_DRAFT:?GH_TEST_DRAFT is required}"
        ;;
    *"--json assets"*)
        printf '%s\n' "${GH_TEST_ASSETS-}"
        ;;
    *)
        echo "unexpected gh invocation: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$fake_bin/gh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_case() {
    local name="$1"
    shift
    : > "$output_file"
    if ! PATH="$fake_bin:$PATH" \
        GITHUB_REPOSITORY=example/pg_durable \
        GITHUB_OUTPUT="$output_file" \
        "$@"; then
        fail "$name exited nonzero"
    fi
}

run_failure_case() {
    local name="$1"
    shift
    : > "$output_file"
    if PATH="$fake_bin:$PATH" \
        GITHUB_REPOSITORY=example/pg_durable \
        GITHUB_OUTPUT="$output_file" \
        "$@"; then
        fail "$name unexpectedly succeeded"
    fi
    echo "PASS: $name"
}

assert_output() {
    local key="$1"
    local expected="$2"
    grep -Fxq "$key=$expected" "$output_file" ||
        fail "expected $key=$expected, got: $(tr '\n' ' ' < "$output_file")"
}

assert_workflow_configuration() {
    local prepare_job
    local publish_job
    local workflow_permissions
    local expected_group
    local failures=0

    prepare_job="$(
        awk '
            /^  prepare:$/ { in_prepare = 1 }
            in_prepare && /^  [[:alnum:]_-]+:$/ && $0 != "  prepare:" { exit }
            in_prepare { print }
        ' "$workflow"
    )"
    publish_job="$(
        awk '
            /^  publish:$/ { in_publish = 1 }
            in_publish && /^  [[:alnum:]_-]+:$/ && $0 != "  publish:" { exit }
            in_publish { print }
        ' "$workflow"
    )"
    workflow_permissions="$(
        awk '
            /^permissions:$/ { in_permissions = 1 }
            in_permissions && /^env:$/ { exit }
            in_permissions { print }
        ' "$workflow"
    )"

    if grep -Fxq '    permissions:' <<< "$prepare_job" &&
        grep -Fxq '      contents: write' <<< "$prepare_job" &&
        [ "$(grep -Fxc '      contents: write' "$workflow")" -eq 1 ]; then
        echo "PASS: prepare_draft_release_permission"
    else
        echo "FAIL: prepare must be the only job granted contents: write" >&2
        failures=$((failures + 1))
    fi

    if grep -Fxq '  contents: read' <<< "$workflow_permissions" &&
        grep -Fxq '  packages: write' <<< "$workflow_permissions"; then
        echo "PASS: workflow_least_privilege"
    else
        echo "FAIL: workflow permissions must retain contents: read and packages: write" >&2
        failures=$((failures + 1))
    fi

    if [ "$(grep -Fxc "        if: steps.prepare.outputs.ready == 'true'" <<< "$prepare_job")" -eq 2 ] &&
        grep -Fq '          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' <<< "$prepare_job" &&
        grep -Fq '          TAG: ${{ steps.prepare.outputs.tag }}' <<< "$prepare_job" &&
        grep -Fq '          gh release download "${TAG}" \' <<< "$prepare_job" &&
        grep -Fq '            --pattern "pg-durable-postgresql-17_*_amd64.deb" \' <<< "$prepare_job" &&
        grep -Fq '            --pattern "pg-durable-postgresql-18_*_amd64.deb" \' <<< "$prepare_job" &&
        grep -Fq '        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1' <<< "$prepare_job" &&
        grep -Fq '          name: pg-durable-docker-packages-${{ github.run_id }}' <<< "$prepare_job" &&
        grep -Fq '          path: dist/*.deb' <<< "$prepare_job"; then
        echo "PASS: prepare_downloads_and_uploads_release_packages"
    else
        echo "FAIL: ready prepare job must download both release packages and upload one run-scoped artifact" >&2
        failures=$((failures + 1))
    fi

    if grep -Fq '        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1' <<< "$publish_job" &&
        grep -Fq '          name: pg-durable-docker-packages-${{ github.run_id }}' <<< "$publish_job" &&
        grep -Fq '          path: dist' <<< "$publish_job" &&
        grep -Fq 'compgen -G "dist/pg-durable-postgresql-${PG_MAJOR}_*_amd64.deb"' <<< "$publish_job" &&
        ! grep -Fq 'gh release download' <<< "$publish_job"; then
        echo "PASS: publish_consumes_prepared_package_artifact"
    else
        echo "FAIL: publish matrix must consume the prepared artifact and only check its matrix package" >&2
        failures=$((failures + 1))
    fi

    expected_group="  group: docker-publish-\${{ github.event.release.tag_name || (github.event_name == 'workflow_dispatch' && github.event.inputs.dry_run != 'true' && github.event.inputs.ref) || (github.event_name == 'workflow_run' && github.event.workflow_run.event == 'push' && github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.head_branch) || github.run_id }}"
    if grep -Fxq "$expected_group" "$workflow"; then
        echo "PASS: manual_dry_run_concurrency_isolated"
    else
        echo "FAIL: concurrency must isolate manual dry runs and ineligible workflow_run events by run ID" >&2
        failures=$((failures + 1))
    fi

    [ "$failures" -eq 0 ] || return 1
}

run_case manual_dry_run_draft env \
    EVENT_NAME=workflow_dispatch INPUT_REF=v0.2.8 INPUT_DRY_RUN=true \
    GH_TEST_DRAFT=true GH_TEST_ASSETS="$all_assets" \
    "$resolver"
assert_output tag v0.2.8
assert_output version 0.2.8
assert_output ready true
echo "PASS: manual_dry_run_draft"

run_case manual_push_draft env \
    EVENT_NAME=workflow_dispatch INPUT_REF=v0.2.8 INPUT_DRY_RUN=false \
    GH_TEST_DRAFT=true GH_TEST_ASSETS="$all_assets" \
    "$resolver"
assert_output ready false
echo "PASS: manual_push_draft"

run_failure_case manual_missing_assets env \
    EVENT_NAME=workflow_dispatch INPUT_REF=v0.2.8 INPUT_DRY_RUN=true \
    GH_TEST_DRAFT=true \
    GH_TEST_ASSETS=pg-durable-postgresql-17_0.2.8_amd64.deb \
    "$resolver"

run_case draft env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=true GH_TEST_ASSETS="$all_assets" \
    "$resolver"
assert_output ready false
echo "PASS: draft"

run_failure_case draft_missing_pg18 env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=true \
    GH_TEST_ASSETS=pg-durable-postgresql-17_0.2.8_amd64.deb \
    "$resolver"

run_failure_case draft_missing_pg17 env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=true \
    GH_TEST_ASSETS=pg-durable-postgresql-18_0.2.8_amd64.deb \
    "$resolver"

run_case early_release env \
    EVENT_NAME=release RELEASE_TAG=v0.2.8 \
    GH_TEST_DRAFT=false GH_TEST_ASSETS="" \
    "$resolver"
assert_output ready false
echo "PASS: early_release"

run_case packages_first_release env \
    EVENT_NAME=release RELEASE_TAG=v0.2.8 \
    GH_TEST_DRAFT=false GH_TEST_ASSETS="$all_assets" \
    "$resolver"
assert_output tag v0.2.8
assert_output version 0.2.8
assert_output ready true
echo "PASS: packages_first_release"

run_case package_complete env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=false GH_TEST_ASSETS="$all_assets" \
    "$resolver"
assert_output ready true
echo "PASS: package_complete"

run_case failed_upstream env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=failure WORKFLOW_RUN_TAG=v0.2.8 \
    "$resolver"
assert_output ready false
echo "PASS: failed_upstream"

run_failure_case missing_pg17 env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=false \
    GH_TEST_ASSETS=pg-durable-postgresql-18_0.2.8_amd64.deb \
    "$resolver"

run_failure_case missing_pg18 env \
    EVENT_NAME=workflow_run WORKFLOW_RUN_EVENT=push \
    WORKFLOW_RUN_CONCLUSION=success WORKFLOW_RUN_TAG=v0.2.8 \
    GH_TEST_DRAFT=false \
    GH_TEST_ASSETS=pg-durable-postgresql-17_0.2.8_amd64.deb \
    "$resolver"

assert_workflow_configuration

echo "All prepare-docker-publish tests passed"
