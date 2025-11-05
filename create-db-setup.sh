#!/bin/bash

# ============================================================================
# 🗄️ DATABASE CREATION SCRIPT - FCG APPLICATIONS
# ============================================================================
# Autor: Criado com Amazon Q
# Versão: 1.0
# Descrição: Script para criar bancos de dados RDS para aplicações FCG
# 
# BANCOS DE DADOS A SEREM CRIADOS:
# 1. fcg-payments-db     - MySQL para API de pagamentos
# 2. fcg-user-api-db     - PostgreSQL para API de usuários
# 3. fcg-gamelibrary-db  - MySQL para biblioteca de jogos
# 4. fcg-analytics-db    - PostgreSQL para analytics
# 5. fcg-cache-redis     - ElastiCache Redis para cache
# 
# USO:
# ./create-databases.sh --all              # Criar todos os DBs
# ./create-databases.sh --db payments      # Criar DB específico
# ./create-databases.sh --verify           # Verificar DBs criados
# ./create-databases.sh --credentials      # Mostrar credenciais
# ============================================================================
# COMO USAR
#============================================================================

# 1. Salvar o script
#nano create-databases.sh

# 2. Dar permissão
#chmod +x create-databases.sh

# 3. Criar todos os bancos
#./create-databases.sh --all

# 4. Ou criar específicos
#./create-databases.sh --db payments
#./create-databases.sh --db redis

# 5. Aguardar criação
#./create-databases.sh --wait

# 6. Verificar
#./create-databases.sh --verify

# 7. Ver credenciais
#./create-databases.sh --credentials

#============================================================================



set -e

# Configurações
PROJECT_NAME="fcg-eks-user"
AWS_REGION="us-east-1"
DB_INSTANCE_CLASS="db.t3.micro"  # Classe econômica para desenvolvimento
REDIS_NODE_TYPE="cache.t3.micro"  # Classe econômica para Redis

# Configurações de segurança
DB_USERNAME="fcgadmin"
DB_PASSWORD_LENGTH=16

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
# FUNÇÃO PARA GERAR SENHA SEGURA
# ============================================================================

generate_password() {
    # Gerar senha com letras, números e símbolos seguros para RDS
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-${DB_PASSWORD_LENGTH}
}

# ============================================================================
# FUNÇÃO PARA OBTER VPC E SUBNETS
# ============================================================================

get_vpc_info() {
    # Tentar obter VPC do projeto primeiro
    local vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=${PROJECT_NAME}-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$vpc_id" = "None" ] || [ "$vpc_id" = "null" ]; then
        # Se não encontrar, usar VPC padrão
        vpc_id=$(aws ec2 describe-vpcs \
            --filters "Name=isDefault,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text 2>/dev/null || echo "None")
    fi
    
    if [ "$vpc_id" = "None" ] || [ "$vpc_id" = "null" ]; then
        error "Nenhuma VPC encontrada. Crie uma VPC primeiro."
    fi
    
    echo $vpc_id
}

get_subnets() {
    local vpc_id=$1
    
    # Obter subnets da VPC
    local subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'Subnets[*].SubnetId' \
        --output text)
    
    if [ -z "$subnets" ]; then
        error "Nenhuma subnet encontrada na VPC $vpc_id"
    fi
    
    echo $subnets
}

get_db_security_group() {
    # Obter Security Group do banco de dados
    local sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=fcg-db" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "None")
    
    if [ "$sg_id" = "None" ] || [ "$sg_id" = "null" ]; then
        warn "Security Group 'fcg-db' não encontrado. Criando um básico..."
        create_basic_db_security_group
        sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=fcg-db-basic" \
            --query 'SecurityGroups[0].GroupId' \
            --output text)
    fi
    
    echo $sg_id
}

create_basic_db_security_group() {
    local vpc_id=$(get_vpc_info)
    
    info "Criando Security Group básico para banco de dados..."
    local sg_id=$(aws ec2 create-security-group \
        --group-name "fcg-db-basic" \
        --description "Basic Security Group for FCG Databases" \
        --vpc-id "$vpc_id" \
        --query 'GroupId' \
        --output text)
    
    # Adicionar regras básicas
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr 10.0.0.0/16 2>/dev/null || true
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 5432 \
        --cidr 10.0.0.0/16 2>/dev/null || true
    
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 6379 \
        --cidr 10.0.0.0/16 2>/dev/null || true
    
    aws ec2 create-tags \
        --resources "$sg_id" \
        --tags Key=Name,Value="fcg-db-basic" Key=Project,Value="$PROJECT_NAME"
    
    success "✅ Security Group básico criado: $sg_id"
}

