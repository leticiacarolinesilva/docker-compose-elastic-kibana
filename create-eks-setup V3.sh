#!/bin/bash

# ============================================================================
# 🚀 EKS DEPLOYMENT SCRIPT MODULAR - AMAZON ELASTIC KUBERNETES SERVICE
# ============================================================================
# Autor: Criado com Amazon Q
# Versão: 3.0 - Modular, Seguro e Verificável
# Descrição: Script modular para criar cluster EKS passo a passo
# 
# CARACTERÍSTICAS:
# ✅ Execução passo a passo
# ✅ Verificação de cada etapa
# ✅ Seguro para qualquer conta AWS
# ✅ Não deleta recursos existentes
# ✅ Permite execução individual de passos
# 
# USO:
# ./eks-setup.sh --all              # Executar todos os passos
# ./eks-setup.sh --step 1           # Executar passo específico
# ./eks-setup.sh --verify           # Verificar deployment
# ./eks-setup.sh --check            # Verificar pré-requisitos
# ============================================================================

# ============================================================================
# 🚀 COMO USAR
# ============================================================================
# 1. Salvar o script
#nano eks-setup.sh
# (colar o código acima)

# 2. Dar permissão
#chmod +x eks-setup.sh

# 3. Verificar pré-requisitos
#./eks-setup.sh --check

# 4. Executar tudo
#./eks-setup.sh --all

# 5. Ou executar passo a passo
#./eks-setup.sh --step 1  # Rede
#./eks-setup.sh --step 2  # Roles
# ... etc

# 6. Verificar
#./eks-setup.sh --verify

# 7. Gerar relatório
#./eks-setup.sh --report







set -e  # Parar em caso de erro

# Configurações - MODIFIQUE AQUI SE NECESSÁRIO
PROJECT_NAME="fcg-eks-user"
CLUSTER_NAME="fcg-eks-user-cluster"
NODEGROUP_NAME="fcg-worker-nodes-micro"
AWS_REGION="us-east-1"
INSTANCE_TYPE="t3.micro"  # Confirmado: t3.micro
NODE_MIN_SIZE=1
NODE_MAX_SIZE=2
NODE_DESIRED_SIZE=2

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Funções de log
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[AVISO] $1${NC}"
}

error() {
    echo -e "${RED}[ERRO] $1${NC}"
    exit 1
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

success() {
    echo -e "${PURPLE}[SUCESSO] $1${NC}"
}

step_header() {
    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
}

# ============================================================================
# FUNÇÃO DE VERIFICAÇÃO DE PRÉ-REQUISITOS
# ============================================================================

check_prerequisites() {
    step_header "🔍 VERIFICANDO PRÉ-REQUISITOS"
    
    local all_good=true
    
    # 1. Verificar AWS CLI
    if command -v aws &> /dev/null; then
        success "✅ AWS CLI encontrado: $(aws --version | head -n1)"
    else
        error "❌ AWS CLI não encontrado. Instale: https://aws.amazon.com/cli/"
        all_good=false
    fi
    
    # 2. Verificar kubectl
    if command -v kubectl &> /dev/null; then
        success "✅ kubectl encontrado: $(kubectl version --client --short 2>/dev/null || echo 'versão não detectada')"
    else
        error "❌ kubectl não encontrado. Instale: https://kubernetes.io/docs/tasks/tools/"
        all_good=false
    fi
    
    # 3. Verificar jq
    if command -v jq &> /dev/null; then
        success "✅ jq encontrado: $(jq --version)"
    else
        warn "⚠️  jq não encontrado. Tentando instalar..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y jq
        elif command -v yum &> /dev/null; then
            sudo yum install -y jq
        elif command -v brew &> /dev/null; then
            brew install jq
        else
            error "❌ Instale jq manualmente: https://stedolan.github.io/jq/"
            all_good=false
        fi
    fi
    
    # 4. Verificar credenciais AWS
    if aws sts get-caller-identity &> /dev/null; then
        local account_id=$(aws sts get-caller-identity --query Account --output text)
        local user_arn=$(aws sts get-caller-identity --query Arn --output text)
        success "✅ Credenciais AWS válidas"
        info "   Conta: $account_id"
        info "   Usuário: $user_arn"
        info "   Região: $AWS_REGION"
    else
        error "❌ Credenciais AWS não configuradas. Execute: aws configure"
        all_good=false
    fi
    
    # 5. Verificar permissões básicas
    info "Verificando permissões AWS básicas..."
    
    # Testar EC2
    if aws ec2 describe-regions --region $AWS_REGION &>/dev/null; then
        success "✅ Permissões EC2 OK"
    else
        error "❌ Sem permissões EC2"
        all_good=false
    fi
    
    # Testar IAM
    if aws iam get-account-summary &>/dev/null; then
        success "✅ Permissões IAM OK"
    else
        error "❌ Sem permissões IAM"
        all_good=false
    fi
    
    # Testar EKS
    if aws eks list-clusters --region $AWS_REGION &>/dev/null; then
        success "✅ Permissões EKS OK"
    else
        error "❌ Sem permissões EKS"
        all_good=false
    fi
    
    if [ "$all_good" = true ]; then
        success "🎉 Todos os pré-requisitos atendidos!"
        return 0
    else
        error "❌ Alguns pré-requisitos não foram atendidos. Corrija antes de continuar."
        return 1
    fi
}

# ============================================================================
# FUNÇÃO PARA VERIFICAR SE RECURSO JÁ EXISTE
# ============================================================================

resource_exists() {
    local resource_type=$1
    local resource_name=$2
    
    case $resource_type in
        "vpc")
            aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$resource_name" --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v "None" &>/dev/null
            ;;
        "cluster")
            aws eks describe-cluster --name $resource_name --region $AWS_REGION &>/dev/null
            ;;
        "nodegroup")
            aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $resource_name --region $AWS_REGION &>/dev/null
            ;;
        "iam-role")
            aws iam get-role --role-name $resource_name &>/dev/null
            ;;
        "iam-user")
            aws iam get-user --user-name $resource_name &>/dev/null
            ;;
        "iam-policy")
            aws iam get-policy --policy-arn $resource_name &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================================
