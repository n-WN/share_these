use axum::{
    extract::{ConnectInfo, Path, State},
    http::{header::{CONTENT_TYPE, CONTENT_LENGTH, RANGE, ACCEPT_RANGES, CONTENT_RANGE}, StatusCode, HeaderMap},
    response::{Html, IntoResponse, Response},
    routing::get,
    Router,
    body::Body,
};
use std::net::SocketAddr;
use std::{path::PathBuf, sync::Arc, io::SeekFrom};
use tokio::fs::{self, File};
use tokio::io::{AsyncSeekExt, AsyncRead, AsyncReadExt};
use tower_http::trace::TraceLayer;
use tracing::{error, info, Level};
use tracing_subscriber::FmtSubscriber;
use anyhow::{Context, Result, anyhow};
use tokio_util::io::ReaderStream;
use std::cmp::min;
use clap::Parser;
use tower::limit::ConcurrencyLimitLayer;
use moka::future::Cache;

mod templates;
use templates::render_file_list;

// 命令行参数定义
#[derive(Parser)]
#[command(
    name = PKG_NAME,
    author = PKG_AUTHORS,
    version = PKG_VERSION,
    about = PKG_DESCRIPTION,
    long_about = "分享当前目录(包括子目录)下的所有文件"
)]
struct Args {
    /// 服务器绑定的端口
    #[arg(short, long, default_value_t = 3000)]
    port: u16,

    /// 服务器绑定的网卡地址
    #[arg(short, long, default_value = "0.0.0.0")]
    host: String,
}

// 作者信息结构体
#[derive(Clone)]
pub struct Author {
    pub name: String,
    pub email: Option<String>,
    pub website: Option<String>,
    pub github: Option<String>,
}

// 编译时常量，从Cargo.toml读取
const PKG_NAME: &str = env!("CARGO_PKG_NAME");
const PKG_VERSION: &str = env!("CARGO_PKG_VERSION");
const PKG_AUTHORS: &str = env!("CARGO_PKG_AUTHORS");
const PKG_DESCRIPTION: &str = env!("CARGO_PKG_DESCRIPTION");
const PKG_REPOSITORY: &str = env!("CARGO_PKG_REPOSITORY");

// 应用状态，存储根目录路径和作者信息
#[derive(Clone)]
struct AppState {
    root_dir: Arc<PathBuf>,
    author: Author,
    cache: Cache<String, Vec<u8>>,
}

// 最大缓存文件大小 (1MB)
const MAX_CACHE_FILE_SIZE: u64 = 1024 * 1024;

#[tokio::main]
async fn main() -> Result<()> {
    // 解析命令行参数
    let args = Args::parse();

    // 初始化日志
    let subscriber = FmtSubscriber::builder()
        .with_max_level(Level::INFO)
        .with_target(false)
        .finish();

    tracing::subscriber::set_global_default(subscriber)
        .context("Failed to set global tracing subscriber")?;

    // 输出项目信息
    println!("----------------------------------------");
    println!("📂 {} v{}", PKG_NAME, PKG_VERSION);
    println!("📝 {}", PKG_DESCRIPTION);
    println!("👤 {}", PKG_AUTHORS);
    println!("🔗 {}", PKG_REPOSITORY);
    println!("----------------------------------------");

    // 获取工作目录作为根目录
    let root_dir = std::env::current_dir()
        .context("Failed to get current working directory")?;
    
    // 创建作者信息
    let author = Author {
        name: PKG_AUTHORS.split(',').next().unwrap_or("文件分享工具").trim().to_string(),
        email: None,  // 不再显示邮箱
        website: None,
        github: Some(PKG_REPOSITORY.to_string()),
    };

    // 创建缓存
    let cache = Cache::new(100); // 缓存最多100个文件
    
    let state = AppState {
        root_dir: Arc::new(root_dir),
        author,
        cache,
    };

    // 构建应用程序
    let app = Router::new()
        .route("/", get(list_files))
        // 使用 {*path} 来捕获所有路径段，包括嵌套路径
        .route("/files/{*path}", get(serve_file))
        .layer(TraceLayer::new_for_http())
        .layer(ConcurrencyLimitLayer::new(64)) // 限制最大并发请求数为64
        .with_state(state.clone()); // https://github.com/n-WN/share_these/blob/80c267ed15729df5daadb4b480e05cf120d3abc7/src/main.rs#L135

    // 使用用户指定的地址和端口
    let addr = format!("{}:{}", args.host, args.port);
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .context(format!("Failed to bind to address {}", addr))?;
    
    // 如果主机是0.0.0.0，显示时用localhost方便用户访问
    let display_host = if args.host == "0.0.0.0" { "localhost" } else { &args.host };
    info!("Server running at http://{}:{}", display_host, args.port);
    
    // 统一使用state.root_dir而不是单独打印root_dir
    println!("项目根目录: {}", state.root_dir.display());
    println!("访问地址: http://{}:{}", display_host, args.port);
    println!("按 Ctrl+C 停止服务");

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
        .await
        .context("Server error")?;

    Ok(())
}