# ============================================================================
# FUNÇÃO PARA CRIAR SUBNET GROUP
# ============================================================================

create_db_subnet_group() {
    local subnet_group_name="${PROJECT_NAME}-db-subnet-group"
    
    # Verificar se já existe
    if aws rds describe-db-subnet-groups --db-subnet-group-name "$subnet_group_name" &>/dev/null; then
        warn "DB Subnet Group '$subnet_group_name' já existe."
        echo $subnet_group_name
        return 0
    fi
    
    local vpc_id=$(get_vpc_info)
    local subnets=$(get_subnets "$vpc_id")
    
    info "Criando DB Subnet Group..."
    aws rds create-db-subnet-group \
        --db-subnet-group-name "$subnet_group_name" \
        --db-subnet-group-description "Subnet group for FCG databases" \
        --subnet-ids $subnets \
        --tags Key=Name,Value="$subnet_group_name" Key=Project,Value="$PROJECT_NAME" > /dev/null
    
    success "✅ DB Subnet Group criado: $subnet_group_name"
    echo $subnet_group_name
}

# ============================================================================
# FUNÇÃO PARA VERIFICAR SE DB EXISTE
# ============================================================================

db_exists() {
    local db_identifier=$1
    aws rds describe-db-instances --db-instance-identifier "$db_identifier" &>/dev/null
}

redis_exists() {
    local cluster_id=$1
    aws elasticache describe-cache-clusters --cache-cluster-id "$cluster_id" &>/dev/null
}

# ============================================================================
# 1. BANCO DE DADOS: FCG-PAYMENTS (MySQL)
# ============================================================================

create_db_payments() {
    step_header "💳 CRIANDO BANCO DE DADOS: FCG-PAYMENTS (MySQL)"
    
    local db_identifier="fcg-payments-db"
    local db_name="fcg_payments"
    
    if db_exists "$db_identifier"; then
        warn "Banco de dados '$db_identifier' já existe. Pulando criação."
        return 0
    fi
    
    local password=$(generate_password)
    local subnet_group=$(create_db_subnet_group)
    local security_group=$(get_db_security_group)
    
    info "Criando banco MySQL para FCG Payments..."
    aws rds create-db-instance \
        --db-instance-identifier "$db_identifier" \
        --db-instance-class "$DB_INSTANCE_CLASS" \
        --engine mysql \
        --engine-version "8.0.35" \
        --master-username "$DB_USERNAME" \
        --master-user-password "$password" \
        --allocated-storage 20 \
        --storage-type gp2 \
        --db-name "$db_name" \
        --vpc-security-group-ids "$security_group" \
        --db-subnet-group-name "$subnet_group" \
        --backup-retention-period 7 \
        --storage-encrypted \
        --multi-az false \
        --publicly-accessible false \
        --auto-minor-version-upgrade true \
        --tags Key=Name,Value="$db_identifier" Key=Project,Value="$PROJECT_NAME" Key=Application,Value="payments" > /dev/null
    
    # Salvar credenciais
    cat >> .fcg-db-credentials << EOF
# FCG Payments Database (MySQL)
FCG_PAYMENTS_DB_IDENTIFIER=$db_identifier
FCG_PAYMENTS_DB_ENDPOINT=# Será preenchido após criação
FCG_PAYMENTS_DB_NAME=$db_name
FCG_PAYMENTS_DB_USERNAME=$DB_USERNAME
FCG_PAYMENTS_DB_PASSWORD=$password
FCG_PAYMENTS_DB_PORT=3306

EOF
    
    success "✅ Banco FCG Payments criado: $db_identifier"
    info "   Engine: MySQL 8.0.35"
    info "   Database: $db_name"
    info "   Username: $DB_USERNAME"
    warn "   ⚠️  Senha salva em .fcg-db-credentials"
}

# ============================================================================
# 2. BANCO DE DADOS: FCG-USER-API (PostgreSQL)
# ============================================================================

