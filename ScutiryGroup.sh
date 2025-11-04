#!/bin/bash

# ============================================================================
# 🔒 SECURITY GROUPS CREATION SCRIPT - FCG APPLICATIONS
# ============================================================================
# Autor: Criado com Amazon Q
# Versão: 1.0
# Descrição: Script para criar Security Groups específicos para aplicações FCG
# 
# SECURITY GROUPS A SEREM CRIADOS:
# 1. fcg-payments     - API de pagamentos
# 2. fcg-user-api     - API de usuários  
# 3. fcg-dev          - Ambiente de desenvolvimento
# 4. fcg-gamelibrary  - Biblioteca de jogos
# 5. fcg-db           - Banco de dados
# 
# USO:
# ./create-security-groups.sh --all              # Criar todos os SGs
# ./create-security-groups.sh --sg payments      # Criar SG específico
# ./create-security-groups.sh --verify           # Verificar SGs criados
# ./create-security-groups.sh --list             # Listar SGs existentes
# ============================================================================

set -e

# Configurações
PROJECT_NAME="fcg-eks-user"
AWS_REGION="us-east-1"

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
# FUNÇÃO PARA OBTER VPC ID
# ============================================================================

get_vpc_id() {
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
        error "Nenhuma VPC encontrada. Crie uma VPC primeiro ou execute o script EKS."
    fi
    
    echo $vpc_id
}

# ============================================================================
# FUNÇÃO PARA VERIFICAR SE SECURITY GROUP EXISTE
# ============================================================================

sg_exists() {
    local sg_name=$1
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null | grep -v "None" &>/dev/null
}

# ============================================================================
# FUNÇÃO PARA CRIAR SECURITY GROUP BASE
# ============================================================================

create_base_sg() {
    local sg_name=$1
    local description=$2
    local vpc_id=$3
    
    if sg_exists "$sg_name"; then
        warn "Security Group '$sg_name' já existe. Pulando criação."
        local existing_sg_id=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=$sg_name" \
            --query 'SecurityGroups[0].GroupId' \
            --output text)
        echo $existing_sg_id
        return 0
    fi
    
    info "Criando Security Group: $sg_name"
    local sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "$description" \
        --vpc-id "$vpc_id" \
        --query 'GroupId' \
        --output text)
    
    # Adicionar tags
    aws ec2 create-tags \
        --resources "$sg_id" \
        --tags Key=Name,Value="$sg_name" Key=Project,Value="$PROJECT_NAME"
    
    success "✅ Security Group criado: $sg_name ($sg_id)"
    echo $sg_id
}

# ============================================================================
# 1. SECURITY GROUP: FCG-PAYMENTS (API DE PAGAMENTOS)
# ============================================================================

create_sg_payments() {
    step_header "💳 CRIANDO SECURITY GROUP: FCG-PAYMENTS"
    
    local vpc_id=$(get_vpc_id)
    local sg_id=$(create_base_sg "fcg-payments" "Security Group para API de Pagamentos FCG" "$vpc_id")
    
    info "Configurando regras para fcg-payments..."
    
    # INBOUND RULES
    # HTTPS (443) - Para API externa
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTPS-External},{Key=Purpose,Value=API-Access}]' \
        2>/dev/null || warn "Regra HTTPS já pode existir"
    
    # HTTP (80) - Para redirecionamento
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTP-Redirect},{Key=Purpose,Value=Redirect-to-HTTPS}]' \
        2>/dev/null || warn "Regra HTTP já pode existir"
    
    # Porta customizada para aplicação (8080)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 8080 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=App-Internal},{Key=Purpose,Value=Internal-Communication}]' \
        2>/dev/null || warn "Regra porta 8080 já pode existir"
    
    # SSH (22) - Apenas da VPC interna
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=SSH-Internal},{Key=Purpose,Value=Management}]' \
        2>/dev/null || warn "Regra SSH já pode existir"
    
    success "✅ Security Group fcg-payments configurado com sucesso!"
    info "   ID: $sg_id"
    info "   Portas: 443 (HTTPS), 80 (HTTP), 8080 (App), 22 (SSH)"
}