// 列出当前目录下的文件和文件夹
async fn list_files(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
) -> Response {
    let dir = &*state.root_dir;

    match read_directory(dir, None).await {
        Ok((folders, files)) => {
            info!(ip = %addr.ip(), "File list requested for root directory");
            render_file_list(folders, files, Some("/"), &state.author)
        }
        Err(e) => {
            error!(ip = %addr.ip(), "Failed to read directory: {:#}", e);
            Html(format!(
                r#"<html><body><h1>Error</h1><p>{:#}</p></body></html>"#,
                e
            ))
                .into_response()
        }
    }
}

// 提供文件下载
async fn serve_file(
    Path(path): Path<String>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Response {
    // 检查路径安全性
    if path.contains("..") {
        error!(ip = %addr.ip(), "安全问题: 路径包含'..'序列: {}", path);
        return StatusCode::BAD_REQUEST.into_response();
    }

    let full_path = state.root_dir.join(&path);

    // 检查文件是否存在
    if !full_path.exists() {
        error!(ip = %addr.ip(), "File not found: {:?}", full_path);
        return StatusCode::NOT_FOUND.into_response();
    }

    // 如果是目录，则显示目录内容
    if full_path.is_dir() {
        match read_directory(&full_path, Some(&path)).await {
            Ok((folders, files)) => {
                info!(ip = %addr.ip(), "Directory listing for: {}", path);
                render_file_list(folders, files, Some(&path), &state.author)
            }
            Err(e) => {
                error!(ip = %addr.ip(), "Failed to read directory: {:#}", e);
                Html(format!(
                    r#"<html><body><h1>Error</h1><p>{:#}</p></body></html>"#,
                    e
                ))
                    .into_response()
            }
        }
    } else {
        // 检查缓存 - 使用await等待Future完成
        if let Some(cached_data) = state.cache.get(&path).await {
            info!(ip = %addr.ip(), "Serving cached file: {:?}", full_path);
            return Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, determine_content_type(&full_path))
                .header(CONTENT_LENGTH, cached_data.len().to_string())
                .body(Body::from(cached_data))
                .unwrap()
                .into_response();
        }

        // 流式传输文件内容
        match stream_file(&full_path, &path, &headers, addr.ip().to_string(), &state.cache).await {
            Ok(response) => response,
            Err(e) => {
                error!(ip = %addr.ip(), "Failed to stream file: {:?}, error: {:#}", full_path, e);
                match e.downcast_ref::<std::io::Error>() {
                    Some(io_err) if io_err.kind() == std::io::ErrorKind::PermissionDenied => {
                        StatusCode::FORBIDDEN.into_response()
                    },
                    Some(io_err) if io_err.kind() == std::io::ErrorKind::NotFound => {
                        StatusCode::NOT_FOUND.into_response()
                    },
                    _ => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
                }
            }
        }
    }
}

