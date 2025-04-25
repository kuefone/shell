#!/bin/bash

# --- Configuration ---
DOMAINS_LIST="www.gstatic.com,cp.cloudflare.com,www.google.com"
MAX_TRIES=5
LATENCY_THRESHOLD_MS=5.0
PING_TIMEOUT=1 # seconds
HOSTS_MARKER_BEGIN="# BEGIN MANAGED HOSTS BY SCRIPT"
HOSTS_MARKER_END="# END MANAGED HOSTS BY SCRIPT"

# --- Function: Check and Install Dependencies ---
check_and_install() {
    local cmd="$1"
    local pkg="$2"
    # Suppress stdout/stderr for command check unless debugging
    if ! command -v "$cmd" &> /dev/null; then
        echo "命令 '$cmd' 未找到。正在尝试安装 '$pkg'..."
        # Run apt-get update and install quietly
        if ! apt-get update -qq; then
             echo "错误: apt-get update 失败。"
             exit 1
        fi
        if ! apt-get install -y -qq "$pkg"; then
             echo "错误: 无法安装 '$pkg'。"
             exit 1
        fi
        # Verify installation
        if ! command -v "$cmd" &> /dev/null; then
            echo "错误: 安装 '$pkg' 后仍然找不到 '$cmd'。"
            exit 1
        fi
        echo "'$pkg' 安装成功。"
    fi
}

# --- Script Main ---

# 1. Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
   echo "错误: 请以 root 身份运行此脚本。"
   exit 1
fi

# 2. Check and install dependencies
echo "检查必要的工具..."
check_and_install "dig" "dnsutils"
check_and_install "ping" "iputils-ping"
check_and_install "awk" "gawk"
check_and_install "sed" "sed" # Typically built-in, but check
check_and_install "grep" "grep" # Typically built-in
check_and_install "head" "coreutils" # Typically built-in
check_and_install "tail" "coreutils" # Typically built-in
check_and_install "cut" "coreutils" # Typically built-in
check_and_install "mktemp" "coreutils" # Typically built-in
echo "所有必要的工具都已存在或已安装。"


# 3. Process Domains
echo "开始解析和测试域名..."
IFS=',' read -r -a DOMAINS <<< "$DOMAINS_LIST"
declare -A final_hosts