# ============================================================================
# 2. SECURITY GROUP: FCG-USER-API (API DE USUÁRIOS)
# ============================================================================

create_sg_user_api() {
    step_header "👥 CRIANDO SECURITY GROUP: FCG-USER-API"
    
    local vpc_id=$(get_vpc_id)
    local sg_id=$(create_base_sg "fcg-user-api" "Security Group para API de Usuários FCG" "$vpc_id")
    
    info "Configurando regras para fcg-user-api..."
    
    # INBOUND RULES
    # HTTPS (443) - Para API externa
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTPS-External},{Key=Purpose,Value=API-Access}]' \
        2>/dev/null || warn "Regra HTTPS já pode existir"
    
    # HTTP (80) - Para redirecionamento
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTP-Redirect},{Key=Purpose,Value=Redirect-to-HTTPS}]' \
        2>/dev/null || warn "Regra HTTP já pode existir"
    
    # Porta customizada para aplicação (3000)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3000 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=App-Internal},{Key=Purpose,Value=Internal-Communication}]' \
        2>/dev/null || warn "Regra porta 3000 já pode existir"
    
    # SSH (22) - Apenas da VPC interna
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=SSH-Internal},{Key=Purpose,Value=Management}]' \
        2>/dev/null || warn "Regra SSH já pode existir"
    
    success "✅ Security Group fcg-user-api configurado com sucesso!"
    info "   ID: $sg_id"
    info "   Portas: 443 (HTTPS), 80 (HTTP), 3000 (App), 22 (SSH)"
}

# ============================================================================
# 3. SECURITY GROUP: FCG-DEV (AMBIENTE DE DESENVOLVIMENTO)
# ============================================================================

create_sg_dev() {
    step_header "🛠️ CRIANDO SECURITY GROUP: FCG-DEV"
    
    local vpc_id=$(get_vpc_id)
    local sg_id=$(create_base_sg "fcg-dev" "Security Group para Ambiente de Desenvolvimento FCG" "$vpc_id")
    
    info "Configurando regras para fcg-dev..."
    
    # INBOUND RULES - Mais permissivo para desenvolvimento
    # HTTP (80)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTP-Dev},{Key=Purpose,Value=Development-Access}]' \
        2>/dev/null || warn "Regra HTTP já pode existir"
    
    # HTTPS (443)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTPS-Dev},{Key=Purpose,Value=Development-Access}]' \
        2>/dev/null || warn "Regra HTTPS já pode existir"
    
    # Portas de desenvolvimento comuns
    # Node.js (3000)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3000 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=NodeJS-Dev},{Key=Purpose,Value=Development}]' \
        2>/dev/null || warn "Regra porta 3000 já pode existir"
    
    # React Dev Server (3001)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3001 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=React-Dev},{Key=Purpose,Value=Development}]' \
        2>/dev/null || warn "Regra porta 3001 já pode existir"
    
    # Spring Boot (8080)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 8080 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=SpringBoot-Dev},{Key=Purpose,Value=Development}]' \
        2>/dev/null || warn "Regra porta 8080 já pode existir"
    
    # SSH (22)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=SSH-Dev},{Key=Purpose,Value=Development-Management}]' \
        2>/dev/null || warn "Regra SSH já pode existir"
    
    success "✅ Security Group fcg-dev configurado com sucesso!"
    info "   ID: $sg_id"
    info "   Portas: 80, 443, 3000, 3001, 8080, 22"
    warn "   ⚠️  Este SG é mais permissivo - apenas para desenvolvimento!"
}

# ============================================================================
# 4. SECURITY GROUP: FCG-GAMELIBRARY (BIBLIOTECA DE JOGOS)
# ============================================================================

