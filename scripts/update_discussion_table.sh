#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${TITLE:?TITLE is required}"
: "${DISCUSSION_TITLE:?DISCUSSION_TITLE is required}"

OWNER="${REPO%/*}"
NAME="${REPO#*/}"

# 例: 環境変数 CUSTOMERS_CSV="株式会社A,株式会社B,株式会社C"
IFS=',' read -r -a CUSTOMERS <<< "${CUSTOMERS_CSV:-株式会社A,株式会社B,株式会社C}"

echo "🔍 Repository: $OWNER/$NAME"

DISCUSSION_JSON=$(gh api "repos/$OWNER/$NAME/discussions" --paginate)
DISCUSSION_ID=$(echo "$DISCUSSION_JSON" | jq -r ".[] | select(.title==\"$DISCUSSION_TITLE\") | .node_id" | head -n 1)

# 無ければ作成（任意）
if [[ -z "$DISCUSSION_ID" ]]; then
  echo "ℹ️ Discussion not found. Creating..."
  CREATED=$(gh api -X POST "repos/$OWNER/$NAME/discussions" \
    -f title="$DISCUSSION_TITLE" \
    -f body=$'### 🧾 顧客別リリース反映状況\n\n(初期化済み)')
  DISCUSSION_ID=$(echo "$CREATED" | jq -r '.node_id')
fi

CURRENT_BODY=$(gh api graphql -f query='
  query($id: ID!) { node(id: $id) { ... on Discussion { body } } }
' -f id="$DISCUSSION_ID" --jq '.data.node.body')

# すでに同じリリース行が存在するならスキップ
RELEASE_LINK="| [${TITLE}](https://github.com/${REPO}/releases/tag/${TITLE})"
if echo "$CURRENT_BODY" | grep -Fq "$RELEASE_LINK"; then
  echo "✅ Row for ${TITLE} already exists. No change."
  exit 0
fi

if echo "$CURRENT_BODY" | grep -q '^| リリース名'; then
  echo "🧩 Append to existing table"
  TABLE_HEADER=$(echo "$CURRENT_BODY" | grep -m1 '^| リリース名')
  SEPARATOR=$(echo "$CURRENT_BODY" | grep -m1 '^|[-]')
  EXISTING_ROWS=$(echo "$CURRENT_BODY" | awk 'BEGIN{p=0} /^| リリース名/{p=1;next} /^|[-]/{next} {if(p)print}')
  PRE_TABLE_CONTENT=$(echo "$CURRENT_BODY" | sed '/^| リリース名/,$d')

  NEW_ROW="$RELEASE_LINK"
  for _ in "${CUSTOMERS[@]}"; do NEW_ROW="${NEW_ROW} | ⬜"; done
  NEW_ROW="${NEW_ROW} |"

  UPDATED_TABLE=$(printf "%s\n%s\n%s\n%s\n" \
    "$TABLE_HEADER" "$SEPARATOR" "$EXISTING_ROWS" "$NEW_ROW")

  UPDATED_BODY=$(printf "%s\n%s\n" "$PRE_TABLE_CONTENT" "$UPDATED_TABLE")
else
  echo "🆕 Create new table"
  HEADER="| リリース名"
  for C in "${CUSTOMERS[@]}"; do HEADER="${HEADER} | ${C}"; done
  HEADER="${HEADER} |"

  SEPARATOR="|-------------"
  for _ in "${CUSTOMERS[@]}"; do SEPARATOR="${SEPARATOR}|------------"; done
  SEPARATOR="${SEPARATOR}|"

  NEW_ROW="$RELEASE_LINK"
  for _ in "${CUSTOMERS[@]}"; do NEW_ROW="${NEW_ROW} | ⬜"; done
  NEW_ROW="${NEW_ROW} |"

  UPDATED_BODY=$(printf "%s\n\n%s\n%s\n%s\n" \
    "### 🧾 顧客別リリース反映状況" "$HEADER" "$SEPARATOR" "$NEW_ROW")
fi

gh api graphql -f query='
  mutation($id: ID!, $body: String!) {
    updateDiscussion(input: {discussionId: $id, body: $body}) { discussion { url } }
  }
' -f id="$DISCUSSION_ID" --raw-field body="$UPDATED_BODY"

echo "✅ Discussion updated"
