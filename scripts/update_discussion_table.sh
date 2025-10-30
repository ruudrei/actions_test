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
# ex) 
# ### 🧾 顧客別リリース反映状況
# TABLE_HEADER="| リリース名 | 株式会社A | 株式会社B | 株式会社C |"
# |-------------|------------|------------|------------|
# | [v1.0.0](https://github.com/${REPO}/releases/tag/v1.0.0) | ⬜ | ⬜ | ⬜ |
# | [v1.1.0](https://github.com/${REPO}/releases/tag/v1.1.0) | ⬜ | ⬜ | ⬜ |
# ...


# すでに同じリリース行が存在するならスキップ
RELEASE_LINK="| [${TITLE}](https://github.com/${REPO}/releases/tag/${TITLE})"
if echo "$CURRENT_BODY" | grep -Fq "$RELEASE_LINK"; then
  echo "✅ Row for ${TITLE} already exists. No change."
  exit 0
fi

if echo "$CURRENT_BODY" | grep -q '^| リリース名'; then
  echo "🧩 既存のテーブルに追加"

  # 先頭が | リリース名 で始まる最初の行」を探し、その行全体を取得
  TABLE_HEADER=$(echo "$CURRENT_BODY" | grep -m1 '^| リリース名')
  # 行頭が | に続いて - で始まる最初の行」を探し、その行全体を取得
  SEPARATOR=$(echo "$CURRENT_BODY" | grep -m1 '^|[-]')
  # テーブルヘッダ行以降の既存行を取得
  EXISTING_ROWS=$(printf '%s\n' "$CURRENT_BODY" | awk 'BEGIN{p=0} /^\| リリース名/{p=1;next} /^\|[-]/{next} p{print}')
  # テーブルヘッダ行（| リリース名）以降を削除」して、テーブルの前にある本文部分だけを PRE_TABLE_CONTENT に格納
  PRE_TABLE_CONTENT=$(echo "$CURRENT_BODY" | sed '/^| リリース名/,$d')

# 新しい行を作成
  NEW_ROW="$RELEASE_LINK"
  # 各顧客列に対して未反映マークを追加
  for _ in "${CUSTOMERS[@]}"; do NEW_ROW="${NEW_ROW} | ⬜"; done
  # 行の終わりにパイプを追加
  NEW_ROW="${NEW_ROW} |"

  # 更新されたテーブルを組み立て
  UPDATED_TABLE=$(printf "%s\n%s\n%s\n%s\n" \
    "$TABLE_HEADER" "$SEPARATOR" "$EXISTING_ROWS" "$NEW_ROW")

  if [[ -z "$EXISTING_ROWS" ]]; then
    # 既存行が無ければ空行を挟まずにヘッダー・セパレータ・新行のみを出力
    UPDATED_TABLE=$(printf "%s\n%s\n%s\n" \
      "$TABLE_HEADER" "$SEPARATOR" "$NEW_ROW")
  else
    # 既存行があれば既存行を挟んで出力
    UPDATED_TABLE=$(printf "%s\n%s\n%s\n%s\n" \
      "$TABLE_HEADER" "$SEPARATOR" "$EXISTING_ROWS" "$NEW_ROW")

  # # 最終的な本文を組み立て
  UPDATED_BODY=$(printf "%s\n%s\n" "$PRE_TABLE_CONTENT" "$UPDATED_TABLE")

  fi


  # echoで各変数を確認
  echo "✅ 変数内容確認:"
  echo "TABLE_HEADER: $TABLE_HEADER"
  echo "SEPARATOR: $SEPARATOR"
  echo "EXISTING_ROWS: $EXISTING_ROWS"
  echo "PRE_TABLE_CONTENT: $PRE_TABLE_CONTENT"
  echo "UPDATED_TABLE: $UPDATED_TABLE"
  echo "UPDATED_BODY: $UPDATED_BODY"

else
  echo "🆕 新規にテーブルを作成"
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
