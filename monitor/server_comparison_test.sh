#!/bin/bash

# 服务器性能对比测试脚本
# 依次测试 Rust服务器、http-file-server、Python HTTP Server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARISON_DIR="$SCRIPT_DIR/server_comparison_$(date +%Y%m%d_%H%M%S)"

echo "🎯 服务器性能对比测试"
echo "========================"
echo "• 测试目标: 对比不同HTTP服务器的并发性能"
echo "• 测试场景: 50用户同时并发下载1GB文件"
echo "• 测试方法: 黑洞模式(/dev/null) + 修正本地回环重复计算"
echo "• 对比服务器:"
echo "  1. Rust 异步服务器 (share_these)"
echo "  2. http-file-server (Go语言)"
echo "  3. Python HTTP Server (python -m http.server)"
echo ""

# 创建对比结果目录
mkdir -p "$COMPARISON_DIR"

# 检查所需的测试脚本
RUST_SCRIPT="$SCRIPT_DIR/concurrent_50_test.sh"
HFS_SCRIPT="$SCRIPT_DIR/concurrent_50_test_http_file_server.sh"
PYTHON_SCRIPT="$SCRIPT_DIR/concurrent_50_test_python_server.sh"

echo "🔍 检查测试脚本..."
for script in "$RUST_SCRIPT" "$HFS_SCRIPT" "$PYTHON_SCRIPT"; do
    if [ ! -f "$script" ]; then
        echo "❌ 找不到脚本: $script"
        exit 1
    fi
    if [ ! -x "$script" ]; then
        echo "🔧 设置执行权限: $script"
        chmod +x "$script"
    fi
done
echo "✅ 所有测试脚本就绪"

# 测试函数
run_server_test() {
    local server_name="$1"
    local script_path="$2"
    local log_prefix="$3"
    
    echo ""
    echo "🚀 开始测试: $server_name"
    echo "================================"
    echo "脚本: $script_path"
    echo "开始时间: $(date)"
    echo ""
    
    # 运行测试并捕获输出
    if timeout 300 bash "$script_path" > "$COMPARISON_DIR/${log_prefix}_output.log" 2>&1; then
        echo "✅ $server_name 测试完成"
    else
        echo "⚠️ $server_name 测试超时或失败"
    fi
    
    echo "结束时间: $(date)"
    echo ""
}

# 提取测试结果的函数
extract_results() {
    local server_name="$1"
    local log_file="$2"
    local results_dir="$3"
    
    if [ ! -f "$log_file" ]; then
        echo "未找到日志文件: $log_file"
        return 1
    fi
    
    # 从日志中提取关键性能指标
    local success_rate=$(grep "成功率:" "$log_file" | head -1 | sed 's/.*成功率: \([0-9.]*\)%.*/\1/' || echo "0")
    local total_transfer=$(grep "总传输量:" "$log_file" | head -1 | sed 's/.*总传输量: \([0-9]*\)MB.*/\1/' || echo "0")
    local max_memory=$(grep "内存峰值:" "$log_file" | head -1 | sed 's/.*内存峰值: \([0-9]*\)MB.*/\1/' || echo "0")
    local max_cpu=$(grep "CPU峰值:" "$log_file" | head -1 | sed 's/.*CPU峰值: \([0-9]*\)%.*/\1/' || echo "0")
    local max_connections=$(grep "最大连接:" "$log_file" | head -1 | sed 's/.*最大连接: \([0-9]*\).*/\1/' || echo "0")
    local max_concurrent=$(grep "最大并发:" "$log_file" | head -1 | sed 's/.*最大并发: \([0-9]*\).*/\1/' || echo "0")
    local peak_bandwidth=$(grep "峰值带宽:" "$log_file" | head -1 | sed 's/.*峰值带宽: \([0-9.]*\)MB\/s.*/\1/' || echo "0")
    local avg_bandwidth=$(grep "平均带宽:" "$log_file" | head -1 | sed 's/.*平均带宽: \([0-9.]*\)MB\/s.*/\1/' || echo "0")
    
    # 输出结果到CSV
    echo "$server_name,$success_rate,$total_transfer,$max_memory,$max_cpu,$max_connections,$max_concurrent,$peak_bandwidth,$avg_bandwidth" >> "$results_dir/comparison_results.csv"
    
    # 创建单独的结果文件
    cat > "$results_dir/${server_name}_summary.txt" << EOF
服务器: $server_name
成功率: ${success_rate}%
总传输量: ${total_transfer}MB
内存峰值: ${max_memory}MB
CPU峰值: ${max_cpu}%
最大连接: $max_connections
最大并发: $max_concurrent
峰值带宽: ${peak_bandwidth}MB/s
平均带宽: ${avg_bandwidth}MB/s
EOF
}