create_db_user_api() {
    step_header "👥 CRIANDO BANCO DE DADOS: FCG-USER-API (PostgreSQL)"
    
    local db_identifier="fcg-user-api-db"
    local db_name="fcg_users"
    
    if db_exists "$db_identifier"; then
        warn "Banco de dados '$db_identifier' já existe. Pulando criação."
        return 0
    fi
    
    local password=$(generate_password)
    local subnet_group=$(create_db_subnet_group)
    local security_group=$(get_db_security_group)
    
    info "Criando banco PostgreSQL para FCG User API..."
    aws rds create-db-instance \
        --db-instance-identifier "$db_identifier" \
        --db-instance-class "$DB_INSTANCE_CLASS" \
        --engine postgres \
        --engine-version "15.4" \
        --master-username "$DB_USERNAME" \
        --master-user-password "$password" \
        --allocated-storage 20 \
        --storage-type gp2 \
        --db-name "$db_name" \
        --vpc-security-group-ids "$security_group" \
        --db-subnet-group-name "$subnet_group" \
        --backup-retention-period 7 \
        --storage-encrypted \
        --multi-az false \
        --publicly-accessible false \
        --auto-minor-version-upgrade true \
        --tags Key=Name,Value="$db_identifier" Key=Project,Value="$PROJECT_NAME" Key=Application,Value="user-api" > /dev/null
    
    # Salvar credenciais
    cat >> .fcg-db-credentials << EOF
# FCG User API Database (PostgreSQL)
FCG_USER_API_DB_IDENTIFIER=$db_identifier
FCG_USER_API_DB_ENDPOINT=# Será preenchido após criação
FCG_USER_API_DB_NAME=$db_name
FCG_USER_API_DB_USERNAME=$DB_USERNAME
FCG_USER_API_DB_PASSWORD=$password
FCG_USER_API_DB_PORT=5432

EOF
    
    success "✅ Banco FCG User API criado: $db_identifier"
    info "   Engine: PostgreSQL 15.4"
    info "   Database: $db_name"
    info "   Username: $DB_USERNAME"
    warn "   ⚠️  Senha salva em .fcg-db-credentials"
}

# ============================================================================
# 3. BANCO DE DADOS: FCG-GAMELIBRARY (MySQL)
# ============================================================================

create_db_gamelibrary() {
    step_header "🎮 CRIANDO BANCO DE DADOS: FCG-GAMELIBRARY (MySQL)"
    
    local db_identifier="fcg-gamelibrary-db"
    local db_name="fcg_games"
    
    if db_exists "$db_identifier"; then
        warn "Banco de dados '$db_identifier' já existe. Pulando criação."
        return 0
    fi
    
    local password=$(generate_password)
    local subnet_group=$(create_db_subnet_group)
    local security_group=$(get_db_security_group)
    
    info "Criando banco MySQL para FCG Game Library..."
    aws rds create-db-instance \
        --db-instance-identifier "$db_identifier" \
        --db-instance-class "$DB_INSTANCE_CLASS" \
        --engine mysql \
        --engine-version "8.0.35" \
        --master-username "$DB_USERNAME" \
        --master-user-password "$password" \
        --allocated-storage 20 \
        --storage-type gp2 \
        --db-name "$db_name" \
        --vpc-security-group-ids "$security_group" \
        --db-subnet-group-name "$subnet_group" \
        --backup-retention-period 7 \
        --storage-encrypted \
        --multi-az false \
        --publicly-accessible false \
        --auto-minor-version-upgrade true \
        --tags Key=Name,Value="$db_identifier" Key=Project,Value="$PROJECT_NAME" Key=Application,Value="gamelibrary" > /dev/null
    
    # Salvar credenciais
    cat >> .fcg-db-credentials << EOF
# FCG Game Library Database (MySQL)
FCG_GAMELIBRARY_DB_IDENTIFIER=$db_identifier
FCG_GAMELIBRARY_DB_ENDPOINT=# Será preenchido após criação
FCG_GAMELIBRARY_DB_NAME=$db_name
FCG_GAMELIBRARY_DB_USERNAME=$DB_USERNAME
FCG_GAMELIBRARY_DB_PASSWORD=$password
FCG_GAMELIBRARY_DB_PORT=3306

EOF
    
    success "✅ Banco FCG Game Library criado: $db_identifier"
    info "   Engine: MySQL 8.0.35"
    info "   Database: $db_name"
    info "   Username: $DB_USERNAME"
    warn "   ⚠️  Senha salva em .fcg-db-credentials"
}