// 流式传输文件
async fn stream_file(
    path: &PathBuf, 
    cache_key: &str,
    headers: &HeaderMap, 
    client_ip: String, 
    cache: &Cache<String, Vec<u8>>
) -> Result<Response> {
    // 获取文件元数据
    let metadata = fs::metadata(path).await
        .with_context(|| format!("Failed to get metadata for {:?}", path))?;
    let file_size = metadata.len();
    
    // 确定内容类型
    let content_type = determine_content_type(path);
    
    // 检查是否是范围请求
    if let Some(range_header) = headers.get(RANGE) {
        return handle_range_request(path, range_header, file_size, content_type, client_ip).await;
    }
    
    // 标准请求 - 流式传输整个文件
    info!(ip = %client_ip, "Streaming full file: {:?}", path);
    
    // 如果文件小于阈值，先读入内存然后缓存并返回
    if file_size <= MAX_CACHE_FILE_SIZE {
        // 添加日志，记录哪些文件被缓存
        info!(ip = %client_ip, "Caching small file: {:?} ({} bytes)", path, file_size);
        
        let mut file = File::open(path).await
            .with_context(|| format!("Failed to open file {:?}", path))?;
        
        let mut buffer = Vec::with_capacity(file_size as usize);
        file.read_to_end(&mut buffer).await
            .with_context(|| format!("Failed to read file {:?}", path))?;
        
        // 缓存文件内容
        cache.insert(cache_key.to_string(), buffer.clone()).await;
        
        // 设置响应头
        let mut response_headers = HeaderMap::new();
        response_headers.insert(CONTENT_TYPE, content_type.parse().unwrap());
        response_headers.insert(CONTENT_LENGTH, file_size.to_string().parse().unwrap());
        response_headers.insert(ACCEPT_RANGES, "bytes".parse().unwrap());
        
        return Ok((StatusCode::OK, response_headers, Body::from(buffer)).into_response());
    }
    
    // 对于大文件，使用流式传输
    let file = File::open(path).await
        .with_context(|| format!("Failed to open file {:?}", path))?;
    
    // 创建流，使用8KB的缓冲区
    let reader_stream = ReaderStream::with_capacity(file, 8 * 1024);
    let body = Body::from_stream(reader_stream);
    
    // 设置响应头
    let mut response_headers = HeaderMap::new();
    response_headers.insert(CONTENT_TYPE, content_type.parse().unwrap());
    response_headers.insert(CONTENT_LENGTH, file_size.to_string().parse().unwrap());
    response_headers.insert(ACCEPT_RANGES, "bytes".parse().unwrap());
    
    Ok((StatusCode::OK, response_headers, body).into_response())
}

// 处理HTTP Range请求
async fn handle_range_request(
    path: &PathBuf,
    range_header: &axum::http::HeaderValue,
    file_size: u64,
    content_type: &'static str,
    client_ip: String
) -> Result<Response> {
    // 解析Range头 (格式: "bytes=start-end")
    let range_str = range_header.to_str().map_err(|_| anyhow!("Invalid range header"))?;
    
    if !range_str.starts_with("bytes=") {
        return Err(anyhow!("Unsupported range unit"));
    }
    
    let range_parts: Vec<&str> = range_str["bytes=".len()..].split('-').collect();
    if range_parts.len() != 2 {
        return Err(anyhow!("Invalid range format"));
    }
    
    // 解析start和end位置
    let start = if range_parts[0].is_empty() { 
        0 
    } else { 
        range_parts[0].parse::<u64>().map_err(|_| anyhow!("Invalid range start"))? 
    };
    
    let end = if range_parts[1].is_empty() { 
        file_size - 1 
    } else { 
        range_parts[1].parse::<u64>().map_err(|_| anyhow!("Invalid range end"))? 
    };
    
    // 验证范围有效性并提供更详细的错误信息
    if start > end {
        return Err(anyhow!("Invalid range: start ({}) > end ({})", start, end));
    }
    
    if start >= file_size {
        return Err(anyhow!("Range start ({}) exceeds file size ({})", start, file_size));
    }
    
    // 范围长度和实际结束位置
    let end = min(end, file_size - 1);
    let content_length = end - start + 1;
    
    info!(ip = %client_ip, "Range request: {:?}, bytes {}-{}/{}", path, start, end, file_size);
    
    // 打开文件并跳到起始位置
    let mut file = File::open(path).await
        .with_context(|| format!("Failed to open file {:?}", path))?;
    
    file.seek(SeekFrom::Start(start)).await
        .with_context(|| format!("Failed to seek to position {} in file {:?}", start, path))?;
    
    // 创建自定义流以限制读取的字节数
    let bounded_file = BoundedReader::new(file, content_length);
    let reader_stream = ReaderStream::with_capacity(bounded_file, 8 * 1024); // 设置8KB缓冲区
    let body = Body::from_stream(reader_stream);
    
    // 设置响应头
    let mut response_headers = HeaderMap::new();
    response_headers.insert(CONTENT_TYPE, content_type.parse().unwrap());
    response_headers.insert(CONTENT_LENGTH, content_length.to_string().parse().unwrap());
    response_headers.insert(
        CONTENT_RANGE, 
        format!("bytes {}-{}/{}", start, end, file_size).parse().unwrap()
    );
    response_headers.insert(ACCEPT_RANGES, "bytes".parse().unwrap());
    
    Ok((StatusCode::PARTIAL_CONTENT, response_headers, body).into_response())
}

