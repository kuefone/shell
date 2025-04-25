#!/bin/bash

# === 颜色定义 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

# 需要测试的域名列表
DOMAINS=("www.google.com" "www.gstatic.com" "cp.cloudflare.com")

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：${RESET}此脚本需要root权限运行。"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}检查并安装依赖...${RESET}"
    if ! command -v ping &> /dev/null; then
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update
            apt-get install -y iputils-ping
        elif [ -x "$(command -v yum)" ]; then
            yum install -y iputils
        else
            echo -e "${RED}错误：${RESET}无法安装ping工具，请手动安装后重试。"
            exit 1
        fi
    fi
    echo -e "${GREEN}依赖检查完成。${RESET}"
}

# 解析域名获取IP列表
get_ips_for_domain() {
    local domain=$1
    echo -e "${BLUE}正在解析域名 ${domain}...${RESET}"
    
    # 使用dig或nslookup获取IP列表
    if command -v dig &> /dev/null; then
        dig +short $domain | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    elif command -v nslookup &> /dev/null; then
        nslookup $domain | grep -E '^Address: ' | tail -n +2 | awk '{print $2}'
    else
        # 如果没有dig和nslookup，使用host命令
        host $domain | grep "has address" | awk '{print $4}'
    fi
}

# 测试IP延迟
test_ip_latency() {
    local ip=$1
    local count=5
    local result
    
    echo -e "测试 ${ip} 的延迟..."
    
    # 执行ping测试，提取平均延迟
    result=$(ping -c $count $ip 2>/dev/null | grep "avg" | awk -F'/' '{print $5}')
    
    if [[ -z "$result" ]]; then
        echo "999" # 如果ping失败，返回一个很大的值
    else
        echo "$result"
    fi
}

# 主函数
optimize_hosts() {
    check_root
    install_dependencies
    
    echo -e "${GREEN}开始优化hosts文件...${RESET}"
    
    # 创建临时hosts文件
    TEMP_HOSTS=$(mktemp)
    
    # 复制原hosts文件内容，但移除我们将要添加的域名
    grep -v -E "$(echo "${DOMAINS[@]}" | tr ' ' '|')" /etc/hosts > $TEMP_HOSTS
    
    # 为每个域名找到最佳IP
    for domain in "${DOMAINS[@]}"; do
        echo -e "\n${YELLOW}处理域名: ${domain}${RESET}"
        
        best_ip=""
        min_latency=999
        
        # 获取域名的所有IP
        ips=($(get_ips_for_domain $domain))
        
        if [[ ${#ips[@]} -eq 0 ]]; then
            echo -e "${RED}无法解析域名 ${domain}，跳过。${RESET}"
            continue
        fi
        
        echo -e "找到 ${#ips[@]} 个IP地址，开始测试延迟..."
        
        # 测试每个IP
        for ip in "${ips[@]}"; do
            latency=$(test_ip_latency $ip)
            echo -e "IP: ${ip}, 延迟: ${latency}ms"
            
            # 如果延迟小于5ms，立即选择此IP
            if (( $(echo "$latency < 5" | bc -l) )); then
                best_ip=$ip
                min_latency=$latency
                echo -e "${GREEN}找到延迟小于5ms的IP: ${best_ip} (${min_latency}ms)，选择此IP。${RESET}"
                break
            fi
            
            # 否则记录最小延迟的IP
            if (( $(echo "$latency < $min_latency" | bc -l) )); then
                best_ip=$ip
                min_latency=$latency
            fi
        done
        
        if [[ -n "$best_ip" ]]; then
            echo -e "${GREEN}为 ${domain} 选择的最佳IP: ${best_ip} (${min_latency}ms)${RESET}"
            echo "$best_ip $domain" >> $TEMP_HOSTS
        else
            echo -e "${RED}无法为 ${domain} 找到可用IP。${RESET}"
        fi
    done
    
    # 更新hosts文件
    cp $TEMP_HOSTS /etc/hosts
    rm $TEMP_HOSTS
    
    echo -e "\n${GREEN}hosts文件优化完成！${RESET}"
    echo -e "当前hosts文件内容:"
    grep -E "$(echo "${DOMAINS[@]}" | tr ' ' '|')" /etc/hosts
}

# 设置定时任务
setup_cron() {
    # 检查是否已存在相同的cron任务
    if ! crontab -l 2>/dev/null | grep -q "optimiziHosts.sh"; then
        # 创建临时cron文件
        TEMP_CRON=$(mktemp)
        
        # 获取当前crontab内容
        crontab -l 2>/dev/null > $TEMP_CRON
        
        # 添加新的cron任务 - 每3天执行一次
        echo "0 0 */3 * * $(readlink -f $0) > /var/log/optimize_hosts.log 2>&1" >> $TEMP_CRON
        
        # 更新crontab
        crontab $TEMP_CRON
        rm $TEMP_CRON
        
        echo -e "${GREEN}已设置定时任务，脚本将每3天自动执行一次。${RESET}"
    else
        echo -e "${YELLOW}定时任务已存在，无需重复设置。${RESET}"
    fi
}

# 如果脚本直接执行（非通过cron调用）
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo -e "${BLUE}=== 开始执行hosts优化脚本 ===${RESET}"
    echo -e "时间: $(date)"
    
    optimize_hosts
    setup_cron
    
    echo -e "${BLUE}=== 脚本执行完毕 ===${RESET}"
fi