# ============================================================================
# 4. BANCO DE DADOS: FCG-ANALYTICS (PostgreSQL)
# ============================================================================

create_db_analytics() {
    step_header "📊 CRIANDO BANCO DE DADOS: FCG-ANALYTICS (PostgreSQL)"
    
    local db_identifier="fcg-analytics-db"
    local db_name="fcg_analytics"
    
    if db_exists "$db_identifier"; then
        warn "Banco de dados '$db_identifier' já existe. Pulando criação."
        return 0
    fi
    
    local password=$(generate_password)
    local subnet_group=$(create_db_subnet_group)
    local security_group=$(get_db_security_group)
    
    info "Criando banco PostgreSQL para FCG Analytics..."
    aws rds create-db-instance \
        --db-instance-identifier "$db_identifier" \
        --db-instance-class "$DB_INSTANCE_CLASS" \
        --engine postgres \
        --engine-version "15.4" \
        --master-username "$DB_USERNAME" \
        --master-user-password "$password" \
        --allocated-storage 20 \
        --storage-type gp2 \
        --db-name "$db_name" \
        --vpc-security-group-ids "$security_group" \
        --db-subnet-group-name "$subnet_group" \
        --backup-retention-period 7 \
        --storage-encrypted \
        --multi-az false \
        --publicly-accessible false \
        --auto-minor-version-upgrade true \
        --tags Key=Name,Value="$db_identifier" Key=Project,Value="$PROJECT_NAME" Key=Application,Value="analytics" > /dev/null
    
    # Salvar credenciais
    cat >> .fcg-db-credentials << EOF
# FCG Analytics Database (PostgreSQL)
FCG_ANALYTICS_DB_IDENTIFIER=$db_identifier
FCG_ANALYTICS_DB_ENDPOINT=# Será preenchido após criação
FCG_ANALYTICS_DB_NAME=$db_name
FCG_ANALYTICS_DB_USERNAME=$DB_USERNAME
FCG_ANALYTICS_DB_PASSWORD=$password
FCG_ANALYTICS_DB_PORT=5432

EOF
    
    success "✅ Banco FCG Analytics criado: $db_identifier"
    info "   Engine: PostgreSQL 15.4"
    info "   Database: $db_name"
    info "   Username: $DB_USERNAME"
    warn "   ⚠️  Senha salva em .fcg-db-credentials"
}

# ============================================================================
# 5. CACHE: FCG-REDIS (ElastiCache)
# ============================================================================

create_redis_cache() {
    step_header "🔄 CRIANDO CACHE REDIS: FCG-CACHE"
    
    local cluster_id="fcg-cache-redis"
    
    if redis_exists "$cluster_id"; then
        warn "Cluster Redis '$cluster_id' já existe. Pulando criação."
        return 0
    fi
    
    local subnet_group=$(create_cache_subnet_group)
    local security_group=$(get_db_security_group)
    
    info "Criando cluster Redis para FCG Cache..."
    aws elasticache create-cache-cluster \
        --cache-cluster-id "$cluster_id" \
        --cache-node-type "$REDIS_NODE_TYPE" \
        --engine redis \
        --engine-version "7.0" \
        --num-cache-nodes 1 \
        --cache-subnet-group-name "$subnet_group" \
        --security-group-ids "$security_group" \
        --tags Key=Name,Value="$cluster_id" Key=Project,Value="$PROJECT_NAME" Key=Application,Value="cache" > /dev/null
    
    # Salvar informações
    cat >> .fcg-db-credentials << EOF
# FCG Redis Cache
FCG_REDIS_CLUSTER_ID=$cluster_id
FCG_REDIS_ENDPOINT=# Será preenchido após criação
FCG_REDIS_PORT=6379

EOF
    
    success "✅ Cluster Redis criado: $cluster_id"
    info "   Engine: Redis 7.0"
    info "   Node Type: $REDIS_NODE_TYPE"
    warn "   ⚠️  Endpoint será disponível após criação"
}

