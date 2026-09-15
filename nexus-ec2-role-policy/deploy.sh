#!/usr/bin/env bash
#
# nexus-ec2-role 一次性部署脚本（幂等，可重复执行）
#
# 部署内容:
#   1. IAM Role            nexus-ec2-role            (信任策略: ec2 / ecs-tasks / lambda / bedrock-agentcore)
#   2. 客户托管策略        nexus-ec2-role-runtime    (数据面: bedrock / ssm / efs / rds / secrets / elasticache / ddb / sqs / s3)
#   3. 客户托管策略        nexus-ec2-role-deploy     (控制面: cfn / ec2 / iam / elb / cloudfront / lambda)
#   4. AWS 托管策略        AmazonSSMManagedInstanceCore (提供 ssmmessages/ec2messages，ssm:* 不覆盖)
#   5. 实例配置文件        nexus-ec2-role            (供 EC2 使用)
#
# 用法:
#   ./deploy.sh                          # 部署/更新
#   ./deploy.sh --dry-run                # 只打印将要执行的动作
#   ./deploy.sh --cleanup-legacy         # 额外清理旧的内联策略 Policy 与旧托管策略 nexus-demo-role-ec2 的挂载
#   ROLE_NAME=my-role ./deploy.sh        # 换个角色名部署
#   AWS_PROFILE=xxx AWS_REGION=us-east-1 ./deploy.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${POLICY_DIR:-${SCRIPT_DIR}/deduped}"

ROLE_NAME="${ROLE_NAME:-nexus-ec2-role}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-${ROLE_NAME}}"
ROLE_DESCRIPTION="${ROLE_DESCRIPTION:-Nexus-AI EC2 / ECS / Lambda / AgentCore execution role}"
MAX_SESSION_DURATION="${MAX_SESSION_DURATION:-3600}"
AWS_REGION="${AWS_REGION:-us-east-1}"

AWS_MANAGED_POLICIES=(
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
)
# 文件名(不含 .json) 即策略名
CUSTOMER_POLICIES=(
  "nexus-ec2-role-runtime"
  "nexus-ec2-role-deploy"
)
LEGACY_INLINE_POLICIES=("Policy")
LEGACY_MANAGED_POLICIES=("nexus-demo-role-ec2")

DRY_RUN=false
CLEANUP_LEGACY=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --cleanup-legacy) CLEANUP_LEGACY=true ;;
    -h|--help)        sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[0;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }
