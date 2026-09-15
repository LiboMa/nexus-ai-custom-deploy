1. generating the one-command link:

A. 维护者发布(在你本地仓库执行)
cd <Nexus AI Dir>
source .venv/bin/activate
./nexus-cli deploy release v0.3.12 \
    --bucket nexus-ai-releases --region us-east-1 \
    --env-prefix nexus-ai-basic --deploy-region us-east-1 \
    --instance-type c8i.2xlarge --volume-size 150 \
    --key-name nexus-ai-demo --db-password 'NexusVerify2026!' \
    --enable-sandbox --sandbox-default-runtime ec2 \
    --sandbox-instance-type c8i.xlarge --sandbox-pool-size 1 --sandbox-max-nodes 5 \
    --enable-avatar \
    --expires-hours 24 \
    --edition basic | enterprise



```
 ./nexus-cli deploy release v0.3.23 \
    --bucket nexus-ai-releases-demo-1 --region us-east-1 \
    --env-prefix nexus-ai-basic --deploy-region us-east-1 \
    --instance-type c8i.2xlarge --volume-size 150 \
    --key-name nexus-ai-demo --db-password 'NexusVerify2026!' \
    --enable-sandbox --sandbox-default-runtime ec2 \
    --sandbox-instance-type c8i.xlarge --sandbox-pool-size 1 --sandbox-max-nodes 5 \
    --enable-avatar \
    --expires-hours 24 \
    --edition enterprise

```


B.
B.1 Create key-pair in the target region: for exmaple ->  NEXUS_KEY_NAME='nexus-ai-deploy'

B.2 Creating EC2 mannually

B.3 Creating IAM Role,

```
cd  nexus-ec2-role-policy
bash -x deploy.sh
```

Login to the EC2;


RUN:

export NEXUS_KEY_NAME='nexus-ai-deploy'
export NEXUS_DB_PASSWORD='NexusVerify2026!'
curl -fsSL "https://nexus-ai-releases.s3.amazonaws.com/releases/v0.3.12/go.sh?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=xxxxxxx...." | bash


C. 验证(浏览器/控制台)
打开输出的 CloudFront 地址,用 admin/nexus 登录。左下角用户头像修改密码
运维/服务面板:确认默认 EC2 模式 + sandbox 节点在运行。
D. 清理(止损)
cd ~/nexus-deploy/nexus-ai
source .venv-deploy/bin/activate 2>/dev/null || source .venv/bin/activate
python nexus-cli deploy down <stack-prefix> --clean-data -y