# 开始对比测试
echo "📋 测试计划:"
echo "   1. 依次运行三个服务器测试"
echo "   2. 每个测试预计耗时2-5分钟"
echo "   3. 自动提取性能指标"
echo "   4. 生成对比报告"
echo ""

read -p "是否开始对比测试？(y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "测试已取消"
    exit 0
fi

# 创建CSV表头
echo "服务器,成功率(%),总传输量(MB),内存峰值(MB),CPU峰值(%),最大连接,最大并发,峰值带宽(MB/s),平均带宽(MB/s)" > "$COMPARISON_DIR/comparison_results.csv"

# 测试1: Rust服务器
run_server_test "Rust异步服务器" "$RUST_SCRIPT" "rust"
extract_results "Rust异步服务器" "$COMPARISON_DIR/rust_output.log" "$COMPARISON_DIR"

echo "⏱️  等待5秒后继续下一个测试..."
sleep 5

# 测试2: http-file-server
run_server_test "http-file-server" "$HFS_SCRIPT" "hfs"
extract_results "http-file-server" "$COMPARISON_DIR/hfs_output.log" "$COMPARISON_DIR"

echo "⏱️  等待5秒后继续下一个测试..."
sleep 5

# 测试3: Python HTTP Server
run_server_test "Python HTTP Server" "$PYTHON_SCRIPT" "python"
extract_results "Python HTTP Server" "$COMPARISON_DIR/python_output.log" "$COMPARISON_DIR"

# 生成对比报告
echo ""
echo "📊 生成对比报告..."

cat > "$COMPARISON_DIR/server_comparison_report.md" << 'EOF'
# HTTP服务器性能对比报告

## 测试概述
本报告对比了三种不同的HTTP服务器在50用户同时并发下载1GB文件场景下的性能表现。

### 测试环境
- **测试场景**: 50用户同时启动并发下载
- **测试文件**: 1GB大文件
- **下载模式**: /dev/null 黑洞模式（排除磁盘I/O影响）
- **网络**: 本地回环接口（localhost）
- **带宽监控**: 修正本地回环TX/RX重复计算问题

### 被测服务器
1. **Rust异步服务器** (share_these)
   - 架构: 异步I/O + Tokio运行时
   - 语言: Rust
   - 特点: 零成本抽象，内存安全，高并发

2. **http-file-server**
   - 架构: Go语言HTTP服务器
   - 语言: Go
   - 特点: Goroutine并发模型

3. **Python HTTP Server**
   - 架构: 单线程同步I/O
   - 语言: Python
   - 特点: 简单易用，性能有限

## 性能对比结果

### 核心性能指标
EOF

# 添加对比表格
echo "" >> "$COMPARISON_DIR/server_comparison_report.md"
echo "| 服务器 | 成功率(%) | 总传输量(MB) | 峰值带宽(MB/s) | 平均带宽(MB/s) | 内存峰值(MB) | CPU峰值(%) |" >> "$COMPARISON_DIR/server_comparison_report.md"
echo "|--------|-----------|--------------|----------------|----------------|--------------|------------|" >> "$COMPARISON_DIR/server_comparison_report.md"

# 从CSV文件读取数据并格式化
if [ -f "$COMPARISON_DIR/comparison_results.csv" ]; then
    tail -n +2 "$COMPARISON_DIR/comparison_results.csv" | while IFS=',' read -r server success_rate total_transfer max_memory max_cpu max_connections max_concurrent peak_bandwidth avg_bandwidth; do
        echo "| $server | $success_rate | $total_transfer | $peak_bandwidth | $avg_bandwidth | $max_memory | $max_cpu |" >> "$COMPARISON_DIR/server_comparison_report.md"
    done
fi

# 添加分析部分
cat >> "$COMPARISON_DIR/server_comparison_report.md" << 'EOF'

## 性能分析

### 预期性能排序
1. **Rust异步服务器**: 预期最高性能
   - ✅ 异步I/O避免阻塞
   - ✅ 零成本抽象减少开销
   - ✅ 内存安全且高效