# PASSO 1: CRIAR INFRAESTRUTURA DE REDE
# ============================================================================

step1_create_network() {
    step_header "📡 PASSO 1/7: CRIANDO INFRAESTRUTURA DE REDE"
    
    # Verificar se VPC já existe
    if resource_exists "vpc" "${PROJECT_NAME}-vpc"; then
        warn "VPC ${PROJECT_NAME}-vpc já existe. Pulando criação da rede."
        info "Para usar VPC existente, certifique-se que tem as configurações corretas."
        return 0
    fi
    
    # 1.1 Criar VPC
    info "Criando VPC..."
    local vpc_id=$(aws ec2 create-vpc \
      --cidr-block 10.0.0.0/16 \
      --query 'Vpc.VpcId' \
      --output text)

    aws ec2 create-tags \
      --resources $vpc_id \
      --tags Key=Name,Value=${PROJECT_NAME}-vpc Key=Project,Value=$PROJECT_NAME

    success "✅ VPC criada: $vpc_id"

    # 1.2 Criar Internet Gateway
    info "Criando Internet Gateway..."
    local igw_id=$(aws ec2 create-internet-gateway \
      --query 'InternetGateway.InternetGatewayId' \
      --output text)

    aws ec2 attach-internet-gateway \
      --vpc-id $vpc_id \
      --internet-gateway-id $igw_id

    aws ec2 create-tags \
      --resources $igw_id \
      --tags Key=Name,Value=${PROJECT_NAME}-igw Key=Project,Value=$PROJECT_NAME

    success "✅ Internet Gateway criado: $igw_id"

    # 1.3 Criar Subnets
    info "Criando Subnets..."
    local subnet1_id=$(aws ec2 create-subnet \
      --vpc-id $vpc_id \
      --cidr-block 10.0.1.0/24 \
      --availability-zone ${AWS_REGION}a \
      --query 'Subnet.SubnetId' \
      --output text)

    local subnet2_id=$(aws ec2 create-subnet \
      --vpc-id $vpc_id \
      --cidr-block 10.0.2.0/24 \
      --availability-zone ${AWS_REGION}b \
      --query 'Subnet.SubnetId' \
      --output text)

    aws ec2 create-tags \
      --resources $subnet1_id \
      --tags Key=Name,Value=${PROJECT_NAME}-subnet-1 Key=Project,Value=$PROJECT_NAME

    aws ec2 create-tags \
      --resources $subnet2_id \
      --tags Key=Name,Value=${PROJECT_NAME}-subnet-2 Key=Project,Value=$PROJECT_NAME

    success "✅ Subnets criadas: $subnet1_id, $subnet2_id"

    # 1.4 Configurar Route Table
    info "Configurando Route Table..."
    local route_table_id=$(aws ec2 create-route-table \
      --vpc-id $vpc_id \
      --query 'RouteTable.RouteTableId' \
      --output text)

    aws ec2 create-route \
      --route-table-id $route_table_id \
      --destination-cidr-block 0.0.0.0/0 \
      --gateway-id $igw_id

    aws ec2 associate-route-table \
      --subnet-id $subnet1_id \
      --route-table-id $route_table_id

    aws ec2 associate-route-table \
      --subnet-id $subnet2_id \
      --route-table-id $route_table_id

    aws ec2 create-tags \
      --resources $route_table_id \
      --tags Key=Name,Value=${PROJECT_NAME}-rt Key=Project,Value=$PROJECT_NAME

    # 1.5 Habilitar auto-assign IP público
    aws ec2 modify-subnet-attribute \
      --subnet-id $subnet1_id \
      --map-public-ip-on-launch

    aws ec2 modify-subnet-attribute \
      --subnet-id $subnet2_id \
      --map-public-ip-on-launch

    success "✅ Roteamento configurado"

    # 1.6 Criar Security Group
    info "Criando Security Group..."
    local sg_id=$(aws ec2 create-security-group \
      --group-name ${PROJECT_NAME}-sg \
      --description "Security group for EKS cluster" \
      --vpc-id $vpc_id \
      --query 'GroupId' \
      --output text)

    # Adicionar regras básicas
    aws ec2 authorize-security-group-ingress \
      --group-id $sg_id \
      --protocol tcp \
      --port 443 \
      --cidr 0.0.0.0/0

    aws ec2 authorize-security-group-ingress \
      --group-id $sg_id \
      --protocol tcp \
      --port 80 \
      --cidr 0.0.0.0/0

    aws ec2 create-tags \
      --resources $sg_id \
      --tags Key=Name,Value=${PROJECT_NAME}-sg Key=Project,Value=$PROJECT_NAME

    success "✅ Security Group criado: $sg_id"

    # Salvar IDs para próximos passos
    cat > .eks-network-info << EOF
VPC_ID=$vpc_id
IGW_ID=$igw_id
SUBNET1_ID=$subnet1_id
SUBNET2_ID=$subnet2_id
ROUTE_TABLE_ID=$route_table_id
SG_ID=$sg_id
EOF

    success "🎉 PASSO 1 CONCLUÍDO: Infraestrutura de rede criada!"
}

