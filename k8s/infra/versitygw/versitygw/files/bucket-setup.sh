#!/bin/sh
# Creates one bucket and, if a policy is supplied, applies it.
#
# Shared by every bucket this chart owns: the IAM backend's own bucket (no
# policy), the shared cnpg-backups bucket, and one bucket per data client.
#
# Inputs (all from the environment):
#   ADMIN, S3, SIGV4            versitygw endpoints and sigv4 scope
#   ROOT_ACCESS_KEY_ID/SECRET   root credentials
#   BUCKET                      bucket name
#   POLICY_JSON                 bucket policy, or empty to skip step 2
set -eu

: "${POLICY_JSON:=}"

# 1. Ensure the bucket exists first -- PutBucketPolicy on a nonexistent
# bucket 404s. Owner goes in a HEADER, not a query param (a query param here
# 500s, not 400 -- see BOOTSTRAP.md), and the bucket name is a PATH segment.
code=$(curl -sS -o /tmp/resp -w '%{http_code}' \
  --aws-sigv4 "$SIGV4" \
  --user "${ROOT_ACCESS_KEY_ID}:${ROOT_SECRET_ACCESS_KEY}" \
  -H "x-vgw-owner: ${ROOT_ACCESS_KEY_ID}" \
  -X PATCH "$ADMIN/${BUCKET}/create")
echo "create-bucket ${BUCKET} -> HTTP $code"; cat /tmp/resp; echo

case "$code" in
  201) : ;;
  *)
    if ! grep -q "BucketAlreadyOwnedByYou\|BucketAlreadyExists" /tmp/resp; then
      echo "create-bucket failed"; exit 1
    fi
    ;;
esac

if [ -z "$POLICY_JSON" ]; then
  echo "${BUCKET}: no policy configured, done"
  exit 0
fi

# 2. Re-apply the full policy document -- bucket policies are replace, not
# merge, so the whole thing is re-declared every run. Plain S3 API, not the
# admin API. Always a 204 on success, no "already set" to special-case.
#
# PutBucketPolicy validates that every Principal names an EXISTING account
# (400 MalformedPolicy: Invalid principal), and this Job has no ordering
# guarantee relative to versitygw-create-users. Verified live: applying both
# at once raced and failed on the first attempt, only passing because
# Kubernetes' own Job-level pod-restart backoff happened to retry after the
# account existed -- not a guarantee. Retry explicitly and boundedly here
# instead of relying on that accident.
attempt=1
max_attempts=12
while true; do
  code=$(curl -sS -o /tmp/resp -w '%{http_code}' \
    --aws-sigv4 "$SIGV4" \
    --user "${ROOT_ACCESS_KEY_ID}:${ROOT_SECRET_ACCESS_KEY}" \
    -X PUT "$S3/${BUCKET}?policy" --data-binary "$POLICY_JSON")
  echo "put-bucket-policy ${BUCKET} attempt $attempt -> HTTP $code"; cat /tmp/resp; echo

  [ "$code" = "204" ] && break

  if ! grep -q "Invalid principal" /tmp/resp || [ "$attempt" -ge "$max_attempts" ]; then
    echo "put-bucket-policy failed"; exit 1
  fi
  attempt=$((attempt + 1))
  sleep 5
done
echo "${BUCKET}: bucket and policy reconciled"