for domain in "${DOMAINS[@]}"; do
    echo "处理: $domain"
    best_ip=""
    min_latency=999999.0
    found_fast_ip=false

    for (( i=1; i<=$MAX_TRIES; i++ )); do
        # Use dig +short +tries=1 +time=1 for quicker attempts? No, let OS handle retries for now.
        current_ip=$(dig +short A "$domain" | head -n 1)

        if [ -z "$current_ip" ]; then
            sleep 0.5
            continue
        fi

        # Filter out non-IP addresses (like CNAME responses sometimes sneaking in)
        if ! [[ "$current_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
             sleep 0.1 # Maybe it was a CNAME, give it a moment? Unlikely necessary.
             continue
        fi

        ping_data=$(LANG=C ping -c 1 -W $PING_TIMEOUT "$current_ip" 2>/dev/null) # Suppress stderr "unknown host" if IP invalid
        exit_code=$?

        if [ $exit_code -ne 0 ]; then
             current_latency=999998.0
        else
            current_latency=$(echo "$ping_data" | awk -F'/' 'END{ if (NF>=7) print $5; else print 999997.0 }')
            if ! [[ "$current_latency" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                current_latency=999996.0
            fi

            is_below_threshold=$(awk -v lat="$current_latency" -v threshold="$LATENCY_THRESHOLD_MS" 'BEGIN { exit (lat <= threshold) ? 0 : 1 }')
            if [ $? -eq 0 ]; then
                best_ip=$current_ip
                found_fast_ip=true
                break
            fi
        fi

        is_lower=$(awk -v cur="$current_latency" -v min="$min_latency" 'BEGIN { exit (cur < min) ? 0 : 1 }')
        if [ $? -eq 0 ]; then
            min_latency=$current_latency
            best_ip=$current_ip
        fi
        sleep 0.2
    done

    if [ -n "$best_ip" ]; then
        final_hosts[$domain]=$best_ip
        echo "  选择 IP: $best_ip for $domain"
    else
        echo "  警告: 未能为 $domain 找到有效的 IP。跳过。"
    fi
done

# 4. Update /etc/hosts file
if [ ${#final_hosts[@]} -eq 0 ]; then
    echo "没有有效的域名/IP对可供更新。退出。"
    exit 0
fi

echo "准备更新 /etc/hosts 文件..."
temp_hosts_file=$(mktemp)
if [ -z "$temp_hosts_file" ]; then
    echo "错误: 无法创建临时文件。"
    exit 1
fi
# Ensure temp file is cleaned up on exit, error or interrupt
trap 'rm -f "$temp_hosts_file" "$new_block_file"' EXIT HUP INT QUIT TERM

# Prepare the new block of hosts entries
new_block=""
for domain in "${!final_hosts[@]}"; do
    ip=${final_hosts[$domain]}
    # Ensure we don't add empty lines if ip or domain is somehow empty
    if [ -n "$ip" ] && [ -n "$domain" ]; then
        new_block+="${ip} ${domain}\n"
    fi
done
# 确保每个条目后有换行符，包括最后一个条目
new_block=$(echo -e "${new_block}")

# Check if both markers exist using grep -Fx for exact whole line match
begin_marker_present=$(grep -Fx "$HOSTS_MARKER_BEGIN" /etc/hosts)
end_marker_present=$(grep -Fx "$HOSTS_MARKER_END" /etc/hosts)

if [ -n "$begin_marker_present" ] && [ -n "$end_marker_present" ]; then
    echo "找到现有标记，将替换标记之间的内容。"

    # Get line numbers reliably, take the first match if markers somehow duplicated
    begin_line=$(grep -nxF "$HOSTS_MARKER_BEGIN" /etc/hosts | head -n 1 | cut -d: -f1)
    end_line=$(grep -nxF "$HOSTS_MARKER_END" /etc/hosts | head -n 1 | cut -d: -f1)

    # Validate line numbers
    if [[ "$begin_line" =~ ^[0-9]+$ ]] && [[ "$end_line" =~ ^[0-9]+$ ]] && [ "$end_line" -gt "$begin_line" ]; then
        # Create a temporary file containing the new block content
        new_block_file=$(mktemp)
        trap 'rm -f "$temp_hosts_file" "$new_block_file"' EXIT HUP INT QUIT TERM # Update trap
        echo -e "$new_block" > "$new_block_file"

        # Use sed: delete lines between markers, then read new block after begin marker
        # SED Script:
        # 1. On the line AFTER begin_line up to the line BEFORE end_line: Delete (d)
        # 2. On the begin_line: execute 'r new_block_file' (r appends content read from file AFTER the current line)
        sed -e "$((begin_line + 1)),$((end_line - 1))d" \
            -e "${begin_line}r ${new_block_file}" \
            /etc/hosts > "$temp_hosts_file"

        if [ $? -ne 0 ]; then
             echo "错误: sed 命令在处理标记时失败。"
             # temp files cleaned by trap
             exit 1
        fi
        # No longer need the block file
        rm -f "$new_block_file"
        trap 'rm -f "$temp_hosts_file"' EXIT HUP INT QUIT TERM # Update trap again

    else
        echo "错误: 标记行号无效或顺序错误。将在文件末尾附加新块以防万一。"
        # Fallback to appending method
        cp /etc/hosts "$temp_hosts_file" || { echo "错误: 无法复制 /etc/hosts"; exit 1; }
        # Add a newline if the file doesn't end with one
        [[ $(tail -c1 "$temp_hosts_file" | wc -l) -eq 0 ]] && echo "" >> "$temp_hosts_file"
        echo "$HOSTS_MARKER_BEGIN" >> "$temp_hosts_file"
        echo -e "$new_block" >> "$temp_hosts_file"
        echo "$HOSTS_MARKER_END" >> "$temp_hosts_file"
    fi
else
    echo "未找到标记或标记不完整。将在文件末尾附加新块。"
    # Append new block
    cp /etc/hosts "$temp_hosts_file" || { echo "错误: 无法复制 /etc/hosts"; exit 1; }
    # Add a newline if the file doesn't end with one
    [[ $(tail -c1 "$temp_hosts_file" | wc -l) -eq 0 ]] && echo "" >> "$temp_hosts_file"
    echo "$HOSTS_MARKER_BEGIN" >> "$temp_hosts_file"
    echo -e "$new_block" >> "$temp_hosts_file"
    echo "$HOSTS_MARKER_END" >> "$temp_hosts_file"
fi

# 5. Replace original hosts file (NO BACKUP)
echo "直接用新内容覆盖 /etc/hosts (无备份)..."
# Use cat and redirect instead of mv to preserve original permissions/owner more reliably sometimes
if cat "$temp_hosts_file" > /etc/hosts; then
    # No chmod needed if cat preserves original permissions/owner
    # chmod 644 /etc/hosts # Keep if cat doesn't preserve permissions as expected
    echo "/etc/hosts 文件更新成功。"
else
    echo "错误: 更新 /etc/hosts 文件失败！原始文件可能已损坏。"
    # temp file cleaned by trap
    exit 1
fi

# Clean exit, trap will remove temp file
echo "脚本执行完毕。"
exit 0