create_cache_subnet_group() {
    local subnet_group_name="${PROJECT_NAME}-cache-subnet-group"
    
    # Verificar se já existe
    if aws elasticache describe-cache-subnet-groups --cache-subnet-group-name "$subnet_group_name" &>/dev/null; then
        warn "Cache Subnet Group '$subnet_group_name' já existe."
        echo $subnet_group_name
        return 0
    fi
    
    local vpc_id=$(get_vpc_info)
    local subnets=$(get_subnets "$vpc_id")
    
    info "Criando Cache Subnet Group..."
    aws elasticache create-cache-subnet-group \
        --cache-subnet-group-name "$subnet_group_name" \
        --cache-subnet-group-description "Subnet group for FCG cache" \
        --subnet-ids $subnets > /dev/null
    
    success "✅ Cache Subnet Group criado: $subnet_group_name"
    echo $subnet_group_name
}

# ============================================================================
# FUNÇÃO PARA AGUARDAR CRIAÇÃO DOS BANCOS
# ============================================================================

wait_for_databases() {
    step_header "⏳ AGUARDANDO CRIAÇÃO DOS BANCOS DE DADOS"
    
    local dbs=("fcg-payments-db" "fcg-user-api-db" "fcg-gamelibrary-db" "fcg-analytics-db")
    
    info "Aguardando bancos ficarem disponíveis (pode levar 10-15 minutos)..."
    
    for db_id in "${dbs[@]}"; do
        if db_exists "$db_id"; then
            info "Aguardando $db_id ficar disponível..."
            
            local start_time=$(date +%s)
            while true; do
                local status=$(aws rds describe-db-instances \
                    --db-instance-identifier "$db_id" \
                    --query 'DBInstances[0].DBInstanceStatus' \
                    --output text 2>/dev/null || echo "not-found")
                
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                
                if [ "$status" = "available" ]; then
                    success "✅ $db_id está disponível!"
                    break
                elif [ "$status" = "failed" ]; then
                    error "❌ Falha na criação de $db_id"
                    return 1
                elif [ $elapsed -gt 1200 ]; then  # 20 minutos timeout
                    error "❌ Timeout aguardando $db_id (20 minutos)"
                    return 1
                else
                    echo -ne "\r⏳ $db_id: $status | Tempo: ${elapsed}s"
                    sleep 30
                fi
            done
        fi
    done
    
    # Aguardar Redis
    if redis_exists "fcg-cache-redis"; then
        info "Aguardando Redis ficar disponível..."
        
        local start_time=$(date +%s)
        while true; do
            local status=$(aws elasticache describe-cache-clusters \
                --cache-cluster-id "fcg-cache-redis" \
                --query 'CacheClusters[0].CacheClusterStatus' \
                --output text 2>/dev/null || echo "not-found")
            
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            
            if [ "$status" = "available" ]; then
                success "✅ Redis está disponível!"
                break
            elif [ $elapsed -gt 900 ]; then  # 15 minutos timeout
                error "❌ Timeout aguardando Redis (15 minutos)"
                return 1
            else
                echo -ne "\r⏳ Redis: $status | Tempo: ${elapsed}s"
                sleep 30
            fi
        done
    fi
    
    echo ""
    success "🎉 Todos os bancos de dados estão disponíveis!"
}

# ============================================================================
# FUNÇÃO PARA ATUALIZAR ENDPOINTS
# ============================================================================