skip() { printf '\033[0;33m  =\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

aws_iam() {
  if $DRY_RUN; then
    echo "    DRY-RUN: aws iam $*"
    return 0
  fi
  aws iam --region "$AWS_REGION" "$@"
}

command -v aws >/dev/null || die "未找到 aws CLI"
command -v jq  >/dev/null || die "未找到 jq"

for p in "${CUSTOMER_POLICIES[@]}"; do
  [[ -f "${POLICY_DIR}/${p}.json" ]] || die "缺少策略文件 ${POLICY_DIR}/${p}.json"
  jq -e . "${POLICY_DIR}/${p}.json" >/dev/null || die "${p}.json 不是合法 JSON"
done
[[ -f "${POLICY_DIR}/trust-policy.json" ]] || die "缺少 ${POLICY_DIR}/trust-policy.json"
jq -e . "${POLICY_DIR}/trust-policy.json" >/dev/null || die "trust-policy.json 不是合法 JSON"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER="$(aws sts get-caller-identity --query Arn --output text)"
log "账号 ${ACCOUNT_ID} / 调用者 ${CALLER} / region ${AWS_REGION}"
$DRY_RUN && log "DRY-RUN 模式：不会做任何变更"

# ---------------------------------------------------------------- 1. Role
log "1/5 角色 ${ROLE_NAME}"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws_iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://${POLICY_DIR}/trust-policy.json"
  ok "角色已存在，信任策略已更新"
else
  aws_iam create-role \
    --role-name "$ROLE_NAME" \
    --description "$ROLE_DESCRIPTION" \
    --max-session-duration "$MAX_SESSION_DURATION" \
    --assume-role-policy-document "file://${POLICY_DIR}/trust-policy.json" \
    --tags "Key=Project,Value=Nexus-AI" "Key=ManagedBy,Value=nexus-ec2-role-policy/deploy.sh" \
    >/dev/null
  ok "角色已创建"
fi

# ------------------------------------------------- 2. 客户托管策略(创建/更新版本)
log "2/5 客户托管策略"
declare -a CUSTOMER_POLICY_ARNS=()
for name in "${CUSTOMER_POLICIES[@]}"; do
  arn="arn:aws:iam::${ACCOUNT_ID}:policy/${name}"
  file="${POLICY_DIR}/${name}.json"
  CUSTOMER_POLICY_ARNS+=("$arn")

  if aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    current_ver="$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text)"
    remote="$(aws iam get-policy-version --policy-arn "$arn" --version-id "$current_ver" \
              --query 'PolicyVersion.Document' --output json | jq -S -c .)"
    local_doc="$(jq -S -c . "$file")"
    if [[ "$remote" == "$local_doc" ]]; then
      skip "${name} 内容一致 (${current_ver})，跳过"
      continue
    fi
    # IAM 每个策略最多 5 个版本，先清理非默认的旧版本
    for old in $(aws iam list-policy-versions --policy-arn "$arn" \
                 --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
      aws_iam delete-policy-version --policy-arn "$arn" --version-id "$old"
    done
    new_ver="$(aws_iam create-policy-version --policy-arn "$arn" \
                --policy-document "file://${file}" --set-as-default \
                --query 'PolicyVersion.VersionId' --output text 2>/dev/null || echo "vNEW")"
    ok "${name} 已更新为新版本 ${new_ver}"
  else
    aws_iam create-policy \
      --policy-name "$name" \
      --description "Nexus-AI ${name}" \
      --policy-document "file://${file}" \
      --tags "Key=Project,Value=Nexus-AI" \
      >/dev/null
    ok "${name} 已创建"
  fi
done

# ---------------------------------------------------------------- 3. 挂载策略
log "3/5 挂载策略到角色"
attached="$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
            --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")"
for arn in "${CUSTOMER_POLICY_ARNS[@]}" "${AWS_MANAGED_POLICIES[@]}"; do
  if grep -qw -- "$arn" <<<"$attached"; then
    skip "已挂载 $(basename "$arn")"
  else
    aws_iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn"
    ok "已挂载 $(basename "$arn")"
  fi
done

# ------------------------------------------------------------ 4. 实例配置文件
log "4/5 实例配置文件 ${INSTANCE_PROFILE_NAME}"
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  skip "实例配置文件已存在"
else
  aws_iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
  ok "实例配置文件已创建"
  $DRY_RUN || sleep 8   # IAM 最终一致性
fi
in_profile="$(aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
              --query 'InstanceProfile.Roles[].RoleName' --output text 2>/dev/null || echo "")"
if grep -qw -- "$ROLE_NAME" <<<"$in_profile"; then
  skip "角色已在实例配置文件中"
else
  aws_iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$ROLE_NAME"
  ok "角色已加入实例配置文件"
fi

# ---------------------------------------------------------------- 5. 旧资源清理
log "5/5 旧资源清理"
if $CLEANUP_LEGACY; then
  for p in "${LEGACY_INLINE_POLICIES[@]}"; do
    if aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$p" >/dev/null 2>&1; then
      aws_iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$p"
      ok "已删除内联策略 ${p}（内容已并入 ${CUSTOMER_POLICIES[0]}）"
    else
      skip "内联策略 ${p} 不存在"
    fi
  done
  for p in "${LEGACY_MANAGED_POLICIES[@]}"; do
    arn="arn:aws:iam::${ACCOUNT_ID}:policy/${p}"
    if grep -qw -- "$arn" <<<"$attached"; then
      aws_iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn"
      ok "已从角色卸载 ${p}（策略本身保留，未删除）"
    else
      skip "${p} 未挂载"
    fi
  done
else
  skip "未指定 --cleanup-legacy，保留旧的内联策略 Policy / 托管策略 nexus-demo-role-ec2"
fi

# ---------------------------------------------------------------- 汇总
if ! $DRY_RUN; then
  echo
  log "部署完成，当前状态："
  echo "  Role ARN             : arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
  echo "  InstanceProfile ARN  : arn:aws:iam::${ACCOUNT_ID}:instance-profile/${INSTANCE_PROFILE_NAME}"
  echo "  已挂载托管策略        :"
  aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
      --query 'AttachedPolicies[].PolicyName' --output text | tr '\t' '\n' | sed 's/^/    - /'
  echo "  内联策略              :"
  aws iam list-role-policies --role-name "$ROLE_NAME" \
      --query 'PolicyNames' --output text | tr '\t' '\n' | sed 's/^/    - /'
fi