# ============================================================================
# PASSO 2: CRIAR IAM ROLES PARA EKS
# ============================================================================

step2_create_eks_roles() {
    step_header "👤 PASSO 2/7: CRIANDO IAM ROLES PARA EKS"
    
    # 2.1 Verificar e criar EKS Cluster Role
    if resource_exists "iam-role" "${PROJECT_NAME}-cluster-role"; then
        warn "Role ${PROJECT_NAME}-cluster-role já existe. Pulando criação."
    else
        info "Criando EKS Cluster Service Role..."
        aws iam create-role \
          --role-name ${PROJECT_NAME}-cluster-role \
          --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
              {
                "Effect": "Allow",
                "Principal": {
                  "Service": "eks.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
              }
            ]
          }' \
          --tags Key=Project,Value=$PROJECT_NAME > /dev/null

        aws iam attach-role-policy \
          --role-name ${PROJECT_NAME}-cluster-role \
          --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

        success "✅ EKS Cluster Role criado"
    fi

    # 2.2 Verificar e criar EKS Node Group Role
    if resource_exists "iam-role" "${PROJECT_NAME}-node-role"; then
        warn "Role ${PROJECT_NAME}-node-role já existe. Pulando criação."
    else
        info "Criando EKS Node Group Role..."
        aws iam create-role \
          --role-name ${PROJECT_NAME}-node-role \
          --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
              {
                "Effect": "Allow",
                "Principal": {
                  "Service": "ec2.amazonaws.com"
                },
                "Action": "sts:AssumeRole"
              }
            ]
          }' \
          --tags Key=Project,Value=$PROJECT_NAME > /dev/null

        # Anexar políticas obrigatórias
        aws iam attach-role-policy \
          --role-name ${PROJECT_NAME}-node-role \
          --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

        aws iam attach-role-policy \
          --role-name ${PROJECT_NAME}-node-role \
          --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

        aws iam attach-role-policy \
          --role-name ${PROJECT_NAME}-node-role \
          --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

        success "✅ EKS Node Group Role criado"
    fi

    success "🎉 PASSO 2 CONCLUÍDO: IAM Roles para EKS criados!"
}

# ============================================================================
# PASSO 3: CRIAR USUÁRIO ADMIN
# ============================================================================

step3_create_admin_user() {
    step_header "🔧 PASSO 3/7: CRIANDO USUÁRIO ADMIN"
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    
    # 3.1 Verificar e criar usuário admin
    if resource_exists "iam-user" "${PROJECT_NAME}-admin"; then
        warn "Usuário ${PROJECT_NAME}-admin já existe. Pulando criação."
    else
        info "Criando usuário Admin..."
        aws iam create-user \
          --user-name ${PROJECT_NAME}-admin \
          --tags Key=Project,Value=$PROJECT_NAME > /dev/null

        success "✅ Usuário admin criado: ${PROJECT_NAME}-admin"
    fi

    # 3.2 Verificar e criar política admin
    local admin_policy_arn="arn:aws:iam::${account_id}:policy/${PROJECT_NAME}-AdminPolicy"
    if resource_exists "iam-policy" "$admin_policy_arn"; then
        warn "Política ${PROJECT_NAME}-AdminPolicy já existe. Pulando criação."
    else
        info "Criando política admin..."
        aws iam create-policy \
          --policy-name ${PROJECT_NAME}-AdminPolicy \
          --policy-document '{
            "Version": "2012-10-17",
            "Statement": [
              {
                "Effect": "Allow",
                "Action": [
                  "eks:*",
                  "ec2:DescribeInstances",
                  "ec2:DescribeSecurityGroups",
                  "ec2:DescribeSubnets",
                  "ec2:DescribeVpcs",
                  "iam:GetRole",
                  "iam:ListRoles"
                ],
                "Resource": "*"
              }
            ]
          }' \
          --tags Key=Project,Value=$PROJECT_NAME > /dev/null

        success "✅ Política admin criada"
    fi

    # 3.3 Anexar política ao usuário
    info "Anexando política ao usuário admin..."
    aws iam attach-user-policy \
      --user-name ${PROJECT_NAME}-admin \
      --policy-arn $admin_policy_arn 2>/dev/null || warn "Política já pode estar anexada"

    success "🎉 PASSO 3 CONCLUÍDO: Usuário admin configurado!"
}