create_sg_gamelibrary() {
    step_header "🎮 CRIANDO SECURITY GROUP: FCG-GAMELIBRARY"
    
    local vpc_id=$(get_vpc_id)
    local sg_id=$(create_base_sg "fcg-gamelibrary" "Security Group para Biblioteca de Jogos FCG" "$vpc_id")
    
    info "Configurando regras para fcg-gamelibrary..."
    
    # INBOUND RULES
    # HTTPS (443) - Para API externa
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 443 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTPS-External},{Key=Purpose,Value=API-Access}]' \
        2>/dev/null || warn "Regra HTTPS já pode existir"
    
    # HTTP (80) - Para redirecionamento
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=HTTP-Redirect},{Key=Purpose,Value=Redirect-to-HTTPS}]' \
        2>/dev/null || warn "Regra HTTP já pode existir"
    
    # Porta customizada para aplicação (4000)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 4000 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=App-Internal},{Key=Purpose,Value=Internal-Communication}]' \
        2>/dev/null || warn "Regra porta 4000 já pode existir"
    
    # WebSocket para jogos em tempo real (8081)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 8081 \
        --cidr 0.0.0.0/0 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=WebSocket-Games},{Key=Purpose,Value=Real-time-Gaming}]' \
        2>/dev/null || warn "Regra WebSocket já pode existir"
    
    # SSH (22) - Apenas da VPC interna
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=SSH-Internal},{Key=Purpose,Value=Management}]' \
        2>/dev/null || warn "Regra SSH já pode existir"
    
    success "✅ Security Group fcg-gamelibrary configurado com sucesso!"
    info "   ID: $sg_id"
    info "   Portas: 443 (HTTPS), 80 (HTTP), 4000 (App), 8081 (WebSocket), 22 (SSH)"
}

# ============================================================================
# 5. SECURITY GROUP: FCG-DB (BANCO DE DADOS)
# ============================================================================

create_sg_db() {
    step_header "🗄️ CRIANDO SECURITY GROUP: FCG-DB"
    
    local vpc_id=$(get_vpc_id)
    local sg_id=$(create_base_sg "fcg-db" "Security Group para Banco de Dados FCG" "$vpc_id")
    
    info "Configurando regras para fcg-db..."
    
    # INBOUND RULES - Apenas tráfego interno da VPC
    # MySQL/Aurora (3306)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 3306 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=MySQL-Internal},{Key=Purpose,Value=Database-Access}]' \
        2>/dev/null || warn "Regra MySQL já pode existir"
    
    # PostgreSQL (5432)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 5432 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=PostgreSQL-Internal},{Key=Purpose,Value=Database-Access}]' \
        2>/dev/null || warn "Regra PostgreSQL já pode existir"
    
    # Redis (6379)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 6379 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=Redis-Internal},{Key=Purpose,Value=Cache-Access}]' \
        2>/dev/null || warn "Regra Redis já pode existir"
    
    # MongoDB (27017)
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 27017 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=MongoDB-Internal},{Key=Purpose,Value=Database-Access}]' \
        2>/dev/null || warn "Regra MongoDB já pode existir"
    
    # SSH (22) - Apenas da VPC interna para manutenção
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 10.0.0.0/16 \
        --tag-specifications 'ResourceType=security-group-rule,Tags=[{Key=Name,Value=SSH-Internal},{Key=Purpose,Value=Database-Management}]' \
        2>/dev/null || warn "Regra SSH já pode existir"
    
    success "✅ Security Group fcg-db configurado com sucesso!"
    info "   ID: $sg_id"
    info "   Portas: 3306 (MySQL), 5432 (PostgreSQL), 6379 (Redis), 27017 (MongoDB), 22 (SSH)"
    warn "   🔒 Todas as regras são apenas para tráfego interno da VPC (10.0.0.0/16)"
}

# ============================================================================
# FUNÇÃO PARA VERIFICAR SECURITY GROUPS CRIADOS
# ============================================================================

verify_security_groups() {
    step_header "🔍 VERIFICANDO SECURITY GROUPS CRIADOS"
    
    local sgs=("fcg-payments" "fcg-user-api" "fcg-dev" "fcg-gamelibrary" "fcg-db")
    local all_good=true
    
    for sg_name in "${sgs[@]}"; do
        if sg_exists "$sg_name"; then
            local sg_id=$(aws ec2 describe-security-groups \
                --filters "Name=group-name,Values=$sg_name" \
                --query 'SecurityGroups[0].GroupId' \
                --output text)
            
            local rule_count=$(aws ec2 describe-security-groups \
                --group-ids "$sg_id" \
                --query 'SecurityGroups[0].IpPermissions | length(@)' \
                --output text)
            
            success "✅ $sg_name existe (ID: $sg_id, Regras: $rule_count)"
        else
            error "❌ $sg_name NÃO existe"
            all_good=false
        fi
    done
    
    if [ "$all_good" = true ]; then
        success "🎉 Todos os Security Groups estão criados e configurados!"
    else
        error "❌ Alguns Security Groups estão faltando"
    fi
}

