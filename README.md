# actions_test

このリポジトリには、GitHub Discussion に「顧客別リリース反映状況」を自動で追記するスクリプトと、その GitHub Actions ワークフローが含まれています。

## 対象スクリプト

- `scripts/update_discussion_table.sh`

## 概要

`update_discussion_table.sh`は、指定したリポジトリの Discussion を取得し、「顧客別リリース反映状況」セクションにチェックリスト形式でリリース項目を追加します。

追加される形式（例）:

- [ ] [v0.0.41:修正](https://github.com/owner/repo/releases/tag/v0.0.41)
  - [ ] 株式会社 A
  - [ ] 株式会社 B
  - [ ] 株式会社 C

リンクの URL は必ず実在するリリースタグ（`tag`）を参照するようにしており、表示テキストは`TITLE`のまま出力します。TITLE に`v0.0.41:修正`のように説明が含まれる場合でも、URL 部分は`v0.0.41`（あるいは存在する`0.0.41`）へリンクされます。

## 主な機能

- Discussion の作成/取得
- 既存のセクションがテーブル形式の場合はチェックリストへ変換して追記
- TITLE からタグ（v 付き/なし）を推定し、GitHub API で存在するタグを採用して URL を作成
- 顧客リストは`CUSTOMERS_CSV`環境変数で上書き可能（デフォルト: `株式会社A,株式会社B,株式会社C`）

## 環境変数

- `GH_TOKEN` (必須): GitHub API トークン
- `REPO` (必須): `owner/repo` 形式（例: `ruudrei/actions_test`）
- `TITLE` (必須): 追加対象のリリースのタイトル（例: `v0.0.41:修正` や `1.2.3` など）
- `DISCUSSION_TITLE` (必須): 対象の Discussion タイトル（例: `顧客別リリース反映状況`）
- `CUSTOMERS_CSV` (任意): 顧客名をカンマ区切りで指定（例: `株式会社A,株式会社B,株式会社C`）
- `RELEASE_TAG` (任意): リンクに使う明示的なタグ（指定しない場合は TITLE から候補を推定）

## GitHub Actions（yml）との対応と使い方（推奨）

このプロジェクトでは、基本的に GitHub Actions のワークフローからスクリプトを呼び出します。手動でローカル実行するのではなく、リリース公開イベント時（`release: published`）に自動実行されます。

- ワークフールファイル: `.github/workflows/post-release-checklist.yml`
- 呼び出しスクリプト: `scripts/update_discussion_table.sh`

ワークフロー内の主要な環境変数マッピング:

```
GH_TOKEN         ← secrets.GITHUB_TOKEN（Actionsが自動注入）
REPO             ← github.repository（owner/repo）
TITLE            ← github.event.release.name（リリース名。例: v0.0.41:修正）
RELEASE_TAG      ← github.event.release.tag_name（リンクURLに使う実在タグ）
DISCUSSION_TITLE ← 固定文字列（例: リリース反映チェックリスト）
CUSTOMERS_CSV    ← 固定または組織の運用方針に応じて設定
```

該当のワークフロー例（本リポジトリに同梱）:

```yaml
name: Post release checklist

on:
  release:
    types: [published]

jobs:
  update_discussion:
    runs-on: ubuntu-latest
    permissions:
      discussions: write
      contents: read
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
      - name: Update discussion table
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REPO: ${{ github.repository }}
          TITLE: ${{ github.event.release.name }}
          RELEASE_TAG: ${{ github.event.release.tag_name }}
          DISCUSSION_TITLE: "リリース反映チェックリスト"
          CUSTOMERS_CSV: "株式会社A,株式会社B,株式会社C"
        run: |
          bash scripts/update_discussion_table.sh
```