# ============================================================================
# PASSO 4: CRIAR USUÁRIO GITHUB CI/CD
# ============================================================================

step4_create_github_user() {
    step_header "🤖 PASSO 4/7: CRIANDO USUÁRIO GITHUB CI/CD"
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    
    # 4.1 Verificar e criar usuário GitHub
    if resource_exists "iam-user" "${PROJECT_NAME}-github-cicd"; then
        warn "Usuário ${PROJECT_NAME}-github-cicd já existe. Pulando criação."
    else
        info "Criando usuário GitHub CI/CD..."
        aws iam create-user \
          --user-name ${PROJECT_NAME}-github-cicd \
          --tags Key=Project,Value=$PROJECT_NAME > /dev/null

        success "✅ Usuário GitHub CI/CD criado: ${PROJECT_NAME}-github-cicd"
    fi

    # 4.2 Verificar e criar política GitHub CI/CD
    local github_policy_arn="arn:aws:iam::${account_id}:policy/${PROJECT_NAME}-GitHubCICDPolicy"
    if resource_exists "iam-policy" "$github_policy_arn"; then
        warn "Política ${PROJECT_NAME}-GitHubCICDPolicy já existe. Pulando criação."
    else
        info "Criando política completa para GitHub CI/CD..."
        aws iam create-policy \
          --policy-name ${PROJECT_NAME}-GitHubCICDPolicy \
          --policy-document '{
            "Version": "2012-10-17",
            "Statement": [
              {
                "Sid": "EKSFullAccess",
                "Effect": "Allow",
                "Action": ["eks:*"],
                "Resource": "*"
              },
              {
                "Sid": "ECRFullAccess",
                "Effect": "Allow",
                "Action": ["ecr:*"],
                "Resource": "*"
              },
              {
                "Sid": "EC2ForEKS",
                "Effect": "Allow",
                "Action": [
                  "ec2:Describe*",
                  "ec2:CreateTags",
                  "ec2:DeleteTags"
                ],
                "Resource": "*"
              },
              {
                "Sid": "IAMForEKS",
                "Effect": "Allow",
                "Action": [
                  "iam:GetRole",
                  "iam:PassRole",
                  "iam:ListAttachedRolePolicies",
                  "iam:GetPolicy",
                  "iam:GetPolicyVersion"
                ],
                "Resource": "*"
              },
              {
                "Sid": "CloudFormationAccess",
                "Effect": "Allow",
                "Action": ["cloudformation:*"],
                "Resource": "*"
              },
              {
                "Sid": "S3ForArtifacts",
                "Effect": "Allow",
                "Action": [
                  "s3:GetObject",
                  "s3:PutObject",
                  "s3:DeleteObject",
                  "s3:ListBucket",
                  "s3:CreateBucket",
                  "s3:GetBucketLocation"
                ],
                "Resource": "*"
              },
              {
                "Sid": "LogsAndMonitoring",
                "Effect": "Allow",
                "Action": ["logs:*", "cloudwatch:*"],
                "Resource": "*"
              },
              {
                "Sid": "LoadBalancerAccess",
                "Effect": "Allow",
                "Action": ["elasticloadbalancing:*"],
                "Resource": "*"
              },
              {
                "Sid": "AutoScalingAccess",
                "Effect": "Allow",
                "Action": ["autoscaling:*", "application-autoscaling:*"],
                "Resource": "*"
              },
              {
                "Sid": "SecretsAccess",
                "Effect": "Allow",
                "Action": [
                  "ssm:GetParameter",
                  "ssm:GetParameters",
                  "ssm:PutParameter",
                  "secretsmanager:GetSecretValue"
                ],
                "Resource": "*"
              }
            ]
          }' \
          --tags Key=Project,Value=$PROJECT_NAME > /dev/null

        success "✅ Política GitHub CI/CD criada"
    fi

    # 4.3 Anexar política ao usuário
    info "Anexando política ao usuário GitHub..."
    aws iam attach-user-policy \
      --user-name ${PROJECT_NAME}-github-cicd \
      --policy-arn $github_policy_arn 2>/dev/null || warn "Política já pode estar anexada"

    # 4.4 Criar access keys (apenas se não existirem)
    local existing_keys=$(aws iam list-access-keys --user-name ${PROJECT_NAME}-github-cicd --query 'AccessKeyMetadata' --output text 2>/dev/null || echo "")
    
    if [ -z "$existing_keys" ] || [ "$existing_keys" = "None" ]; then
        info "Criando access keys para GitHub Actions..."
        local github_keys=$(aws iam create-access-key --user-name ${PROJECT_NAME}-github-cicd --output json)
        local github_access_key=$(echo $github_keys | jq -r '.AccessKey.AccessKeyId')
        local github_secret_key=$(echo $github_keys | jq -r '.AccessKey.SecretAccessKey')

        # Salvar credenciais
        cat > .eks-github-credentials << EOF
