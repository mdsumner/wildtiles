#!/bin/bash
# One-time bucket establishment (human, interactive, credentialed).
# Usage: ./setup.sh <bucket>     e.g. ./setup.sh tnbc
set -euo pipefail
BUCKET=${1:?usage: setup.sh <bucket>}
ENDPOINT=https://projects.pawsey.org.au
PROFILE=${AWS_PROFILE:-pawsey1197}

aws s3 mb "s3://$BUCKET" --profile "$PROFILE" --endpoint-url "$ENDPOINT" || true
sed "s/BUCKET/$BUCKET/" "$(dirname "$0")/policy.json" > /tmp/policy_$BUCKET.json
aws s3api put-bucket-policy --bucket "$BUCKET" --profile "$PROFILE" \
  --endpoint-url "$ENDPOINT" --policy "file:///tmp/policy_$BUCKET.json"

aws s3api put-bucket-cors --bucket "$BUCKET" --profile "$PROFILE" \
  --endpoint-url "$ENDPOINT" --cors-configuration '{
  "CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","HEAD"],
  "AllowedHeaders":["*"],"ExposeHeaders":["Content-Range","Content-Length","ETag"],
  "MaxAgeSeconds":3600}]}'

echo "verify: anonymous PUT must fail, anonymous GET of objects must work"
curl -sS -o /dev/null -w "anon PUT -> %{http_code} (expect 403)\n" \
  -X PUT "$ENDPOINT/$BUCKET/_probe" -d x