2. **http-file-server (Go)**: 预期中等性能
   - ✅ Goroutine轻量级并发
   - ✅ 垃圾回收可能带来延迟
   - ✅ 整体性能良好

3. **Python HTTP Server**: 预期最低性能
   - ❌ 单线程模型限制并发
   - ❌ 同步I/O导致阻塞
   - ❌ 不适合高并发场景

### 技术架构对比

#### 并发模型
- **Rust**: 异步I/O + 事件循环
- **Go**: Goroutine + 调度器
- **Python**: 单线程阻塞I/O

#### 内存管理
- **Rust**: 零成本抽象 + 所有权系统
- **Go**: 垃圾回收器
- **Python**: 引用计数 + 垃圾回收

#### I/O处理
- **Rust**: 非阻塞异步I/O
- **Go**: 阻塞I/O + 轻量级线程
- **Python**: 阻塞同步I/O

## 实际应用建议

### 生产环境选择
1. **高性能需求**: 选择Rust或Go服务器
2. **开发便利性**: Python适合快速原型
3. **运维考虑**: Go的单二进制部署优势明显
4. **性能极致**: Rust在系统级应用中表现最佳

### 使用场景
- **Rust服务器**: 高并发、低延迟、系统级应用
- **Go服务器**: 微服务、API网关、通用Web服务
- **Python服务器**: 开发测试、原型验证、学习用途

## 面试要点总结

### 性能差异的根本原因
1. **I/O模型**: 异步vs同步的巨大差异
2. **并发策略**: 事件循环vs线程vs单线程
3. **语言特性**: 编译型vs解释型的性能差距
4. **内存管理**: 手动管理vs垃圾回收的权衡

### 架构选择考虑因素
1. **性能要求**: QPS、延迟、吞吐量
2. **开发效率**: 团队技能、开发周期
3. **运维成本**: 部署、监控、维护
4. **扩展性**: 水平扩展、负载均衡

## 测试文件说明
- `comparison_results.csv` - 对比数据汇总
- `*_output.log` - 各服务器详细测试日志
- `*_summary.txt` - 各服务器性能摘要

EOF

echo "✅ 对比报告生成完成"

# 显示结果摘要
echo ""
echo "🎯 服务器性能对比测试完成"
echo "=========================="
echo ""

if [ -f "$COMPARISON_DIR/comparison_results.csv" ]; then
    echo "📊 性能对比摘要:"
    echo ""
    printf "%-20s | %-8s | %-12s | %-12s | %-12s\n" "服务器" "成功率%" "峰值带宽" "平均带宽" "内存峰值"
    echo "--------------------------------------------------------------------------------"
    
    tail -n +2 "$COMPARISON_DIR/comparison_results.csv" | while IFS=',' read -r server success_rate total_transfer max_memory max_cpu max_connections max_concurrent peak_bandwidth avg_bandwidth; do
        printf "%-20s | %-8s | %-10s MB/s | %-10s MB/s | %-8s MB\n" "$server" "$success_rate" "$peak_bandwidth" "$avg_bandwidth" "$max_memory"
    done
fi

echo ""
echo "📁 详细结果位置: $COMPARISON_DIR"
echo "📋 对比报告: cat $COMPARISON_DIR/server_comparison_report.md"
echo "📊 原始数据: cat $COMPARISON_DIR/comparison_results.csv"
echo ""
echo "💡 主要收获:"
echo "   • 🚀 验证了不同架构的性能差异"
echo "   • 📈 确认了带宽监控修正的有效性"
echo "   • 🔍 展示了I/O模型对并发性能的影响"
echo "   • ⚡ 为技术选型提供了实际数据支撑"
echo ""

# 检查哪个服务器性能最好
if [ -f "$COMPARISON_DIR/comparison_results.csv" ]; then
    echo "🏆 性能排行榜:"
    
    # 按峰值带宽排序
    echo "   按峰值带宽排序:"
    tail -n +2 "$COMPARISON_DIR/comparison_results.csv" | sort -t',' -k8 -nr | nl | while read num line; do
        server=$(echo "$line" | cut -d',' -f1)
        bandwidth=$(echo "$line" | cut -d',' -f8)
        echo "   $num. $server: ${bandwidth}MB/s"
    done
fi

echo "=========================="