update_endpoints() {
    step_header "🔗 ATUALIZANDO ENDPOINTS DOS BANCOS"
    
    info "Obtendo endpoints dos bancos de dados..."
    
    # Criar arquivo temporário com endpoints
    cat > .fcg-db-endpoints << EOF
# FCG Database Endpoints - $(date)

EOF
    
    # Obter endpoints RDS
    local dbs=("fcg-payments-db" "fcg-user-api-db" "fcg-gamelibrary-db" "fcg-analytics-db")
    
    for db_id in "${dbs[@]}"; do
        if db_exists "$db_id"; then
            local endpoint=$(aws rds describe-db-instances \
                --db-instance-identifier "$db_id" \
                --query 'DBInstances[0].Endpoint.Address' \
                --output text 2>/dev/null || echo "not-available")
            
            local port=$(aws rds describe-db-instances \
                --db-instance-identifier "$db_id" \
                --query 'DBInstances[0].Endpoint.Port' \
                --output text 2>/dev/null || echo "not-available")
            
            echo "${db_id^^}_ENDPOINT=$endpoint" >> .fcg-db-endpoints
            echo "${db_id^^}_PORT=$port" >> .fcg-db-endpoints
            
            success "✅ $db_id: $endpoint:$port"
        fi
    done
    
    # Obter endpoint Redis
    if redis_exists "fcg-cache-redis"; then
        local redis_endpoint=$(aws elasticache describe-cache-clusters \
            --cache-cluster-id "fcg-cache-redis" \
            --show-cache-node-info \
            --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' \
            --output text 2>/dev/null || echo "not-available")
        
        echo "FCG_REDIS_ENDPOINT=$redis_endpoint" >> .fcg-db-endpoints
        success "✅ Redis: $redis_endpoint:6379"
    fi
    
    success "✅ Endpoints salvos em .fcg-db-endpoints"
}

# ============================================================================
# FUNÇÃO DE VERIFICAÇÃO
# ============================================================================

verify_databases() {
    step_header "🔍 VERIFICANDO BANCOS DE DADOS CRIADOS"
    
    local all_good=true
    
    # Verificar RDS
    local dbs=("fcg-payments-db" "fcg-user-api-db" "fcg-gamelibrary-db" "fcg-analytics-db")
    
    info "Verificando instâncias RDS..."
    for db_id in "${dbs[@]}"; do
        if db_exists "$db_id"; then
            local status=$(aws rds describe-db-instances \
                --db-instance-identifier "$db_id" \
                --query 'DBInstances[0].DBInstanceStatus' \
                --output text)
            
            local engine=$(aws rds describe-db-instances \
                --db-instance-identifier "$db_id" \
                --query 'DBInstances[0].Engine' \
                --output text)
            
            if [ "$status" = "available" ]; then
                success "✅ $db_id ($engine) - $status"
            else
                warn "⚠️  $db_id ($engine) - $status"
            fi
        else
            error "❌ $db_id não encontrado"
            all_good=false
        fi
    done
    
    # Verificar Redis
    info "Verificando cluster Redis..."
    if redis_exists "fcg-cache-redis"; then
        local status=$(aws elasticache describe-cache-clusters \
            --cache-cluster-id "fcg-cache-redis" \
            --query 'CacheClusters[0].CacheClusterStatus' \
            --output text)
        
        if [ "$status" = "available" ]; then
            success "✅ fcg-cache-redis (Redis) - $status"
        else
            warn "⚠️  fcg-cache-redis (Redis) - $status"
        fi
    else
        error "❌ fcg-cache-redis não encontrado"
        all_good=false
    fi
    
    if [ "$all_good" = true ]; then
        success "🎉 Todos os bancos de dados estão funcionando!"
        
        # Mostrar custos estimados
        echo ""
        info "💰 CUSTOS ESTIMADOS (MENSAIS):"
        info "   RDS t3.micro (4 instâncias): ~$60.00/mês"
        info "   ElastiCache t3.micro: ~$15.00/mês"
        info "   Storage (20GB x 4): ~$8.00/mês"
        info "   ═══════════════════════════════════════"
        info "   TOTAL ESTIMADO: ~$83.00/mês"
        
        return 0
    else
        error "❌ Alguns bancos de dados não estão funcionando"
        return 1
    fi
}

# ============================================================================
# FUNÇÃO PARA MOSTRAR CREDENCIAIS
# ============================================================================

show_credentials() {
    step_header "🔑 CREDENCIAIS DOS BANCOS DE DADOS"
    
    if [ -f .fcg-db-credentials ]; then
        info "Credenciais salvas em .fcg-db-credentials:"
        echo ""
        cat .fcg-db-credentials
        echo ""
        warn "⚠️  IMPORTANTE: Mantenha este arquivo seguro!"
        warn "⚠️  Não commite credenciais no Git!"
    else
        warn "Arquivo de credenciais não encontrado."
        info "Execute --all para criar os bancos primeiro."
    fi
    
    if [ -f .fcg-db-endpoints ]; then
        echo ""
        info "Endpoints atualizados em .fcg-db-endpoints:"
        echo ""
        cat .fcg-db-endpoints
    fi
}

# ============================================================================
# FUNÇÃO PARA GERAR RELATÓRIO
# ============================================================================

generate_db_report() {
    step_header "📄 GERANDO RELATÓRIO DOS BANCOS DE DADOS"
    
    cat > database-report.txt << EOF
🗄️ DATABASE REPORT - FCG APPLICATIONS - $(date)

============================================================================
📋 INFORMAÇÕES GERAIS
============================================================================
   Projeto: $PROJECT_NAME
   Região AWS: $AWS_REGION
   DB Instance Class: $DB_INSTANCE_CLASS
   Redis Node Type: $REDIS_NODE_TYPE

============================================================================
🗄️ BANCOS DE DADOS CRIADOS
============================================================================

1. FCG-PAYMENTS-DB (MySQL 8.0.35)
   Identifier: fcg-payments-db
   Database: fcg_payments
   Port: 3306
   Uso: API de pagamentos
   Storage: 20GB (gp2)
   Backup: 7 dias

2. FCG-USER-API-DB (PostgreSQL 15.4)
   Identifier: fcg-user-api-db
   Database: fcg_users
   Port: 5432
   Uso: API de usuários
   Storage: 20GB (gp2)
   Backup: 7 dias

3. FCG-GAMELIBRARY-DB (MySQL 8.0.35)
   Identifier: fcg-gamelibrary-db
   Database: fcg_games
   Port: 3306
   Uso: Biblioteca de jogos
   Storage: 20GB (gp2)
   Backup: 7 dias

4. FCG-ANALYTICS-DB (PostgreSQL 15.4)
   Identifier: fcg-analytics-db
   Database: fcg_analytics
   Port: 5432
   Uso: Analytics e relatórios
   Storage: 20GB (gp2)
   Backup: 7 dias

5. FCG-CACHE-REDIS (Redis 7.0)
   Cluster ID: fcg-cache-redis
   Port: 6379
   Uso: Cache de aplicações
   Node Type: cache.t3.micro
   Nodes: 1

============================================================================
🔒 CONFIGURAÇÕES DE SEGURANÇA
============================================================================
   ✅ Storage criptografado
   ✅ Acesso apenas interno (VPC)
   ✅ Security Groups configurados
   ✅ Backup automático habilitado
   ✅ Multi-AZ desabilitado (economia)
   ✅ Acesso público desabilitado

============================================================================
🔑 CREDENCIAIS
============================================================================
   Username: $DB_USERNAME
   Passwords: Consulte arquivo .fcg-db-credentials
   Endpoints: Consulte arquivo .fcg-db-endpoints

============================================================================
💰 CUSTOS ESTIMADOS (MENSAIS)
============================================================================
   💸 RDS t3.micro (4 instâncias): ~$60.00/mês
   💸 ElastiCache t3.micro: ~$15.00/mês
   💸 Storage (20GB x 4): ~$8.00/mês
   💸 Backup storage: ~$2.00/mês
   ═══════════════════════════════════════
   💰 TOTAL ESTIMADO: ~$85.00/mês

============================================================================
🔍 COMANDOS DE VERIFICAÇÃO
============================================================================
   # Verificar bancos RDS
   aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus,Engine]'
   
   # Verificar Redis
   aws elasticache describe-cache-clusters --query 'CacheClusters[*].[CacheClusterId,CacheClusterStatus]'
   
   # Verificar com este script
   $0 --verify

============================================================================
🚀 STRINGS DE CONEXÃO (EXEMPLO)
============================================================================
   # MySQL (Payments/Games)
   mysql://fcgadmin:PASSWORD@ENDPOINT:3306/DATABASE_NAME
   
   # PostgreSQL (Users/Analytics)
   postgresql://fcgadmin:PASSWORD@ENDPOINT:5432/DATABASE_NAME
   
   # Redis
   redis://REDIS_ENDPOINT:6379

============================================================================
📞 COMANDOS ÚTEIS
============================================================================
   # Criar todos os bancos
   $0 --all
   
   # Criar banco específico
   $0 --db payments
   
   # Verificar bancos
   $0 --verify
   
   # Mostrar credenciais
   $0 --credentials
   
   # Aguardar criação
   $0 --wait

============================================================================
⚠️ IMPORTANTE
============================================================================
   • Bancos geram custos 24/7 (~$85/mês)
   • Credenciais são geradas automaticamente
   • Backups automáticos por 7 dias
   • Acesso apenas interno da VPC
   • Monitore custos regularmente

Relatório gerado em: $(date)
EOF

    success "✅ Relatório salvo em: database-report.txt"
}