GITHUB_ACCESS_KEY=$github_access_key
GITHUB_SECRET_KEY=$github_secret_key
EOF

        success "✅ Access keys criadas e salvas"
    else
        warn "Access keys já existem para o usuário GitHub CI/CD"
        info "Se precisar de novas keys, delete as existentes primeiro"
    fi

    success "🎉 PASSO 4 CONCLUÍDO: Usuário GitHub CI/CD configurado!"
}

# ============================================================================
# PASSO 5: AGUARDAR PROPAGAÇÃO
# ============================================================================

step5_wait_propagation() {
    step_header "⏳ PASSO 5/7: AGUARDANDO PROPAGAÇÃO DOS ROLES"
    
    info "Aguardando 30 segundos para propagação dos IAM roles..."
    
    for i in {30..1}; do
        echo -ne "\r⏳ Aguardando: $i segundos restantes..."
        sleep 1
    done
    echo ""
    
    success "🎉 PASSO 5 CONCLUÍDO: Propagação finalizada!"
}

# ============================================================================
# PASSO 6: CRIAR CLUSTER EKS
# ============================================================================

step6_create_eks_cluster() {
    step_header "🎯 PASSO 6/7: CRIANDO CLUSTER EKS"
    
    # Verificar se cluster já existe
    if resource_exists "cluster" "$CLUSTER_NAME"; then
        warn "Cluster $CLUSTER_NAME já existe. Pulando criação."
        return 0
    fi

    # Carregar informações da rede
    if [ ! -f .eks-network-info ]; then
        error "Arquivo .eks-network-info não encontrado. Execute o Passo 1 primeiro."
        return 1
    fi
    
    source .eks-network-info
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    # 6.1 Criar EKS Cluster
    info "Criando EKS Cluster (pode levar 10-15 minutos)..."
    aws eks create-cluster \
      --name $CLUSTER_NAME \
      --version 1.30 \
      --role-arn arn:aws:iam::${account_id}:role/${PROJECT_NAME}-cluster-role \
      --resources-vpc-config subnetIds=${SUBNET1_ID},${SUBNET2_ID},securityGroupIds=${SG_ID} \
      --tags Project=$PROJECT_NAME > /dev/null

    success "✅ Comando de criação do cluster enviado"

    # 6.2 Aguardar cluster ficar ativo
    info "⏳ Aguardando cluster ficar ativo..."
    info "📊 Isso pode levar 10-15 minutos, seja paciente..."
    
    local start_time=$(date +%s)
    while true; do
        local status=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ "$status" = "ACTIVE" ]; then
            echo ""
            success "✅ Cluster EKS ativo!"
            break
        elif [ "$status" = "FAILED" ]; then
            echo ""
            error "❌ Falha na criação do cluster"
            return 1
        elif [ $elapsed -gt 1200 ]; then  # 20 minutos timeout
            echo ""
            error "❌ Timeout na criação do cluster (20 minutos)"
            return 1
        else
            echo -ne "\r⏳ Status: $status | Tempo: ${elapsed}s | $(date +'%H:%M:%S')"
            sleep 30
        fi
    done

    success "🎉 PASSO 6 CONCLUÍDO: Cluster EKS criado e ativo!"
}

# ============================================================================
# PASSO 7: CRIAR NODE GROUP
# ============================================================================

