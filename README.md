# genai-web-cloudshell-helper

> ⚠️ **非公式 / コミュニティ作成ツールです。デジタル庁公式のツールではありません。**
> デジタル庁「源内 Web」([digital-go-jp/genai-web](https://github.com/digital-go-jp/genai-web)) を
> AWS CloudShell 上でローカル環境構築なしにデプロイ・カスタマイズするための補助スクリプトです。
> 利用は自己責任でお願いします。

ローカルへの Node.js / AWS CLI / CDK / jq のインストールを一切せずに、
ブラウザの **AWS CloudShell** だけで源内 Web を構築・カスタマイズ・削除できます。
ハンズオンでの環境構築の手間をなくすことを目的としています。

---

## Author

**Crafted by Hideyuki Nagata** — [AWS Builder Center プロフィール](https://builder.aws.com/community/@hideg?tab=badges)
AWS Community Builder (AI Engineering, 2nd year)
Built with Kiro 🤖

---

## 同梱物

| ファイル | 用途 |
|----------|------|
| `genai-web-cloudshell-helper.sh` | 本体（`setup` / `deploy` / `destroy` のサブコマンド方式） |
| `cdk.json.handson-sample` | ハンズオン向けの構成サンプル（IP制限なし・監視オフ・セルフサインアップ有効） |
| `test/` | （主催者用）ローカル検証スクリプト |

---

## クイックスタート（CloudShell）

### 0. 事前条件
- 自分の AWS アカウントにサインインできること（デプロイに十分な IAM 権限。管理者相当を推奨）
- リージョンは **東京 (ap-northeast-1)** を使用

### 1. スクリプトを CloudShell に取り込む

**おすすめ: `curl` で 1 行取得**（CloudShell には curl がプリインストール済み）

```bash
curl -fsSL https://raw.githubusercontent.com/hide-G/genai-web-cloudshell-helper/main/genai-web-cloudshell-helper.sh -o genai-web-cloudshell-helper.sh
```

> 既に同名ファイルがあって最新版に置き換えたい場合は、上記がそのまま上書きします。
> （`-o` で同名指定。`-f` で 4xx/5xx 時にファイルを作らず終了します）

**代替: ブラウザからアップロード**

CloudShell 右上「アクション ▼ → ファイルのアップロード」で
`genai-web-cloudshell-helper.sh` を選択。
（同名ファイルが既にあるとアップロードに失敗するので、先に `rm -f ~/genai-web-cloudshell-helper.sh` してから）

### 2. ソース取得・準備
```bash
chmod +x genai-web-cloudshell-helper.sh
./genai-web-cloudshell-helper.sh setup
```
源内 Web のソースが `~/genai-web` に取得され、Node.js v22 の準備と `npm ci` まで自動実行されます。

### 3. （任意）カスタマイズ
取得したソースを編集します（CloudShell のエディタ `vi`、または「アクション → ファイルのダウンロード/アップロード」で差し替え）。
- ヘッダー/ロゴ: `/tmp/genai-web/packages/web/src/components/ui/Logo.tsx`
- フッター/コピーライト: `/tmp/genai-web/packages/web/src/components/ui/Footer.tsx`

これなら一発置換です:

```bash
sed -i 's/ここにロゴが入る/源内ハンズオン/g' /tmp/genai-web/packages/web/src/components/ui/Logo.tsx
sed -i 's/ここにロゴが入る/源内ハンズオン/g' /tmp/genai-web/packages/web/src/components/ui/Footer.tsx
sed -i 's/ここにコピーライトが入る/© JAWS-UG AIML支部/g' /tmp/genai-web/packages/web/src/components/ui/Footer.tsx
```

> `Logo.tsx` には「ここにロゴが入る」が 2 箇所（ランディングページ用と通常ページ用）あり、
> `sed` の `/g` フラグで両方とも一度に置換されます。文言部分（`源内ハンズオン` /
> `© JAWS-UG AIML支部`）はお好みで変更してください。

### 4. デプロイ
```bash
./genai-web-cloudshell-helper.sh deploy -e -handson
```
10〜20 分後、源内 Web の URL（CloudFront）が表示されます。

### 5. 再カスタマイズ（何度でも）
ソースは `~/genai-web` に残っているので、編集して **手順4を再実行**するだけで反映されます。
2 回目以降は差分更新のため、初回より短時間で完了します（環境やログインユーザーは維持されます）。

### 6. 片付け
```bash
./genai-web-cloudshell-helper.sh destroy -e -handson
```

---

## コマンドリファレンス

```
./genai-web-cloudshell-helper.sh <command> [options]

Commands:
  setup       ソース取得 + Node準備 + 依存導入（~/genai-web に保存）
  deploy      取得済みソースをデプロイ
  destroy     デプロイ済みスタックを削除
  help        ヘルプ表示

Common options:
  -d, --dir <path>           ソースディレクトリ (デフォルト: $HOME/genai-web)

setup options:
  -b, --branch <name>        ブランチ (デフォルト: main)

deploy/destroy options:
  -e, --env <name>           環境名 (例: -handson)

deploy options:
  -c, --cdk-context <path>   差し替える cdk.json のパス
  --use-repo-cdk-json        リポジトリの cdk.json をそのまま使う（自動調整しない）
```

---

## カスタマイズはデプロイ後も何度でも可能

このツールは「初回デプロイして終わり」ではありません。`setup` で取得したソースが
`~/genai-web` に残るため、次のサイクルを何度でも回せます。

```
編集（Logo.tsx / Footer.tsx など）→ deploy → 確認 → また編集 → deploy …
```

CDK は差分のみを更新するため、環境（DB・認証・URL）は維持されたまま、フロントエンドの
変更が CloudFront に反映されます。

---

## 重要な設計上の注意（なぜ自動調整するのか）

源内リポジトリ既定の `cdk.json` は `allowedIpV4AddressRanges` が **空配列 `[]`** です。
JavaScript では空配列も「真」と評価されるため、このままデプロイすると
**CloudFront 用 WAF が「許可 IP ゼロ＝全アクセス拒否」** となり、サイトが 403 になります。

本ツールの `deploy` は、`-c` も `--use-repo-cdk-json` も指定しない場合、ハンズオン向けに
以下を **自動適用**してこの罠を回避します。

- `allowedIpV4AddressRanges` / IPv6 / 国コード → **`null`**（IP 制限なし＝誰でもアクセス可）
- `selfSignUpEnabled` → **`true`**（自分でサインアップしてログイン可能）
- `monitoring` → **`false`**（ハンズオン向けに監視スタックを省略）
- `env` / `appEnv` → `-e` の値に合わせて設定

> アクセス元を絞りたい場合は、`cdk.json` の `allowedIpV4AddressRanges` に実 IP を
> `["203.0.113.10/32"]` のように設定し、`-c` で渡すか `--use-repo-cdk-json` を使ってください。
> **空配列のままにはしないでください（403 になります）。**

---

## デプロイ後の管理者設定（AIアプリ登録をする場合）

源内 Web には「チーム管理」機能があり、AI アプリの登録やメンバー追加は
**システム管理者 (SystemAdminGroup)** だけが行えます。デプロイ直後は管理者が未設定なので、
最初に自分を管理者にする必要があります（チャットを試すだけなら不要）。

```bash
# 1. まずサイトでサインアップ（セルフサインアップ有効）してユーザーを作る
# 2. 自分を管理者に昇格（源内リポジトリ同梱のスクリプトを使用）
cd ~/genai-web
./scripts/add-system-admin.sh -handson あなたのメールアドレス
# 3. 再ログインすると「アカウント」メニューに「チーム管理」が表示される
```

---

## 主催者向け：ローカル事前検証（Windows / WSL不要）

- `genai-web-cloudshell-helper.sh` の静的解析: shellcheck（スタンドアロン EXE 利用、インストール不要）
- `test/test-cdkjson-transform.js`: `deploy` の cdk.json 自動調整ロジックの単体テスト
  （空配列 WAF トラップを防げているかを検証。`node test/test-cdkjson-transform.js` で実行）

> 本体の `setup`/`deploy` は CloudShell（Amazon Linux 2023 / bash / Node22）での実行を前提に
> しています。Windows ローカルでの実行は想定していません（源内は Node v22 を engineStrict で
> 要求するため、ローカル実行は環境差で失敗しやすい）。

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| サイトが 403 になる | `allowedIp...` が空配列 `[]` になっていないか確認（本ツールの自動調整なら null になる） |
| `npm ci` が EBADENGINE で失敗 | Node が v22 でない。`setup` を実行して nvm 導入を確認 |
| `cdk bootstrap` で権限エラー | 実行ロールに CloudFormation/IAM/S3 等の権限が必要 |
| デプロイ成功だが AI 応答が出ない | Amazon Bedrock のモデルアクセス（東京）を有効化（`modelIds` のモデル） |
| 「チーム管理」が出ない | `add-system-admin.sh` で管理者登録後、再ログイン |

---

## ライセンス / 免責

- 源内 Web 本体は [digital-go-jp/genai-web](https://github.com/digital-go-jp/genai-web)（MIT、一部 ASL）です。
- 本ツールはその配布物を取得・デプロイするための**非公式の補助ラッパー**であり、
  デジタル庁とは無関係のコミュニティ成果物です。
- 源内リポジトリは Pull Request を受け付けていないため、本ツールはハンズオン配布用として
  独立管理します（本家への PR は想定しません）。
