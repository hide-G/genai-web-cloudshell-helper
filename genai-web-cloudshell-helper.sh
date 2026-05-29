#!/bin/bash
###############################################################################
# genai-web-cloudshell-helper.sh
#
#  ⚠️ 非公式 / コミュニティ作成ツール
#     デジタル庁公式のツールではありません。
#     デジタル庁「源内 Web」(https://github.com/digital-go-jp/genai-web) を
#     AWS CloudShell 上でローカル環境構築なしにデプロイ・カスタマイズするための
#     補助スクリプトです。利用は自己責任でお願いします。
#
#  ------------------------------------------------------------------------
#  Crafted by Hideyuki Nagata — https://builder.aws.com/community/@hideg
#  AWS Community Builder (AI Engineering, 2nd year)
#  Built with Kiro 🤖
#  ------------------------------------------------------------------------
#
#  用途:
#     ローカルへの Node.js / AWS CLI / CDK / jq のインストールなしに、
#     ブラウザの CloudShell だけで源内 Web を構築・更新・削除できます。
#
#  使い方（サブコマンド方式）:
#     chmod +x genai-web-cloudshell-helper.sh
#
#     ./genai-web-cloudshell-helper.sh setup
#         源内 Web のソースを取得し、Node 準備・依存導入まで実施（/tmp/genai-web に保存）
#
#     ./genai-web-cloudshell-helper.sh deploy -e -handson
#         取得済みソースをデプロイ（ロゴ等をカスタマイズ後、何度でも再実行可）
#
#     ./genai-web-cloudshell-helper.sh destroy -e -handson
#         デプロイしたスタックを削除
#
#     ./genai-web-cloudshell-helper.sh help
#         ヘルプ表示
###############################################################################

set -euo pipefail

# ---- 定数 -------------------------------------------------------------------
REPO_URL="https://github.com/digital-go-jp/genai-web"
REQUIRED_NODE_MAJOR=22
REQUIRED_NODE_VERSION="22.22.2"   # .node-version / package.json engines に一致
CFN_GLOBAL_REGION="us-east-1"     # AppDomainStack は us-east-1 固定
MODEL_REGION_DEFAULT="ap-northeast-1"

# CloudShell のホームは 1GB 制限のため、容量を圧迫しないよう作業ディレクトリは
# /tmp（ホーム制限外・容量潤沢）に置く。npm はシンボリックリンクの node_modules を
# 実体へ作り替えてしまうため、ソースごと /tmp に置くのが最も確実。
# 注意: /tmp はセッション終了で消えるため、再接続後は setup からやり直す。
#       カスタマイズ作業は同一セッション内で「編集→deploy」を繰り返す想定。
DEFAULT_WORK_DIR="${TMPDIR:-/tmp}/genai-web"

# CloudShell のメモリ制約対策（CDK 合成 / Vite ビルドの OOM 回避）
export NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=1536}"

# ---- ログ用ヘルパー ---------------------------------------------------------
log()  { echo -e "\033[1;36m[INFO]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

print_banner() {
  echo "=================================================================="
  echo "  genai-web-cloudshell-helper  (非公式 / コミュニティ作成ツール)"
  echo "  対象: digital-go-jp/genai-web  on AWS CloudShell"
  echo "  ----------------------------------------------------------------"
  echo "  Crafted by Hideyuki Nagata - https://builder.aws.com/community/@hideg"
  echo "  AWS Community Builder (AI Engineering, 2nd year) / Built with Kiro"
  echo "=================================================================="
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "コマンドが見つかりません: $1"; exit 1; }; }

usage() {
  cat <<'EOF'
genai-web-cloudshell-helper.sh  (非公式 / コミュニティ作成ツール)

源内 Web を AWS CloudShell でデプロイ・カスタマイズするための補助スクリプトです。
デジタル庁公式のツールではありません。

Usage:
  ./genai-web-cloudshell-helper.sh <command> [options]

Commands:
  setup                ソース取得 + Node準備 + 依存導入（/tmp/genai-web に保存）
  deploy               取得済みソースをデプロイ
  destroy              デプロイ済みスタックを削除
  help                 このヘルプを表示

Common options:
  -d, --dir <path>           ソースディレクトリ (デフォルト: /tmp/genai-web)

setup options:
  -b, --branch <name>        クローンするブランチ (デフォルト: main)

deploy/destroy options:
  -e, --env <name>           環境名 (例: -handson)

deploy options:
  -c, --cdk-context <path>   差し替える cdk.json のパス
  --use-repo-cdk-json        リポジトリの cdk.json をそのまま使う（自動調整しない）

Examples:
  ./genai-web-cloudshell-helper.sh setup
  ./genai-web-cloudshell-helper.sh deploy -e -handson
  ./genai-web-cloudshell-helper.sh destroy -e -handson

Note:
  deploy で -c も --use-repo-cdk-json も指定しない場合、ハンズオン向けに
  IP制限なし（誰でもアクセス可）・セルフサインアップ有効の構成を自動適用します。
  （リポジトリ既定の cdk.json は allowedIpV4AddressRanges が空配列 [] のため、
   そのままデプロイすると WAF が全アクセスをブロックし 403 になります）

  作業ディレクトリは /tmp 配下です。CloudShell のセッションが切れると /tmp は
  消えるため、再接続後は setup からやり直してください（ホーム 1GB 制限の回避のため）。
EOF
}