step7_create_node_group() {
    step_header "🖥️ PASSO 7/7: CRIANDO NODE GROUP"
    
    # Verificar se node group já existe
    if resource_exists "nodegroup" "$NODEGROUP_NAME"; then
        warn "Node Group $NODEGROUP_NAME já existe. Pulando criação."
        return 0
    fi

    # Carregar informações da rede
    if [ ! -f .eks-network-info ]; then
        error "Arquivo .eks-network-info não encontrado. Execute o Passo 1 primeiro."
        return 1
    fi
    
    source .eks-network-info
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    # 7.1 Criar Node Group
    info "Criando Node Group com instâncias $INSTANCE_TYPE..."
    aws eks create-nodegroup \
      --cluster-name $CLUSTER_NAME \
      --nodegroup-name $NODEGROUP_NAME \
      --instance-types $INSTANCE_TYPE \
      --node-role arn:aws:iam::${account_id}:role/${PROJECT_NAME}-node-role \
      --subnets $SUBNET1_ID $SUBNET2_ID \
      --scaling-config minSize=$NODE_MIN_SIZE,maxSize=$NODE_MAX_SIZE,desiredSize=$NODE_DESIRED_SIZE \
      --tags Project=$PROJECT_NAME > /dev/null

    success "✅ Comando de criação do node group enviado"

    # 7.2 Aguardar node group ficar ativo
    info "⏳ Aguardando node group ficar ativo..."
    
    local start_time=$(date +%s)
    while true; do
        local status=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NODEGROUP_NAME --query 'nodegroup.status' --output text 2>/dev/null || echo "NOT_FOUND")
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ "$status" = "ACTIVE" ]; then
            echo ""
            success "✅ Node Group ativo!"
            break
        elif [ "$status" = "CREATE_FAILED" ] || [ "$status" = "FAILED" ]; then
            echo ""
            error "❌ Falha na criação do node group"
            return 1
        elif [ $elapsed -gt 900 ]; then  # 15 minutos timeout
            echo ""
            error "❌ Timeout na criação do node group (15 minutos)"
            return 1
        else
            echo -ne "\r⏳ Status: $status | Tempo: ${elapsed}s | $(date +'%H:%M:%S')"
            sleep 30
        fi
    done

    # 7.3 Configurar kubectl
    info "Configurando kubectl..."
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

    success "✅ kubectl configurado"

    # 7.4 Configurar RBAC
    info "Configurando RBAC para usuário admin..."
    kubectl create clusterrolebinding ${PROJECT_NAME}-admin-binding \
      --clusterrole=cluster-admin \
      --user=${PROJECT_NAME}-admin 2>/dev/null || warn "RBAC binding já pode existir"

    success "✅ RBAC configurado"

    # 7.5 Verificar nodes
    info "Verificando nodes do cluster..."
    kubectl get nodes

    success "🎉 PASSO 7 CONCLUÍDO: Node Group criado e configurado!"
}

# ============================================================================
# FUNÇÃO DE VERIFICAÇÃO COMPLETA
# ============================================================================

verify_deployment() {
    step_header "🔍 VERIFICAÇÃO COMPLETA DO DEPLOYMENT"
    
    local all_good=true
    
    # 1. Verificar cluster
    info "1. Verificando Cluster EKS..."
    local cluster_status=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$cluster_status" = "ACTIVE" ]; then
        success "✅ Cluster EKS está ATIVO"
        local cluster_version=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.version' --output text)
        info "   Nome: $CLUSTER_NAME"
        info "   Versão: $cluster_version"
        info "   Status: $cluster_status"
    else
        error "❌ Cluster EKS não está ativo: $cluster_status"
        all_good=false
    fi

    # 2. Verificar node group
    info "2. Verificando Node Group..."
    local nodegroup_status=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NODEGROUP_NAME --query 'nodegroup.status' --output text 2>/dev/null || echo "NOT_FOUND")
    
    if [ "$nodegroup_status" = "ACTIVE" ]; then
        success "✅ Node Group está ATIVO"
        local instance_types=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NODEGROUP_NAME --query 'nodegroup.instanceTypes[0]' --output text)
        local desired_size=$(aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NODEGROUP_NAME --query 'nodegroup.scalingConfig.desiredSize' --output text)
        info "   Nome: $NODEGROUP_NAME"
        info "   Tipo de instância: $instance_types"
        info "   Tamanho desejado: $desired_size"
        info "   Status: $nodegroup_status"
    else
        error "❌ Node Group não está ativo: $nodegroup_status"
        all_good=false
    fi

    # 3. Verificar kubectl
    info "3. Verificando kubectl..."
    if command -v kubectl &> /dev/null; then
        success "✅ kubectl está instalado"
        if kubectl cluster-info &> /dev/null; then
            success "✅ kubectl está configurado corretamente"
            echo ""
            info "Nodes do cluster:"
            kubectl get nodes
            echo ""
            info "Pods do sistema:"
            kubectl get pods -A | head -10
        else
            warn "⚠️  kubectl não está configurado. Execute:"
            info "   aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME"
        fi
    else
        error "❌ kubectl não está instalado"
        all_good=false
    fi

    # 4. Verificar usuários IAM
    info "4. Verificando usuários IAM..."
    if resource_exists "iam-user" "${PROJECT_NAME}-admin"; then
        success "✅ Usuário admin existe: ${PROJECT_NAME}-admin"
    else
        error "❌ Usuário admin não encontrado"
        all_good=false
    fi

    if resource_exists "iam-user" "${PROJECT_NAME}-github-cicd"; then
        success "✅ Usuário GitHub CI/CD existe: ${PROJECT_NAME}-github-cicd"
    else
        error "❌ Usuário GitHub CI/CD não encontrado"
        all_good=false
    fi

    # 5. Verificar roles IAM
    info "5. Verificando roles IAM..."
    if resource_exists "iam-role" "${PROJECT_NAME}-cluster-role"; then
        success "✅ Cluster role existe: ${PROJECT_NAME}-cluster-role"
    else
        error "❌ Cluster role não encontrado"
        all_good=false
    fi

    if resource_exists "iam-role" "${PROJECT_NAME}-node-role"; then
        success "✅ Node role existe: ${PROJECT_NAME}-node-role"
    else
        error "❌ Node role não encontrado"
        all_good=false
    fi

    # 6. Verificar infraestrutura de rede
    info "6. Verificando infraestrutura de rede..."
    if resource_exists "vpc" "${PROJECT_NAME}-vpc"; then
        success "✅ VPC existe: ${PROJECT_NAME}-vpc"
    else
        error "❌ VPC não encontrada"
        all_good=false
    fi

    echo ""
    if [ "$all_good" = true ]; then
        success "🎉 VERIFICAÇÃO CONCLUÍDA: Todos os componentes estão funcionando!"
        
        # Mostrar informações de custos
        echo ""
        info "💰 CUSTOS ESTIMADOS (MENSAIS):"
        info "   EKS Cluster: ~$72.00/mês"
        info "   EC2 Nodes (${NODE_DESIRED_SIZE}x $INSTANCE_TYPE): ~$15.00/mês"
        info "   VPC/Networking: ~$2.00/mês"
        info "   ═══════════════════════════════════════"
        info "   TOTAL ESTIMADO: ~$89.00/mês"
        
        # Mostrar credenciais GitHub se existirem
        if [ -f .eks-github-credentials ]; then
            echo ""
            info "🔑 CREDENCIAIS GITHUB ACTIONS:"
            source .eks-github-credentials
            info "   AWS_ACCESS_KEY_ID: $GITHUB_ACCESS_KEY"
            info "   AWS_SECRET_ACCESS_KEY: [HIDDEN]"
            info "   AWS_REGION: $AWS_REGION"
            info "   EKS_CLUSTER_NAME: $CLUSTER_NAME"
        fi
        
        return 0
    else
        error "❌ VERIFICAÇÃO FALHOU: Alguns componentes não estão funcionando corretamente"
        return 1
    fi
}

