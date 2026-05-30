# 発展ハンズオン：Query Expansion RAG API を CloudShell でデプロイし、源内 Web と連携する

> ⚠️ これは **発展（上級）課題** です。基本ハンズオン（源内 Web のデプロイ）が完了している前提です。
> 対象: [digital-go-jp/genai-ai-api](https://github.com/digital-go-jp/genai-ai-api) の `aws/query-expansion-rag`
>
> ⚠️⚠️ **コスト警告**: このアプリは **OpenSearch Serverless**（ベクトルDB）を作成します。
> 起動しているだけで **継続的に課金**（月数百ドル規模になり得る）されます。
> ハンズオン後は必ず `cdk destroy` で削除してください（後片付け章参照）。

このハンズオンでは、専用スクリプトを使わず **CloudShell にコマンドを手入力**して
RAG API をデプロイし、基本ハンズオンで作った源内 Web に「外部 AI アプリ」として連携登録します。

> ⚠️ **重要**: このアプリは **IAM Identity Center (SSO) 運用前提**で、`cdk.json` のデフォルト
> パラメータ（`apiLambdaIntegrationTimeout: 180` など）も AWS 側の上限と整合していません。
> そのため、**そのままではデプロイが通らず**、3 箇所のハマりどころを順に解消する必要があります。
> 本手順書はそれを全て反映した「実機で通った順序」になっています。

---

## 全体の流れ

```
[A] CloudShell で query-expansion-rag をデプロイ
        ↓ ApiEndpoint と ApiKey を取得
[B] WAF の IP 制限を解除（CloudShell から API を呼べるように）
        ↓
[C] 源内 Web の「チーム管理 → アプリの作成」で RAG API を登録
        ↓
[D] 源内 Web 上で RAG アプリを実行
        ↓
[E] 後片付け（必須）
```

---

# A章　CloudShell で RAG API をデプロイする

## A-1. 前提

- 基本ハンズオンと同じ AWS アカウント・東京リージョン (ap-northeast-1)
- Bedrock モデルアクセス（東京）で以下を**有効化済み**
  - `Amazon Nova Lite`（RAG のクエリ拡張・関連性評価・回答生成のデフォルト）
  - `Amazon Nova-2 Lite`（推論プロファイル `jp.amazon.nova-2-lite-v1:0` 用）
  - `Amazon Titan Text Embeddings V2`（埋め込み = ベクトル化）
  - `Anthropic Claude Haiku 4.5`、`Anthropic Claude Sonnet 4.5`（詳細回答用）

> モデルアクセスの確認: `aws bedrock get-foundation-model-availability --model-id <ID> --region ap-northeast-1`
> で `entitlementAvailability: AVAILABLE` かつ `agreementAvailability.status: AVAILABLE`（または `AUTHORIZED`）であること。

## A-2. ソースを取得（CloudShell）

CloudShell のホームは 1GB 制限のため、源内と同様 **/tmp** で作業します。

```bash
# Node.js v22 を準備（基本ハンズオンで nvm 導入済みならそのまま使える）
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
node -v   # v22 系であることを確認。違う場合は: nvm install 22.22.2 && nvm use 22.22.2

# /tmp に取得
cd /tmp
rm -rf genai-ai-api
git clone https://github.com/digital-go-jp/genai-ai-api
cd genai-ai-api/aws/query-expansion-rag
```

## A-3. 依存をインストール

```bash
# CloudShell のメモリ対策
export NODE_OPTIONS="--max-old-space-size=1536"

npm ci
```

## A-4. デプロイ対象アプリを定義する

デフォルトの `cdk.json` は **デプロイ対象アプリが空**（`qeRagAppNames: []`）なので、
このままだと RAG API が作られません。サンプルアプリ `qerag` を 1 つ追加します。

```bash
node -e "const fs=require('fs');const p='cdk.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));j.context.qeRagAppNames=[{appName:'qerag',appParamFile:'qerag.toml'}];fs.writeFileSync(p,JSON.stringify(j,null,2));console.log('qeRagAppNames set: qerag');"
```

> 補足: `cdk.json` のデフォルトには `idcUserNames: ["dummy-user"]` と `switchRoleName: "DummyRole"`
> が入っています。`bin/qe-rag-apis.ts` がこれらの存在をデプロイ前にバリデーションするため、
> 値自体は残してください（次の A-5 で別の対処を行います）。

## A-5. ハマりどころ ①：SwitchRole の信頼先を修正（SSO 非対応環境では必須）

このアプリは IAM Identity Center（SSO）運用を前提に設計されており、`SwitchRoleStack` が
「`switchRoleName` という名前の SSO 予約ロール」を信頼先（principal）に指定します。
SSO を使っていない通常環境では、その SSO ロールが実在しないため、デプロイが以下のエラーで失敗します。

```
Invalid principal in policy:
"AWS":"arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/ap-northeast-1/DummyRole"
```

**対処**: SwitchRole の信頼先を、実在する **アカウントルート** に変更します。

```bash
# 開始行を確認（main 現行版では37行目）
grep -n "assumeRolePrincipal = new iam.ArnPrincipal" lib/switch-role-stack.ts

# 37〜43行目（ArnPrincipal(...).withConditions({...})）を AccountRootPrincipal に置換
sed -i '37,43c\    const assumeRolePrincipal = new iam.AccountRootPrincipal();' lib/switch-role-stack.ts

# 確認: AccountRootPrincipal の1行になり、ArnPrincipal が消えていること
grep -n "AccountRootPrincipal\|ArnPrincipal" lib/switch-role-stack.ts
```

> なぜこれで良いか: `AccountRootPrincipal` は「このAWSアカウント自身」を信頼先にします。
> SSO ロールに依存しなくなるため IAM の検証を通過します。スイッチロール自体は本ハンズオン
> （RAG をデプロイして源内から呼ぶだけ）には不要なので、これで支障ありません。

## A-6. ハマりどころ ②：API Gateway 統合タイムアウトを上限以下にする

`cdk.json` の既定値は `apiLambdaIntegrationTimeout: 180`（180 秒）ですが、
**API Gateway (REST API) の統合タイムアウト上限は 29 秒**です。デフォルト値が上限を超えているため、
デプロイが以下のエラーで失敗します。

```
Timeout should be between 50 ms and 29000 ms
```

**対処**: 値を 29 に変更します。

```bash
node -e "const fs=require('fs');const p='cdk.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));j.context.apiLambdaIntegrationTimeout=29;fs.writeFileSync(p,JSON.stringify(j,null,2));console.log('apiLambdaIntegrationTimeout=29');"
grep apiLambdaIntegrationTimeout cdk.json
```

## A-7. CDK Bootstrap（未実施なら）

```bash
npx cdk bootstrap aws://$(aws sts get-caller-identity --query Account --output text)/ap-northeast-1
```

基本ハンズオンで実施済みなら `Environment ... bootstrapped (no changes)` と出ます。

## A-8. デプロイ

```bash
npx cdk deploy --all --require-approval never
```

作られるスタック（順番）:

1. `ApiWafStack` — WAF WebACL（東京 REGIONAL スコープ）
2. `qerag-SwitchRoleStack` — A-5 で修正したスイッチロール
3. `qerag-qeRagKB` — **OpenSearch Serverless コレクション** + Knowledge Base + KMS。**ここが最も時間がかかる**（5〜10 分）
4. `qerag-qeRagApi` — Lambda（Python）+ API Gateway

全体の所要時間は **15〜25 分**。

> 万一 A-5 や A-6 を飛ばして失敗した場合、`ROLLBACK_COMPLETE` で残った失敗スタックを削除して
> から再デプロイします。
> ```bash
> aws cloudformation delete-stack --stack-name qerag-SwitchRoleStack
> aws cloudformation wait stack-delete-complete --stack-name qerag-SwitchRoleStack
> # 必要に応じて qerag-qeRagApi も同様に削除
> npx cdk deploy --all --require-approval never
> ```

## A-9. ApiEndpoint と ApiKey を取得

デプロイ完了後、`qerag-qeRagApi` の Outputs に `ApiEndpoint` と `ApiKeyId` が出ます。
API キーの実値は別途取得します。

```bash
# 出力一覧を確認
aws cloudformation describe-stacks --stack-name qerag-qeRagApi \
  --query "Stacks[0].Outputs" --output table

# シェル変数に格納（以降のテスト用）
API_ENDPOINT=$(aws cloudformation describe-stacks --stack-name qerag-qeRagApi \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" --output text)
API_KEY_ID=$(aws cloudformation describe-stacks --stack-name qerag-qeRagApi \
  --query "Stacks[0].Outputs[?OutputKey=='ApiKeyId'].OutputValue" --output text)
API_KEY=$(aws apigateway get-api-key --api-key "$API_KEY_ID" --include-value --query value --output text)

echo "ApiEndpoint: $API_ENDPOINT"
echo "ApiKey:      $API_KEY"
```

`API_ENDPOINT` と `API_KEY` を **必ず控えておいてください**。源内 Web への登録（C 章）で使います。

---

# B章　ハマりどころ ③：WAF の IP 制限を解除する

A-9 が終わったら API を直接テストしたくなりますが、デフォルトの WAF 設定だと弾かれます。

```bash
curl -X POST "$API_ENDPOINT" -H "Content-Type: application/json" -H "x-api-key: $API_KEY" \
  -d '{"inputs":{"question":"テスト","n_queries":3}}'
# → {"message":"Forbidden"}
```

これは WAF のデフォルト動作によるものです。重要な仕様を理解する必要があります。

## なぜ Forbidden になるのか（このアプリの WAF 仕様）

`lib/constructs/common-web-acl.ts` の WebACL は次の動作をします。

- **DefaultAction は常に `block`（デフォルト全ブロック）**
- 許可ルールは `allowedIpV4AddressRanges` などに値がある時だけ追加される
- つまり **`null` や `[]` にすると「全ブロック＋許可ルールなし」＝ 完全に全拒否**

源内 Web（IP 制限を null にすると WAF スタック自体が作られない）とは設計が**真逆**です。

## 対処：全 IP を許可するルールを追加（API キー認証は引き続き有効）

```bash
# 全IPv4を /1 + /1 でカバー（WAFは 0.0.0.0/0 を受け付けないため）
node -e "const fs=require('fs');const p='cdk.json';const j=JSON.parse(fs.readFileSync(p,'utf8'));j.context.allowedIpV4AddressRanges=['0.0.0.0/1','128.0.0.0/1'];j.context.allowedIpV6AddressRanges=null;j.context.allowedCountryCodes=null;fs.writeFileSync(p,JSON.stringify(j,null,2));console.log('allow all v4');"

# WAF スタックだけ再デプロイ（数十秒）
npx cdk deploy ApiWafStack --require-approval never
```

> ⚠️ **WAF の `0.0.0.0/0` 不可仕様**: AWS WAF は IPSet に `0.0.0.0/0` を登録できません
> （`The parameter contains formatting that is not valid. parameter: 0.0.0.0/0`）。
> 「全 IP を表現したい場合は `/1` を 2 つ並べる」のが定石です。
>
> ⚠️ **セキュリティ補足**: ハンズオンでは手軽さ優先で全 IP 許可にしますが、API キー認証は
> 引き続き有効なので、キーを知らない人は呼べません。本番運用では「源内側の外部アプリ起動 EIP」
> を `allowedIpV4AddressRanges: ["x.x.x.x/32","y.y.y.y/32"]` で限定指定するのが正しい運用です。
> 源内側の EIP は `docs/AIアプリ登録手順書.md` 手順1 の方法で取得できます。

## 動作確認

WAF ルール反映後、もう一度 curl してください（反映に数十秒かかる場合あり）。

```bash
curl -X POST "$API_ENDPOINT" -H "Content-Type: application/json" -H "x-api-key: $API_KEY" \
  -d '{"inputs":{"question":"テスト","n_queries":3}}'
```

期待結果: `{"outputs": "...", "usageMetadata": [...]}` が返る。
内容は KnowledgeBase が空のため「情報がない」旨だが、**API としては正常**。
`usageMetadata` にクエリ拡張用 Nova Lite と回答生成用 Claude Haiku 4.5 が記録されていれば、
RAG の全工程（クエリ拡張 → KB 検索 → 関連性評価 → 回答生成）が動いています。

---

# C章　源内 Web に外部 AI アプリとして登録する

## C-1. システム管理者でログイン

源内 Web に **システム管理者** でログインします。基本ハンズオンで `add-system-admin.sh` で
昇格させたユーザーを使ってください。ヘッダーの「アカウント」メニューに「**チーム管理**」が
出ていれば OK です。

## C-2. RAG アプリ用のチームを作る

1. ヘッダー右上 **「アカウント」→「チーム管理」** をクリック
2. **「チームを作成」** をクリック
3. 入力:
   - **チーム名**: `RAGハンズオン`（任意）
   - **チーム管理者のメールアドレス**: 自分のメールアドレス
4. **「作成」**

> 全ユーザーに公開したい場合は、源内既存の **共通チーム**（`TEAM_ID: 00000000-0000-0000-0000-000000000000`）
> にアプリを登録する選択肢もあります。

## C-3. AI アプリを作成

1. 作成したチーム「RAGハンズオン」のページを開く
2. 「AIアプリ」タブで **「AIアプリを作成」** をクリック
3. 以下を入力（フィールド名は実際の UI に合わせる）

| 項目 | 値 |
|---|---|
| アプリ名 | `Query Expansion RAG` |
| 説明 | `クエリ拡張RAGのデモ。質問に対してKnowledge Baseを検索して回答します。` |
| エンドポイント URL | A-9 で控えた `API_ENDPOINT`（例: `https://xxxx.execute-api.ap-northeast-1.amazonaws.com/prod/invoke`） |
| API キー | A-9 で控えた `API_KEY` |
| 同期/非同期 | **同期**（あれば。RAG は `{"outputs":...}` を直接返すため） |
| リクエスト形式（JSON） | 下記をそのまま貼り付け |

リクエスト形式 JSON:

```json
{
  "question": {
    "title": "質問",
    "desc": "社内規程やマニュアルについて質問してください。",
    "type": "text",
    "required": true
  },
  "n_queries": {
    "title": "クエリ拡張数",
    "type": "number",
    "min": 1,
    "max": 5,
    "default_value": 3
  }
}
```

4. 保存（または「作成」）

> このリクエスト形式 JSON をもとに、源内が画面に「質問」テキスト欄と「クエリ拡張数」数値欄を
> 描画します。送出時は `{"inputs":{"question":"...","n_queries":3}}` の形に変換され、RAG API は
> `{"outputs":"..."}` を返します（`docs/AIアプリAPI仕様.md` 準拠）。

---

# D章　動作確認

1. 登録したアプリ「Query Expansion RAG」を開く
2. **「質問」** 欄に何か入力（例: `こんにちは`）
3. **「実行」** をクリック
4. 数秒後、AI 応答が画面に表示される

> KnowledgeBase が空なら「情報が見つからない」または定型挨拶系の回答になりますが、
> 源内画面に応答が出れば **連携成功**です。`qerag.toml` で定義された `responseFooter`
> （「※この回答文章は生成 AI によって作成されており…」）も末尾に付きます。

---

# E章　後片付け（必須・RAG API側）

OpenSearch Serverless は起動しているだけで継続課金されます。検証が終わったら必ず削除してください。

## E-1. /tmp が生きている場合（同じセッション内）

最も簡単。`cdk destroy` で全スタックをまとめて削除できます。

```bash
cd /tmp/genai-ai-api/aws/query-expansion-rag
npx cdk destroy --all --force
```

## E-2. /tmp がクリアされた場合（再接続後など）★今日のハンズオンで実際に発生

CloudShell のセッションが切れて `/tmp/genai-ai-api` が消えていると、`destroy` は使えません。
その場合は **AWS CLI でスタックを直接削除**します。`cdk destroy` を使わなくても、
CloudFormation の依存関係（API → KB → SwitchRole → WAF）の逆順で削除すれば確実です。

```bash
# 1. qerag-qeRagApi（Lambda + API Gateway）を削除
aws cloudformation delete-stack --stack-name qerag-qeRagApi --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name qerag-qeRagApi --region ap-northeast-1
echo "qerag-qeRagApi: deleted"

# 2. qerag-qeRagKB（OpenSearch Serverless + KnowledgeBase + KMS）を削除 ★最重要（コスト発生源）
aws cloudformation delete-stack --stack-name qerag-qeRagKB --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name qerag-qeRagKB --region ap-northeast-1
echo "qerag-qeRagKB: deleted"

# 3. qerag-SwitchRoleStack を削除
aws cloudformation delete-stack --stack-name qerag-SwitchRoleStack --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name qerag-SwitchRoleStack --region ap-northeast-1
echo "qerag-SwitchRoleStack: deleted"

# 4. ApiWafStack を削除
aws cloudformation delete-stack --stack-name ApiWafStack --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name ApiWafStack --region ap-northeast-1
echo "ApiWafStack: deleted"

echo "=== 全削除完了 ==="
```

> `wait stack-delete-complete` は完了まで無言で待ちます（数十秒〜数分）。
> `qerag-qeRagKB`（OpenSearch）の削除に **5 分前後** かかります。全体で **10 分前後**を見込んでください。

## E-3. 完了確認

```bash
aws cloudformation describe-stacks --region ap-northeast-1 \
  --query "Stacks[?contains(StackName, 'qerag') || StackName=='ApiWafStack'].{Name:StackName,Status:StackStatus}" \
  --output table

# OpenSearch Serverless コレクションが残っていないか
aws opensearchserverless list-collections --region ap-northeast-1 \
  --query "collectionSummaries[].name" --output table
```

両方とも **空の結果（リソースなし）** が出れば完全削除成功です。

> KMS キーや S3 バケットなど `RemovalPolicy.RETAIN` のリソースは残る場合があります。
> 残しても起動コストはほぼゼロですが、気になるならコンソールで手動削除してください。

---

# F章　源内 Web も削除する場合

基本ハンズオンでデプロイした源内 Web 側もまとめて片付けたい場合、同じく AWS CLI で
直接スタックを削除します。源内 Web は **東京** と **us-east-1** の 2 リージョンに
スタックがあるので、両方削除します。

## F-1. CloudFront 用ログバケット類を空にする（S3 の制約）

源内 Web の削除でハマりやすいのが **「S3 バケットに中身があると CloudFormation が削除できない」**
仕様です。CloudFront のアクセスログが溜まっているバケットを先に空にしておきます。

```bash
# 関連バケットを抽出して、各バケットの全バージョンを削除
for b in $(aws s3 ls | awk '{print $3}' | grep -i 'generativeaiusecasesstack'); do
  echo "Emptying: $b"
  # バージョン付きオブジェクトをループで削除（1回1000件、無くなるまで繰り返す）
  while true; do
    out=$(aws s3api list-object-versions --bucket "$b" \
            --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
    if [ "$(echo "$out" | jq '.Objects | length')" = "0" ] || [ -z "$out" ]; then break; fi
    echo "$out" | aws s3api delete-objects --bucket "$b" --delete file:///dev/stdin >/dev/null 2>&1 || true

    # DeleteMarkers も同様に
    out2=$(aws s3api list-object-versions --bucket "$b" \
             --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null)
    if [ "$(echo "$out2" | jq '.Objects | length')" = "0" ] || [ -z "$out2" ]; then break; fi
    echo "$out2" | aws s3api delete-objects --bucket "$b" --delete file:///dev/stdin >/dev/null 2>&1 || true
  done
done
echo "=== バケット空化完了 ==="
```

## F-2. スタックを順に削除（東京 → us-east-1）

依存関係（メインスタックが ACM 証明書スタックを参照）の順序で削除します。

```bash
# 1. メインスタック（東京）
aws cloudformation delete-stack --stack-name GenerativeAiUseCasesStack-handson --region ap-northeast-1
aws cloudformation wait stack-delete-complete --stack-name GenerativeAiUseCasesStack-handson --region ap-northeast-1
echo "GenerativeAiUseCasesStack-handson: deleted"

# 2. AppDomainStack（us-east-1、ACM 証明書用）
aws cloudformation delete-stack --stack-name AppDomainStack-handson --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name AppDomainStack-handson --region us-east-1
echo "AppDomainStack-handson: deleted"

echo "=== 源内 Web 全削除完了 ==="
```

メインスタック（CloudFront・Cognito・Lambda 数十個・DynamoDB 等を含む）の削除に **10〜20 分**かかります。

> もし `DELETE_FAILED` で止まったら、**S3 バケットがまだ空でなかった**のが原因です。
> F-1 をもう一度実行してから、`delete-stack` を再実行してください。

## F-3. 管理から外れた残存リソースの掃除（必要なら）

CloudFormation スタック削除後も、過去のデプロイで作られて管理から外れた残存リソースが
残ることがあります（特に複数回デプロイ・削除を繰り返した場合）。気になるなら以下で確認・削除します。

```bash
# 残存 Lambda
aws lambda list-functions --region ap-northeast-1 \
  --query "Functions[?starts_with(FunctionName, 'GenerativeAiUseCasesStack')].FunctionName" --output text \
  | tr '\t' '\n' | while read fn; do
    [ -n "$fn" ] && aws lambda delete-function --function-name "$fn" --region ap-northeast-1 && echo "deleted lambda: $fn"
  done

# 残存 DynamoDB
aws dynamodb list-tables --region ap-northeast-1 \
  --query "TableNames[?starts_with(@, 'GenerativeAiUseCasesStack')]" --output text \
  | tr '\t' '\n' | while read t; do
    [ -n "$t" ] && aws dynamodb delete-table --table-name "$t" --region ap-northeast-1 >/dev/null && echo "deleted table: $t"
  done

# 残存 S3（中身を空にしてから削除。F-1のループで空にした上で実行）
for b in $(aws s3 ls | awk '{print $3}' | grep -i 'generativeaiusecasesstack'); do
  aws s3 rb "s3://$b" --force && echo "deleted bucket: $b"
done
```

## F-4. 完了確認

```bash
echo "=== 東京 ==="
aws cloudformation describe-stacks --region ap-northeast-1 \
  --query "Stacks[?contains(StackName, 'handson') || contains(StackName, 'GenerativeAi')].{Name:StackName,Status:StackStatus}" \
  --output table
echo "=== us-east-1 ==="
aws cloudformation describe-stacks --region us-east-1 \
  --query "Stacks[?contains(StackName, 'handson')].{Name:StackName,Status:StackStatus}" \
  --output table
echo "=== Lambda ==="
aws lambda list-functions --region ap-northeast-1 \
  --query "Functions[?starts_with(FunctionName, 'GenerativeAiUseCasesStack')].FunctionName" --output text
echo "=== DynamoDB ==="
aws dynamodb list-tables --region ap-northeast-1 \
  --query "TableNames[?starts_with(@, 'GenerativeAiUseCasesStack')]" --output text
echo "=== S3 ==="
aws s3 ls | grep -i 'generativeaiusecasesstack' || echo "（残存なし）"
```

すべて空表示なら源内 Web も完全削除完了です。

---

# 補足：今日のハンズオンで実機確認したハマりどころ一覧

| # | 症状 | 原因 | 対処 |
|---|---|---|---|
| ① | `Invalid principal in policy: ...DummyRole` | このアプリは IAM Identity Center (SSO) 運用前提。SSO ロールが実在しない | A-5: `lib/switch-role-stack.ts` を `AccountRootPrincipal` に1行修正 |
| ② | `Timeout should be between 50 ms and 29000 ms` | `cdk.json` 既定の `apiLambdaIntegrationTimeout: 180` が API Gateway 上限 29 秒を超過 | A-6: 値を 29 に変更 |
| ③ | API curl で `{"message":"Forbidden"}` | このアプリの WAF は DefaultAction が常に `block` で、許可ルールが空（null/[]）だと全拒否 | B章: `["0.0.0.0/1","128.0.0.0/1"]` で全 IP 許可（`0.0.0.0/0` は WAF が拒否） |

これら 3 点は**リポジトリ側の設定が AWS 仕様と整合していない**ことに起因しており、
公式手順書には記載がありません。本手順書は実機で全て解消したうえで通った順序を記録しています。

---

## RAG が使うモデルを変更したい場合

`config/apps/qerag.toml` や `config/defaults/*.toml` の `modelId` を編集します。
デフォルトは東京リージョンの推論プロファイル（Nova / Claude 系）です。
変更後は `npx cdk deploy --all` で再デプロイすれば反映されます
（設定ファイルのハッシュで Lambda が自動再ビルドされます）。

---

Crafted by Hideyuki Nagata — https://builder.aws.com/community/@hideg
AWS Community Builder (AI Engineering, 2nd year) / Built with Kiro 🤖
