#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${REPO:?REPO is required}"
: "${TITLE:?TITLE is required}"
: "${DISCUSSION_TITLE:?DISCUSSION_TITLE is required}"

OWNER="${REPO%/*}"
NAME="${REPO#*/}"

# 顧客一覧（デフォルト: 株式会社A,株式会社B,株式会社C）
IFS=',' read -r -a CUSTOMERS <<< "${CUSTOMERS_CSV:-株式会社A,株式会社B,株式会社C}"

SECTION_HEADER='### 顧客別リリース反映状況'

# 対象リリースのタグを決定（RELEASE_TAG が未設定なら TITLE から推定し、v付き/なしを両方試す）
RELEASE_TAG="${RELEASE_TAG:-}"
if [[ -z "$RELEASE_TAG" ]]; then
  CANDIDATES=()
  if [[ "$TITLE" =~ ([vV]?)([0-9]+(\.[0-9]+)+) ]]; then
    PREFIX="${BASH_REMATCH[1]}"
    VERSION_CORE="${BASH_REMATCH[2]}"
    if [[ -n "$PREFIX" ]]; then
      CANDIDATES+=("v${VERSION_CORE}" "${VERSION_CORE}")
    else
      CANDIDATES+=("${VERSION_CORE}" "v${VERSION_CORE}")
    fi
  fi
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    NAME_LOOKUP_TAG=$(gh api -X GET "repos/$OWNER/$NAME/releases" --paginate --jq "(.[] | select(.name==\"$TITLE\") | .tag_name) // empty" 2>/dev/null | head -n1 || true)
    if [[ -n "$NAME_LOOKUP_TAG" ]]; then
      CANDIDATES+=("$NAME_LOOKUP_TAG")
    fi
  fi
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    CANDIDATES+=("$TITLE")
  fi
  WORKING_TAG=""
  for cand in "${CANDIDATES[@]}"; do
    if gh api -X GET "repos/$OWNER/$NAME/releases/tags/$cand" >/dev/null 2>&1; then
      WORKING_TAG="$cand"
      break
    fi
  done
  RELEASE_TAG="${WORKING_TAG:-${CANDIDATES[0]}}"
fi

# 種別判定（対象外はスキップ）
KIND=""
case "$RELEASE_TAG" in
  backend_v*) KIND="backend_v" ;;
  learning_v*) KIND="learning_v" ;;
  v*) KIND="v" ;;
  *) KIND="" ;;
 esac

if [[ -z "$KIND" ]]; then
  echo "⏭️ Skip: Not a target release tag (v|backend_v|learning_v). tag=${RELEASE_TAG}"
  exit 0
fi

# 日本語ラベル
case "$KIND" in
  v)          LABEL_JA="フロントエンド" ;;
  backend_v)  LABEL_JA="バックエンド" ;;
  learning_v) LABEL_JA="ラーニング" ;;
  *)          LABEL_JA="$KIND" ;;
 esac
CATEGORY_HEADER="### ${LABEL_JA}"

# Discussion 取得/作成
DISCUSSION_JSON=$(gh api "repos/$OWNER/$NAME/discussions" --paginate)
DISCUSSION_ID=$(echo "$DISCUSSION_JSON" | jq -r ".[] | select(.title==\"$DISCUSSION_TITLE\") | .node_id" | head -n 1)
if [[ -z "$DISCUSSION_ID" ]]; then
  echo "ℹ️ Discussion not found. Creating..."
  CREATED=$(gh api -X POST "repos/$OWNER/$NAME/discussions" \
    -f title="$DISCUSSION_TITLE" \
    -f body=$'### 顧客別リリース反映状況\n\n(初期化済み)')
  DISCUSSION_ID=$(echo "$CREATED" | jq -r '.node_id')
fi