# ============================================================================
# FUNÇÃO PARA GERAR RELATÓRIO FINAL
# ============================================================================

generate_final_report() {
    step_header "📄 GERANDO RELATÓRIO FINAL"
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    
    # Carregar informações se existirem
    local vpc_id="N/A"
    local subnet1_id="N/A"
    local subnet2_id="N/A"
    local sg_id="N/A"
    local github_access_key="N/A"
    
    if [ -f .eks-network-info ]; then
        source .eks-network-info
        vpc_id=$VPC_ID
        subnet1_id=$SUBNET1_ID
        subnet2_id=$SUBNET2_ID
        sg_id=$SG_ID
    fi
    
    if [ -f .eks-github-credentials ]; then
        source .eks-github-credentials
        github_access_key=$GITHUB_ACCESS_KEY
    fi

    cat > eks-deployment-report.txt << EOF
🎉 EKS DEPLOYMENT REPORT - $(date)

============================================================================
📋 INFORMAÇÕES DO CLUSTER
============================================================================
   Nome do Cluster: $CLUSTER_NAME
   Região AWS: $AWS_REGION
   Versão Kubernetes: 1.30
   Account ID: $account_id
   Tipo de Instância: $INSTANCE_TYPE
   Nodes Desejados: $NODE_DESIRED_SIZE

============================================================================
🏗️ INFRAESTRUTURA CRIADA
============================================================================
   VPC ID: $vpc_id
   Subnet 1: $subnet1_id (${AWS_REGION}a)
   Subnet 2: $subnet2_id (${AWS_REGION}b)
   Security Group: $sg_id

============================================================================
👥 USUÁRIOS E ROLES CRIADOS
============================================================================
   🔧 Admin User: ${PROJECT_NAME}-admin
   🤖 GitHub CI/CD User: ${PROJECT_NAME}-github-cicd
   👤 Cluster Role: ${PROJECT_NAME}-cluster-role
   🖥️ Node Role: ${PROJECT_NAME}-node-role

============================================================================
🔑 CREDENCIAIS PARA GITHUB ACTIONS
============================================================================
   AWS_ACCESS_KEY_ID: $github_access_key
   AWS_SECRET_ACCESS_KEY: [Consulte arquivo .eks-github-credentials]
   AWS_REGION: $AWS_REGION
   EKS_CLUSTER_NAME: $CLUSTER_NAME

   📝 CONFIGURAR NO GITHUB:
   1. Settings > Secrets and variables > Actions
   2. Adicionar as secrets acima
   3. Usar nos workflows

============================================================================
💰 CUSTOS ESTIMADOS (MENSAIS)
============================================================================
   💸 EKS Cluster: ~$72.00/mês
   💸 EC2 Nodes (${NODE_DESIRED_SIZE}x $INSTANCE_TYPE): ~$15.00/mês
   💸 VPC/Networking: ~$2.00/mês
   ═══════════════════════════════════════
   💰 TOTAL ESTIMADO: ~$89.00/mês

============================================================================
🔍 COMANDOS DE VERIFICAÇÃO
============================================================================
   # Verificar nodes
   kubectl get nodes
   
   # Verificar pods do sistema
   kubectl get pods -A
   
   # Informações do cluster
   kubectl cluster-info
   
   # Status do cluster
   aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION

============================================================================
🚀 PRÓXIMOS PASSOS
============================================================================
   1. 🔑 Configurar GitHub Actions com as credenciais
   2. 📦 Criar repositório ECR para imagens Docker
   3. 🚀 Desenvolver aplicações para Kubernetes
   4. 📊 Configurar monitoramento (CloudWatch)
   5. 🔒 Revisar políticas de segurança

============================================================================
📞 COMANDOS ÚTEIS
============================================================================
   # Verificar deployment completo
   $0 --verify
   
   # Executar passo específico
   $0 --step [1-7]
   
   # Verificar pré-requisitos
   $0 --check

============================================================================
⚠️ IMPORTANTE
============================================================================
   • Recursos geram custos 24/7 (~$89/mês)
   • Mantenha credenciais seguras
   • Monitore custos regularmente
   • Use tags para organização

Relatório gerado em: $(date)
EOF

    success "✅ Relatório salvo em: eks-deployment-report.txt"
    
    if [ -f .eks-github-credentials ]; then
        info "🔑 Credenciais GitHub salvas em: .eks-github-credentials"
    fi
    
    if [ -f .eks-network-info ]; then
        info "🏗️ Informações de rede salvas em: .eks-network-info"
    fi
}

