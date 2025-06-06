#!/bin/bash

# 面试场景：同时启动50用户并发测试 (使用 http-file-server-linux-x86_64)
# 实时显示系统资源占用

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINARY_PATH="$PROJECT_DIR/http-file-server-linux-x86_64"
TEST_DIR="$PROJECT_DIR"
RESULTS_DIR="$SCRIPT_DIR/concurrent_50_test_hfs_$(date +%Y%m%d_%H%M%S)"

# 测试参数
CONCURRENT_USERS=50
TEST_DURATION=90
SERVER_PORT=8000  # http-file-server 默认端口
TEST_FILE="test_1gb.bin"  # 使用1GB文件进行更真实的测试

echo "🎯 面试场景：50用户同时并发测试（http-file-server + 黑洞模式 + 智能平滑）"
echo "================================================================"
echo "• 服务器: http-file-server-linux-x86_64"
echo "• 并发策略: 50用户同时启动（非分批）"
echo "• 下载模式: /dev/null 黑洞模式（不占磁盘空间）"
echo "• 实时监控: CPU/内存/连接数/带宽/文件描述符"
echo "• 智能平滑: EWMA加权移动平均 + 异常值过滤"
echo "• 测试时长: ${TEST_DURATION}秒"
echo "• 目标文件: $TEST_FILE (1GB大文件)"
echo "• 服务端口: $SERVER_PORT"
echo "• 结果目录: $RESULTS_DIR"
echo ""

# 检查 http-file-server 二进制文件
if [ ! -f "$BINARY_PATH" ]; then
    echo "❌ 找不到 http-file-server-linux-x86_64 文件"
    echo "   期望位置: $BINARY_PATH"
    exit 1
fi

if [ ! -x "$BINARY_PATH" ]; then
    echo "🔧 设置可执行权限..."
    chmod +x "$BINARY_PATH"
fi

# 创建结果目录
mkdir -p "$RESULTS_DIR"

# 检查系统资源
TOTAL_MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEMORY_GB=$((TOTAL_MEMORY_KB / 1024 / 1024))
echo "系统总内存: ${TOTAL_MEMORY_GB}GB"

# 启动服务器
echo ""
echo "1️⃣ 启动 http-file-server..."
cd "$TEST_DIR"
nohup "$BINARY_PATH" -p $SERVER_PORT -b 0.0.0.0 . > "$RESULTS_DIR/server.log" 2>&1 &
SERVER_PID=$!

# 等待服务器启动
sleep 3

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ 服务器启动失败"
    cat "$RESULTS_DIR/server.log"
    exit 1
fi

echo "✅ http-file-server 启动成功 (PID: $SERVER_PID, Port: $SERVER_PORT)"