# 現在の本文
CURRENT_BODY=$(gh api graphql -f query='
  query($id: ID!) { node(id: $id) { ... on Discussion { body } } }
' -f id="$DISCUSSION_ID" --jq '.data.node.body')

# 追記するチェックリスト項目
RELEASE_LINK="[${TITLE}](https://github.com/${REPO}/releases/tag/${RELEASE_TAG})"
PARENT_LINE="- [ ] ${RELEASE_LINK}"
CHILD_LINES=""
for C in "${CUSTOMERS[@]}"; do
  CHILD_LINES+=$(printf "\n  - [ ] %s" "$C")
done
NEW_ITEM=$(printf "%s%s" "$PARENT_LINE" "$CHILD_LINES")
NEW_ITEM_WITH_RULE=$(printf "%s\n---\n\n" "$NEW_ITEM")

# セクションの存在確認
if echo "$CURRENT_BODY" | grep -q "^${SECTION_HEADER}$"; then
  # セクション前/後の分離
  PRE_SECTION=$(echo "$CURRENT_BODY" | sed "/^${SECTION_HEADER//\//\/}\$/,\$d")
  AFTER_SECTION=$(printf '%s\n' "$CURRENT_BODY" | sed -n "/^${SECTION_HEADER//\//\/}\$/,\$p" | tail -n +2)

  # 初期化文を除去し、余計な空行を整形
  CLEANED_AFTER=$(printf '%s' "$AFTER_SECTION" | sed '/^(初期化済み)/d')
  CLEANED_AFTER=$(printf '%s' "$CLEANED_AFTER" | awk 'BEGIN{blank=0} {if(NF==0){blank++; if(blank==1) print; else next} else {blank=0; print}}')

  if printf '%s\n' "$CLEANED_AFTER" | grep -q "^${CATEGORY_HEADER}$"; then
    echo "🔁 既存カテゴリ(${LABEL_JA})に追記"
    # 対象カテゴリブロックの開始・終了行を取得してから挿入位置を決定
    START_LINE=$(printf '%s\n' "$CLEANED_AFTER" | awk -v ch="${CATEGORY_HEADER}" '$0==ch{print NR; exit}')

    # カテゴリ終端（--- または次の ### 見出しの直前）に NEW_ITEM を挿入
    END_LINE=$(printf '%s\n' "$CLEANED_AFTER" | awk -v start="${START_LINE}" 'NR>start && /^### /{print NR; exit} END{ if (NR>=start) print NR+1 }')

    # 分割
    BEFORE_PART=""
    if [ "${START_LINE}" -gt 1 ]; then
      BEFORE_PART=$(printf '%s\n' "$CLEANED_AFTER" | sed -n "1,$((START_LINE-1))p")
    fi

    # カテゴリブロック（開始〜終了行）
    CATEGORY_BLOCK=$(printf '%s\n' "$CLEANED_AFTER" | sed -n "${START_LINE},$((END_LINE-1))p")

    # カテゴリブロックの前後を取得
    AFTER_PART=$(printf '%s\n' "$CLEANED_AFTER" | sed -n "${END_LINE},\$p")

    if printf '%s\n' "$CATEGORY_BLOCK" | grep -q '^---$'; then
      # 既存の区切り線の直前に挿入（区切り線は既存を利用）
      MODIFIED_BLOCK=$(printf '%s\n' "$CATEGORY_BLOCK" | awk -v nb="${NEW_ITEM}" 'BEGIN{done=0} { if (!done && $0=="---") { print ""; printf "%s", nb; print $0; done=1; next } print }')
    else
      # 区切り線が無い場合は末尾に（空行→---→空行を含めて）追記
      MODIFIED_BLOCK=$(printf '%s\n\n%s' "$CATEGORY_BLOCK" "$NEW_ITEM_WITH_RULE")
    fi

    UPDATED_AFTER=$(printf '%s\n%s\n%s\n' "$BEFORE_PART" "$MODIFIED_BLOCK" "$AFTER_PART")
    UPDATED_SECTION=$(printf "%s\n\n%s" "$SECTION_HEADER" "$UPDATED_AFTER")
  else
    echo "🧩 カテゴリ(${LABEL_JA})を新規作成して追記"
    UPDATED_SECTION=$(printf "%s\n\n%s\n\n%s\n\n%s" "$SECTION_HEADER" "$CLEANED_AFTER" "$CATEGORY_HEADER" "$NEW_ITEM_WITH_RULE")
  fi
  UPDATED_BODY=$(printf "%s\n%s\n" "$PRE_SECTION" "$UPDATED_SECTION")
else
  echo "🆕 セクションを新規作成"
  UPDATED_BODY=$(printf "%s\n\n%s\n\n%s" "$CURRENT_BODY" "$CATEGORY_HEADER" "$NEW_ITEM_WITH_RULE")
fi

# Discussion 本文を更新
gh api graphql -f query='
mutation($id: ID!, $body: String!) {
  updateDiscussion(input: {discussionId: $id, body: $body}) { discussion { url } }
}
' -f id="$DISCUSSION_ID" --raw-field body="${UPDATED_BODY:-}"

echo "✅ Discussion updated"