# ============================================================================
# FUNÇÃO PRINCIPAL DE CONTROLE
# ============================================================================

show_help() {
    echo -e "${CYAN}"
    echo "============================================================================"
    echo "🚀 EKS DEPLOYMENT SCRIPT v3.0 - MODULAR E SEGURO"
    echo "============================================================================"
    echo -e "${NC}"
    echo ""
    echo "USO:"
    echo "  $0 --all              # Executar todos os passos (1-7)"
    echo "  $0 --step N           # Executar passo específico (1-7)"
    echo "  $0 --verify           # Verificar deployment completo"
    echo "  $0 --check            # Verificar pré-requisitos"
    echo "  $0 --report           # Gerar relatório final"
    echo "  $0 --help             # Mostrar esta ajuda"
    echo ""
    echo "PASSOS DISPONÍVEIS:"
    echo "  1. Criar infraestrutura de rede (VPC, Subnets, etc.)"
    echo "  2. Criar IAM Roles para EKS"
    echo "  3. Criar usuário admin"
    echo "  4. Criar usuário GitHub CI/CD"
    echo "  5. Aguardar propagação dos roles"
    echo "  6. Criar cluster EKS"
    echo "  7. Criar node group e configurar kubectl"
    echo ""
    echo "EXEMPLOS:"
    echo "  chmod +x $0"
    echo "  ./$0 --check          # Verificar pré-requisitos primeiro"
    echo "  ./$0 --all            # Criar tudo"
    echo "  ./$0 --step 1         # Apenas criar rede"
    echo "  ./$0 --verify         # Verificar se está funcionando"
    echo ""
    echo "CONFIGURAÇÕES ATUAIS:"
    echo "  Projeto: $PROJECT_NAME"
    echo "  Cluster: $CLUSTER_NAME"
    echo "  Região: $AWS_REGION"
    echo "  Instância: $INSTANCE_TYPE"
    echo "  Nodes: $NODE_DESIRED_SIZE"
    echo ""
}

# Controle principal
case "${1:-}" in
    --all)
        check_prerequisites
        step1_create_network
        step2_create_eks_roles
        step3_create_admin_user
        step4_create_github_user
        step5_wait_propagation
        step6_create_eks_cluster
        step7_create_node_group
        generate_final_report
        echo ""
        success "🎉 DEPLOYMENT COMPLETO! Veja eks-deployment-report.txt para detalhes."
        ;;
    --step)
        if [ -z "$2" ]; then
            error "Especifique o número do passo (1-7)"
        fi
        
        case "$2" in
            1) check_prerequisites && step1_create_network ;;
            2) check_prerequisites && step2_create_eks_roles ;;
            3) check_prerequisites && step3_create_admin_user ;;
            4) check_prerequisites && step4_create_github_user ;;
            5) step5_wait_propagation ;;
            6) check_prerequisites && step6_create_eks_cluster ;;
            7) check_prerequisites && step7_create_node_group ;;
            *) error "Passo inválido. Use 1-7." ;;
        esac
        ;;
    --verify)
        verify_deployment
        ;;
    --check)
        check_prerequisites
        ;;
    --report)
        generate_final_report
        ;;
    --help|-h)
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        error "Parâmetro inválido: $1. Use --help para ver opções disponíveis."
        ;;
esac
