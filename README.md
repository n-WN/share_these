# 📂 Share_These

## 📝 简介

分享当前目录(包括子目录)下的所有文件

> 由程序员视角

share these files in current directory (including subdirectories)

> from the perspective of a programmer

<img width="1218" alt="demo" src="https://github.com/user-attachments/assets/ddf6cb04-d998-4888-b30c-e474f5aacc70" />

## ✨ 功能特点

- 🚀 **快速部署**：无需配置，直接运行
- 🔄 **实时访问**：直接访问工作目录文件，无需预先上传
- 📱 **响应式设计**：支持电脑和移动设备
- 🌓 **暗色模式**：自动适应系统设置
- 📦 **文件缓存**：小文件缓存提高性能
- 🔒 **安全保障**：路径安全检查，防止目录遍历
- ⚡ **流式传输**：高效处理大文件
- 📊 **并发控制**：限制同时连接数，保障稳定性
- 🌐 **网络配置**：可定制端口和绑定地址

## 🤔 为什么要写这个程序？

- 现存的分享APP需要把文件拖拽到APP中，有时候文件太多，会很麻烦
- 有时候，我只是想分享当前目录下的所有文件，但是又不想把文件打包成压缩包
- `python3 -m http.server` 不适合生产环境，不适合多人分享（不稳定）

## 🚀 安装

### 预编译二进制文件

```shell
# 下载最新版本
curl -L https://github.com/n-WN/share_these/releases/latest/download/share_these-linux-amd64 -o share_these
chmod +x share_these
```

### 从源码编译

```shell
git clone https://github.com/n-WN/share_these.git
cd share_these
cargo build --release
```

## 📋 使用方法

### 基本用法

```shell
# 赋予执行权限
chmod +x ./share_these

# 基本运行（默认端口3000，所有网卡）
./share_these

# 指定端口
./share_these --port 8080
./share_these -p 8080

# 指定绑定地址
./share_these --host 127.0.0.1
./share_these -h 127.0.0.1

# 同时指定端口和地址
./share_these -h 127.0.0.1 -p 8080

# 查看帮助
./share_these --help
```

### 命令行参数

| 参数 | 简写 | 说明 | 默认值 |
|------|------|------|--------|
| `--port` | `-p` | 服务器绑定的端口 | 3000 |
| `--host` | `-h` | 服务器绑定的网卡地址 | 0.0.0.0 |
| `--help` | | 显示帮助信息 | |
| `--version` | | 显示版本信息 | |

## 🔧 技术依赖

```toml
[dependencies]
# 错误处理
anyhow = "1.0.97"
# 异步运行时
tokio = { version = "1.44.1", features = ["full"] }
# Web框架
axum = { version = "0.8.1" }
# 日志系统
tracing = "0.1.41"
tracing-subscriber = "0.3.19"
# HTTP中间件
tower-http = { version = "0.6.2", features = ["trace"] }
tower = { version = "0.5.2", features = ["limit"] }
# 异步工具
tokio-util = { version = "0.7.14", features = ["io"] }
# 时间处理
chrono = "0.4"
# 命令行参数解析
clap = { version = "4.5", features = ["derive"] }
# 文件缓存
moka = { version = "0.12.10", features = ["future"] }
```

## 📊 日志示例

```
> ./share_these
2025-03-15T19:28:46.760080Z  INFO Server running at http://localhost:3000
2025-03-15T19:28:52.926080Z  INFO File list requested for root directory ip=127.0.0.1
2025-03-15T19:28:53.889118Z  INFO File served: "/Users/Downloads/funny.js" ip=127.0.0.1
2025-03-15T19:29:30.927127Z  INFO Directory listing for: how ip=127.0.0.1
```

## TODO

- [x] 支持自定义端口
- [ ] 支持自定义目录
- [ ] 支持自定义分享出去的文件类型
- [ ] 权限控制 (random token)
- [x] 待分享的文件载入内存, 方便分享给多人
- [ ] P2P分享 (仅内网, 下载客户端后自动触发做种)

## License

MPL-2.0
