# Share_These

## Description

分享当前目录(包括子目录)下的所有文件

> 由程序员视角

share these files in current directory (including subdirectories)

> from the perspective of a programmer

<img width="1218" alt="demo" src="https://github.com/user-attachments/assets/ddf6cb04-d998-4888-b30c-e474f5aacc70" />

## Why

为什么要写这个程序？

Why write this program?

- 现存的分享APP, 需要把文件拖拽到APP中, 有时候文件太多, 会很麻烦
- 有时候, 我只是想分享当前目录下的所有文件, 但是又不想把文件打包成压缩包
- `python3 -m http.server` 不适合生产环境, 不适合分享多个人(不稳定)

## Usage

```shell
# 赋予执行权限
chmod +x ./share_these

# 运行
./share_these
```

## Dependencies

```toml
[dependencies]
# "?" is shorter than ".unwrap()"
anyhow = "1.0.97"
# full features because of laziness
tokio = { version = "1.44.1", features = ["full"] }
# import the greatest framework
axum = { version = "0.8.1" }
tracing = "0.1.41"
tracing-subscriber = "0.3.19"
tower-http = { version = "0.6.2", features = ["trace"] }
```

## log

```
> ./share_these
2025-03-15T19:28:46.760080Z  INFO Server running at http://localhost:3000
2025-03-15T19:28:52.926080Z  INFO File list requested for root directory ip=127.0.0.1
2025-03-15T19:28:53.889118Z  INFO File served: "/Users/Downloads/funny.js" ip=127.0.0.1
2025-03-15T19:29:30.927127Z  INFO Directory listing for: how ip=127.0.0.1
```

## TODO

- [ ] 支持自定义端口
- [ ] 支持自定义目录
- [ ] 支持自定义分享出去的文件类型
- [ ] 权限控制 (random token)
- [ ] 待分享的文件载入内存, 方便分享给多人
- [ ] P2P分享 (仅内网, 下载客户端后自动触发做种)

## License

MPL-2.0