# ============================================================================
# FUNÇÃO PARA LISTAR SECURITY GROUPS
# ============================================================================

list_security_groups() {
    step_header "📋 LISTANDO SECURITY GROUPS FCG"
    
    info "Security Groups do projeto FCG:"
    aws ec2 describe-security-groups \
        --filters "Name=tag:Project,Values=$PROJECT_NAME" \
        --query 'SecurityGroups[*].[GroupName,GroupId,Description]' \
        --output table
    
    echo ""
    info "Todos os Security Groups na VPC:"
    local vpc_id=$(get_vpc_id)
    aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --query 'SecurityGroups[*].[GroupName,GroupId,Description]' \
        --output table
}

# ============================================================================
# FUNÇÃO PARA GERAR RELATÓRIO DOS SECURITY GROUPS
# ============================================================================

generate_sg_report() {
    step_header "📄 GERANDO RELATÓRIO DOS SECURITY GROUPS"
    
    local vpc_id=$(get_vpc_id)
    
    cat > security-groups-report.txt << EOF
🔒 SECURITY GROUPS REPORT - FCG APPLICATIONS - $(date)

============================================================================
📋 INFORMAÇÕES GERAIS
============================================================================
   Projeto: $PROJECT_NAME
   Região AWS: $AWS_REGION
   VPC ID: $vpc_id

============================================================================
🔒 SECURITY GROUPS CRIADOS
============================================================================

1. FCG-PAYMENTS (API de Pagamentos)
   Nome: fcg-payments
   Portas Abertas:
   - 443 (HTTPS) - Externa (0.0.0.0/0)
   - 80 (HTTP) - Externa (0.0.0.0/0) 
   - 8080 (App) - Interna (10.0.0.0/16)
   - 22 (SSH) - Interna (10.0.0.0/16)

2. FCG-USER-API (API de Usuários)
   Nome: fcg-user-api
   Portas Abertas:
   - 443 (HTTPS) - Externa (0.0.0.0/0)
   - 80 (HTTP) - Externa (0.0.0.0/0)
   - 3000 (App) - Interna (10.0.0.0/16)
   - 22 (SSH) - Interna (10.0.0.0/16)

3. FCG-DEV (Ambiente de Desenvolvimento)
   Nome: fcg-dev
   Portas Abertas:
   - 443 (HTTPS) - Externa (0.0.0.0/0)
   - 80 (HTTP) - Externa (0.0.0.0/0)
   - 3000 (Node.js) - Externa (0.0.0.0/0)
   - 3001 (React) - Externa (0.0.0.0/0)
   - 8080 (Spring Boot) - Externa (0.0.0.0/0)
   - 22 (SSH) - Externa (0.0.0.0/0)
   ⚠️  ATENÇÃO: Mais permissivo para desenvolvimento

4. FCG-GAMELIBRARY (Biblioteca de Jogos)
   Nome: fcg-gamelibrary
   Portas Abertas:
   - 443 (HTTPS) - Externa (0.0.0.0/0)
   - 80 (HTTP) - Externa (0.0.0.0/0)
   - 4000 (App) - Interna (10.0.0.0/16)
   - 8081 (WebSocket) - Externa (0.0.0.0/0)
   - 22 (SSH) - Interna (10.0.0.0/16)

5. FCG-DB (Banco de Dados)
   Nome: fcg-db
   Portas Abertas:
   - 3306 (MySQL) - Interna (10.0.0.0/16)
   - 5432 (PostgreSQL) - Interna (10.0.0.0/16)
   - 6379 (Redis) - Interna (10.0.0.0/16)
   - 27017 (MongoDB) - Interna (10.0.0.0/16)
   - 22 (SSH) - Interna (10.0.0.0/16)
   🔒 SEGURO: Apenas tráfego interno

============================================================================
🔍 COMANDOS DE VERIFICAÇÃO
============================================================================
   # Listar todos os SGs
   aws ec2 describe-security-groups --filters "Name=tag:Project,Values=$PROJECT_NAME"
   
   # Verificar regras de um SG específico
   aws ec2 describe-security-groups --group-names fcg-payments
   
   # Verificar com este script
   $0 --verify

============================================================================
⚠️ RECOMENDAÇÕES DE SEGURANÇA
============================================================================
   1. 🔒 Revisar regularmente as regras dos SGs
   2. 🔍 Monitorar tráfego de rede
   3. 🚫 Evitar 0.0.0.0/0 em produção quando possível
   4. 🔐 Usar VPN ou bastion host para SSH
   5. 📊 Implementar logging de rede
   6. 🔄 Rotacionar credenciais regularmente

============================================================================
📞 COMANDOS ÚTEIS
============================================================================
   # Criar todos os SGs
   $0 --all
   
   # Criar SG específico
   $0 --sg payments
   
   # Verificar SGs
   $0 --verify
   
   # Listar SGs
   $0 --list

Relatório gerado em: $(date)
EOF

    success "✅ Relatório salvo em: security-groups-report.txt"
}

