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
| `HANDSON-query-expansion-rag.md` | （発展課題）Query Expansion RAG を CloudShell でデプロイし源内と連携する手順書 |

---

## クイックスタート（CloudShell）

### 0. 事前条件
- 自分の AWS アカウントにサインインできること
- リージョンは **東京 (ap-northeast-1)** を使用
- 有効な支払い方法（クレジットカード等）が登録済みであること
  （新規アカウントだと一部の Bedrock モデル利用契約が通らないため）
- **AdministratorAccess 相当の IAM 権限**を持っていること
  （CDK が CloudFormation/IAM/Lambda/CloudFront/Cognito/DynamoDB/S3/KMS/API Gateway 等を作成するため）

#### 権限の自己診断（推奨）

ハンズオン開始前に CloudShell で以下を実行してください。すべて `allowed` なら準備 OK です。

```bash
ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "Caller: $ARN"
aws iam simulate-principal-policy \
  --policy-source-arn "$ARN" \
  --action-names \
    cloudformation:CreateStack \
    iam:CreateRole \
    iam:PassRole \
    lambda:CreateFunction \
    cloudfront:CreateDistribution \
    cognito-idp:CreateUserPool \
    dynamodb:CreateTable \
    s3:CreateBucket \
    apigateway:POST \
    kms:CreateKey \
    bedrock:InvokeModel \
    bedrock:ListFoundationModels \
  --query "EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}" \
  --output table
```

**結果の見方**

| 結果 | 意味 |
|------|------|
| すべて `allowed` | ✅ ハンズオン続行可能 |
| `implicitDeny` または `explicitDeny` | ⚠️ そのままだとデプロイ途中で詰まる可能性大。IAM 権限の見直しが必要 |
| `simulate-principal-policy` 自体が AccessDenied | ⚠️ そもそも `iam:SimulatePrincipalPolicy` 権限が無い ＝ Admin 相当ではない可能性大 |

**この診断の限界（参考）**

- Service Control Policy (SCP / Organizations) による制約は検出できません
- Bedrock のモデルアクセス（東京リージョン）有効化の有無は別途コンソールで確認してください
- 各サービスのクォータ（VPC 数・CloudFront ディストリビューション数等）は別途確認が必要です
- SSO（IAM Identity Center）経由の場合、ARN 形式によってはシミュレートが動かないことがあります

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

### 5. システム管理者に昇格

デプロイ直後はサインアップしたユーザー全員が一般ユーザー（`UserGroup`）で、ヘッダーに「チーム管理」メニューが出ません。
チーム作成・AI アプリ登録などを行うには、自分を **システム管理者（SystemAdminGroup）** に昇格させる必要があります。

#### 5-1. 源内 Web にサインアップしてログイン

デプロイ完了時に表示された CloudFront URL を開き、メールアドレス／パスワードでサインアップ → ログインします。

#### 5-2. CloudShell で昇格スクリプトを実行

源内リポジトリ同梱の `add-system-admin.sh`（公式スクリプト）を使います。

```bash
cd /tmp/genai-web
./scripts/add-system-admin.sh -handson <あなたのメールアドレス>
```

成功すると以下が表示されます。

```
完了: ユーザー '<メールアドレス>' を SystemAdminGroup に追加しました。
```

#### 5-3. 一度ログアウト → 再ログイン

権限は JWT トークンに埋め込まれているので、**昇格後は一度ログアウトして再ログインしないと反映されません**。
ヘッダー右上「アカウント」→「ログアウト」→ 再度ログイン。

#### 5-4. 確認

ヘッダー右上「アカウント」メニューに **「チーム管理」** が出現していれば成功です。
これでチーム作成・AI アプリ登録などができるようになります。

### 6. 再カスタマイズ（何度でも）
ソースは `/tmp/genai-web` に残っているので、編集して **手順4を再実行**するだけで反映されます。
2 回目以降は差分更新のため、初回より短時間で完了します（環境やログインユーザーは維持されます）。

### 7. 片付け
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

## 主催者向け：ローカル事前検証（Windows / WSL不要・任意）

`genai-web-cloudshell-helper.sh` の静的解析は shellcheck（スタンドアロン EXE、インストール不要）で
ローカル実行できます。本リポジトリには検証用ファイルは含まれていません。

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

## 発展課題: Query Expansion RAG との連携

源内 Web の AI アプリ機能（外部 AI API 連携）を試したい上級者向けの追加課題です。
デジタル庁が公開している **Query Expansion RAG API**（[digital-go-jp/genai-ai-api](https://github.com/digital-go-jp/genai-ai-api/tree/main/aws/query-expansion-rag)）を
CloudShell でデプロイし、源内 Web に外部 AI アプリとして連携登録するまでの手順を記載しています。

→ [HANDSON-query-expansion-rag.md](./HANDSON-query-expansion-rag.md)

> ⚠️ **OpenSearch Serverless を使うため継続課金が発生します。検証後は必ず削除してください。**
> また、このアプリは IAM Identity Center (SSO) 運用前提で設計されているため、
> 一般的な AWS アカウント環境でデプロイするには複数のハマりどころがあります。
> 詳細と回避策は手順書側に記載しています。

---

## ライセンス / 免責

- 源内 Web 本体は [digital-go-jp/genai-web](https://github.com/digital-go-jp/genai-web)（MIT、一部 ASL）です。
- 本ツールはその配布物を取得・デプロイするための**非公式の補助ラッパー**であり、
  デジタル庁とは無関係のコミュニティ成果物です。
- 源内リポジトリは Pull Request を受け付けていないため、本ツールはハンズオン配布用として
  独立管理します（本家への PR は想定しません）。