# ---- Node.js バージョン整合（源内は engineStrict で v22 必須） --------------
# install_if_missing=true なら nvm 導入から行う（setup 用）
# false なら use のみ試み、失敗時はエラー（deploy 用）
ensure_node_version() {
  local install_if_missing="$1"
  local current_major=""
  if command -v node >/dev/null 2>&1; then
    current_major="$(node -v | sed -E 's/^v([0-9]+)\..*/\1/')"
  fi
  if [[ "$current_major" == "$REQUIRED_NODE_MAJOR" ]]; then
    log "Node.js バージョン OK: $(node -v)"
    return 0
  fi

  export NVM_DIR="$HOME/.nvm"
  if [[ "$install_if_missing" == "true" ]]; then
    warn "源内 Web は Node.js v${REQUIRED_NODE_VERSION} を要求します。nvm で準備します..."
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
      log "nvm をインストールしています..."
      curl -fsSL -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    fi
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm install "$REQUIRED_NODE_VERSION"
    nvm use "$REQUIRED_NODE_VERSION"
    nvm alias default "$REQUIRED_NODE_VERSION"
  else
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
      # shellcheck disable=SC1091
      . "$NVM_DIR/nvm.sh"
      nvm use "$REQUIRED_NODE_MAJOR" >/dev/null 2>&1 || true
    fi
  fi

  current_major="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+)\..*/\1/')"
  if [[ "$current_major" != "$REQUIRED_NODE_MAJOR" ]]; then
    if [[ "$install_if_missing" == "true" ]]; then
      err "Node.js のバージョン切り替えに失敗しました（現在: $(node -v 2>/dev/null || echo なし)）"
    else
      err "Node.js v${REQUIRED_NODE_MAJOR} が有効化されていません（現在: $(node -v 2>/dev/null || echo なし)）"
      err "先に './genai-web-cloudshell-helper.sh setup' を実行してください。"
    fi
    exit 1
  fi
  log "Node.js バージョン準備完了: $(node -v)"
}

# =============================================================================
# サブコマンド: setup
# =============================================================================
cmd_setup() {
  local target_dir="$DEFAULT_WORK_DIR"
  local branch="main"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir)    [[ $# -ge 2 ]] || { err "$1 には値が必要です"; exit 1; }; target_dir="$2"; shift 2;;
      -b|--branch) [[ $# -ge 2 ]] || { err "$1 には値が必要です"; exit 1; }; branch="$2"; shift 2;;
      -h|--help)   usage; exit 0;;
      *)           err "setup: 不明なオプション: $1"; exit 1;;
    esac
  done

  print_banner
  echo "  [setup] ソース取得・準備"
  echo "------------------------------------------------------------------"

  need_cmd git
  need_cmd curl

  ensure_node_version "true"

  if [[ -d "$target_dir/.git" ]]; then
    warn "既存のリポジトリを使用します: $target_dir"
    warn "（再取得したい場合は '$target_dir' を削除してから再実行してください）"
  else
    if [[ -e "$target_dir" ]]; then
      err "$target_dir が存在しますが Git リポジトリではありません。削除または別ディレクトリ(-d)を指定してください。"
      exit 1
    fi
    log "源内 Web をクローンしています (branch: $branch) -> $target_dir"
    git clone --branch "$branch" "$REPO_URL" "$target_dir"
  fi

  cd "$target_dir"
  # 作業ディレクトリが /tmp 配下のため node_modules も /tmp に収まり、ホーム 1GB を圧迫しない
  log "依存パッケージをインストールしています (npm ci)... 数分かかります"
  npm ci

  echo ""
  echo "*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*"
  echo " セットアップ完了 ✅   ソース: $target_dir"
  echo ""
  echo " 次の操作:"
  echo "  1. （任意）カスタマイズ:"
  echo "       ${target_dir}/packages/web/src/components/ui/Logo.tsx    （ヘッダー/ロゴ）"
  echo "       ${target_dir}/packages/web/src/components/ui/Footer.tsx  （フッター/コピーライト）"
  echo "  2. デプロイ:"
  echo "       ./genai-web-cloudshell-helper.sh deploy -e -handson"
  echo "*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*"
}

