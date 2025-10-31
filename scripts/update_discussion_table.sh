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

# discussion の取得
DISCUSSION_JSON=$(gh api "repos/$OWNER/$NAME/discussions" --paginate)
DISCUSSION_ID=$(echo "$DISCUSSION_JSON" | jq -r ".[] | select(.title==\"$DISCUSSION_TITLE\") | .node_id" | head -n 1)

# discussion が無ければ作成
if [[ -z "$DISCUSSION_ID" ]]; then
  echo "ℹ️ Discussion not found. Creating..."
  CREATED=$(gh api -X POST "repos/$OWNER/$NAME/discussions" \
    -f title="$DISCUSSION_TITLE" \
    -f body=$'### 🧾 顧客別リリース反映状況\n\n(初期化済み)')
  DISCUSSION_ID=$(echo "$CREATED" | jq -r '.node_id')
fi

# で現在の本文を取得
CURRENT_BODY=$(gh api graphql -f query='
  query($id: ID!) { node(id: $id) { ... on Discussion { body } } }
' -f id="$DISCUSSION_ID" --jq '.data.node.body')
# ex)
# ### 🧾 顧客別リリース反映状況
# - [ ] v1.0.0: 〇〇 の追加
#   - [ ] 株式会社A
#   - [ ] 株式会社B
#   - [ ] 株式会社C
# - [ ] v1.1.0: 〇〇 の追加
#   - [ ] 株式会社A
#   - [ ] 株式会社B
#   - [ ] 株式会社C

# 保険: 未定義参照を防ぐために一旦初期化しておく
UPDATED_BODY=''

# 表形式からチェックリスト形式への移行と追加に対応
SECTION_HEADER='### 🧾 顧客別リリース反映状況'

# リリース名（Release.name）を取得（なければ空）
RELEASE_NAME=$(gh api -X GET "repos/$OWNER/$NAME/releases/tags/$TITLE" --jq '.name' 2>/dev/null || true)
if [[ "$RELEASE_NAME" == "null" ]]; then RELEASE_NAME=""; fi

# 追加する親行を作成
if [[ -n "$RELEASE_NAME" && "$RELEASE_NAME" != "$TITLE" ]]; then
  PARENT_LINE="- [ ] ${TITLE}: ${RELEASE_NAME} の追加"
else
  PARENT_LINE="- [ ] ${TITLE} の追加"
fi

# 子行（顧客）を作成
CHILD_LINES=""
for C in "${CUSTOMERS[@]}"; do
  CHILD_LINES+=$(printf "\n  - [ ] %s" "$C")
done

NEW_BLOCK=$(printf "%s%s\n\n" "$PARENT_LINE" "$CHILD_LINES")

if echo "$CURRENT_BODY" | grep -q "^${SECTION_HEADER}$"; then
  echo "🧩 既存セクションに追記"

  # セクションより前の本文
  PRE_SECTION=$(echo "$CURRENT_BODY" | sed "/^${SECTION_HEADER//\//\/}\$/,\$d")

  # セクション本文（ヘッダ以降）
  AFTER_HEADER=$(printf '%s\n' "$CURRENT_BODY" | sed -n "/^${SECTION_HEADER//\//\/}\$/,\$p" | tail -n +2)

  # 既存がテーブルでなければ、そのまま追記（初期化文のみの可能性もあり）
  CLEANED_AFTER=$(printf '%s' "$AFTER_HEADER" | sed '/^(初期化済み)/d')
  
  # 余計な先頭の空行は1つに圧縮
  CLEANED_AFTER=$(printf '%s' "$CLEANED_AFTER" | awk 'BEGIN{blank=0} {if(NF==0){blank++; if(blank==1) print; else next} else {blank=0; print}}')
  
  UPDATED_SECTION=$(printf "%s\n\n%s%s" "$SECTION_HEADER" "$CLEANED_AFTER" "$NEW_BLOCK")
  
  UPDATED_BODY=$(printf "%s\n%s\n" "$PRE_SECTION" "$UPDATED_SECTION")
else
  echo "🆕 セクションを新規作成"
  UPDATED_BODY=$(printf "%s\n\n%s\n\n%s" "$CURRENT_BODY" "$SECTION_HEADER" "$NEW_BLOCK")
fi

# api 呼び出しで discussion を更新
gh api graphql -f query='
mutation($id: ID!, $body: String!) {
  updateDiscussion(input: {discussionId: $id, body: $body}) { discussion { url } }
}
' -f id="$DISCUSSION_ID" --raw-field body="${UPDATED_BODY:-}"

echo "✅ Discussion updated"
