# nexus-ec2-role 权限留存与一次性部署

导出自 `arn:aws:iam::533267047935:role/nexus-ec2-role`，导出时间 2026-09-15 18:47 (UTC+8)。

## 目录

```
original/                              # 原样留存，未做任何修改
  role-snapshot.json                   # 角色/实例配置文件/策略挂载关系快照
  trust-policy.json                    # AssumeRolePolicyDocument
  inline-Policy.json                   # 内联策略 "Policy"
  managed-nexus-demo-role-ec2-v1.json  # 客户托管策略 nexus-demo-role-ec2 (v1, 默认版本)
deduped/                               # 去重合并后的部署产物
  trust-policy.json
  nexus-ec2-role-runtime.json          # 数据面权限
  nexus-ec2-role-deploy.json           # 控制面/部署权限
deploy.sh                              # 一次性幂等部署脚本
```

AWS 托管策略 `AmazonSSMManagedInstanceCore` 由 AWS 维护，不导出文档，脚本中直接按 ARN 挂载。
它提供 `ssmmessages:*` / `ec2messages:*`（`ssm:*` 不覆盖这两个命名空间），因此必须保留。

## 原始结构

| 类型 | 名称 | 说明 |
|---|---|---|
| 信任策略 | — | ec2 / ecs-tasks / lambda / bedrock-agentcore 四个服务主体 |
| 内联策略 | `Policy` | bedrock 推理、ssm:*、efs:*、Aurora、Secrets、ElastiCache、DynamoDB、SQS、S3 |
| 客户托管 | `nexus-demo-role-ec2` | CFN、ec2:*、IAM、RDS、ElastiCache、EFS、ELB、CloudFront、Lambda、SSM、STS、Quotas、S3 |
| AWS 托管 | `AmazonSSMManagedInstanceCore` | Session Manager 通道 |
| 实例配置文件 | `nexus-ec2-role` | 已绑定该角色 |

## 去重结果

两份策略去重前共 169 条唯一 action 条目，合并后 150 条，**权限集合无损失**（已用通配符展开逐条比对验证）。

被吸收的 19 条：

- `ssm:*` 吸收 `nexus-demo-role-ec2` 中 12 条具体 SSM 动作
  （GetParameter(s) / PutParameter / DeleteParameter / SendCommand / GetCommandInvocation /
  ListCommands / ListCommandInvocations / DescribeInstanceInformation / 三个 tag 动作）
- `rds:Describe*` 吸收 `DescribeDBClusters` / `DescribeDBClusterEndpoints` / `DescribeDBInstances` /
  `DescribeDBSnapshots` / `DescribeDBClusterSnapshots`
- `elasticache:Describe*` 吸收 `DescribeServerlessCaches` / `DescribeUsers`

其他合并：

- `elasticfilesystem:*` 在两份策略中重复出现，合并为一条
- S3 动作在两份策略中部分重叠，合并为一条并集语句（含 `s3vectors:*`）
- `sts:GetCallerIdentity` 与 `servicequotas:*` 两条单动作语句合并
- 原内联策略把 `ssm:*` / `elasticfilesystem:*` 混在 `BedrockModelInference` 语句里，已拆到独立语句

单个客户托管策略上限 6144 字符，因此拆成两份（压缩后 2713 / 2558 字符），按数据面与控制面划分：

- `nexus-ec2-role-runtime` — 应用运行时需要的：Bedrock 推理、SSM、EFS、Aurora(含 Data API)、
  Secrets Manager、ElastiCache、DynamoDB、SQS、S3/S3 Vectors、STS、Service Quotas
- `nexus-ec2-role-deploy` — 部署时需要的：CloudFormation、EC2、IAM、ELB、CloudFront、Lambda

## 部署

```bash
./deploy.sh --dry-run     # 先看将执行的动作
./deploy.sh               # 部署/更新
```

脚本是幂等的：角色存在则更新信任策略；策略存在且内容一致则跳过，不一致则清理旧版本后创建新版本并设为默认；
挂载与实例配置文件均先检查后操作。

在已有角色上执行时，默认**保留**旧的内联策略 `Policy` 和 `nexus-demo-role-ec2` 挂载（新旧并存，权限等价，安全）。
确认新策略生效后再执行清理：

```bash
./deploy.sh --cleanup-legacy   # 删除内联策略 Policy，并从角色卸载 nexus-demo-role-ec2
```

清理只卸载挂载、删除内联策略，不会删除 `nexus-demo-role-ec2` 策略本身。

依赖 `aws` CLI 与 `jq`。可用环境变量覆盖：`ROLE_NAME`、`INSTANCE_PROFILE_NAME`、`AWS_REGION`、
`AWS_PROFILE`、`MAX_SESSION_DURATION`、`POLICY_DIR`。

## 已知安全提示

- `iam:PassRole` 的 Resource 为 `*`（沿用原策略）。IAM Access Analyzer 会报
  `PASS_ROLE_WITH_STAR_IN_RESOURCE`。收紧方式：限定具体角色 ARN，或加
  `iam:PassedToService` 条件键。
- 多条语句使用 `Resource: "*"` 与 `ec2:*` / `ssm:*` / `elasticfilesystem:*` / `s3vectors:*` 等通配动作，
  权限较宽。这是从原策略原样继承的，本次去重未改变权限边界。
- Access Analyzer 对 `bedrock:Converse` / `bedrock:ConverseStream` /
  `dynamodb:TransactGetItems` / `dynamodb:TransactWriteItems` 报 INVALID_ACTION，
  是其动作库滞后导致的误报（这些动作在原策略中已实际生效）。