# =============================================================================
# サブコマンド: deploy
# =============================================================================
cmd_deploy() {
  local target_dir="$DEFAULT_WORK_DIR"
  local env_name=""
  local cdk_context_path=""
  local use_repo_cdk_json="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir)             [[ $# -ge 2 ]] || { err "$1 には値が必要です"; exit 1; }; target_dir="$2"; shift 2;;
      -e|--env)             [[ $# -ge 2 ]] || { err "$1 には値が必要です"; exit 1; }; env_name="$2"; shift 2;;
      -c|--cdk-context)     [[ $# -ge 2 ]] || { err "$1 には値が必要です"; exit 1; }; cdk_context_path="$2"; shift 2;;
      --use-repo-cdk-json)  use_repo_cdk_json="true"; shift;;
      -h|--help)            usage; exit 0;;
      *)                    err "deploy: 不明なオプション: $1"; exit 1;;
    esac
  done

  print_banner
  echo "  [deploy] デプロイ"
  echo "------------------------------------------------------------------"

  need_cmd git
  need_cmd aws
  need_cmd jq

  if [[ ! -d "$target_dir" || ! -f "$target_dir/package.json" ]]; then
    err "ソースが見つかりません: $target_dir"
    err "先に './genai-web-cloudshell-helper.sh setup' を実行してください。"
    exit 1
  fi
  cd "$target_dir"

  ensure_node_version "false"

  # node_modules の実体が無い（/tmp が消えた等）場合は npm ci で復旧
  if [[ ! -e node_modules/.package-lock.json && ! -d node_modules/aws-cdk-lib ]]; then
    warn "node_modules が見つかりません（セッション再接続等で /tmp が消えた可能性）。"
    log "npm ci で復旧します... 数分かかります"
    npm ci
  fi

  # ---- cdk.json の決定（優先順位: -c > --use-repo-cdk-json > handson 自動） ----
  if [[ -n "$cdk_context_path" ]]; then
    [[ -f "$cdk_context_path" ]] || { err "cdk.json が見つかりません: $cdk_context_path"; exit 1; }
    log "指定された cdk.json を適用します: $cdk_context_path"
    cp -f "$cdk_context_path" packages/cdk/cdk.json
  elif [[ "$use_repo_cdk_json" == "true" ]]; then
    warn "リポジトリの cdk.json をそのまま使用します。"
    warn "注意: allowedIpV4AddressRanges が空配列 [] の場合、WAF が全アクセスを"
    warn "      ブロックし 403 になります。必要に応じて null に変更してください。"
  else
    log "ハンズオン構成を自動適用します（IP制限なし・セルフサインアップ有効・監視オフ）"
    node - "$env_name" <<'NODE'
const fs = require('fs');
const path = 'packages/cdk/cdk.json';
const applyEnv = process.argv[2] || '';
const j = JSON.parse(fs.readFileSync(path, 'utf8'));
j.context = j.context || {};
j.context.env = applyEnv;
j.context.appEnv = (applyEnv || 'handson').replace(/^-/, '');
j.context.selfSignUpEnabled = true;
// IP 制限なし（null）。空配列 [] は WAF 全拒否（403）になるため必ず null にする
j.context.allowedIpV4AddressRanges = null;
j.context.allowedIpV6AddressRanges = null;
j.context.allowedCountryCodes = null;
// ハンズオンでは監視スタックを無効化
j.context.monitoring = false;
fs.writeFileSync(path, JSON.stringify(j, null, 2));
console.log('cdk.json updated: env=' + j.context.env + ', appEnv=' + j.context.appEnv +
            ', selfSignUp=true, allowedIpV4=null, monitoring=false');