// 有界读取器 - 限制读取的字节数
struct BoundedReader<R> {
    inner: R,
    remaining: u64,
}

impl<R> BoundedReader<R> {
    fn new(inner: R, limit: u64) -> Self {
        Self {
            inner,
            remaining: limit,
        }
    }
}

impl<R: AsyncRead + Unpin> AsyncRead for BoundedReader<R> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        // 如果没有剩余字节要读取，返回EOF
        if self.remaining == 0 {
            return std::task::Poll::Ready(Ok(()));
        }

        // 限制读取缓冲区大小
        let max_read = std::cmp::min(self.remaining as usize, buf.remaining());
        let mut limited_buf = tokio::io::ReadBuf::new(buf.initialize_unfilled_to(max_read));
        
        // 读取到有限的缓冲区
        match AsyncRead::poll_read(std::pin::Pin::new(&mut self.inner), cx, &mut limited_buf) {
            std::task::Poll::Ready(Ok(())) => {
                let n = limited_buf.filled().len();
                buf.advance(n);
                self.remaining -= n as u64;
                std::task::Poll::Ready(Ok(()))
            }
            other => other,
        }
    }
}

// 辅助函数：确定内容类型
fn determine_content_type(path: &PathBuf) -> &'static str {
    match path.extension().and_then(|e| e.to_str()) {
        Some("html") | Some("htm") => "text/html",
        Some("css") => "text/css",
        Some("js") => "application/javascript",
        Some("json") => "application/json",
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("svg") => "image/svg+xml",
        Some("pdf") => "application/pdf",
        Some("txt") | Some("md") => "text/plain",
        _ => "application/octet-stream",
    }
}

// 辅助函数：读取目录内容
async fn read_directory(
    dir: &PathBuf,
    path_prefix: Option<&String>,
) -> Result<(Vec<(String, String, u64)>, Vec<(String, String, u64)>)> {
    let mut entries = fs::read_dir(dir)
        .await
        .with_context(|| format!("Failed to read directory {:?}", dir))?;

    let mut files = Vec::new();
    let mut folders = Vec::new();

    while let Some(entry) = entries.next_entry()
        .await
        .with_context(|| format!("Failed to read directory entry in {:?}", dir))?
    {
        let metadata = entry.metadata()
            .await
            .with_context(|| format!("Failed to read metadata for {:?}", entry.path()))?;

        let entry_path = entry.path();
        let name = entry_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("Unknown")
            .to_string();

        // 处理相对路径
        let relative_path = if let Some(prefix) = path_prefix {
            format!("{}/{}", prefix, name)
        } else {
            entry_path.strip_prefix(dir)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| name.clone())
        };

        // 区分文件和文件夹
        if metadata.is_dir() {
            folders.push((name, relative_path, 0));
        } else {
            files.push((name, relative_path, metadata.len()));
        }
    }

    // 按字母顺序排序
    folders.sort_by(|a, b| a.0.cmp(&b.0));
    files.sort_by(|a, b| a.0.cmp(&b.0));

    Ok((folders, files))
}

// 格式化文件大小
pub fn format_size(size: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if size < KB {
        format!("{} B", size)
    } else if size < MB {
        format!("{:.1} KB", size as f64 / KB as f64)
    } else if size < GB {
        format!("{:.1} MB", size as f64 / MB as f64)
    } else {
        format!("{:.1} GB", size as f64 / GB as f64)
    }
}