# ============================================================================
# FUNÇÃO DE AJUDA
# ============================================================================

show_help() {
    echo -e "${CYAN}"
    echo "============================================================================"
    echo "🗄️ DATABASE CREATION SCRIPT - FCG APPLICATIONS"
    echo "============================================================================"
    echo -e "${NC}"
    echo ""
    echo "USO:"
    echo "  $0 --all                    # Criar todos os bancos de dados"
    echo "  $0 --db <nome>              # Criar banco específico"
    echo "  $0 --wait                   # Aguardar criação dos bancos"
    echo "  $0 --endpoints              # Atualizar endpoints"
    echo "  $0 --verify                 # Verificar bancos criados"
    echo "  $0 --credentials            # Mostrar credenciais"
    echo "  $0 --report                 # Gerar relatório completo"
    echo "  $0 --help                   # Mostrar esta ajuda"
    echo ""
    echo "BANCOS DISPONÍVEIS:"
    echo "  payments      # fcg-payments-db (MySQL)"
    echo "  userapi       # fcg-user-api-db (PostgreSQL)"
    echo "  gamelibrary   # fcg-gamelibrary-db (MySQL)"
    echo "  analytics     # fcg-analytics-db (PostgreSQL)"
    echo "  redis         # fcg-cache-redis (ElastiCache)"
    echo ""
    echo "EXEMPLOS:"
    echo "  chmod +x $0"
    echo "  ./$0 --all                  # Criar todos"
    echo "  ./$0 --db payments          # Apenas pagamentos"
    echo "  ./$0 --wait                 # Aguardar criação"
    echo "  ./$0 --verify               # Verificar status"
    echo ""
    echo "CONFIGURAÇÕES:"
    echo "  Projeto: $PROJECT_NAME"
    echo "  Região: $AWS_REGION"
    echo "  Instance Class: $DB_INSTANCE_CLASS"
    echo "  Redis Node: $REDIS_NODE_TYPE"
    echo ""
}