# ============================================================================
# FUNÇÃO DE AJUDA
# ============================================================================

show_help() {
    echo -e "${CYAN}"
    echo "============================================================================"
    echo "🔒 SECURITY GROUPS CREATION SCRIPT - FCG APPLICATIONS"
    echo "============================================================================"
    echo -e "${NC}"
    echo ""
    echo "USO:"
    echo "  $0 --all                    # Criar todos os Security Groups"
    echo "  $0 --sg <nome>              # Criar Security Group específico"
    echo "  $0 --verify                 # Verificar SGs criados"
    echo "  $0 --list                   # Listar SGs existentes"
    echo "  $0 --report                 # Gerar relatório completo"
    echo "  $0 --help                   # Mostrar esta ajuda"
    echo ""
    echo "SECURITY GROUPS DISPONÍVEIS:"
    echo "  payments      # fcg-payments (API de Pagamentos)"
    echo "  userapi       # fcg-user-api (API de Usuários)"
    echo "  dev           # fcg-dev (Ambiente de Desenvolvimento)"
    echo "  gamelibrary   # fcg-gamelibrary (Biblioteca de Jogos)"
    echo "  db            # fcg-db (Banco de Dados)"
    echo ""
    echo "EXEMPLOS:"
    echo "  chmod +x $0"
    echo "  ./$0 --all                  # Criar todos"
    echo "  ./$0 --sg payments          # Apenas pagamentos"
    echo "  ./$0 --sg db                # Apenas banco de dados"
    echo "  ./$0 --verify               # Verificar criação"
    echo ""
    echo "CONFIGURAÇÕES:"
    echo "  Projeto: $PROJECT_NAME"
    echo "  Região: $AWS_REGION"
    echo ""
}

# ============================================================================
# CONTROLE PRINCIPAL
# ============================================================================

case "${1:-}" in
    --all)
        info "Criando todos os Security Groups FCG..."
        create_sg_payments
        create_sg_user_api
        create_sg_dev
        create_sg_gamelibrary
        create_sg_db
        generate_sg_report
        success "🎉 Todos os Security Groups criados com sucesso!"
        ;;
    --sg)
        if [ -z "$2" ]; then
            error "Especifique o nome do Security Group (payments, userapi, dev, gamelibrary, db)"
        fi
        
        case "$2" in
            payments) create_sg_payments ;;
            userapi) create_sg_user_api ;;
            dev) create_sg_dev ;;
            gamelibrary) create_sg_gamelibrary ;;
            db) create_sg_db ;;
            *) error "Security Group inválido. Use: payments, userapi, dev, gamelibrary, db" ;;
        esac
        ;;
    --verify)
        verify_security_groups
        ;;
    --list)
        list_security_groups
        ;;
    --report)
        generate_sg_report
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