NODE
  fi

  # ---- AWS 認証情報確認 ----
  log "AWS 認証情報を確認しています..."
  local caller_identity account_id deploy_region
  caller_identity=$(aws sts get-caller-identity --output json 2>/dev/null) || {
    err "AWS 認証情報が無効です。CloudShell のログイン状態を確認してください。"; exit 1;
  }
  account_id=$(echo "$caller_identity" | jq -r '.Account')
  deploy_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-$MODEL_REGION_DEFAULT}}"
  log "AWS アカウント : $account_id"
  log "デプロイリージョン: $deploy_region"

  # ---- 合成チェック（事前検証） ----
  log "CDK 合成 (synth) で設定を事前検証します..."
  if [[ -n "$env_name" ]]; then
    npm -w packages/cdk run cdk -- synth --quiet -c "env=${env_name}" >/dev/null
  else
    npm -w packages/cdk run cdk -- synth --quiet >/dev/null
  fi
  log "合成チェック OK"

  # ---- CDK Bootstrap（未実施なら実施） ----
  _bootstrap_if_needed() {
    local region="$1"
    if aws cloudformation describe-stacks --stack-name CDKToolkit --region "$region" \
         --query "Stacks[0].StackStatus" --output text >/dev/null 2>&1; then
      log "bootstrap 済み: $region"
    else
      log "CDK bootstrap を実行: aws://${account_id}/${region}"
      npm -w packages/cdk run cdk -- bootstrap "aws://${account_id}/${region}"
    fi
  }
  _bootstrap_if_needed "$deploy_region"
  if [[ "$deploy_region" != "$CFN_GLOBAL_REGION" ]]; then
    _bootstrap_if_needed "$CFN_GLOBAL_REGION"
  fi

  # ---- デプロイ ----
  log "CDK デプロイを開始します...（フロントビルドを含むため 10〜20 分程度）"
  if [[ -n "$env_name" ]]; then
    npm -w packages/cdk run cdk -- deploy --all --require-approval never -c "env=${env_name}"
  else
    npm -w packages/cdk run cdk -- deploy --all --require-approval never
  fi

  # ---- 出力 URL の取得 ----
  local stack_name web_url stack_json
  stack_name="GenerativeAiUseCasesStack${env_name}"
  web_url=""
  if stack_json=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" --region "$deploy_region" --output json 2>/dev/null); then
    web_url=$(echo "$stack_json" \
      | jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="WebUrl") | .OutputValue')
  fi

  echo ""
  echo "*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*"
  if [[ -n "$web_url" && "$web_url" != "null" ]]; then
    echo " デプロイ完了 🎉"
    echo " 源内 Web URL: $web_url"
  else
    warn "WebUrl を自動取得できませんでした。CloudFormation コンソールで"
    warn "スタック '${stack_name}' の出力 'WebUrl' を確認してください。"
  fi
  echo "*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*"
}

# =============================================================================
# サブコマンド: destroy
# =============================================================================
cmd_destroy() {
  local target_dir="$DEFAULT_WORK_DIR"
  local env_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir)  [[ $# -ge 2 ]] || { err "$1 には値が必要です"; exit 1; }; target_dir="$2"; shift 2;;
      -e|--env)  [[ $# -ge 2 ]] || { err "$1 には値が必要です"; exit 1; }; env_name="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *)         err "destroy: 不明なオプション: $1"; exit 1;;
    esac
  done

  print_banner
  echo "  [destroy] スタック削除"
  echo "------------------------------------------------------------------"

  need_cmd aws
  if [[ ! -d "$target_dir" || ! -f "$target_dir/package.json" ]]; then
    err "ソースが見つかりません: $target_dir（setup 済みのディレクトリを -d で指定してください）"
    exit 1
  fi
  cd "$target_dir"
  ensure_node_version "false"

  warn "環境 '${env_name}' のスタックを削除します。この操作は元に戻せません。"
  printf "本当に削除しますか? [y/N]: "
  read -r ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    log "中止しました。"
    exit 0
  fi

  if [[ -n "$env_name" ]]; then
    npm -w packages/cdk run cdk -- destroy --all --force -c "env=${env_name}"
  else
    npm -w packages/cdk run cdk -- destroy --all --force
  fi

  echo ""
  warn "RETAIN 設定のリソース（S3 バケット・KMS キー等）は残る場合があります。"
  warn "必要に応じて AWS コンソールで手動削除してください。"
}

# =============================================================================
# ディスパッチ
# =============================================================================
main() {
  local sub="${1:-help}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  case "$sub" in
    setup)            cmd_setup "$@";;
    deploy)           cmd_deploy "$@";;
    destroy)          cmd_destroy "$@";;
    help|-h|--help|"") usage;;
    *)                err "不明なコマンド: $sub"; echo ""; usage; exit 1;;
  esac
}

main "$@"