# ============================================================================
# CONTROLE PRINCIPAL
# ============================================================================

case "${1:-}" in
    --all)
        info "Criando todos os bancos de dados FCG..."
        
        # Inicializar arquivo de credenciais
        cat > .fcg-db-credentials << EOF
# FCG Database Credentials - $(date)
# ⚠️  MANTENHA ESTE ARQUIVO SEGURO!

EOF
        
        create_db_payments
        create_db_user_api
        create_db_gamelibrary
        create_db_analytics
        create_redis_cache
        
        info "Aguardando criação dos bancos..."
        wait_for_databases
        update_endpoints
        generate_db_report
        
        success "🎉 Todos os bancos de dados criados com sucesso!"
        warn "⚠️  Credenciais salvas em .fcg-db-credentials"
        ;;
    --db)
        if [ -z "$2" ]; then
            error "Especifique o nome do banco (payments, userapi, gamelibrary, analytics, redis)"
        fi
        
        # Inicializar arquivo se não existir
        if [ ! -f .fcg-db-credentials ]; then
            cat > .fcg-db-credentials << EOF
# FCG Database Credentials - $(date)
# ⚠️  MANTENHA ESTE ARQUIVO SEGURO!

EOF
        fi
        
        case "$2" in
            payments) create_db_payments ;;
            userapi) create_db_user_api ;;
            gamelibrary) create_db_gamelibrary ;;
            analytics) create_db_analytics ;;
            redis) create_redis_cache ;;
            *) error "Banco inválido. Use: payments, userapi, gamelibrary, analytics, redis" ;;
        esac
        ;;
    --wait)
        wait_for_databases
        update_endpoints
        ;;
    --endpoints)
        update_endpoints
        ;;
    --verify)
        verify_databases
        ;;
    --credentials)
        show_credentials
        ;;
    --report)
        generate_db_report
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
