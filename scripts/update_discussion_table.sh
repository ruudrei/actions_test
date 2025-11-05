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

# CURRENTBODYの中身を確認
echo "✅ CURRENT_BODY preview:"
echo "---------------------------------"
echo "$CURRENT_BODY"
echo "---------------------------------"

# 保険: 未定義参照を防ぐために一旦初期化しておく
UPDATED_BODY=''

# 表形式からチェックリスト形式への移行と追加に対応
SECTION_HEADER='### 🧾 顧客別リリース反映状況'


# リリースタグ
# - RELEASE_TAG が未指定なら、TITLE 先頭から "v?x.x.x" を抽出
# - リポジトリ側のタグが v 付き/なし両方の可能性があるため、候補を両方試す
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

  # バージョン候補が見つからない場合は、リリース一覧から name 一致で tag_name を取得
  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    NAME_LOOKUP_TAG=$(gh api -X GET "repos/$OWNER/$NAME/releases" --paginate --jq "(.[] | select(.name==\"$TITLE\") | .tag_name) // empty" 2>/dev/null | head -n1 || true)
    if [[ -n "$NAME_LOOKUP_TAG" ]]; then
      CANDIDATES+=("$NAME_LOOKUP_TAG")
    fi
  fi

  # それでも候補が無ければ、最後の手段として TITLE を候補に
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

# リリース名（Release.name）を取得（なければ空）
RELEASE_NAME=$(gh api -X GET "repos/$OWNER/$NAME/releases/tags/$RELEASE_TAG" --jq '.name' 2>/dev/null || true)
if [[ "$RELEASE_NAME" == "null" ]]; then RELEASE_NAME=""; fi

# クリック可能なリリースリンク（リンク先はタグ、表示は TITLE）
RELEASE_LINK="[${TITLE}](https://github.com/${REPO}/releases/tag/${RELEASE_TAG})"

# リリース種別（v | backend_v | learning_v）の判定
RELEASE_KIND=""
case "$RELEASE_TAG" in
  backend_v*) RELEASE_KIND="backend_v" ;;
  learning_v*) RELEASE_KIND="learning_v" ;;
  v*) RELEASE_KIND="v" ;;
  *) RELEASE_KIND="" ;;
esac

# 種別が対象外なら終了（ワークフローは成功としてスキップ）
if [[ -z "$RELEASE_KIND" ]]; then
  echo "⏭️ Skip: Not a target release tag (v|backend_v|learning_v). tag=${RELEASE_TAG}"
  exit 0
fi

# 追加する親行（リリースリンク）を作成（種別はサブセクションで明示する）
PARENT_LINE="- [ ] ${RELEASE_LINK} "

# 子行（顧客別チェック項目）を作成
CHILD_LINES=""
for C in "${CUSTOMERS[@]}"; do
  CHILD_LINES+=$(printf "\n  - [ ] %s" "$C")
done

# 既存の本文に追加するため、新しいブロックを作成
NEW_BLOCK=$(printf "%s%s\n\n" "$PARENT_LINE" "$CHILD_LINES")

# サブセクション（種別）ヘッダ（日本語ラベルに変換）
case "$RELEASE_KIND" in
  v)          SUB_HEADER_LABEL="フロントエンド" ;;
  backend_v)  SUB_HEADER_LABEL="バックエンド" ;;
  learning_v) SUB_HEADER_LABEL="ラーニング" ;;
  *)          SUB_HEADER_LABEL="$RELEASE_KIND" ;;
esac
SUB_HEADER="#### ${SUB_HEADER_LABEL}"

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
  
  # 種別サブヘッダの有無で分岐
  if printf '%s\n' "$CLEANED_AFTER" | grep -q "^${SUB_HEADER}$"; then
    echo "🔁 既存のサブセクション(${RELEASE_KIND})に追記"
    # 対象サブセクションの末尾に NEW_BLOCK を挿入
    UPDATED_AFTER=$(printf '%s\n' "$CLEANED_AFTER" | awk -v sh="${SUB_HEADER}" -v nb="${NEW_BLOCK}" '
      BEGIN{in_sub=0}
      {
        if ($0==sh) { print $0; in_sub=1; next }
        if (in_sub && $0 ~ /^#### /) { print ""; printf "%s", nb; in_sub=0 }
        print $0
      }
      END{
        if (in_sub) { print ""; printf "%s", nb }
      }
    ')
    UPDATED_SECTION=$(printf "%s\n\n%s" "$SECTION_HEADER" "$UPDATED_AFTER")
  else
    echo "🧩 サブセクション(${RELEASE_KIND})を新規作成して追記"
    # 直前の本文と新しいリストの間に必ず空行を入れて描画崩れを防ぐ
    UPDATED_SECTION=$(printf "%s\n\n%s\n\n%s\n\n%s" "$SECTION_HEADER" "$CLEANED_AFTER" "$SUB_HEADER" "$NEW_BLOCK")
  fi

  UPDATED_BODY=$(printf "%s\n%s\n" "$PRE_SECTION" "$UPDATED_SECTION")
else
  echo "🆕 セクションを新規作成"
  UPDATED_BODY=$(printf "%s\n\n%s\n\n%s\n\n%s" "$CURRENT_BODY" "$SECTION_HEADER" "$SUB_HEADER" "$NEW_BLOCK")
fi

echo "✅ NEW_BLOCK preview:"
echo "---------------------------------"
echo "$NEW_BLOCK"
echo "---------------------------------"

# api 呼び出しで discussion を更新
gh api graphql -f query='
mutation($id: ID!, $body: String!) {
  updateDiscussion(input: {discussionId: $id, body: $body}) { discussion { url } }
}
' -f id="$DISCUSSION_ID" --raw-field body="${UPDATED_BODY:-}"

echo "✅ Discussion updated"