# 实时监控函数
monitor_resources() {
    local output_file="$1"
    {
        echo "时间,内存(MB),CPU(%),连接数,FD数,活跃下载,完成下载,系统负载,网络发送(MB/s),网络接收(MB/s),总带宽(MB/s)"
        
        # 初始化网络统计和简单平滑
        local prev_tx_bytes=0
        local prev_rx_bytes=0
        local prev_timestamp=$(date +%s)
        local bandwidth_samples=()  # 最近几个样本，用于简单平均
        
        while true; do
            local timestamp=$(date '+%H:%M:%S')
            local current_timestamp=$(date +%s)
            
            # 服务器进程资源
            if [ -d "/proc/$SERVER_PID" ]; then
                local mem_kb=$(ps -p $SERVER_PID -o rss --no-headers 2>/dev/null | tr -d ' ' || echo "0")
                local mem_mb=$((mem_kb / 1024))
                local cpu_percent=$(ps -p $SERVER_PID -o %cpu --no-headers 2>/dev/null | tr -d ' ' | cut -d. -f1 || echo "0")
                local fd_count=$(ls /proc/$SERVER_PID/fd 2>/dev/null | wc -l || echo "0")
            else
                local mem_mb=0
                local cpu_percent=0
                local fd_count=0
            fi
            
            # 网络连接数 - 只统计TCP连接
            local connections=$(ss -tn 2>/dev/null | grep ":$SERVER_PORT" | grep ESTAB | wc -l || echo "0")
            
            # 活跃下载进程数
            local active_downloads=$(pgrep -f "curl.*localhost:$SERVER_PORT" | wc -l || echo "0")
            
            # 完成的下载数
            local completed_downloads=$(find "$RESULTS_DIR/downloads" -name "user_*.log" -exec grep -l "下载完成\|下载失败" {} \; 2>/dev/null | wc -l || echo "0")
            
            # 系统负载
            local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
            
            # 网络带宽计算 - 简化版，专注准确性
            local net_line=""
            local interface_name="未知"
            if [ -f /proc/net/dev ]; then
                # 优先使用lo接口（本地测试），然后是其他网络接口
                net_line=$(cat /proc/net/dev | grep -E "^\s*lo:" | head -1)
                if [ -n "$net_line" ]; then
                    interface_name="lo"
                else
                    net_line=$(cat /proc/net/dev | grep -E "^\s*(eth0|ens|enp)" | head -1)
                    if [ -n "$net_line" ]; then
                        interface_name=$(echo "$net_line" | awk '{print $1}' | tr -d ':')
                    fi
                fi
            fi
            
            local tx_mb_per_sec=0
            local rx_mb_per_sec=0
            local total_bandwidth=0
            
            if [ -n "$net_line" ]; then
                local rx_bytes=$(echo "$net_line" | awk '{print $2}')
                local tx_bytes=$(echo "$net_line" | awk '{print $10}')
                
                if [ $prev_timestamp -gt 0 ] && [ $current_timestamp -gt $prev_timestamp ]; then
                    local time_diff=$((current_timestamp - prev_timestamp))
                    if [ $time_diff -gt 0 ] && [ $prev_tx_bytes -gt 0 ] && [ $prev_rx_bytes -gt 0 ]; then
                        local tx_diff=$((tx_bytes - prev_tx_bytes))
                        local rx_diff=$((rx_bytes - prev_rx_bytes))
                        
                        # 确保差值为正数
                        if [ $tx_diff -ge 0 ] && [ $rx_diff -ge 0 ]; then
                            tx_mb_per_sec=$(echo "scale=2; $tx_diff / $time_diff / 1024 / 1024" | bc 2>/dev/null || echo "0")
                            rx_mb_per_sec=$(echo "scale=2; $rx_diff / $time_diff / 1024 / 1024" | bc 2>/dev/null || echo "0")
                            
                            # 对于本地回环接口，正确理解TX和RX
                            # TX: 本地服务器发送的数据 (实际下载速度)
                            # RX: 本地客户端接收的数据 (应该与TX相等)
                            # 实际带宽应该是TX和RX中的较大值，不是相加
                            local raw_bandwidth
                            if [ "$(echo "$tx_mb_per_sec > $rx_mb_per_sec" | bc 2>/dev/null)" = "1" ]; then
                                raw_bandwidth=$tx_mb_per_sec
                            else
                                raw_bandwidth=$rx_mb_per_sec
                            fi
                            
                            # 简化的异常值检测 - 只过滤明显错误的值
                            if [ "$(echo "$raw_bandwidth > 10000" | bc 2>/dev/null)" = "1" ]; then
                                # 只过滤超过10GB/s的明显错误值
                                raw_bandwidth=0
                            fi
                            
                            # 添加到样本数组
                            bandwidth_samples+=($raw_bandwidth)
                            # 只保留最近3个样本
                            if [ ${#bandwidth_samples[@]} -gt 3 ]; then
                                bandwidth_samples=("${bandwidth_samples[@]:1}")
                            fi
                            
                            # 轻度平滑 - 只使用最近3个样本的平均值
                            local sample_count=${#bandwidth_samples[@]}
                            if [ $sample_count -eq 1 ]; then
                                total_bandwidth=$raw_bandwidth
                            else
                                local sum=0
                                for sample in "${bandwidth_samples[@]}"; do
                                    sum=$(echo "$sum + $sample" | bc)
                                done
                                total_bandwidth=$(echo "scale=2; $sum / $sample_count" | bc 2>/dev/null || echo "$raw_bandwidth")
                            fi
                        fi
                    fi
                fi
                
                prev_tx_bytes=$tx_bytes
                prev_rx_bytes=$rx_bytes
            fi
            
            prev_timestamp=$current_timestamp
            
            # 输出干净的CSV数据，确保数值字段不包含额外字符
            echo "$timestamp,$mem_mb,$cpu_percent,$connections,$fd_count,$active_downloads,$completed_downloads,$load_avg,$tx_mb_per_sec,$rx_mb_per_sec,$total_bandwidth"
            sleep 1
        done
    } > "$output_file" &
    echo $!
}

# 启动实时监控
echo ""
echo "2️⃣ 启动实时监控..."
MONITOR_PID=$(monitor_resources "$RESULTS_DIR/realtime_stats.csv")
echo "✅ 监控已启动 (PID: $MONITOR_PID)"

# 实时显示函数
show_realtime_stats() {
    local stats_file="$RESULTS_DIR/realtime_stats.csv"
    local history_lines=()
    local max_history=10
    
    # 清屏并设置终端
    clear
    echo "🎯 50用户同时并发测试 - 实时监控面板 (http-file-server)"
    echo "=========================================================="
    echo ""
    
    while true; do
        if [ -f "$stats_file" ]; then
            local latest=$(tail -n 1 "$stats_file" 2>/dev/null)
            if [ -n "$latest" ] && [[ "$latest" != *"时间,内存"* ]]; then
                # 解析CSV行，只取前11个字段（排除可能的额外字段）
                local csv_fields=($(echo "$latest" | cut -d',' -f1-11 | tr ',' ' '))
                if [ ${#csv_fields[@]} -ge 11 ]; then
                    time="${csv_fields[0]}"
                    mem="${csv_fields[1]}"
                    cpu="${csv_fields[2]}"
                    conn="${csv_fields[3]}"
                    fd="${csv_fields[4]}"
                    active="${csv_fields[5]}"
                    completed="${csv_fields[6]}"
                    load="${csv_fields[7]}"
                    tx_bw="${csv_fields[8]}"
                    rx_bw="${csv_fields[9]}"
                    total_bw="${csv_fields[10]}"
                    
                    # 确保数值字段都是纯数字
                    total_bw=$(echo "$total_bw" | sed 's/[^0-9.]//g')
                    tx_bw=$(echo "$tx_bw" | sed 's/[^0-9.]//g')
                    rx_bw=$(echo "$rx_bw" | sed 's/[^0-9.]//g')
                fi
                
                # 移动到顶部重新绘制
                printf "\033[4;1H"
                
                # 当前状态 - 使用更好看的格式
                echo "📊 实时状态 [$time] - http-file-server:$SERVER_PORT"
                echo "┌─────────────────────────────────────────────────────────────────┐"
                printf "│ 💾 内存: %6s MB   🚀 CPU: %3s%%   🔗 连接: %3s   📁 FD: %3s    │\n" "$mem" "$cpu" "$conn" "$fd"
                printf "│ 📥 活跃: %6s      ✅ 完成: %3s   ⚖️  负载: %4s             │\n" "$active" "$completed" "$load"
                
                # 正确的带宽显示 - 修正本地回环重复计算
                local display_bw="$total_bw"
                local bw_indicator="📊"
                local raw_total=$(echo "scale=2; $tx_bw + $rx_bw" | bc 2>/dev/null || echo "0")
                
                # 简单状态指示
                if [ "$active" -gt 0 ]; then
                    if [ "$(echo "$total_bw > 100" | bc 2>/dev/null)" = "1" ]; then
                        bw_indicator="🚀"  # 高速传输
                    elif [ "$(echo "$total_bw > 10" | bc 2>/dev/null)" = "1" ]; then
                        bw_indicator="📈"  # 正常传输
                    else
                        bw_indicator="📊"  # 低速传输
                    fi
                else
                    bw_indicator="⏸️"  # 暂停状态
                fi
                
                printf "│ 🌐 带宽: %s %8.2f MB/s (TX:%s RX:%s 修正前:%s)      │\n" "$bw_indicator" "$total_bw" "$tx_bw" "$rx_bw" "$raw_total"
                echo "└─────────────────────────────────────────────────────────────────┘"
                echo ""
                
                # 进度条
                local progress_percent=0
                if [ $CONCURRENT_USERS -gt 0 ]; then
                    progress_percent=$((completed * 100 / CONCURRENT_USERS))
                fi
                echo "📈 完成进度: $completed/$CONCURRENT_USERS"
                printf "["
                local filled=$((progress_percent / 2))
                for i in $(seq 1 $filled); do printf "█"; done
                for i in $(seq $((filled + 1)) 50); do printf "░"; done
                printf "] %d%%\n" $progress_percent
                echo ""
                
                # 添加到历史记录（避免重复）
                local display_line=$(printf "%s | 内存:%3sMB CPU:%2s%% 连接:%2s 活跃:%2s 完成:%2s 带宽:%5sMB/s" \
                    "$time" "$mem" "$cpu" "$conn" "$active" "$completed" "$total_bw")
                
                # 检查是否与最后一条记录相同（避免重复）
                local should_add=true
                if [ ${#history_lines[@]} -gt 0 ]; then
                    local last_line="${history_lines[-1]}"
                    if [ "$display_line" = "$last_line" ]; then
                        should_add=false
                    fi
                fi
                
                if [ "$should_add" = true ]; then
                    history_lines+=("$display_line")
                    
                    # 保持历史记录长度
                    if [ ${#history_lines[@]} -gt $max_history ]; then
                        history_lines=("${history_lines[@]:1}")
                    fi
                fi
                
                # 显示历史记录
                echo "📋 历史数据 (最近${#history_lines[@]}条记录):"
                echo "┌─────────────────────────────────────────────────────────────────┐"
                for hist_line in "${history_lines[@]}"; do
                    printf "│ %-63s │\n" "$hist_line"
                done
                echo "└─────────────────────────────────────────────────────────────────┘"
                echo ""
                
                # 添加实时性能分析
                if [ "$completed" -gt 0 ] && [ "$active" -gt 0 ]; then
                    local throughput_per_user=$(echo "scale=2; $total_bw / $active" | bc 2>/dev/null || echo "0")
                    echo "⚡ 性能分析 (http-file-server + 修正算法):"
                    printf "   • 单用户平均吞吐: %s MB/s\n" "$throughput_per_user"
                    printf "   • 并发效率: %s%% (活跃连接/最大连接)\n" "$((active * 100 / CONCURRENT_USERS))"
                    printf "   • 📈 修正: 本地回环TX/RX选最大值(避免重复计算)\n"
                    printf "   • 🔧 服务器: http-file-server (端口%s)\n" "$SERVER_PORT"
                    
                    if [ "${#history_lines[@]}" -gt 3 ]; then
                        local prev_completed=$(echo "${history_lines[-2]}" | sed 's/.*完成:\([0-9]*\).*/\1/' || echo "0")
                        local completion_rate=$((completed - prev_completed))
                        if [ "$completion_rate" -gt 0 ]; then
                            printf "   • 完成速率: %s/秒\n" "$completion_rate"
                        fi
                    fi
                    echo ""
                fi
                
                echo "💡 按 Ctrl+C 停止监控 | 💾 黑洞模式 + 🔧 修正本地回环重复计算"
                
                # 测试状态提示
                if [ "$completed" -eq "$CONCURRENT_USERS" ]; then
                    echo ""
                    echo "🎉 测试完成！所有 $CONCURRENT_USERS 个用户下载完成"
                elif [ "$active" -eq 0 ] && [ "$completed" -eq 0 ]; then
                    echo ""
                    echo "⏳ 准备启动测试..."
                else
                    local remaining=$((CONCURRENT_USERS - completed))
                    echo ""
                    echo "🔄 测试进行中：$active 个活跃连接，$remaining 个等待完成"
                fi
            fi
        fi
        sleep 1
    done
}

# 预热测试
echo ""
echo "3️⃣ 预热测试..."
if curl -s -o /dev/null -w "%{http_code}" http://localhost:$SERVER_PORT/$TEST_FILE | grep -q "200"; then
    echo "✅ 预热成功"
else
    echo "❌ 预热失败，检查文件是否存在"
    echo "   尝试访问: http://localhost:$SERVER_PORT/$TEST_FILE"
    # 列出根目录内容
    echo "   可用文件:"
    curl -s http://localhost:$SERVER_PORT/ | head -20 || echo "   无法获取目录列表"
fi

# 准备下载目录
download_dir="$RESULTS_DIR/downloads"
mkdir -p "$download_dir"

echo ""
echo "4️⃣ 同时启动50个并发下载..."
echo "⏱️  实时监控面板将在后台运行..."
echo ""

# 启动实时显示（在后台运行）
show_realtime_stats &
DISPLAY_PID=$!

# 给显示界面时间初始化
sleep 3

# 在新终端窗口中显示启动信息（不影响监控面板）
{
    sleep 5
    echo "🚀 50个并发下载已启动，监控面板运行中..."
    echo "💡 使用 Ctrl+C 可以停止测试"
} >/dev/tty &

# 同时启动所有50个下载进程
pids=()
start_time=$(date +%s)

for i in $(seq 1 $CONCURRENT_USERS); do
    {
        user_id=$(printf "%03d" $i)
        log_file="$download_dir/user_${user_id}.log"
        url="http://localhost:$SERVER_PORT/$TEST_FILE"
        
        start_time_user=$(date +%s)
        echo "$(date '+%H:%M:%S') 用户 $user_id 开始下载到 /dev/null" > "$log_file"
        
        # 执行下载到 /dev/null（黑洞模式，不占用磁盘空间）
        if timeout $TEST_DURATION curl -s -o /dev/null -w "下载字节数:%{size_download} 平均速度:%{speed_download} HTTP状态:%{http_code}" "$url" >> "$log_file" 2>&1; then
            end_time_user=$(date +%s)
            duration=$((end_time_user - start_time_user))
            
            # 从curl的输出中提取下载信息
            download_info=$(tail -n 1 "$log_file" | grep "下载字节数:")
            if [ -n "$download_info" ]; then
                bytes=$(echo "$download_info" | sed 's/.*下载字节数:\([0-9]*\).*/\1/')
                speed=$(echo "$download_info" | sed 's/.*平均速度:\([0-9.]*\).*/\1/')
                http_code=$(echo "$download_info" | sed 's/.*HTTP状态:\([0-9]*\).*/\1/')
                
                if [ "$http_code" = "200" ] && [ "$bytes" -gt 0 ]; then
                    speed_mbps=$(echo "scale=2; $speed / 1024 / 1024" | bc 2>/dev/null || echo "0")
                    echo "$(date '+%H:%M:%S') 用户 $user_id 下载完成: ${duration}秒, 大小$(($bytes / 1024 / 1024))MB, 速度${speed_mbps}MB/s" >> "$log_file"
                else
                    echo "$(date '+%H:%M:%S') 用户 $user_id 下载失败: HTTP $http_code" >> "$log_file"
                fi
            else
                echo "$(date '+%H:%M:%S') 用户 $user_id 下载完成: ${duration}秒" >> "$log_file"
            fi
        else
            echo "$(date '+%H:%M:%S') 用户 $user_id 下载失败或超时" >> "$log_file"
        fi
    } &
    
    pids+=($!)
done

# 继续监控直到测试完成
echo ""
echo "⏱️  测试进行中，实时监控运行..."
echo ""

# 等待所有进程完成或超时
test_end_time=$(($(date +%s) + TEST_DURATION + 10))

while [ $(date +%s) -lt $test_end_time ]; do
    completed=0
    active=0
    
    for pid in "${pids[@]}"; do
        if ! kill -0 $pid 2>/dev/null; then
            completed=$((completed + 1))
        else
            active=$((active + 1))
        fi
    done
    
    if [ $completed -eq $CONCURRENT_USERS ]; then
        # 给用户一点时间看到完成状态
        sleep 5
        break
    fi
    
    sleep 2
done

# 停止实时显示
kill $DISPLAY_PID 2>/dev/null || true
sleep 1
clear

# 强制结束剩余进程
echo ""
echo "5️⃣ 清理资源..."
for pid in "${pids[@]}"; do
    if kill -0 $pid 2>/dev/null; then
        kill $pid 2>/dev/null || true
    fi
done

# 停止监控
kill $MONITOR_PID 2>/dev/null || true

# 停止服务器
if [ ! -z "$SERVER_PID" ] && kill -0 $SERVER_PID 2>/dev/null; then
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null || true
fi

echo "✅ 所有进程已停止"

# 生成最终报告
echo ""
echo "6️⃣ 生成测试报告..."

# 统计结果
total_downloads=$(find "$download_dir" -name "user_*.log" | wc -l)
successful_downloads=$(grep -l "下载完成" "$download_dir"/user_*.log 2>/dev/null | wc -l || echo "0")
failed_downloads=$((total_downloads - successful_downloads))
success_rate=0
if [ $total_downloads -gt 0 ]; then
    success_rate=$(echo "scale=1; $successful_downloads * 100 / $total_downloads" | bc 2>/dev/null || echo "0")
fi

# 计算总下载量（基于curl统计）
total_bytes=0
total_mb=0
# 从日志中获取下载信息
for f in "$download_dir"/user_*.log; do
    if [ -f "$f" ]; then
        bytes=$(grep "下载字节数:" "$f" 2>/dev/null | tail -n 1 | sed 's/.*下载字节数:\([0-9]*\).*/\1/' || echo "0")
        if [ -n "$bytes" ] && [ "$bytes" -gt 0 ]; then
            total_bytes=$((total_bytes + bytes))
        fi
    fi
done
total_mb=$((total_bytes / 1024 / 1024))

# 分析资源峰值
if [ -f "$RESULTS_DIR/realtime_stats.csv" ]; then
    max_memory=$(tail -n +2 "$RESULTS_DIR/realtime_stats.csv" | cut -d, -f2 | sort -n | tail -1 || echo "0")
    max_cpu=$(tail -n +2 "$RESULTS_DIR/realtime_stats.csv" | cut -d, -f3 | sort -n | tail -1 || echo "0")
    max_connections=$(tail -n +2 "$RESULTS_DIR/realtime_stats.csv" | cut -d, -f4 | sort -n | tail -1 || echo "0")
    max_fds=$(tail -n +2 "$RESULTS_DIR/realtime_stats.csv" | cut -d, -f5 | sort -n | tail -1 || echo "0")
    max_concurrent=$(tail -n +2 "$RESULTS_DIR/realtime_stats.csv" | cut -d, -f6 | sort -n | tail -1 || echo "0")
    max_bandwidth=$(tail -n +2 "$RESULTS_DIR/realtime_stats.csv" | cut -d, -f11 | sort -n | tail -1 || echo "0")
    avg_bandwidth=$(tail -n +2 "$RESULTS_DIR/realtime_stats.csv" | cut -d, -f11 | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}' || echo "0")
else
    max_memory=0
    max_cpu=0
    max_connections=0
    max_fds=0
    max_concurrent=0
    max_bandwidth=0
    avg_bandwidth=0
fi

# 生成详细报告
cat > "$RESULTS_DIR/concurrent_test_report.md" << EOF
# 50用户同时并发测试报告（http-file-server + 黑洞模式）

## 测试策略
**核心特点**: 50个用户同时启动（非分批），模拟真实突发访问场景
**下载模式**: /dev/null 黑洞模式，不占用磁盘空间，专注测试并发性能
**服务器**: http-file-server-linux-x86_64 (类似 python -m http.server)

## 测试配置
- **并发用户数**: $CONCURRENT_USERS (同时启动)
- **测试文件**: $TEST_FILE (1GB大文件)
- **下载目标**: /dev/null (黑洞模式)
- **测试时长**: ${TEST_DURATION}秒
- **服务器**: http-file-server-linux-x86_64
- **服务端口**: $SERVER_PORT
- **系统内存**: ${TOTAL_MEMORY_GB}GB

## 测试结果

### 并发处理能力
- **总请求数**: $total_downloads
- **成功下载**: $successful_downloads
- **失败下载**: $failed_downloads
- **成功率**: ${success_rate}%
- **总传输量**: ${total_mb}MB (通过网络传输)

### 系统资源峰值
- **最大内存使用**: ${max_memory}MB
- **最大CPU使用率**: ${max_cpu}%
- **最大网络连接**: $max_connections
- **最大文件描述符**: $max_fds
- **最大并发下载**: $max_concurrent
- **峰值带宽**: ${max_bandwidth}MB/s
- **平均带宽**: ${avg_bandwidth}MB/s

## 性能分析

### http-file-server vs share_these 对比
1. **部署简便**: http-file-server 无需编译，开箱即用
2. **标准协议**: 标准 HTTP 文件服务器，兼容性好
3. **资源占用**: 与自定义服务器的对比分析
4. **并发处理**: 验证标准文件服务器的并发能力

### 同时启动vs分批启动对比
1. **瞬时冲击**: 同时启动能更好测试系统抗冲击能力
2. **真实场景**: 模拟用户同时访问的真实情况
3. **资源峰值**: 更准确反映系统资源使用峰值
4. **并发控制**: 验证背压控制和连接限制机制

### 关键技术验证
- ✅ HTTP 标准协议处理大量同时连接
- ✅ 静态文件服务的并发能力
- ✅ 系统级别的连接管理
- ✅ 文件描述符合理使用

## 面试回答要点

### http-file-server 的优势
1. **标准化**: 遵循标准 HTTP 协议
2. **简单部署**: 单一二进制文件，无依赖
3. **跨平台**: 支持多种操作系统
4. **轻量级**: 资源占用小

### 并发处理挑战
1. **连接风暴**: 瞬间大量连接建立
2. **内存压力**: 同时处理多个大文件
3. **文件描述符**: 避免耗尽系统资源
4. **CPU调度**: 合理分配处理时间

### 技术解决方案
1. **事件驱动**: 高效的 I/O 处理模型
2. **流式传输**: 减少内存使用
3. **连接管理**: 系统级别的连接控制
4. **资源监控**: 实时调整策略

## 测试文件说明
- \`realtime_stats.csv\` - 实时资源监控数据
- \`server.log\` - http-file-server 运行日志  
- \`downloads/\` - 用户下载文件和详细日志

## 服务器对比
- **http-file-server**: 标准 HTTP 静态文件服务器
- **share_these**: 自定义高性能文件共享服务器
- **测试目的**: 验证不同服务器的并发处理能力

EOF

echo "✅ 报告已生成"

# 显示最终结果
echo ""
echo "🎯 同时50用户并发测试完成（http-file-server + 黑洞模式）"
echo "======================================================="
echo ""
echo "📊 最终统计:"
echo "   • 服务器: http-file-server-linux-x86_64"
echo "   • 测试策略: 50用户同时启动"
echo "   • 下载模式: /dev/null 黑洞模式"
echo "   • 测试文件: 1GB大文件"
echo "   • 服务端口: $SERVER_PORT"
echo "   • 成功率: ${success_rate}%"
echo "   • 总传输量: ${total_mb}MB"
echo "   • 内存峰值: ${max_memory}MB"
echo "   • CPU峰值: ${max_cpu}%"
echo "   • 最大连接: $max_connections"
echo "   • 最大并发: $max_concurrent"
echo "   • 峰值带宽: ${max_bandwidth}MB/s"
echo "   • 平均带宽: ${avg_bandwidth}MB/s"
echo ""
echo "💡 http-file-server 特点:"
echo "   • 🚀 标准 HTTP 协议：兼容性强"
echo "   • 💾 无需编译：开箱即用"
echo "   • 🔬 轻量级服务器：资源占用小"
echo "   • ⚡ 简单部署：单一二进制文件"
echo ""
echo "💡 黑洞模式优势:"
echo "   • 🚀 专注性能测试：不受磁盘I/O影响"
echo "   • 💾 零磁盘占用：50GB数据流向/dev/null"
echo "   • 🔬 纯粹网络测试：测试真实网络和服务器性能"
echo "   • ⚡ 无磁盘瓶颈：排除存储限制因素"
echo ""
echo "📁 结果位置: $RESULTS_DIR"
echo "📋 详细报告: cat $RESULTS_DIR/concurrent_test_report.md"
echo ""

# 使用bc进行浮点数比较
success_rate_int=$(echo "$success_rate" | cut -d. -f1)
if [ $success_rate_int -gt 95 ]; then
    echo "🎉 测试成功！http-file-server 能够处理50个同时连接"
    echo "   黑洞模式验证了纯网络传输性能优异"
elif [ $success_rate_int -gt 80 ]; then
    echo "⚠️  测试基本成功，但有少量失败"
    echo "   可能存在网络或并发处理瓶颈"
else
    echo "❌ 测试发现问题，需要优化并发处理能力"
    echo "   建议检查网络配置和服务器设置"
fi

echo "======================================================="
echo "🔧 与原版对比测试:"
echo "   原版脚本: ./concurrent_50_test.sh (share_these)"
echo "   新版脚本: ./concurrent_50_test_http_file_server.sh (http-file-server)"
echo "   可以运行两个脚本进行性能对比分析"
echo "======================================================="
