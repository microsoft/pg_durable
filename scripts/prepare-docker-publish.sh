#!/usr/bin/env bash
set -euo pipefail

write_outputs() {
    local output_tag="$1"
    local output_version="$2"
    local output_ready="$3"

    {
        echo "tag=$output_tag"
        echo "version=$output_version"
        echo "ready=$output_ready"
    } >> "$GITHUB_OUTPUT"
}

case "$EVENT_NAME" in
    workflow_dispatch)
        tag="$INPUT_REF"
        ;;
    release)
        tag="$RELEASE_TAG"
        ;;
    workflow_run)
        if [ "$WORKFLOW_RUN_EVENT" != push ] || [ "$WORKFLOW_RUN_CONCLUSION" != success ]; then
            write_outputs "" "" false
            exit 0
        fi
        tag="$WORKFLOW_RUN_TAG"
        ;;
    *)
        echo "unsupported event: $EVENT_NAME" >&2
        exit 2
        ;;
esac

case "$tag" in
    v?*)
        version="${tag#v}"
        ;;
    *)
        echo "invalid release tag: $tag" >&2
        exit 2
        ;;
esac

if [ "$EVENT_NAME" = workflow_dispatch ]; then
    write_outputs "$tag" "$version" true
    exit 0
fi

is_draft="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft)"
assets="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')"

if [ "$is_draft" = true ]; then
    write_outputs "$tag" "$version" false
    exit 0
fi

has_pg17=false
has_pg18=false
if grep -Eq '^pg-durable-postgresql-17_.*_amd64\.deb$' <<< "$assets"; then
    has_pg17=true
fi
if grep -Eq '^pg-durable-postgresql-18_.*_amd64\.deb$' <<< "$assets"; then
    has_pg18=true
fi

if [ "$has_pg17" = true ] && [ "$has_pg18" = true ]; then
    write_outputs "$tag" "$version" true
elif [ "$EVENT_NAME" = release ]; then
    write_outputs "$tag" "$version" false
else
    echo "release $tag is missing a PostgreSQL 17 or 18 package" >&2
    exit 1
fi
